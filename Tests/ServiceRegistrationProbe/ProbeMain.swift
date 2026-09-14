import AppKit
import Foundation
import ServiceManagement

@MainActor
private final class ProbeDelegate: NSObject, NSApplicationDelegate {
    let output: URL
    let cleanupOnly: Bool

    init(output: URL, cleanupOnly: Bool) {
        self.output = output
        self.cleanupOnly = cleanupOnly
    }

    func applicationDidFinishLaunching(_: Notification) {
        Task { @MainActor in
            var observations: [[String: Any]] = []
            var clean = true
            for (kind, service) in [("agent", SMAppService.agent(plistName: "ProbeAgent.plist")), ("daemon", SMAppService.daemon(plistName: "ProbeDaemon.plist"))] {
                var result: [String: Any] = ["kind": kind, "before": service.status.rawValue]
                if !cleanupOnly {
                    do { try service.register(); result["registerReturned"] = true }
                    catch {
                        let error = error as NSError
                        result["registrationError"] = ["domain": error.domain, "code": error.code, "message": error.localizedDescription]
                    }
                }
                result["afterRegistration"] = service.status.rawValue
                if service.status != .notRegistered, service.status != .notFound {
                    do { try await service.unregister() }
                    catch {
                        let error = error as NSError
                        result["cleanupError"] = ["domain": error.domain, "code": error.code, "message": error.localizedDescription]
                    }
                }
                result["afterCleanup"] = service.status.rawValue
                clean = clean && (service.status == .notRegistered || service.status == .notFound)
                observations.append(result)
            }
            let report: [String: Any] = [
                "scope": "approved disposable CI only; no power operations",
                "bundleIdentifier": Bundle.main.bundleIdentifier ?? "",
                "cleanupOnly": cleanupOnly,
                "cleanupOK": clean,
                "services": observations,
            ]
            do {
                let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: output, options: .withoutOverwriting)
            } catch {
                FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
                exit(1)
            }
            if !clean { exit(1) }
            NSApp.terminate(nil)
        }
    }
}

@main
private enum RegistrationProbe {
    @MainActor
    static func main() {
        let environment = ProcessInfo.processInfo.environment
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard environment["CI"] == "true", environment["WAKELEASE_REGISTRATION_PROBE"] == "approved-disposable-runner",
              let temporary = environment["RUNNER_TEMP"], !temporary.isEmpty, getuid() != 0,
              arguments.count == 2, ["probe", "cleanup"].contains(arguments[0]), arguments[1].hasPrefix("/"),
              Bundle.main.bundleIdentifier?.hasPrefix("org.wakelease.registration-probe.") == true else { exit(78) }
        let root = URL(fileURLWithPath: temporary, isDirectory: true).resolvingSymlinksInPath().path + "/"
        let output = URL(fileURLWithPath: arguments[1])
        guard Bundle.main.bundleURL.resolvingSymlinksInPath().path.hasPrefix(root),
              output.deletingLastPathComponent().resolvingSymlinksInPath().path.hasPrefix(root) else { exit(78) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 45) { exit(70) }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let delegate = ProbeDelegate(output: output, cleanupOnly: arguments[0] == "cleanup")
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
