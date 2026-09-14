import AdrafinilShared
import Foundation
import os
import Security

@objc
private protocol BoundaryEchoProtocol {
    func echo(_ value: String, reply: @escaping @Sendable (String) -> Void)
}

private final class BoundaryEchoServer: NSObject, NSXPCListenerDelegate, BoundaryEchoProtocol, @unchecked Sendable {
    struct State: Sendable {
        var accepted = 0
        var calls = 0
    }
    let state = OSAllocatedUnfairLock(initialState: State())

    func listener(_: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        state.withLock { $0.accepted += 1 }
        connection.exportedInterface = NSXPCInterface(with: BoundaryEchoProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func echo(_ value: String, reply: @escaping @Sendable (String) -> Void) {
        state.withLock { $0.calls += 1 }
        reply(value)
    }
}

@MainActor
struct XPCBoundaryProbe {
    private struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? {
            message
        }
    }

    private func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message: message) }
    }
    private enum Outcome: Sendable, Equatable {
        case reply(String)
        case rejected(Int)
        case timedOut
        case proxyUnavailable

        var isRejected: Bool {
            if case .rejected = self { return true }
            return false
        }
    }

    private func selfRequirement() throws -> String {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        var text: CFString?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else {
            throw Failure(message: "The owned probe must have a valid ad-hoc signature before execution.")
        }
        return text as String
    }

    private func roundTrip(listenerRequirement: String, clientRequirement: String) async -> (Outcome, Int, Int) {
        let server = BoundaryEchoServer()
        let listener = NSXPCListener.anonymous()
        listener.delegate = server
        listener.setConnectionCodeSigningRequirement(listenerRequirement)
        listener.resume()
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        defer { connection.invalidate(); listener.invalidate() }
        connection.remoteObjectInterface = NSXPCInterface(with: BoundaryEchoProtocol.self)
        connection.setCodeSigningRequirement(clientRequirement)
        let outcome = await withCheckedContinuation { continuation in
            let once = OnceResumer<Outcome> { continuation.resume(returning: $0) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { once.resume(.timedOut) }
            connection.resume()
            let failure: @Sendable (any Error) -> Void = { error in once.resume(.rejected((error as NSError).code)) }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler(failure) as? BoundaryEchoProtocol else { once.resume(.proxyUnavailable); return }
            proxy.echo("owned-test-peer") { once.resume(.reply($0)) }
        }
        return server.state.withLock { (outcome, $0.accepted, $0.calls) }
    }

    func run() async throws {
        let own = try selfRequirement()
        let accepted = await roundTrip(listenerRequirement: own, clientRequirement: own)
        try check(accepted.0 == .reply("owned-test-peer") && accepted.1 == 1 && accepted.2 == 1, "Positive XPC control failed: \(accepted)")
        for role in [ComponentTrust.Role.app, .daemon, .helper] {
            guard let production = ComponentTrust.requirement(team: "TESTTEAM01", role: role) else { throw Failure(message: "Missing production role requirement") }
            let rejected = await roundTrip(listenerRequirement: production, clientRequirement: own)
            try check(rejected.0.isRejected && rejected.1 == 0 && rejected.2 == 0, "Listener admitted the wrong identity for \(role): \(rejected)")
        }
        guard let helper = ComponentTrust.requirement(team: "TESTTEAM01", role: .helper) else { throw Failure(message: "Missing helper requirement") }
        let reply = await roundTrip(listenerRequirement: own, clientRequirement: helper)
        try check(reply.0.isRejected && reply.2 <= 1, "Client accepted an untrusted reply: \(reply)")
    }
}
