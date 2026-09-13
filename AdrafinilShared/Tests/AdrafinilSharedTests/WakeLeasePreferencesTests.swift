import Foundation
import Testing
@testable import AdrafinilShared

@Suite("WakeLease preferences")
struct WakeLeasePreferencesTests {
    private func time(_ value: Double) -> LeaseTime { LeaseTime(wall: Date(timeIntervalSince1970: value), continuous: value) }

    @Test func defaultsArePrivateConservativeAndVersioned() throws {
        let preferences = try JSONDecoder().decode(WakeLeasePreferences.self, from: Data("{}".utf8))
        #expect(preferences.version == 1)
        #expect(!preferences.preSleepCue)
        #expect(!preferences.notifySafety)
        #expect(preferences.policy.waitingGraceSeconds == 600)
        #expect(preferences.policy.batteryCutoff == 20)
    }

    @Test func unsupportedPreferencesAreNotSilentlyDowngraded() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(WakeLeasePreferences.self, from: Data(#"{"version":99}"#.utf8))
        }
    }

    @Test func preferencesRoundTripUsesPrivateAtomicStorage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wl-prefs-" + UUID().uuidString)
        let directory = try SecureDirectory(url: root, create: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var preferences = WakeLeasePreferences()
        preferences.policy.waitingGraceSeconds = 120
        try preferences.save(to: directory)
        #expect(try WakeLeasePreferences.load(from: directory) == preferences)
        #expect(try directory.permissions(name: WakeLeaseIdentity.configFilename) == 0o600)
    }

    @Test func settingsProtocolIsReadOnlyUntilExplicitConfigure() async throws {
        let broker = LeaseBroker()
        let service = LeaseProtocolService(broker: broker, mode: "simulation")
        let reply = await service.handle(LeaseRequest(operation: "settings"), peer: LocalPeer(uid: getuid(), pid: getpid()))
        #expect(reply.ok)
        #expect(reply.preferences?.policy.waitingGraceSeconds == 600)
        #expect(await broker.snapshot().demand == .none)
    }

    @Test func policyBoundsSurviveDirectPreferenceMutation() {
        var preferences = WakeLeasePreferences()
        preferences.policy.batteryCutoff = -10
        preferences.policy.thermalCutoff = 999
        preferences.policy.maximumTTLSeconds = 1e9
        let normalized = preferences.normalized()
        #expect(normalized.policy.batteryCutoff == 10)
        #expect(normalized.policy.thermalCutoff == 95)
        #expect(normalized.policy.maximumTTLSeconds == 86400)
    }

    @Test func waitingPolicyUpdatesAffectExistingWaits() throws {
        var book = LeaseBook(bootID: "boot", policy: LeasePolicy(waitingPolicy: .keepAwake))
        _ = try book.acquire(LeaseProposal(key: "a"), at: time(1000))
        _ = try book.wait(key: "a", at: time(1001))
        _ = book.setPolicy(LeasePolicy(waitingPolicy: .sleep), at: time(1002))
        #expect(book.demand == .none)
    }

    @Test func changedGraceIsMeasuredFromTheOriginalWait() throws {
        var book = LeaseBook(bootID: "boot")
        _ = try book.acquire(LeaseProposal(key: "a"), at: time(1000))
        _ = try book.wait(key: "a", at: time(1001))
        _ = book.setPolicy(LeasePolicy(waitingGraceSeconds: 60), at: time(1020))
        _ = book.advance(to: time(1061))
        #expect(book.demand == .none)
    }

    @Test func aLowerLifetimeLimitBoundsExistingLeases() throws {
        var book = LeaseBook(bootID: "boot")
        _ = try book.acquire(LeaseProposal(key: "a", ttlSeconds: 3600), at: time(1000))
        _ = book.setPolicy(LeasePolicy(maximumTTLSeconds: 30), at: time(1001))
        _ = book.advance(to: time(1031))
        #expect(book.demand == .none)
    }
}
