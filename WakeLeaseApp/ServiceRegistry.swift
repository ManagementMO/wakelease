import AdrafinilShared
import Darwin
import Foundation
import Security
import ServiceManagement

@MainActor
enum ServiceRegistry {
    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? {
            message
        }
    }

    static var bundledCLI: URL {
        if isPackaged { return Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/" + WakeLeaseIdentity.cliBinaryName) }
        return (Bundle.main.executableURL?.deletingLastPathComponent() ?? Bundle.main.bundleURL).appendingPathComponent(WakeLeaseIdentity.cliBinaryName)
    }
    static var isPackaged: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier == WakeLeaseIdentity.appBundleID
    }
    static var canInstall: Bool {
        isPackaged && ComponentTrust.hasRuntimeIdentity
    }

    static func statuses() -> [String: String] {
        [
            "Daemon": name(SMAppService.agent(plistName: "LaunchAgent.plist").status),
            "Helper": name(SMAppService.daemon(plistName: "LaunchDaemon.plist").status),
            "Menu at login": name(SMAppService.mainApp.status),
        ]
    }

    static func install(preferences: WakeLeasePreferences) async throws -> String {
        guard canInstall else { throw Failure(message: "Run the WakeLease installer from the DMG before enabling services, or use a matching team-signed bundle. Uninstalled development uses simulation.") }
        let lock = try SecureDirectory(url: WakeLeasePaths.standardDirectory, create: true).lock(name: "maintenance.lock")
        defer { SecureDirectory.closeLock(lock) }
        let bundle = Bundle.main.bundleURL
        try verify(bundle, role: .app)
        try verify(bundledCLI, role: .cli)
        try verify(bundle.appendingPathComponent("Contents/Library/LaunchAgents/WakeLeaseDaemon"), role: .daemon)
        try verify(bundle.appendingPathComponent("Contents/Library/LaunchDaemons/WakeLeaseHelper"), role: .helper)
        let helper = SMAppService.daemon(plistName: "LaunchDaemon.plist")
        let daemon = SMAppService.agent(plistName: "LaunchAgent.plist")
        for service in [helper, daemon] where service.status == .notRegistered || service.status == .notFound {
            do {
                try service.register()
            } catch {
                guard ServiceRegistrationPolicy.isPendingApproval(error: error, requiresApproval: service.status == .requiresApproval) else { throw error }
            }
        }
        if preferences.launchMenuAtLogin, SMAppService.mainApp.status == .notRegistered { try SMAppService.mainApp.register() }
        try CLILinkManager(stateDirectory: WakeLeasePaths.standardDirectory).install(target: bundledCLI)
        if helper.status == .requiresApproval || daemon.status == .requiresApproval {
            return "Approve WakeLease in System Settings → General → Login Items & Extensions, then refresh."
        }
        let maintenance = HelperMaintenanceClient()
        if let pending = try await maintenance.current() { try await maintenance.cancel(pending.id) }
        return "Services registered; any removal reservation owned by this user was restored. Confirm daemon/helper status and resume explicitly if paused."
    }

    static func setLogin(_ enabled: Bool) async throws {
        guard isPackaged else { throw Failure(message: "Login registration requires the packaged app.") }
        if enabled {
            if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            guard SMAppService.mainApp.status == .enabled else { throw Failure(message: "Login item approval is still required in System Settings.") }
        } else if SMAppService.mainApp.status != .notRegistered { try await SMAppService.mainApp.unregister() }
    }

    static func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private static func verify(_ url: URL, role: ComponentTrust.Role) throws {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard let text = ComponentTrust.requirement(role: role),
              SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else {
            throw Failure(message: "A bundled component failed signature or role validation. Rebuild or reinstall a matching signed bundle.")
        }
    }

    private static func name(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: "Enabled"
        case .requiresApproval: "Needs approval"
        case .notRegistered: "Not registered"
        case .notFound: "Not found in this bundle"
        @unknown default: "Unknown"
        }
    }
}
