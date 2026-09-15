import AppKit
import Darwin
import Foundation
import ServiceManagement

private enum ProbeMode: String {
    /// Register both dummy services, then unregister them in the same run (existing disposable-CI measurement).
    case probe
    /// Register both dummy services and leave them pending so System Settings approval can be exercised.
    case register
    /// Register only the dummy LaunchAgent, isolating user-level approval from the administrator daemon prompt.
    case registerAgent = "register-agent"
    /// Report the current statuses without changing anything.
    case status
    /// Unregister whatever is still registered.
    case cleanup
}

@MainActor
private final class ProbeDelegate: NSObject, NSApplicationDelegate {
    let output: URL
    let mode: ProbeMode

    init(output: URL, mode: ProbeMode) {
        self.output = output
        self.mode = mode
    }

    func applicationDidFinishLaunching(_: Notification) {
        Task { @MainActor in
            var observations: [[String: Any]] = []
            var clean = true
            for (kind, service) in [("agent", SMAppService.agent(plistName: "ProbeAgent.plist")), ("daemon", SMAppService.daemon(plistName: "ProbeDaemon.plist"))] {
                var result: [String: Any] = ["kind": kind, "before": service.status.rawValue]
                if mode == .probe || mode == .register || (mode == .registerAgent && kind == "agent") {
                    do { try service.register(); result["registerReturned"] = true }
                    catch {
                        let error = error as NSError
                        result["registrationError"] = ["domain": error.domain, "code": error.code, "message": error.localizedDescription]
                    }
                }
                result["afterRegistration"] = service.status.rawValue
                if mode == .probe || mode == .cleanup, service.status != .notRegistered, service.status != .notFound {
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
                "scope": "approved disposable CI or Devin Cloud Mac only; no power operations",
                "bundleIdentifier": Bundle.main.bundleIdentifier ?? "",
                "mode": mode.rawValue,
                "cleanupOnly": mode == .cleanup,
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
            if mode == .probe || mode == .cleanup, !clean { exit(1) }
            NSApp.terminate(nil)
        }
    }
}

@main
private enum RegistrationProbe {
    /// Returns the disposable temporary root that must contain both the bundle and the report, or nil when this
    /// process is not on an approved disposable host.
    static func disposableRoot(_ environment: [String: String]) -> String? {
        switch environment["WAKELEASE_REGISTRATION_PROBE"] {
        case "approved-disposable-runner":
            guard environment["CI"] == "true" else { return nil }
            return environment["RUNNER_TEMP"]
        case "approved-disposable-vm":
            var present: Int32 = 0
            var size = MemoryLayout<Int32>.size
            guard sysctlbyname("kern.hv_vmm_present", &present, &size, nil, 0) == 0, present == 1 else { return nil }
            return environment["WAKELEASE_PROBE_TEMP"]
        default:
            return nil
        }
    }

    @MainActor
    static func main() {
        let environment = ProcessInfo.processInfo.environment
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let temporary = disposableRoot(environment), !temporary.isEmpty, getuid() != 0,
              arguments.count == 2, let mode = ProbeMode(rawValue: arguments[0]), arguments[1].hasPrefix("/"),
              Bundle.main.bundleIdentifier?.hasPrefix("org.wakelease.registration-probe.") == true else { exit(78) }
        let root = URL(fileURLWithPath: temporary, isDirectory: true).resolvingSymlinksInPath().path + "/"
        let output = URL(fileURLWithPath: arguments[1])
        guard Bundle.main.bundleURL.resolvingSymlinksInPath().path.hasPrefix(root),
              output.deletingLastPathComponent().resolvingSymlinksInPath().path.hasPrefix(root) else { exit(78) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 45) { exit(70) }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let delegate = ProbeDelegate(output: output, mode: mode)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
