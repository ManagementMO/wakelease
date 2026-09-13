import Foundation
import Testing
@testable import AdrafinilShared

@Suite("WakeLease preferences")
struct WakeLeasePreferencesTests {
    private func time(_ value: Double) -> LeaseTime {
        LeaseTime(wall: Date(timeIntervalSince1970: value), continuous: value)
    }

    @Test
    func `defaults are private conservative and versioned`() throws {
        let preferences = try JSONDecoder().decode(WakeLeasePreferences.self, from: Data("{}".utf8))
        #expect(preferences.version == 1)
        #expect(!preferences.preSleepCue)
        #expect(!preferences.notifySafety)
        #expect(preferences.policy.waitingGraceSeconds == 600)
        #expect(preferences.policy.batteryCutoff == 20)
    }

    @Test
    func `unsupported preferences are not silently downgraded`() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(WakeLeasePreferences.self, from: Data(#"{"version":99}"#.utf8))
        }
    }

    @Test
    func `preferences round trip uses private atomic storage`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wl-prefs-" + UUID().uuidString)
        let directory = try SecureDirectory(url: root, create: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var preferences = WakeLeasePreferences()
        preferences.policy.waitingGraceSeconds = 120
        try preferences.save(to: directory)
        #expect(try WakeLeasePreferences.load(from: directory) == preferences)
        #expect(try directory.permissions(name: WakeLeaseIdentity.configFilename) == 0o600)
    }

    @Test
    func `settings protocol is read only until explicit configure`() async {
        let broker = LeaseBroker()
        let service = LeaseProtocolService(broker: broker, mode: "simulation")
        let reply = await service.handle(LeaseRequest(operation: "settings"), peer: LocalPeer(uid: getuid(), pid: getpid()))
        #expect(reply.ok)
        #expect(reply.preferences?.policy.waitingGraceSeconds == 600)
        #expect(await broker.snapshot().demand == .none)
    }

    @Test
    func `policy bounds survive direct preference mutation`() {
        var preferences = WakeLeasePreferences()
        preferences.policy.batteryCutoff = -10
        preferences.policy.thermalCutoff = 999
        preferences.policy.maximumTTLSeconds = 1e9
        let normalized = preferences.normalized()
        #expect(normalized.policy.batteryCutoff == 10)
        #expect(normalized.policy.thermalCutoff == 95)
        #expect(normalized.policy.maximumTTLSeconds == 86_400)
    }

    @Test
    func `waiting policy updates affect existing waits`() throws {
        var book = LeaseBook(bootID: "boot", policy: LeasePolicy(waitingPolicy: .keepAwake))
        _ = try book.acquire(LeaseProposal(key: "a"), at: time(1_000))
        _ = try book.wait(key: "a", at: time(1_001))
        _ = book.setPolicy(LeasePolicy(waitingPolicy: .sleep), at: time(1_002))
        #expect(book.demand == .none)
    }

    @Test
    func `changed grace is measured from the original wait`() throws {
        var book = LeaseBook(bootID: "boot")
        _ = try book.acquire(LeaseProposal(key: "a"), at: time(1_000))
        _ = try book.wait(key: "a", at: time(1_001))
        _ = book.setPolicy(LeasePolicy(waitingGraceSeconds: 60), at: time(1_020))
        _ = book.advance(to: time(1_061))
        #expect(book.demand == .none)
    }

    @Test
    func `a lower lifetime limit bounds existing leases`() throws {
        var book = LeaseBook(bootID: "boot")
        _ = try book.acquire(LeaseProposal(key: "a", ttlSeconds: 3_600), at: time(1_000))
        _ = book.setPolicy(LeasePolicy(maximumTTLSeconds: 30), at: time(1_001))
        _ = book.advance(to: time(1_031))
        #expect(book.demand == .none)
    }
}
