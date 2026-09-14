import AdrafinilShared
import AppKit
import Darwin
import Foundation
import ServiceManagement

@MainActor
final class AppUninstallEnvironment: UninstallEnvironment {
    private let directory = WakeLeasePaths.standardDirectory
    private var confirmed = false
    private let maintenance = HelperMaintenanceClient()
    private var reservation: HelperRemovalReservation?
    private var maintenanceLock: Int32?

    isolated deinit { if let maintenanceLock { Darwin.close(maintenanceLock) } }

    func pauseAndVerifySleepAllowed() async throws {
        guard ServiceRegistry.isPackaged else { throw ServiceRegistry.Failure(message: "Uninstall services from the packaged app that owns their registration.") }
        guard maintenanceLock == nil else { throw LocalIOError.alreadyRunning }
        maintenanceLock = try SecureDirectory(url: directory, create: true).lock(name: "maintenance.lock")
        let helper = SMAppService.daemon(plistName: "LaunchDaemon.plist")
        let daemon = SMAppService.agent(plistName: "LaunchAgent.plist")
        guard helper.status != .notFound, daemon.status != .notFound else { throw ServiceRegistry.Failure(message: "The bundle is incomplete. Restore a matching app before removing its registered services.") }
        if helper.status == .enabled || daemon.status == .enabled {
            let pending = try await maintenance.current() ?? HelperRemovalReservation(id: UUID(), uid: getuid())
            reservation = pending
            try await maintenance.reserve(pending.id)
        }
        if daemon.status == .enabled {
            let response = try await LeaseSocketClient(directory: directory, timeout: 20).sendAsync(LeaseRequest(operation: "pause"))
            guard response.ok, let status = response.status, status.mode == "system", status.snapshot.paused,
                  !status.snapshot.demand.system, status.power.applied?.system == false,
                  status.power.globalBlocked == false, status.power.error == nil else {
                throw ServiceRegistry.Failure(message: "Sleep cleanup is unconfirmed, or another user's wake claim remains. Services were not removed. Run doctor and resolve this before retrying.")
            }
        }
        let disabled = try await Task.detached { try PowerManagementInspector.readSleepDisabled() }.value
        guard disabled == false else { throw ServiceRegistry.Failure(message: "SleepDisabled is not confirmed OFF. Recovery mechanisms were retained; review other wake utilities and run doctor.") }
        confirmed = true
    }

    func removeOwnedIntegrations() async throws {
        guard confirmed else { throw ServiceRegistry.Failure(message: "Cleanup must be confirmed first.") }
        let manager = LeaseIntegrationManager(stateDirectory: directory, cliPath: ServiceRegistry.bundledCLI.path)
        try await Task.detached {
            for integration in LeaseIntegrations.all {
                _ = try manager.uninstall(integration.id)
            }
        }.value
    }

    func unregisterServices() async throws {
        guard confirmed else { throw ServiceRegistry.Failure(message: "Cleanup must be confirmed first.") }
        for service in [SMAppService.agent(plistName: "LaunchAgent.plist"), SMAppService.daemon(plistName: "LaunchDaemon.plist"), SMAppService.mainApp] {
            if service.status != .notRegistered, service.status != .notFound { try await service.unregister() }
        }
    }

    func removeOwnedCLI() async throws {
        try CLILinkManager(stateDirectory: directory).uninstall()
    }

    func cancelPendingRemoval() async throws {
        guard let reservation else { return }
        if SMAppService.daemon(plistName: "LaunchDaemon.plist").status == .notRegistered {
            try HelperRemovalStore().remove(reservation)
        } else if let current = try await maintenance.current() {
            guard current == reservation else { throw HelperRemovalFailure.invalidReservation }
            try await maintenance.cancel(reservation.id)
        }
        self.reservation = nil
        confirmed = false
    }

    func cleanOwnedState(purge: Bool) async throws {
        guard confirmed, SMAppService.daemon(plistName: "LaunchDaemon.plist").status == .notRegistered else { throw HelperRemovalFailure.reserved }
        if let reservation {
            try HelperRemovalStore().remove(reservation)
            self.reservation = nil
        }
        let state: SecureDirectory
        do { state = try SecureDirectory(url: directory, create: false) }
        catch LocalIOError.system(ENOENT) { return }
        let files = ["leases.json", "daemon.lock", "cli-install.lock"] + (purge ? [WakeLeaseIdentity.configFilename, "events.log"] : [])
        for name in files {
            if let data = try state.read(name: name) { try state.remove(name: name, matching: data) }
        }
        try state.removeSocket(name: WakeLeaseIdentity.cliSocketFilename)
        if purge {
            let url = directory.appendingPathComponent("integrations")
            do {
                let integrations = try SecureDirectory(url: url, create: false)
                for name in try FileManager.default.contentsOfDirectory(atPath: url.path) {
                    let backup = name.range(of: "^backup-[0-9A-Fa-f-]{36}[.]bin$", options: .regularExpression) != nil
                    if backup || name == "install.lock" {
                        if let data = try integrations.read(name: name) { try integrations.remove(name: name, matching: data) }
                    }
                }
                try state.removeEmptyDirectory(name: "integrations")
            } catch LocalIOError.system(ENOENT) {}
            if let identifier = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: identifier) }
        }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: WakeLeaseIdentity.appBundleID) where app.processIdentifier != getpid() && app.bundleURL == Bundle.main.bundleURL {
            app.terminate()
        }
    }
}
