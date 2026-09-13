import Darwin
import Foundation
import Testing
@testable import AdrafinilShared

@Suite("Helper demand ownership")
struct HelperDemandLedgerTests {
    @Test func independentUsersAreMechanicallyReferenceCounted() throws {
        var ledger = HelperDemandLedger()
        let a = UUID(), b = UUID()
        try ledger.connect(uid: 501, token: a)
        try ledger.connect(uid: 502, token: b)
        try ledger.set(uid: 501, token: a, blocked: true, at: 100)
        try ledger.set(uid: 502, token: b, blocked: true, at: 100)
        try ledger.set(uid: 501, token: a, blocked: false, at: 101)
        #expect(ledger.shouldBlock)
        try ledger.set(uid: 502, token: b, blocked: false, at: 102)
        #expect(!ledger.shouldBlock)
    }

    @Test func connectedButWedgedDaemonCannotHoldForever() throws {
        var ledger = HelperDemandLedger()
        let token = UUID()
        try ledger.connect(uid: 501, token: token)
        try ledger.set(uid: 501, token: token, blocked: true, at: 100)
        ledger.expire(at: 189)
        #expect(ledger.shouldBlock)
        ledger.expire(at: 190)
        #expect(!ledger.shouldBlock)
    }

    @Test func reconnectionPreservesDemandAndIgnoresOldInvalidation() throws {
        var ledger = HelperDemandLedger()
        let old = UUID(), new = UUID()
        try ledger.connect(uid: 501, token: old)
        try ledger.set(uid: 501, token: old, blocked: true, at: 100)
        try ledger.connect(uid: 501, token: new)
        ledger.disconnect(uid: 501, token: old, at: 101)
        #expect(ledger.shouldBlock)
        #expect(throws: (any Error).self) { try ledger.set(uid: 501, token: old, blocked: false, at: 102) }
        try ledger.set(uid: 501, token: new, blocked: true, at: 102)
        ledger.expire(at: 190)
        #expect(ledger.shouldBlock)
    }

    @Test func disconnectedDaemonGetsOnlyABoundedGrace() throws {
        var ledger = HelperDemandLedger()
        let token = UUID()
        try ledger.connect(uid: 501, token: token)
        try ledger.set(uid: 501, token: token, blocked: true, at: 100)
        ledger.disconnect(uid: 501, token: token, at: 101)
        ledger.expire(at: 161)
        #expect(!ledger.shouldBlock)
    }
}

@Suite("Safety scheduling")
struct SafetySchedulingTests {
    @Test func newTrafficCannotPostponeAnArmedSafetySweep() {
        var deadline = EarliestDeadline()
        let first = deadline.arm(30)
        let later = deadline.arm(40)
        #expect(first && !later)
        #expect(deadline.value == 30)
        let earlier = deadline.arm(20)
        #expect(earlier && deadline.value == 20)
        deadline.fired()
        let next = deadline.arm(50)
        let cancelled = deadline.arm(nil)
        #expect(next && cancelled && deadline.value == nil)
    }

    @Test func finalReleaseClearsDisplayAndUserActivityAssertions() {
        var slots = WakeAssertionSlots(display: 10, userActivity: 11)
        var released: [UInt32] = []
        let cleared = slots.releaseAll { released.append($0); return true }
        #expect(cleared && released == [10, 11])
        #expect(slots.display == 0 && slots.userActivity == 0)
        slots.userActivity = 12
        let failed = slots.releaseAll { _ in false }
        #expect(!failed && slots.userActivity == 12)
        let retried = slots.releaseAll { _ in true }
        #expect(retried)
    }

    @Test func inspectionDoesNotConfuseDisplaySleepWithGlobalSleepDisable() {
        #expect(PowerManagementInspector.parseSleepDisabled("displaysleep 1\n SleepDisabled 0\n") == false)
        #expect(PowerManagementInspector.parseSleepDisabled("SleepDisabled 1") == true)
        #expect(PowerManagementInspector.parseSleepDisabled("SleepDisabled unknown") == nil)
    }
}

@Suite("Production component trust")
struct ComponentTrustTests {
    @Test func unsignedDevelopmentCannotBuildAProductionRequirement() {
        #expect(ComponentTrust.requirement(team: nil, role: .daemon) == nil)
        #expect(ComponentTrust.requirement(team: "", role: .daemon) == nil)
        #expect(ComponentTrust.requirement(team: "bad\" or true", role: .daemon) == nil)
    }

    @Test func requirementPinsAppleAnchorTeamAndExactRole() throws {
        let requirement = try #require(ComponentTrust.requirement(team: "TESTTEAM01", role: .daemon))
        #expect(requirement.contains("anchor apple generic"))
        #expect(requirement.contains("identifier \"org.wakelease.daemon\""))
        #expect(requirement.contains("TESTTEAM01"))
        #expect(!requirement.contains("identifier \"org.wakelease\""))
    }
}

@Suite("Bounded fixed-program subprocesses", .serialized)
struct BoundedProcessTests {
    @Test func argumentsAndOutputAreLiteral() throws {
        let result = try BoundedProcess.run(arguments: ["/usr/bin/printf", "%s", "a b; $HOME"], timeout: 2)
        #expect(result.status == 0)
        #expect(String(decoding: result.output, as: UTF8.self) == "a b; $HOME")
    }

    @Test func hungChildIsKilledAndReaped() throws {
        let before = SystemLeaseClock().now().continuous
        let result = try BoundedProcess.run(arguments: ["/bin/sh", "-c", "trap '' TERM; exec /bin/sleep 30"], timeout: 0.05)
        #expect(result.timedOut)
        #expect(SystemLeaseClock().now().continuous - before < 3)
        var status: Int32 = 0
        #expect(waitpid(result.pid, &status, WNOHANG) == -1)
        #expect(errno == ECHILD)
    }

    @Test func outputIsBoundedWithoutBlockingTheChild() throws {
        let result = try BoundedProcess.run(arguments: ["/usr/bin/yes", "x"], timeout: 0.05, maximumOutput: 1024)
        #expect(result.timedOut)
        #expect(result.output.count == 1024)
    }
}
