import AdrafinilShared
import AppKit
import Foundation
import Observation
import UserNotifications

struct IntegrationChange: Identifiable {
    let id = UUID()
    let integration: String
    let removing: Bool
    let diff: String
}

@MainActor
@Observable
final class MenuModel {
    var status: LeaseServiceStatus?
    var preferences = WakeLeasePreferences()
    var problem: String?
    var information: String?
    var busy = false
    var integrationHealth: [LeaseIntegrationHealth] = []
    var pendingIntegration: IntegrationChange?
    var settingsTab = "general"
    let preview: Bool
    private(set) var previewState: String?
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var editGeneration: UInt64 = 0
    @ObservationIgnored private var lastNotifiedCutout: Date?
    @ObservationIgnored private let client = LeaseSocketClient()

    var presentation: LeasePresentation { LeasePresentation(status: status) }
    var leases: [WakeLease] { status?.snapshot.leases ?? [] }
    var manager: LeaseIntegrationManager { LeaseIntegrationManager(cliPath: ServiceRegistry.bundledCLI.path) }

    init(previewState: String? = nil) {
        preview = previewState != nil
        self.previewState = previewState
        if let previewState { setPreview(previewState) }
        else if let directory = try? SecureDirectory(url: WakeLeasePaths.directory, create: false),
                let saved = try? WakeLeasePreferences.load(from: directory) { preferences = saved }
    }

    func start() {
        guard !preview else { return }
        observer = DistributedNotificationCenter.default().addObserver(forName: Notification.Name(WakeLeaseIdentity.appBundleID + ".statusChanged"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    func refresh() {
        guard !preview else { return }
        if refreshTask != nil { refreshAgain = true; return }
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                self.refreshAgain = false
                let edit = self.editGeneration
                do {
                    let reply = try await self.client.sendAsync(LeaseRequest(operation: "status"))
                    guard reply.ok, let new = reply.status else { throw ServiceRegistry.Failure(message: reply.error?.message ?? "The daemon did not provide status.") }
                    if let current = self.status, current.snapshot.daemonBootID == new.snapshot.daemonBootID, new.snapshot.generation < current.snapshot.generation { continue }
                    self.status = new
                    self.notifyCutoutIfNeeded(new.snapshot.lastCutout)
                    let settings = try await self.client.sendAsync(LeaseRequest(operation: "settings"))
                    if edit == self.editGeneration, self.saveTask == nil, let values = settings.preferences { self.preferences = values }
                } catch { self.status = nil }
            } while self.refreshAgain && !Task.isCancelled
            self.refreshTask = nil
        }
    }

    func perform(_ operation: String, key: String? = nil) {
        guard !preview, !busy else { return }
        busy = true
        problem = nil
        Task { @MainActor in
            defer { busy = false; refresh() }
            do {
                let result = try await client.sendAsync(LeaseRequest(operation: operation, key: key))
                guard result.ok else { throw ServiceRegistry.Failure(message: result.error?.message ?? "The action was refused.") }
                status = result.status
            } catch { problem = error.localizedDescription }
        }
    }

    func changePreferences(_ change: (inout WakeLeasePreferences) -> Void) {
        var updated = preferences
        change(&updated)
        updated = updated.normalized()
        guard updated != preferences else { return }
        preferences = updated
        guard !preview else { return }
        editGeneration &+= 1
        let generation = editGeneration
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(250)) }
            catch { return }
            let desired = preferences
            var request = LeaseRequest(operation: "configure")
            request.preferences = desired
            do {
                let result = try await client.sendAsync(request)
                guard result.ok else { throw ServiceRegistry.Failure(message: result.error?.message ?? "Settings were refused.") }
                if generation == editGeneration, let saved = result.preferences { preferences = saved; information = "Settings applied." }
            } catch {
                if generation == editGeneration {
                    let offline: Bool
                    switch error {
                    case LocalIOError.unavailable, LocalIOError.system(ENOENT): offline = true
                    default: offline = false
                    }
                    if offline {
                        do {
                            try desired.save(to: SecureDirectory(url: WakeLeasePaths.directory, create: true))
                            information = "Saved locally; applies when the daemon starts."
                        } catch { problem = "Could not save settings: " + error.localizedDescription }
                    } else { problem = error.localizedDescription }
                }
            }
            if generation == editGeneration { saveTask = nil }
            refresh()
        }
    }

    func setLogin(_ enabled: Bool) {
        guard !preview else { return }
        Task { @MainActor in
            do {
                try await ServiceRegistry.setLogin(enabled)
                changePreferences { $0.launchMenuAtLogin = enabled }
            } catch { problem = error.localizedDescription }
        }
    }

    func setNotifications(_ enabled: Bool) {
        guard !preview else { return }
        Task { @MainActor in
            do {
                let allowed = enabled ? try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) : true
                guard allowed else { throw ServiceRegistry.Failure(message: "Notifications were not authorized. You can change this in System Settings.") }
                changePreferences { $0.notifySafety = enabled }
            } catch { problem = error.localizedDescription }
        }
    }

    func installServices() {
        guard !preview, !busy else { return }
        problem = nil
        busy = true
        defer { busy = false }
        do { information = try ServiceRegistry.install(preferences: preferences); refresh() }
        catch { problem = error.localizedDescription }
    }

    func refreshIntegrations() {
        guard !preview else { return }
        let manager = manager
        Task { @MainActor in
            integrationHealth = await Task.detached { LeaseIntegrations.all.map { manager.health($0.id) } }.value
        }
    }

    func previewIntegration(_ id: String, removing: Bool) {
        guard !preview, !busy else { return }
        busy = true
        problem = nil
        let manager = manager
        Task { @MainActor in
            defer { busy = false }
            do {
                let result = try await Task.detached { try removing ? manager.uninstall(id, dryRun: true) : manager.install(id, dryRun: true) }.value
                if result.changed { pendingIntegration = IntegrationChange(integration: id, removing: removing, diff: result.diff) }
                else { information = "No integration changes needed." }
            } catch { problem = error.localizedDescription }
        }
    }

    func applyIntegration(_ change: IntegrationChange) {
        guard !preview else { return }
        let manager = manager
        busy = true
        pendingIntegration = nil
        Task { @MainActor in
            defer { busy = false; refreshIntegrations() }
            do {
                _ = try await Task.detached { try change.removing ? manager.uninstall(change.integration) : manager.install(change.integration) }.value
                information = change.removing ? "Integration removed; backups retained." : "Integration configured. Check any approval requirements in the host."
            } catch { problem = error.localizedDescription }
        }
    }

    func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }

    private func notifyCutoutIfNeeded(_ event: LeaseEvent?) {
        guard preferences.notifySafety, !preview, let event, event.at != lastNotifiedCutout else { return }
        lastNotifiedCutout = event.at
        let content = UNMutableNotificationContent()
        content.title = "WakeLease safety cutoff"
        content.body = event.kind == .thermalCutout ? "Wake leases were released because of thermal conditions." : "Wake leases were released to protect the battery."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "wakelease-safety", content: content, trigger: nil))
    }

    func setPreview(_ name: String) {
        previewState = name
        let now = Date()
        var book = LeaseBook(bootID: "preview")
        if ["active", "waiting", "cutout"].contains(name) {
            _ = try? book.acquire(LeaseProposal(key: "preview:tests", source: "codex", reason: "Integration test suite"), at: LeaseTime(wall: now.addingTimeInterval(-1080), continuous: 1000))
        }
        if name == "active" {
            _ = try? book.acquire(LeaseProposal(key: "preview:build", source: "build", ttlSeconds: 900, reason: "Release build"), at: LeaseTime(wall: now.addingTimeInterval(-120), continuous: 1960))
        }
        _ = book.updateSafety(LeaseSafety(lidClosed: name != "normal", externalDisplayConnected: false, batteryPercent: 84, onBattery: false, temperatureCelsius: 62, thermalState: .nominal), at: LeaseTime(wall: now, continuous: 2080))
        if name == "waiting" { _ = try? book.wait(key: "preview:tests", at: LeaseTime(wall: now, continuous: 2080)) }
        if name == "cutout" { _ = book.updateSafety(LeaseSafety(lidClosed: true, temperatureCelsius: 91, thermalState: .serious), at: LeaseTime(wall: now, continuous: 2080)) }
        if name == "paused" { _ = book.setPaused(true, at: LeaseTime(wall: now, continuous: 2080)) }
        status = LeaseServiceStatus(mode: "system", snapshot: LeaseSnapshot(book: book, daemonBootID: UUID()), power: LeasePowerReport(applied: book.demand, helperConnected: true))
    }

    isolated deinit {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        refreshTask?.cancel()
        saveTask?.cancel()
    }
}
