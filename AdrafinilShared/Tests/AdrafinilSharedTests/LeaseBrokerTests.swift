import Foundation
import Testing
@testable import AdrafinilShared

@Suite("Lease broker concurrency")
struct LeaseBrokerTests {
    @Test func concurrentAcquiresCannotOversubscribeRegistry() async throws {
        let broker = LeaseBroker(policy: LeasePolicy(maxLeases: 16))
        let accepted = await withTaskGroup(of: Bool.self) { group in
            for index in 0..<64 {
                group.addTask {
                    (try? await broker.acquire(LeaseProposal(key: "job-\(index)", source: "build"))) != nil
                }
            }
            var count = 0
            for await didAcquire in group where didAcquire { count += 1 }
            return count
        }
        #expect(accepted == 16)
        #expect(await broker.snapshot().effectiveCount == 16)
        let snapshot = await broker.snapshot()
        await withTaskGroup(of: Void.self) { group in
            for lease in snapshot.leases {
                group.addTask { _ = try? await broker.release(key: lease.key) }
            }
        }
        #expect(await broker.snapshot().demand == .none)
    }

    @Test func aNewAcquireRacingFinalReleaseCannotLeaveAStaleSnapshot() async throws {
        let broker = LeaseBroker()
        _ = try await broker.acquire(LeaseProposal(key: "old"))
        async let release = broker.release(key: "old")
        async let acquire = broker.acquire(LeaseProposal(key: "new"))
        _ = try await (release, acquire)
        let snapshot = await broker.snapshot()
        #expect(snapshot.leases.map(\.key) == ["new"])
        #expect(snapshot.demand.system)
        var iterator = broker.changes.makeAsyncIterator()
        #expect(await iterator.next()?.generation == snapshot.generation)
    }

    @Test func aCutoutRacingAnAcquireCannotBeBypassed() async {
        let broker = LeaseBroker()
        async let acquisition = try? broker.acquire(LeaseProposal(key: "job"))
        async let hazard: Void = broker.updateSafety(LeaseSafety(lidClosed: true, temperatureCelsius: 100, thermalState: .critical))
        _ = await (acquisition, hazard)
        #expect(await broker.snapshot().demand == .none)
        do {
            _ = try await broker.acquire(LeaseProposal(key: "again"))
            Issue.record("A latched or present hazard admitted work")
        } catch {
            #expect(error as? LeaseFailure == .safetyCutout)
        }
    }

    @Test func ownerPIDMustBelongToAuthenticatedUser() async throws {
        let broker = LeaseBroker()
        let identity = try #require(SystemProcessIdentity.read(getpid()))
        let proposal = LeaseProposal(key: "owned", owner: identity)
        do {
            _ = try await broker.acquire(proposal, peerUID: identity.uid + 1)
            Issue.record("Foreign UID accepted")
        } catch {
            #expect(error as? LeaseFailure == .ownerUnavailable)
        }
        _ = try await broker.acquire(proposal, peerUID: identity.uid)
        #expect(await broker.snapshot().effectiveCount == 1)
    }

    @Test func processBirthIdentityIsStableAndInvalidPIDsAreRejected() throws {
        let first = try #require(SystemProcessIdentity.read(getpid()))
        #expect(first == SystemProcessIdentity.read(getpid()))
        #expect(first.uid == getuid())
        #expect(first.startSeconds > 0)
        #expect(SystemProcessIdentity.read(-1) == nil)
        #expect(SystemProcessIdentity.read(0) == nil)
    }

    @Test func safetyLatchSurvivesBrokerRestart() async throws {
        let broker = LeaseBroker()
        _ = try await broker.acquire(LeaseProposal(key: "a"))
        await broker.updateSafety(LeaseSafety(lidClosed: true, temperatureCelsius: 95, thermalState: .critical))
        let data = try await broker.encodedState()
        let restored = LeaseBroker()
        try await restored.restore(data)
        #expect(await restored.snapshot().cutouts.contains(.thermal))
        #expect(await restored.snapshot().demand == .none)
    }
}
