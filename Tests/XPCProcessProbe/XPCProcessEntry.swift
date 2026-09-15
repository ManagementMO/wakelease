import AdrafinilShared
import Darwin
import Foundation
import os
import Security

private struct ProbeFailure: Error, LocalizedError {
    let message: String
    var errorDescription: String? {
        message
    }
}

private struct ProbeContext: Sendable {
    let root: URL
    let scenario: String
    let isService: Bool
    var app: URL {
        root.appendingPathComponent("Client.app")
    }
    var service: URL {
        app.appendingPathComponent("Contents/XPCServices/Probe.xpc")
    }
    var journal: URL {
        root.appendingPathComponent("events.json")
    }

    init() throws {
        guard getuid() != 0,
              let path = Bundle.main.object(forInfoDictionaryKey: "WakeLeaseFixtureRoot") as? String,
              let scenario = Bundle.main.object(forInfoDictionaryKey: "WakeLeaseProbeMode") as? String,
              ["valid", "listener-role", "listener-hash", "server-role", "server-hash"].contains(scenario) else {
            throw ProbeFailure(message: "Missing remote fixture context")
        }
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        guard root.lastPathComponent.hasPrefix("wakelease-xpc-process-"),
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let permissions = attributes[.posixPermissions] as? NSNumber, permissions.uint32Value & 0o077 == 0 else {
            throw ProbeFailure(message: "Fixture directory is not private and owned")
        }
        self.root = root
        self.scenario = scenario
        isService = Bundle.main.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "XPC!"
        guard Bundle.main.bundleURL.resolvingSymlinksInPath() == (isService ? service : app).resolvingSymlinksInPath() else {
            throw ProbeFailure(message: "Executable is outside the owned fixture bundle")
        }
    }

    func requirement(at url: URL, identifier: String, wrongHash: Bool) throws -> String {
        var code: SecStaticCode?
        var information: CFDictionary?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any], let digest = values[kSecCodeInfoUnique as String] as? Data else {
            throw ProbeFailure(message: "Fixture component lacks a valid code signature")
        }
        let zero = String(repeating: "0", count: 40)
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        var hashes = Dictionary(uniqueKeysWithValues: [WakeLeaseIdentity.appBundleID, WakeLeaseIdentity.cliBundleID, WakeLeaseIdentity.daemonBundleID, WakeLeaseIdentity.helperBundleID].map { ($0, [zero]) })
        hashes[identifier] = [wrongHash ? zero : hash]
        let object: [String: Any] = ["version": 1, "build": zero, "hashes": hashes]
        let data = try JSONSerialization.data(withJSONObject: object)
        let record = try JSONDecoder().decode(InstalledComponentTrust.self, from: data)
        guard let requirement = record.requirement(identifier: identifier) else { throw ProbeFailure(message: "Invalid component-pin requirement") }
        return requirement
    }
}

@objc
private protocol ProcessEchoProtocol {
    func echo(_ value: String, reply: @escaping @Sendable (String, Int32, UInt32) -> Void)
}

private struct ProcessMetrics: Codable, Sendable {
    let serverPID: Int32
    let serverUID: UInt32
    var accepted = 0
    var calls = 0
}

private final class ProcessEchoServer: NSObject, NSXPCListenerDelegate, ProcessEchoProtocol, @unchecked Sendable {
    let context: ProbeContext
    let state: OSAllocatedUnfairLock<ProcessMetrics>

    init(context: ProbeContext) throws {
        self.context = context
        state = OSAllocatedUnfairLock(initialState: ProcessMetrics(serverPID: getpid(), serverUID: getuid()))
        super.init()
        try JSONEncoder().encode(state.withLock { $0 }).write(to: context.journal, options: .atomic)
    }

    private func record(_ change: (inout ProcessMetrics) -> Void) {
        state.withLock { metrics in
            change(&metrics)
            do {
                try JSONEncoder().encode(metrics).write(to: context.journal, options: .atomic)
            } catch {
                FileHandle.standardError.write(Data("Cannot write owned XPC fixture evidence\n".utf8))
                exit(1)
            }
        }
    }

    func listener(_: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == getuid() else { return false }
        record { $0.accepted += 1 }
        connection.exportedInterface = NSXPCInterface(with: ProcessEchoProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func echo(_ value: String, reply: @escaping @Sendable (String, Int32, UInt32) -> Void) {
        record { $0.calls += 1 }
        reply(value, getpid(), getuid())
    }

    @MainActor
    static func serve(_ context: ProbeContext) throws {
        let server = try ProcessEchoServer(context: context)
        let identifier = context.scenario == "listener-role" ? WakeLeaseIdentity.daemonBundleID : WakeLeaseIdentity.appBundleID
        let requirement = try context.requirement(at: context.app, identifier: identifier, wrongHash: context.scenario == "listener-hash")
        let listener = NSXPCListener.service()
        listener.delegate = server
        listener.setConnectionCodeSigningRequirement(requirement)
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) { exit(0) }
        withExtendedLifetime(server) {
            listener.resume()
            RunLoop.current.run()
        }
        throw ProbeFailure(message: "XPC service listener returned unexpectedly")
    }
}

private enum ProcessOutcome: Sendable {
    case reply(String, Int32, UInt32)
    case rejected(Int)
    case timedOut
    case proxyUnavailable
}

@MainActor
private func runClient(_ context: ProbeContext) async throws -> [String: Any] {
    let identifier = context.scenario == "server-role" ? WakeLeaseIdentity.daemonBundleID : WakeLeaseIdentity.helperBundleID
    let requirement = try context.requirement(at: context.service, identifier: identifier, wrongHash: context.scenario == "server-hash")
    let connection = NSXPCConnection(serviceName: WakeLeaseIdentity.helperBundleID)
    connection.remoteObjectInterface = NSXPCInterface(with: ProcessEchoProtocol.self)
    connection.setCodeSigningRequirement(requirement)
    defer { connection.invalidate() }
    let outcome = await withCheckedContinuation { continuation in
        let once = OnceResumer<ProcessOutcome> { continuation.resume(returning: $0) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) { once.resume(.timedOut) }
        connection.resume()
        let failure: @Sendable (any Error) -> Void = { once.resume(.rejected(($0 as NSError).code)) }
        guard let proxy = connection.remoteObjectProxyWithErrorHandler(failure) as? ProcessEchoProtocol else {
            once.resume(.proxyUnavailable)
            return
        }
        proxy.echo("owned-cross-process-ping") { once.resume(.reply($0, $1, $2)) }
    }
    let metrics = (try? JSONDecoder().decode(ProcessMetrics.self, from: Data(contentsOf: context.journal))) ?? ProcessMetrics(serverPID: 0, serverUID: 0)
    let label: String
    var matched = false
    var errorCode = 0
    switch outcome {
    case let .reply(value, pid, uid):
        label = "reply"
        matched = value == "owned-cross-process-ping" && pid != getpid() && pid > 0 && uid == getuid()
            && connection.processIdentifier == pid && connection.effectiveUserIdentifier == uid && metrics.serverPID == pid
    case let .rejected(code): label = "rejected"; errorCode = code
    case .timedOut: label = "timed-out"
    case .proxyUnavailable: label = "proxy-unavailable"
    }
    return [
        "scope": "owned cross-process XPC; no power or persistent registration",
        "scenario": context.scenario,
        "outcome": label,
        "clientPID": getpid(),
        "serverPID": metrics.serverPID,
        "serverUID": metrics.serverUID,
        "accepted": metrics.accepted,
        "calls": metrics.calls,
        "peerIdentityMatched": matched,
        "errorCode": errorCode,
    ]
}

@main
enum XPCProcessEntry {
    @MainActor
    static func main() async {
        do {
            let context = try ProbeContext()
            if context.isService {
                try ProcessEchoServer.serve(context)
            } else {
                guard ProcessInfo.processInfo.environment["CI"] == "true",
                      ProcessInfo.processInfo.environment["WAKELEASE_XPC_PROCESS_FIXTURE"] == "1",
                      Array(CommandLine.arguments.dropFirst()) == [context.scenario] else {
                    throw ProbeFailure(message: "Cross-process verification is remote-only")
                }
                let report = try await runClient(context)
                let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
                FileHandle.standardOutput.write(data + Data("\n".utf8))
            }
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
