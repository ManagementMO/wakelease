import AdrafinilShared
import Foundation
import OSLog

final class HelperXPCService: NSObject, HelperXPCProtocol, @unchecked Sendable {
    /// The process-wide blocker, shared across every connection (see `SleepBlocker`). Internally
    /// synchronized, so this service needs no lock of its own.
    private let blocker: SleepBlocker
    /// Launch-time binary identity, shared process-wide, used to adopt an in-place update.
    private let staleness: ExecutableStaleness
    private let log = Logger(subsystem: AdrafinilConstants.helperBundleID, category: "XPCService")
    private let controller: HelperPowerController
    private let uid: UInt32
    private let token: UUID

    init(blocker: SleepBlocker, staleness: ExecutableStaleness, controller: HelperPowerController, uid: UInt32, token: UUID) {
        self.blocker = blocker
        self.staleness = staleness
        self.controller = controller
        self.uid = uid
        self.token = token
        super.init()
    }

    func setSleepBlocked(_ blocked: Bool, reply: @escaping @Sendable (Bool, NSError?) -> Void) {
        log.notice("XPC setSleepBlocked(\(blocked, privacy: .public)) received from daemon")
        controller.set(uid: uid, token: token, blocked: blocked, reply: reply)
        // Unblocking returns us to idle — the safe point to adopt a binary an update swapped in.
        if !blocked { relaunchIfUpdated() }
    }

    func sleepBlockedState(reply: @escaping @Sendable (Bool) -> Void) {
        log.debug("XPC sleepBlockedState query -> \(self.blocker.isBlocked, privacy: .public)")
        reply(blocker.isBlocked)
    }

    func version(reply: @escaping @Sendable (String) -> Void) {
        reply(HelperVersion.string)
        // The daemon probes the helper's version once at startup, so a freshly relaunched (post-
        // update) daemon reaches here — the trigger that adopts a new helper binary while idle.
        relaunchIfUpdated()
    }

    /// Adopts a binary that an in-place app update swapped onto disk by exiting so `launchd`
    /// (KeepAlive) relaunches the helper from the new image. Gated on **not** currently blocking,
    /// since exiting clears the sleep block; idle verification and exit share the controller's
    /// serial executor so a concurrent acquire cannot slip between the check and process exit.
    private func relaunchIfUpdated() {
        controller.ifIdle { [staleness, log] in
            guard staleness.hasBeenReplaced() else { return }
            log.notice("Helper binary replaced by an update — exiting so launchd relaunches the new helper")
            exit(0)
        }
    }
}

enum HelperVersion {
    static let string = AdrafinilConstants.marketingVersion
}
