import AdrafinilShared
import Foundation
import OSLog

final class HelperPowerController: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.wakelease.helper.power")
    private let blocker: SleepBlocker
    private var ledger: HelperDemandLedger
    private let removalStore: HelperRemovalStore
    private var removalIssue: Error?
    private var timer: DispatchSourceTimer?
    private var nextTick = EarliestDeadline()
    private let log = Logger(subsystem: WakeLeaseIdentity.helperBundleID, category: "Recovery")

    init(blocker: SleepBlocker, disconnectGrace: TimeInterval, removalStore: HelperRemovalStore = HelperRemovalStore()) {
        self.blocker = blocker
        self.removalStore = removalStore
        do { ledger = try HelperDemandLedger(disconnectGrace: disconnectGrace, removal: removalStore.load()) }
        catch { ledger = HelperDemandLedger(disconnectGrace: disconnectGrace); removalIssue = error }
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
                guard !blocked || removalIssue == nil else { throw HelperRemovalFailure.unsafeStorage }
                ledger.expire(at: SystemLeaseClock().now().continuous)
                try ledger.set(uid: uid, token: token, blocked: blocked, at: SystemLeaseClock().now().continuous)
                try blocker.set(blocked: ledger.shouldBlock)
                if removalIssue != nil { throw HelperRemovalFailure.unsafeStorage }
                reply(blocked, nil)
            } catch { reply(blocker.isBlocked, error as NSError) }
            schedule()
        }
    }

    func reserveRemoval(uid: UInt32, id: UUID, reply: @escaping @Sendable (Bool, NSError?) -> Void) {
        queue.async { [self] in
            do {
                guard removalIssue == nil else { throw HelperRemovalFailure.unsafeStorage }
                ledger.expire(at: SystemLeaseClock().now().continuous)
                try ledger.reserveRemoval(uid: uid, id: id)
                guard let reservation = ledger.removal else { throw HelperRemovalFailure.invalidReservation }
                do { try removalStore.save(reservation) }
                catch { removalIssue = error; throw error }
                try blocker.set(blocked: false)
                log.notice("helper_removal_reserved — uid=\(uid, privacy: .public)")
                reply(true, nil)
            } catch { reply(false, error as NSError) }
            schedule()
        }
    }

    func cancelRemoval(uid: UInt32, id: UUID, reply: @escaping @Sendable (Bool, NSError?) -> Void) {
        queue.async { [self] in
            do {
                guard let reservation = ledger.removal else { throw HelperRemovalFailure.invalidReservation }
                var next = ledger
                try next.cancelRemoval(uid: uid, id: id)
                try removalStore.remove(reservation)
                ledger = next
                removalIssue = nil
                log.notice("helper_removal_cancelled — uid=\(uid, privacy: .public)")
                reply(true, nil)
            } catch { reply(false, error as NSError) }
            schedule()
        }
    }

    func currentRemoval(uid: UInt32, reply: @escaping @Sendable (String?, UInt32, NSError?) -> Void) {
        queue.async { [self] in
            let reservation = ledger.removal
            reply(reservation?.uid == uid ? reservation?.id.uuidString : nil, reservation?.uid ?? 0, reservation == nil ? removalIssue.map { $0 as NSError } : nil)
        }
    }

    func ifIdle(_ action: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            guard ledger.removal == nil, removalIssue == nil, !ledger.shouldBlock, !blocker.isBlocked, !blocker.needsReconciliation else { return }
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
        let needsRepair = blocker.needsReconciliation || blocker.isBlocked != ledger.shouldBlock
        let desired = [ledger.nextDeadline, needsRepair ? now + 5 : nil].compactMap(\.self).min()
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
        if before != ledger.shouldBlock || blocker.needsReconciliation || blocker.isBlocked != ledger.shouldBlock {
            do {
                try blocker.set(blocked: ledger.shouldBlock)
                log.notice("sleep_block_reconciled — helper deadline/recovery")
            } catch { log.error("sleep_block_reconcile_failed — retry remains armed") }
        }
        schedule()
    }
}
