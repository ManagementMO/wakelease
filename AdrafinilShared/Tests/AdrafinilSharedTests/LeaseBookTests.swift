import Foundation
import Testing
@testable import AdrafinilShared

@Suite("Wake lease invariants")
struct LeaseBookTests {
    private func time(_ seconds: Double) -> LeaseTime {
        LeaseTime(wall: Date(timeIntervalSince1970: 1_000_000 + seconds), continuous: seconds)
    }

    private func proposal(_ key: String, ttl: Double = 3_600, display: Bool = false, owner: ProcessIdentity? = nil, parent: UUID? = nil) -> LeaseProposal {
        LeaseProposal(key: key, source: "test-work", sourceKind: .custom, wakeClass: display ? .display : .system, ttlSeconds: ttl, owner: owner, parentLeaseID: parent)
    }

    private let owner = ProcessIdentity(pid: 100, uid: 501, startSeconds: 900, startMicroseconds: 12)

    @Test
    func `zero leases impose no wake requirement`() {
        let book = LeaseBook(bootID: "boot")
        #expect(book.demand == .none)
        #expect(book.leases.isEmpty)
    }

    @Test
    func `reference count edges occur exactly once`() throws {
        var book = LeaseBook(bootID: "boot")
        var edges: [WakeDemand] = []
        func record(_ change: LeaseChange) {
            if let transition = change.transition { edges.append(transition.to) }
        }
        try record(book.acquire(proposal("a"), at: time(1_000)))
        try record(book.acquire(proposal("b"), at: time(1_001)))
        try record(book.acquire(proposal("b"), at: time(1_002)))
        #expect(book.leases.count == 2)
        try record(book.release(key: "a", at: time(1_003)))
        #expect(book.demand.system)
        try record(book.release(key: "b", at: time(1_004)))
        try record(book.release(key: "b", at: time(1_005)))
        #expect(book.leases.isEmpty)
        #expect(edges == [WakeDemand(system: true, display: false), .none])
    }

    @Test
    func `independent display class drops before system class`() throws {
        var book = LeaseBook(bootID: "boot")
        _ = try book.acquire(proposal("system"), at: time(1_000))
        _ = try book.acquire(proposal("display", display: true), at: time(1_001))
        #expect(book.demand == WakeDemand(system: true, display: true))
        _ = try book.release(key: "display", at: time(1_002))
        #expect(book.demand == WakeDemand(system: true, display: false))
    }

    @Test
    func `duplicate acquire preserves identity and display`() throws {
        var book = LeaseBook(bootID: "boot")
        let first = try #require(book.acquire(proposal("a", display: true), at: time(1_000)).lease)
        let second = try #require(book.acquire(proposal("a"), at: time(1_001)).lease)
        #expect(first.id == second.id)
        #expect(first.acquiredAt == second.acquiredAt)
        #expect(second.wakeClass == .display)
        #expect(book.leases.count == 1)
    }

    @Test
    func `retransmission does not extend lifetime`() throws {
        var book = LeaseBook(bootID: "boot")
        let first = try #require(book.acquire(proposal("a", ttl: 10), at: time(1_000)).lease)
        let retry = try book.acquire(proposal("a", ttl: 10), at: time(1_005), issuedAt: 1_000)
        #expect(retry.lease?.expiresAt == first.expiresAt)
        #expect(!retry.changed)
    }

    @Test
    func `ttl expires at deadline and duplicate release cannot underflow`() throws {
        var book = LeaseBook(bootID: "boot")
        _ = try book.acquire(proposal("a", ttl: 10), at: time(1_000))
        #expect(book.advance(to: time(1_009)).transition == nil)
        #expect(book.advance(to: time(1_010)).transition?.to == WakeDemand.none)
        #expect(try book.release(key: "a", at: time(1_011)).transition == nil)
        #expect(book.demand == .none)
    }

    @Test
    func `heartbeat extends only its lease`() throws {
        var book = LeaseBook(bootID: "boot")
        _ = try book.acquire(proposal("a", ttl: 10), at: time(1_000))
        _ = try book.acquire(proposal("b", ttl: 10), at: time(1_001))
        _ = try book.renew(key: "a", at: time(1_008))
        _ = book.advance(to: time(1_012))
        #expect(book.leases.map(\.key) == ["a"])
        #expect(book.leases.first?.lastHeartbeatAt == time(1_008).wall)
        _ = book.advance(to: time(1_018))
        #expect(book.demand == .none)
    }

    @Test
    func `waiting grace does not restart on duplicate wait or heartbeat`() throws {
        var book = LeaseBook(bootID: "boot", policy: LeasePolicy(waitingGraceSeconds: 600))
        _ = try book.acquire(proposal("a"), at: time(1_000))
        _ = try book.wait(key: "a", at: time(1_010))
        _ = try book.wait(key: "a", at: time(1_020))
        _ = try book.renew(key: "a", at: time(1_030))
        _ = book.advance(to: time(1_609))
        #expect(book.demand.system)
        #expect(book.advance(to: time(1_610)).transition?.to == WakeDemand.none)
        #expect(book.leases.first?.state == .waitingForUser)
        _ = try book.acquire(proposal("a"), at: time(1_611))
        #expect(book.demand.system)
        #expect(book.leases.first?.state == .active)
    }

    @Test
    func `waiting never extends A shorter TTL`() throws {
        var book = LeaseBook(bootID: "boot")
        _ = try book.acquire(proposal("a", ttl: 30), at: time(1_000))
        _ = try book.wait(key: "a", at: time(1_001))
        _ = book.advance(to: time(1_030))
        #expect(book.leases.isEmpty)
        #expect(!book.demand.system)
    }

    @Test
    func `immediate wait policy allows sleep`() throws {
        var book = LeaseBook(bootID: "boot", policy: LeasePolicy(waitingPolicy: .sleep))
        _ = try book.acquire(proposal("a"), at: time(1_000))
        #expect(try book.wait(key: "a", at: time(1_001)).transition?.to == WakeDemand.none)
    }

    @Test
    func `keep awake waiting policy remains bounded by lease lifetime`() throws {
        var book = LeaseBook(bootID: "boot", policy: LeasePolicy(waitingPolicy: .keepAwake))
        _ = try book.acquire(proposal("a", ttl: 1_000), at: time(1_000))
        _ = try book.wait(key: "a", at: time(1_001))
        _ = book.advance(to: time(1_700))
        #expect(book.demand.system)
        _ = book.advance(to: time(2_000))
        #expect(!book.demand.system)
    }

    @Test
    func `owner death and PID reuse release only affected work`() throws {
        for identity in [nil, ProcessIdentity(pid: 100, uid: 501, startSeconds: 1_001, startMicroseconds: 0)] {
            var book = LeaseBook(bootID: "boot")
            _ = try book.acquire(proposal("owned", owner: owner), at: time(1_000))
            _ = try book.acquire(proposal("independent"), at: time(1_001))
            _ = book.advance(to: time(1_002), identity: { _ in identity })
            #expect(book.leases.map(\.key) == ["independent"])
            #expect(book.demand.system)
        }
    }

    @Test
    func `child lease outlives parent`() throws {
        var book = LeaseBook(bootID: "boot")
        let parent = try #require(book.acquire(proposal("parent"), at: time(1_000)).lease)
        _ = try book.acquire(proposal("child", parent: parent.id), at: time(1_001))
        _ = try book.release(key: "parent", at: time(1_002))
        #expect(book.demand.system)
        #expect(book.leases.first?.parentLeaseID == parent.id)
        #expect(try book.release(key: "child", at: time(1_003)).transition?.to == WakeDemand.none)
    }

    @Test
    func `release before delayed acquire cannot resurrect work`() throws {
        var book = LeaseBook(bootID: "boot")
        _ = try book.release(key: "a", at: time(1_002))
        #expect(throws: LeaseFailure.staleRequest) {
            try book.acquire(proposal("a"), at: time(1_003), issuedAt: 1_001)
        }
        #expect(book.demand == .none)
        _ = try book.acquire(proposal("a"), at: time(1_004))
        #expect(book.demand.system)
    }

    @Test
    func `late release cannot remove newer acquisition`() throws {
        var book = LeaseBook(bootID: "boot")
        _ = try book.acquire(proposal("a"), at: time(1_002))
        #expect(throws: LeaseFailure.staleRequest) {
            try book.release(key: "a", at: time(1_003), issuedAt: 1_001)
        }
        #expect(book.demand.system)
    }

    @Test
    func `a release wins an equal timestamp tie`() throws {
        var book = LeaseBook(bootID: "boot")
        _ = try book.acquire(proposal("a"), at: time(1_000))
        _ = try book.release(key: "a", at: time(1_000))
        #expect(throws: LeaseFailure.staleRequest) {
            try book.acquire(proposal("a"), at: time(1_001), issuedAt: 1_000)
        }
    }

    @Test
    func `cutout overrides all classes and latches across new acquires`() throws {
        var book = LeaseBook(bootID: "boot")
        _ = try book.acquire(proposal("a", display: true), at: time(1_000))
        let hazard = LeaseSafety(lidClosed: true, temperatureCelsius: 90, thermalState: .serious)
        #expect(book.updateSafety(hazard, at: time(1_001)).transition?.to == WakeDemand.none)
        #expect(book.cutouts.contains(.thermal))
        #expect(throws: LeaseFailure.safetyCutout) { try book.acquire(proposal("b"), at: time(1_002)) }
        _ = book.updateSafety(LeaseSafety(lidClosed: false, temperatureCelsius: 89, thermalState: .serious), at: time(1_003))
        #expect(book.cutouts.contains(.thermal), "opening the lid is not evidence that an unsafe temperature receded")
        _ = book.updateSafety(LeaseSafety(lidClosed: false, temperatureCelsius: 70, thermalState: .nominal), at: time(1_004))
        _ = book.updateSafety(LeaseSafety(lidClosed: false, temperatureCelsius: 70, thermalState: .nominal), at: time(1_065))
        #expect(book.cutouts.isEmpty)
        _ = try book.acquire(proposal("b"), at: time(1_066))
        #expect(book.demand.system)
    }

    @Test
    func `low battery admission is atomic and uses hysteresis`() throws {
        var book = LeaseBook(bootID: "boot")
        _ = book.updateSafety(LeaseSafety(lidClosed: true, batteryPercent: 20, onBattery: true), at: time(1_000))
        #expect(throws: LeaseFailure.safetyCutout) { try book.acquire(proposal("a"), at: time(1_001)) }
        _ = book.updateSafety(LeaseSafety(lidClosed: true, batteryPercent: 22, onBattery: true), at: time(1_002))
        #expect(book.cutouts.contains(.lowBattery))
        _ = book.updateSafety(LeaseSafety(lidClosed: true, batteryPercent: nil, onBattery: nil), at: time(1_003))
        #expect(book.cutouts.contains(.lowBattery))
        _ = book.updateSafety(LeaseSafety(lidClosed: true, batteryPercent: 25, onBattery: true), at: time(1_004))
        #expect(book.cutouts.isEmpty)
    }

    @Test
    func `pause is A replay barrier`() throws {
        var book = LeaseBook(bootID: "boot")
        _ = try book.acquire(proposal("a"), at: time(1_000))
        _ = book.setPaused(true, at: time(1_002))
        #expect(book.demand == .none)
        #expect(throws: LeaseFailure.paused) { try book.acquire(proposal("b"), at: time(1_003)) }
        _ = book.setPaused(false, at: time(1_004))
        #expect(throws: LeaseFailure.staleRequest) { try book.acquire(proposal("old"), at: time(1_005), issuedAt: 1_001) }
    }

    @Test
    func `invalid TTL and oversized keys fail without mutation`() throws {
        var book = LeaseBook(bootID: "boot")
        for ttl in [0, -1, Double.infinity, Double.nan] {
            #expect(throws: LeaseFailure.invalidTTL) { try book.acquire(proposal("a", ttl: ttl), at: time(1_000)) }
        }
        #expect(throws: LeaseFailure.invalidField) { try book.acquire(proposal(String(repeating: "x", count: 257)), at: time(1_001)) }
        #expect(book.demand == .none)
    }

    @Test
    func `capacity check and mutation are one operation`() throws {
        var book = LeaseBook(bootID: "boot", policy: LeasePolicy(maxLeases: 2))
        _ = try book.acquire(proposal("a"), at: time(1_000))
        _ = try book.acquire(proposal("b"), at: time(1_001))
        _ = try book.acquire(proposal("a"), at: time(1_002))
        #expect(throws: LeaseFailure.capacity) { try book.acquire(proposal("c"), at: time(1_003)) }
        #expect(book.leases.count == 2)
    }

    @Test
    func `reboot and owner reuse invalidate persisted leases`() throws {
        var book = LeaseBook(bootID: "boot")
        _ = try book.acquire(proposal("a", owner: owner), at: time(1_000))
        let data = try JSONEncoder().encode(book)
        var restored = try JSONDecoder().decode(LeaseBook.self, from: data)
        _ = restored.recover(bootID: "other-boot", at: time(1_001), identity: { _ in owner })
        #expect(restored.demand == .none)
        restored = try JSONDecoder().decode(LeaseBook.self, from: data)
        _ = restored.recover(bootID: "boot", at: time(1_001), identity: { _ in nil })
        #expect(restored.demand == .none)
    }

    @Test
    func `reboot resets the continuous clock epoch`() throws {
        var book = LeaseBook(bootID: "old")
        _ = try book.acquire(proposal("old"), at: time(1_000))
        _ = book.recover(bootID: "new", at: time(1), identity: { _ in nil })
        _ = try book.acquire(proposal("new", ttl: 10), at: time(2))
        #expect(book.demand.system)
    }

    @Test
    func `rebinding an existing key cannot bypass owner capacity`() throws {
        var book = LeaseBook(bootID: "boot", policy: LeasePolicy(maxLeasesPerOwner: 1))
        let other = ProcessIdentity(pid: 200, uid: 501, startSeconds: 900, startMicroseconds: 0)
        _ = try book.acquire(proposal("a", owner: owner), at: time(1_000))
        _ = try book.acquire(proposal("b", owner: other), at: time(1_001))
        #expect(throws: LeaseFailure.capacity) {
            try book.acquire(proposal("a", owner: other), at: time(1_002))
        }
    }

    @Test
    func `expired journal entries cannot permanently exhaust capacity`() throws {
        var book = LeaseBook(bootID: "boot")
        for index in 0 ..< 4_096 {
            _ = try book.release(key: "old-\(index)", at: time(1_000 + Double(index) / 1_000))
        }
        _ = try book.acquire(proposal("new"), at: time(1_200))
        #expect(book.demand.system)
    }

    @Test
    func `an expiry and replacement are one demand transition`() throws {
        var book = LeaseBook(bootID: "boot")
        _ = try book.acquire(proposal("old", ttl: 10), at: time(1_000))
        let change = try book.acquire(proposal("new"), at: time(1_010))
        #expect(change.transition == nil)
        #expect(book.leases.map(\.key) == ["new"])
    }

    @Test
    func `corrupt persistence cannot create an unbounded lease`() throws {
        var book = LeaseBook(bootID: "boot")
        _ = try book.acquire(proposal("a", ttl: 60), at: time(1_000))
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(book)) as? [String: Any])
        var entries = try #require(object["entries"] as? [String: [String: Any]])
        entries["a"]?["deadline"] = 1e100
        entries["a"]?["ttlSeconds"] = 1e100
        object["entries"] = entries
        var restored = try JSONDecoder().decode(LeaseBook.self, from: JSONSerialization.data(withJSONObject: object))
        _ = restored.recover(bootID: "boot", at: time(1_001), identity: { _ in nil })
        #expect(restored.demand == .none)
        #expect(restored.leases.isEmpty)
    }

    @Test
    func `wall clock rollback cannot extend an expired lease`() throws {
        var book = LeaseBook(bootID: "boot")
        _ = try book.acquire(proposal("a", ttl: 10), at: time(1_000))
        _ = book.advance(to: LeaseTime(wall: Date(timeIntervalSince1970: 1), continuous: 1_010))
        #expect(book.demand == .none)
    }
}
