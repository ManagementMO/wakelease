import Foundation
import Testing
@testable import AdrafinilShared

private actor PowerTestGate {
    private var entered = false
    private var released = false
    private var enterWaiters: [CheckedContinuation<Void, Never>] = []
    private var waiter: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true
        enterWaiters.forEach { $0.resume() }
        enterWaiters.removeAll()
        if !released { await withCheckedContinuation { waiter = $0 } }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { enterWaiters.append($0) } }
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}

private actor FakeLeasePower: LeasePowerControlling {
    struct Failure: Error {}
    var applied: [WakeDemand] = []
    var attempts: [WakeDemand] = []
    var sleepRequests = 0
    var cues = 0
    var failRelease = 0
    var cueGate: PowerTestGate?
    var releaseGate: PowerTestGate?

    func configure(failRelease: Int = 0, cueGate: PowerTestGate? = nil, releaseGate: PowerTestGate? = nil) {
        self.failRelease = failRelease
        self.cueGate = cueGate
        self.releaseGate = releaseGate
    }
    func apply(_ demand: WakeDemand) async throws {
        attempts.append(demand)
        if !demand.system, failRelease > 0 { failRelease -= 1; throw Failure() }
        applied.append(demand)
        if !demand.system { await releaseGate?.hold() }
    }
    func prepareForRelease() async { cues += 1; await cueGate?.hold() }
    func requestSleep() async throws { sleepRequests += 1 }
    func connectionReport() async -> LeasePowerReport { LeasePowerReport(helperConnected: true) }
}

@Suite("Serialized power reconciliation")
struct LeasePowerReconcilerTests {
    private let awake = WakeDemand(system: true, display: false)
    private func intent(_ version: UInt64, _ demand: WakeDemand, closed: Bool? = false, external: Bool? = false, prompt: Bool = true) -> LeasePowerIntent {
        LeasePowerIntent(version: version, demand: demand, lidClosed: closed, externalDisplay: external, promptSleep: prompt, cue: true)
    }

    @Test func onlyDemandEdgesChangePower() async {
        let power = FakeLeasePower()
        let driver = LeasePowerReconciler(controller: power)
        _ = await driver.reconcile(intent(0, .none))
        _ = await driver.reconcile(intent(1, awake))
        _ = await driver.reconcile(intent(2, awake))
        _ = await driver.reconcile(intent(3, awake))
        _ = await driver.reconcile(intent(4, .none))
        _ = await driver.reconcile(intent(5, .none))
        #expect(await power.applied == [.none, awake, .none])
        #expect(await power.sleepRequests == 0)
    }

    @Test func acquireDuringCueCancelsTheQueuedUnblock() async {
        let power = FakeLeasePower(), gate = PowerTestGate()
        let driver = LeasePowerReconciler(controller: power)
        _ = await driver.reconcile(intent(1, awake))
        await power.configure(cueGate: gate)
        let release = Task { await driver.reconcile(intent(2, .none, closed: true)) }
        await gate.waitUntilEntered()
        await driver.submit(intent(3, awake))
        await gate.release()
        _ = await release.value
        await driver.flush()
        #expect(await power.applied == [awake])
        #expect(await driver.report().applied == awake)
        #expect(await power.sleepRequests == 0)
    }

    @Test func newAcquireDuringUnblockCannotLeaveAStaleFalseState() async {
        let power = FakeLeasePower(), gate = PowerTestGate()
        let driver = LeasePowerReconciler(controller: power)
        _ = await driver.reconcile(intent(1, awake))
        await power.configure(releaseGate: gate)
        let release = Task { await driver.reconcile(intent(2, .none, closed: true)) }
        await gate.waitUntilEntered()
        await driver.submit(intent(3, awake))
        await gate.release()
        _ = await release.value
        await driver.flush()
        #expect(await driver.report().applied == awake)
        #expect(await power.applied == [awake, .none, awake])
        #expect(await power.sleepRequests == 0)
    }

    @Test func failedUnblockIsReportedAndRetriedEvenWithZeroLeases() async {
        let power = FakeLeasePower(), gate = PowerTestGate()
        let driver = LeasePowerReconciler(controller: power, retry: { _ in await gate.hold() })
        _ = await driver.reconcile(intent(1, awake))
        await power.configure(failRelease: 1)
        let report = await driver.reconcile(intent(2, .none))
        #expect(report.error != nil)
        #expect(report.applied == awake)
        await gate.waitUntilEntered()
        await gate.release()
        await driver.flush()
        #expect(await driver.report().applied == WakeDemand.none)
        #expect(await power.attempts == [awake, .none, .none])
    }

    @Test func promptSleepRequiresClosedLidAndKnownAbsenceOfExternalDisplays() async {
        for (closed, external, prompt, expected) in [(true as Bool?, false as Bool?, true, 1), (false, false, true, 0), (true, true, true, 0), (true, nil, true, 0), (nil, false, true, 0), (true, false, false, 0)] {
            let power = FakeLeasePower()
            let driver = LeasePowerReconciler(controller: power)
            _ = await driver.reconcile(intent(1, awake))
            _ = await driver.reconcile(intent(2, .none, closed: closed, external: external, prompt: prompt))
            _ = await driver.reconcile(intent(3, .none, closed: closed, external: external, prompt: prompt))
            #expect(await power.sleepRequests == expected)
        }
    }

    @Test func staleGenerationCannotOverrideNewWork() async {
        let power = FakeLeasePower()
        let driver = LeasePowerReconciler(controller: power)
        _ = await driver.reconcile(intent(3, awake))
        _ = await driver.reconcile(intent(2, .none, closed: true))
        #expect(await power.applied == [awake])
    }

    @Test func disconnectedHelperInvalidatesPreviouslyConfirmedProtection() async {
        let power = FakeLeasePower()
        let driver = LeasePowerReconciler(controller: power)
        _ = await driver.reconcile(intent(1, awake))
        await driver.invalidate()
        #expect(await driver.report().applied == nil)
        _ = await driver.reconcile(intent(1, awake), force: true)
        #expect(await driver.report().applied == awake)
    }

    @Test func forcedReconciliationReappliesForWakeAndHelperReconnect() async {
        let power = FakeLeasePower()
        let driver = LeasePowerReconciler(controller: power)
        _ = await driver.reconcile(intent(1, awake))
        _ = await driver.reconcile(intent(1, awake), force: true)
        #expect(await power.applied == [awake, awake])
    }
}
