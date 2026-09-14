import Darwin
import Foundation

public struct DoctorCheck: Codable, Sendable {
    public enum Level: String, Codable, Sendable { case success, warning, failure, skipped }
    public let id: String
    public let level: Level
    public let message: String
    public init(_ id: String, _ level: Level, _ message: String) {
        self.id = id; self.level = level; self.message = message
    }
}

public struct DoctorReport: Codable, Sendable {
    public let version: Int
    public let productVersion: String
    public let mode: String
    public let checks: [DoctorCheck]
    public var hasFailures: Bool {
        checks.contains { $0.level == .failure }
    }
}

public enum LeaseDiagnostics {
    public static func powerChecks(status: LeaseServiceStatus?, sleepDisabled: Bool?) -> [DoctorCheck] {
        var checks = [DoctorCheck("daemon", status == nil ? .failure : .success, status == nil ? "Daemon unavailable. Open the packaged app and enable its services." : "Daemon reachable over the user-scoped socket.")]
        if status?.mode == "simulation" {
            checks.append(DoctorCheck("powerControl", .skipped, "Simulation: no privileged helper or actual power protection is exercised."))
            return checks
        }
        if let status {
            let confirmed = status.power.helperConnected && status.power.error == nil && status.power.applied == status.snapshot.demand
            checks.append(DoctorCheck("powerControl", confirmed ? .success : .failure, confirmed ? "The authenticated helper reports this user's requested power state applied." : "Protection is unconfirmed. Check Login Items approval, signatures and matching component versions."))
            if !status.snapshot.cutouts.isEmpty { checks.append(DoctorCheck("cutout", .warning, "A safety latch is active: " + status.snapshot.cutouts.map(\.rawValue).sorted().joined(separator: ", "))) }
        }
        if let sleepDisabled {
            let mismatch = sleepDisabled && (status == nil || (status?.snapshot.demand.system == false && status?.power.globalBlocked != true))
                || (!sleepDisabled && status?.snapshot.demand.system == true)
            checks.append(DoctorCheck("sleepOverride", mismatch ? .failure : .success, "SleepDisabled is \(sleepDisabled ? 1 : 0)." + (mismatch ? " Ownership/state does not agree with the reachable broker. Review other wake utilities before any manual reset." : "")))
        } else {
            checks.append(DoctorCheck("sleepOverride", .warning, "Could not read SleepDisabled. No power setting was changed."))
        }
        return checks
    }

    public static func collect(directory: URL = WakeLeasePaths.directory, home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true), cliPath: String) -> DoctorReport {
        let client = LeaseSocketClient(directory: directory)
        let reply = try? client.send(LeaseRequest(operation: "doctor"))
        let status = reply?.ok == true ? reply?.status : nil
        let observed = status?.mode == "simulation" ? nil : (try? PowerManagementInspector.readSleepDisabled())
        var checks = powerChecks(status: status, sleepDisabled: observed)
        do {
            let storage = try SecureDirectory(url: directory, create: false)
            _ = try WakeLeasePreferences.load(from: storage)
            checks.append(DoctorCheck("permissions", .success, "State directory is owned/private and does not traverse unapproved symlinks."))
            checks.append(DoctorCheck("preferences", .success, "Preferences parse and normalize within safety bounds."))
        } catch {
            checks.append(DoctorCheck("permissionsAndPreferences", .failure, "State directory or preferences are missing, malformed or unsafe. Review the local configuration before enabling services."))
        }
        if let status {
            checks.append(DoctorCheck("version", status.version == WakeLeaseIdentity.marketingVersion ? .success : .failure, "CLI \(WakeLeaseIdentity.marketingVersion); daemon \(status.version). Reinstall matching components if different."))
        }
        checks.append(DoctorCheck("cliLink", .warning, CLILinkManager(home: home, stateDirectory: directory).inspect() + ". Human CLI links are separate from the stable bundled paths used by hooks."))
        let manager = LeaseIntegrationManager(home: home, stateDirectory: directory, cliPath: cliPath)
        for integration in LeaseIntegrations.all {
            let health = manager.health(integration.id)
            let level: DoctorCheck.Level = health.state == "modifiedOrUnreadable" || health.state == "missingExecutable" ? .failure : (health.state == "configured" ? .success : .warning)
            checks.append(DoctorCheck("integration." + integration.id, level, health.state + ": " + health.note))
        }
        if status?.mode != "simulation" {
            do {
                let pending = try HelperRemovalStore().load()
                checks.append(DoctorCheck("helperRemoval", pending == nil ? .success : .failure, pending == nil ? "No persisted helper removal reservation." : "Helper removal is pending. Finish uninstall or enable services from the owning app to restore admission; resume the broker explicitly afterward."))
            } catch {
                checks.append(DoctorCheck("helperRemoval", .failure, "Helper removal state is unreadable or unsafe, or belongs to another user. Ask the owning user to finish/restore it; do not delete a live reservation."))
            }
            for (id, service) in [("launchAgent", "gui/\(getuid())/" + WakeLeaseIdentity.daemonBundleID), ("launchDaemon", "system/" + WakeLeaseIdentity.helperBundleID)] {
                let result = try? BoundedProcess.run(arguments: ["/bin/launchctl", "print", service], timeout: 2)
                checks.append(DoctorCheck(id, result?.status == 0 ? .success : .warning, result?.status == 0 ? "Service is registered with launchd." : "Service was not visible to launchctl. Enable it from the packaged app; do not reset system-wide launch records."))
            }
        }
        if let bundle = applicationBundle(containing: URL(fileURLWithPath: cliPath)) {
            let helper = bundle.appendingPathComponent("Contents/Library/LaunchDaemons/WakeLeaseHelper")
            let daemon = bundle.appendingPathComponent("Contents/Library/LaunchAgents/WakeLeaseDaemon")
            let present = FileManager.default.isExecutableFile(atPath: helper.path) && FileManager.default.isExecutableFile(atPath: daemon.path)
            checks.append(DoctorCheck("bundle", present ? .success : .failure, present ? "Bundled daemon and helper executables are present." : "The bundle is incomplete; rebuild or reinstall it."))
            checks.append(DoctorCheck("signature", ComponentTrust.currentTeam == nil ? .warning : .success, ComponentTrust.currentTeam == nil ? "This CLI has no verified Apple-issued team. Development builds cannot operate the privileged helper." : "CLI has an Apple-anchored team signature; the daemon additionally pins the helper's role and team."))
        } else {
            checks.append(DoctorCheck("bundle", .warning, "CLI is outside an application bundle. Use a packaged app for production service installation."))
        }
        checks.append(DoctorCheck("hardware", .skipped, "Doctor is read-only. It does not certify closed-lid behavior, initiate sleep, install services or repair global settings."))
        return DoctorReport(version: 1, productVersion: WakeLeaseIdentity.marketingVersion, mode: status?.mode ?? "unavailable", checks: checks)
    }

    public static func applicationBundle(containing executable: URL) -> URL? {
        var current = executable.deletingLastPathComponent()
        for _ in 0 ..< 8 {
            if current.pathExtension == "app", Bundle(url: current)?.bundleIdentifier == WakeLeaseIdentity.appBundleID { return current }
            let parent = current.deletingLastPathComponent()
            if parent == current { break }
            current = parent
        }
        return nil
    }
}
