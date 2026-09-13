import AdrafinilShared
import Foundation
import OSLog

final class HelperPowerController: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.wakelease.helper.power")
    private let blocker: SleepBlocker
    private var ledger: HelperDemandLedger
    private var timer: DispatchSourceTimer?
    private var nextTick = EarliestDeadline()
    private let log = Logger(subsystem: WakeLeaseIdentity.helperBundleID, category: "Recovery")

    init(blocker: SleepBlocker, disconnectGrace: TimeInterval) {
        self.blocker = blocker
        ledger = HelperDemandLedger(disconnectGrace: disconnectGrace)
        queue.async { [self] in schedule() }
    }

    func connect(uid: UInt32, token: UUID) throws {
        try queue.sync {
            try ledger.connect(uid: uid, token: token)
            schedule()
        }
    }

    func disconnect(uid: UInt32, token: UUID) {
        queue.async { [self] in
            ledger.disconnect(uid: uid, token: token, at: SystemLeaseClock().now().continuous)
            schedule()
        }
    }

    func set(uid: UInt32, token: UUID, blocked: Bool, reply: @escaping @Sendable (Bool, NSError?) -> Void) {
        queue.async { [self] in
            do {
                ledger.expire(at: SystemLeaseClock().now().continuous)
                try ledger.set(uid: uid, token: token, blocked: blocked, at: SystemLeaseClock().now().continuous)
                try blocker.set(blocked: ledger.shouldBlock)
                reply(blocked, nil)
            } catch { reply(blocker.isBlocked, error as NSError) }
            schedule()
        }
    }

    func ifIdle(_ action: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            guard !ledger.shouldBlock, !blocker.isBlocked, !blocker.needsReconciliation else { return }
            action()
        }
    }

    func shutdown(_ completed: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            ledger.clear()
            do { try blocker.set(blocked: false); completed(true) }
            catch { log.fault("shutdown_clear_failed"); completed(false) }
        }
    }

    private func schedule() {
        let now = SystemLeaseClock().now().continuous
        let desired = [ledger.nextDeadline, blocker.needsReconciliation ? now + 5 : nil].compactMap(\.self).min()
        guard nextTick.arm(desired) else { return }
        timer?.cancel()
        timer = nil
        guard let deadline = nextTick.value else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + max(0.01, deadline - now))
        source.setEventHandler { [weak self] in self?.tick() }
        timer = source
        source.resume()
    }

    private func tick() {
        nextTick.fired()
        timer?.cancel()
        timer = nil
        let before = ledger.shouldBlock
        ledger.expire(at: SystemLeaseClock().now().continuous)
        if before != ledger.shouldBlock || blocker.needsReconciliation || (!ledger.shouldBlock && blocker.isBlocked) {
            do {
                try blocker.set(blocked: ledger.shouldBlock)
                log.notice("sleep_block_reconciled — helper deadline/recovery")
            } catch { log.error("sleep_block_reconcile_failed — retry remains armed") }
        }
        schedule()
    }
}
