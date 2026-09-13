import Foundation
import Testing
@testable import AdrafinilShared

@Suite("Wake lease invariants")
struct LeaseBookTests {
    private func time(_ seconds: Double) -> LeaseTime {
        LeaseTime(wall: Date(timeIntervalSince1970: 1_000_000 + seconds), continuous: seconds)
    }

    private func proposal(_ key: String, ttl: Double = 3600, display: Bool = false, owner: ProcessIdentity? = nil, parent: UUID? = nil) -> LeaseProposal {
        LeaseProposal(key: key, source: "test-work", sourceKind: .custom, wakeClass: display ? .display : .system, ttlSeconds: ttl, owner: owner, parentLeaseID: parent)
    }

    private let owner = ProcessIdentity(pid: 100, uid: 501, startSeconds: 900, startMicroseconds: 12)

    @Test func zeroLeasesImposeNoWakeRequirement() {
        let book = LeaseBook(bootID: "boot")
        #expect(book.demand == .none)
        #expect(book.leases.isEmpty)
    }

    @Test func referenceCountEdgesOccurExactlyOnce() throws {
        var book = LeaseBook(bootID: "boot")
        var edges: [WakeDemand] = []
        func record(_ change: LeaseChange) {
            if let transition = change.transition { edges.append(transition.to) }
        }
        record(try book.acquire(proposal("a"), at: time(1000)))
        record(try book.acquire(proposal("b"), at: time(1001)))
        record(try book.acquire(proposal("b"), at: time(1002)))
        #expect(book.leases.count == 2)
        record(try book.release(key: "a", at: time(1003)))
        #expect(book.demand.system)
        record(try book.release(key: "b", at: time(1004)))
        record(try book.release(key: "b", at: time(1005)))
        #expect(book.leases.isEmpty)
        #expect(edges == [WakeDemand(system: true, display: false), .none])
    }

    @Test func independentDisplayClassDropsBeforeSystemClass() throws {
        var book = LeaseBook(bootID: "boot")
        _ = try book.acquire(proposal("system"), at: time(1000))
        _ = try book.acquire(proposal("display", display: true), at: time(1001))
        #expect(book.demand == WakeDemand(system: true, display: true))
        _ = try book.release(key: "display", at: time(1002))
        #expect(book.demand == WakeDemand(system: true, display: false))
    }

    @Test func duplicateAcquirePreservesIdentityAndDisplay() throws {
        var book = LeaseBook(bootID: "boot")
        let first = try #require(book.acquire(proposal("a", display: true), at: time(1000)).lease)
        let second = try #require(book.acquire(proposal("a"), at: time(1001)).lease)
        #expect(first.id == second.id)
        #expect(first.acquiredAt == second.acquiredAt)
        #expect(second.wakeClass == .display)
        #expect(book.leases.count == 1)
    }

    @Test func retransmissionDoesNotExtendLifetime() throws {
        var book = LeaseBook(bootID: "boot")
        let first = try #require(book.acquire(proposal("a", ttl: 10), at: time(1000)).lease)
        let retry = try book.acquire(proposal("a", ttl: 10), at: time(1005), issuedAt: 1000)
        #expect(retry.lease?.expiresAt == first.expiresAt)
        #expect(!retry.changed)
    }

    @Test func ttlExpiresAtDeadlineAndDuplicateReleaseCannotUnderflow() throws {
        var book = LeaseBook(bootID: "boot")
        _ = try book.acquire(proposal("a", ttl: 10), at: time(1000))
        #expect(book.advance(to: time(1009)).transition == nil)
        #expect(book.advance(to: time(1010)).transition?.to == WakeDemand.none)
        #expect(try book.release(key: "a", at: time(1011)).transition == nil)
        #expect(book.demand == .none)
    }

    @Test func heartbeatExtendsOnlyItsLease() throws {
        var book = LeaseBook(bootID: "boot")
        _ = try book.acquire(proposal("a", ttl: 10), at: time(1000))
        _ = try book.acquire(proposal("b", ttl: 10), at: time(1001))
        _ = try book.renew(key: "a", at: time(1008))
        _ = book.advance(to: time(1012))
        #expect(book.leases.map(\.key) == ["a"])
        #expect(book.leases.first?.lastHeartbeatAt == time(1008).wall)
        _ = book.advance(to: time(1018))
        #expect(book.demand == .none)
    }

    @Test func waitingGraceDoesNotRestartOnDuplicateWaitOrHeartbeat() throws {
        var book = LeaseBook(bootID: "boot", policy: LeasePolicy(waitingGraceSeconds: 600))
        _ = try book.acquire(proposal("a"), at: time(1000))
        _ = try book.wait(key: "a", at: time(1010))
        _ = try book.wait(key: "a", at: time(1020))
        _ = try book.renew(key: "a", at: time(1030))
        _ = book.advance(to: time(1609))
        #expect(book.demand.system)
        #expect(book.advance(to: time(1610)).transition?.to == WakeDemand.none)
        #expect(book.leases.first?.state == .waitingForUser)
        _ = try book.acquire(proposal("a"), at: time(1611))
        #expect(book.demand.system)
        #expect(book.leases.first?.state == .active)
    }

    @Test func waitingNeverExtendsAShorterTTL() throws {
        var book = LeaseBook(bootID: "boot")
        _ = try book.acquire(proposal("a", ttl: 30), at: time(1000))
        _ = try book.wait(key: "a", at: time(1001))
        _ = book.advance(to: time(1030))
        #expect(book.leases.isEmpty)
        #expect(!book.demand.system)
    }

    @Test func immediateWaitPolicyAllowsSleep() throws {
        var book = LeaseBook(bootID: "boot", policy: LeasePolicy(waitingPolicy: .sleep))
        _ = try book.acquire(proposal("a"), at: time(1000))
        #expect(try book.wait(key: "a", at: time(1001)).transition?.to == WakeDemand.none)
    }

    @Test func keepAwakeWaitingPolicyRemainsBoundedByLeaseLifetime() throws {
        var book = LeaseBook(bootID: "boot", policy: LeasePolicy(waitingPolicy: .keepAwake))
        _ = try book.acquire(proposal("a", ttl: 1000), at: time(1000))
        _ = try book.wait(key: "a", at: time(1001))
        _ = book.advance(to: time(1700))
        #expect(book.demand.system)
        _ = book.advance(to: time(2000))
        #expect(!book.demand.system)
    }

    @Test func ownerDeathAndPIDReuseReleaseOnlyAffectedWork() throws {
        for identity in [nil, ProcessIdentity(pid: 100, uid: 501, startSeconds: 1001, startMicroseconds: 0)] {
            var book = LeaseBook(bootID: "boot")
            _ = try book.acquire(proposal("owned", owner: owner), at: time(1000))
            _ = try book.acquire(proposal("independent"), at: time(1001))
            _ = book.advance(to: time(1002), identity: { _ in identity })
            #expect(book.leases.map(\.key) == ["independent"])
            #expect(book.demand.system)
        }
    }

    @Test func childLeaseOutlivesParent() throws {
        var book = LeaseBook(bootID: "boot")
        let parent = try #require(book.acquire(proposal("parent"), at: time(1000)).lease)
        _ = try book.acquire(proposal("child", parent: parent.id), at: time(1001))
        _ = try book.release(key: "parent", at: time(1002))
        #expect(book.demand.system)
        #expect(book.leases.first?.parentLeaseID == parent.id)
        #expect(try book.release(key: "child", at: time(1003)).transition?.to == WakeDemand.none)
    }

    @Test func releaseBeforeDelayedAcquireCannotResurrectWork() throws {
        var book = LeaseBook(bootID: "boot")
        _ = try book.release(key: "a", at: time(1002))
        #expect(throws: LeaseFailure.staleRequest) {
            try book.acquire(proposal("a"), at: time(1003), issuedAt: 1001)
        }
        #expect(book.demand == .none)
        _ = try book.acquire(proposal("a"), at: time(1004))
        #expect(book.demand.system)
    }

    @Test func lateReleaseCannotRemoveNewerAcquisition() throws {
        var book = LeaseBook(bootID: "boot")
        _ = try book.acquire(proposal("a"), at: time(1002))
        #expect(throws: LeaseFailure.staleRequest) {
            try book.release(key: "a", at: time(1003), issuedAt: 1001)
        }
        #expect(book.demand.system)
    }

    @Test func aReleaseWinsAnEqualTimestampTie() throws {
        var book = LeaseBook(bootID: "boot")
        _ = try book.acquire(proposal("a"), at: time(1000))
        _ = try book.release(key: "a", at: time(1000))
        #expect(throws: LeaseFailure.staleRequest) {
            try book.acquire(proposal("a"), at: time(1001), issuedAt: 1000)
        }
    }

    @Test func cutoutOverridesAllClassesAndLatchesAcrossNewAcquires() throws {
        var book = LeaseBook(bootID: "boot")
        _ = try book.acquire(proposal("a", display: true), at: time(1000))
        let hazard = LeaseSafety(lidClosed: true, temperatureCelsius: 90, thermalState: .serious)
        #expect(book.updateSafety(hazard, at: time(1001)).transition?.to == WakeDemand.none)
        #expect(book.cutouts.contains(.thermal))
        #expect(throws: LeaseFailure.safetyCutout) { try book.acquire(proposal("b"), at: time(1002)) }
        _ = book.updateSafety(LeaseSafety(lidClosed: false, temperatureCelsius: 89, thermalState: .serious), at: time(1003))
        #expect(book.cutouts.contains(.thermal), "opening the lid is not evidence that an unsafe temperature receded")
        _ = book.updateSafety(LeaseSafety(lidClosed: false, temperatureCelsius: 70, thermalState: .nominal), at: time(1004))
        _ = book.updateSafety(LeaseSafety(lidClosed: false, temperatureCelsius: 70, thermalState: .nominal), at: time(1065))
        #expect(book.cutouts.isEmpty)
        _ = try book.acquire(proposal("b"), at: time(1066))
        #expect(book.demand.system)
    }

    @Test func lowBatteryAdmissionIsAtomicAndUsesHysteresis() throws {
        var book = LeaseBook(bootID: "boot")
        _ = book.updateSafety(LeaseSafety(lidClosed: true, batteryPercent: 20, onBattery: true), at: time(1000))
        #expect(throws: LeaseFailure.safetyCutout) { try book.acquire(proposal("a"), at: time(1001)) }
        _ = book.updateSafety(LeaseSafety(lidClosed: true, batteryPercent: 22, onBattery: true), at: time(1002))
        #expect(book.cutouts.contains(.lowBattery))
        _ = book.updateSafety(LeaseSafety(lidClosed: true, batteryPercent: nil, onBattery: nil), at: time(1003))
        #expect(book.cutouts.contains(.lowBattery))
        _ = book.updateSafety(LeaseSafety(lidClosed: true, batteryPercent: 25, onBattery: true), at: time(1004))
        #expect(book.cutouts.isEmpty)
    }

    @Test func pauseIsAReplayBarrier() throws {
        var book = LeaseBook(bootID: "boot")
        _ = try book.acquire(proposal("a"), at: time(1000))
        _ = book.setPaused(true, at: time(1002))
        #expect(book.demand == .none)
        #expect(throws: LeaseFailure.paused) { try book.acquire(proposal("b"), at: time(1003)) }
        _ = book.setPaused(false, at: time(1004))
        #expect(throws: LeaseFailure.staleRequest) { try book.acquire(proposal("old"), at: time(1005), issuedAt: 1001) }
    }

    @Test func invalidTTLAndOversizedKeysFailWithoutMutation() throws {
        var book = LeaseBook(bootID: "boot")
        for ttl in [0, -1, Double.infinity, Double.nan] {
            #expect(throws: LeaseFailure.invalidTTL) { try book.acquire(proposal("a", ttl: ttl), at: time(1000)) }
        }
        #expect(throws: LeaseFailure.invalidField) { try book.acquire(proposal(String(repeating: "x", count: 257)), at: time(1001)) }
        #expect(book.demand == .none)
    }

    @Test func capacityCheckAndMutationAreOneOperation() throws {
        var book = LeaseBook(bootID: "boot", policy: LeasePolicy(maxLeases: 2))
        _ = try book.acquire(proposal("a"), at: time(1000))
        _ = try book.acquire(proposal("b"), at: time(1001))
        _ = try book.acquire(proposal("a"), at: time(1002))
        #expect(throws: LeaseFailure.capacity) { try book.acquire(proposal("c"), at: time(1003)) }
        #expect(book.leases.count == 2)
    }

    @Test func rebootAndOwnerReuseInvalidatePersistedLeases() throws {
        var book = LeaseBook(bootID: "boot")
        _ = try book.acquire(proposal("a", owner: owner), at: time(1000))
        let data = try JSONEncoder().encode(book)
        var restored = try JSONDecoder().decode(LeaseBook.self, from: data)
        _ = restored.recover(bootID: "other-boot", at: time(1001), identity: { _ in owner })
        #expect(restored.demand == .none)
        restored = try JSONDecoder().decode(LeaseBook.self, from: data)
        _ = restored.recover(bootID: "boot", at: time(1001), identity: { _ in nil })
        #expect(restored.demand == .none)
    }

    @Test func rebootResetsTheContinuousClockEpoch() throws {
        var book = LeaseBook(bootID: "old")
        _ = try book.acquire(proposal("old"), at: time(1000))
        _ = book.recover(bootID: "new", at: time(1), identity: { _ in nil })
        _ = try book.acquire(proposal("new", ttl: 10), at: time(2))
        #expect(book.demand.system)
    }

    @Test func rebindingAnExistingKeyCannotBypassOwnerCapacity() throws {
        var book = LeaseBook(bootID: "boot", policy: LeasePolicy(maxLeasesPerOwner: 1))
        let other = ProcessIdentity(pid: 200, uid: 501, startSeconds: 900, startMicroseconds: 0)
        _ = try book.acquire(proposal("a", owner: owner), at: time(1000))
        _ = try book.acquire(proposal("b", owner: other), at: time(1001))
        #expect(throws: LeaseFailure.capacity) {
            try book.acquire(proposal("a", owner: other), at: time(1002))
        }
    }

    @Test func expiredJournalEntriesCannotPermanentlyExhaustCapacity() throws {
        var book = LeaseBook(bootID: "boot")
        for index in 0..<4096 {
            _ = try book.release(key: "old-\(index)", at: time(1000 + Double(index) / 1000))
        }
        _ = try book.acquire(proposal("new"), at: time(1200))
        #expect(book.demand.system)
    }

    @Test func anExpiryAndReplacementAreOneDemandTransition() throws {
        var book = LeaseBook(bootID: "boot")
        _ = try book.acquire(proposal("old", ttl: 10), at: time(1000))
        let change = try book.acquire(proposal("new"), at: time(1010))
        #expect(change.transition == nil)
        #expect(book.leases.map(\.key) == ["new"])
    }

    @Test func corruptPersistenceCannotCreateAnUnboundedLease() throws {
        var book = LeaseBook(bootID: "boot")
        _ = try book.acquire(proposal("a", ttl: 60), at: time(1000))
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(book)) as? [String: Any])
        var entries = try #require(object["entries"] as? [String: [String: Any]])
        entries["a"]?["deadline"] = 1e100
        entries["a"]?["ttlSeconds"] = 1e100
        object["entries"] = entries
        var restored = try JSONDecoder().decode(LeaseBook.self, from: JSONSerialization.data(withJSONObject: object))
        _ = restored.recover(bootID: "boot", at: time(1001), identity: { _ in nil })
        #expect(restored.demand == .none)
        #expect(restored.leases.isEmpty)
    }

    @Test func wallClockRollbackCannotExtendAnExpiredLease() throws {
        var book = LeaseBook(bootID: "boot")
        _ = try book.acquire(proposal("a", ttl: 10), at: time(1000))
        _ = book.advance(to: LeaseTime(wall: Date(timeIntervalSince1970: 1), continuous: 1010))
        #expect(book.demand == .none)
    }
}
