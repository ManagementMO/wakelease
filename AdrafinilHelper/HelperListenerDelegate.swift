import AdrafinilShared
import Foundation
import os
import OSLog

final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let log = Logger(subsystem: AdrafinilConstants.helperBundleID, category: "Listener")

    /// One process-wide blocker, shared by every connection's service. Keeping the sleep-blocking
    /// state here (not per `HelperXPCService`) means a daemon reconnect reuses the live assertion
    /// instead of orphaning it — see `SleepBlocker`.
    let blocker: SleepBlocker

    /// Records the helper's on-disk binary at launch (this delegate is built once, at process
    /// start), so an in-place app update can be detected and adopted by relaunching — see
    /// `HelperXPCService`.
    let staleness = ExecutableStaleness()

    /// Per-user demand and connection tokens are serialized with power operations. Old connection
    /// callbacks cannot retire a replacement; a connected but wedged daemon also expires.
    let controller: HelperPowerController

    /// How long the helper stays blocked with no daemon connected before concluding the daemon
    /// is gone for good (SIGKILLed at logout, force-quit) and clearing the block itself. Long
    /// enough for a daemon crash + launchd relaunch + reconnect; short enough that a lid-closed
    /// Mac isn't pinned awake indefinitely by a block nobody owns.
    private static let deadManGrace: TimeInterval = 60

    override init() {
        let blocker = SleepBlocker()
        self.blocker = blocker
        controller = HelperPowerController(blocker: blocker, disconnectGrace: Self.deadManGrace)
        super.init()
    }

    func listener(_: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // Only accept connections from binaries signed by us. The daemon is the only
        // legitimate caller. The listener's exact code requirement rejects invalid peers
        // before this delegate is called; there is no unsigned-development fallback.
        guard ComponentTrust.hasRuntimeIdentity, newConnection.effectiveUserIdentifier > 0 else { return false }
        let uid = newConnection.effectiveUserIdentifier
        let token = UUID()
        do { try controller.connect(uid: uid, token: token) }
        catch { return false }
        log.notice("helper_connected — uid=\(uid, privacy: .public)")
        newConnection.exportedInterface = NSXPCInterface(with: HelperXPCProtocol.self)
        newConnection.exportedObject = HelperXPCService(blocker: blocker, staleness: staleness, controller: controller, uid: uid, token: token)
        newConnection.invalidationHandler = { [weak self] in self?.connectionEnded(uid: uid, token: token) }
        newConnection.interruptionHandler = { [weak self] in self?.connectionEnded(uid: uid, token: token) }
        newConnection.resume()
        return true
    }

    /// Dead-man switch: loss of a daemon starts its bounded grace without releasing another user's
    /// live demand. Heartbeat expiration independently handles connections that remain open while
    /// their daemon is wedged. Failed cleanup remains retryable rather than stranding disablesleep.
    private func connectionEnded(uid: UInt32, token: UUID) {
        log.notice("helper_disconnected — uid=\(uid, privacy: .public)")
        controller.disconnect(uid: uid, token: token)
    }
}
