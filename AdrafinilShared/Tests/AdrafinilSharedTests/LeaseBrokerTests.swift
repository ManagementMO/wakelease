import Foundation
import os
import Testing
@testable import AdrafinilShared

@Suite("Lease broker concurrency")
struct LeaseBrokerTests {
    @Test
    func `concurrent acquires cannot oversubscribe registry`() async {
        let broker = LeaseBroker(policy: LeasePolicy(maxLeases: 16))
        let accepted = await withTaskGroup(of: Bool.self) { group in
            for index in 0 ..< 64 {
                group.addTask {
                    await (try? broker.acquire(LeaseProposal(key: "job-\(index)", source: "build"))) != nil
                }
            }
            var count = 0
            for await didAcquire in group where didAcquire {
                count += 1
            }
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

    @Test
    func `a new acquire racing final release cannot leave A stale snapshot`() async throws {
        let broker = LeaseBroker()
        _ = try await broker.acquire(LeaseProposal(key: "old"))
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { _ = try await broker.release(key: "old") }
            group.addTask { _ = try await broker.acquire(LeaseProposal(key: "new")) }
            try await group.waitForAll()
        }
        let snapshot = await broker.snapshot()
        #expect(snapshot.leases.map(\.key) == ["new"])
        #expect(snapshot.demand.system)
        var iterator = broker.changes.makeAsyncIterator()
        #expect(await iterator.next()?.generation == snapshot.generation)
    }

    @Test
    func `a cutout racing an acquire cannot be bypassed`() async {
        let broker = LeaseBroker()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = try? await broker.acquire(LeaseProposal(key: "job")) }
            group.addTask { await broker.updateSafety(LeaseSafety(lidClosed: true, temperatureCelsius: 100, thermalState: .critical)) }
            await group.waitForAll()
        }
        #expect(await broker.snapshot().demand == .none)
        do {
            _ = try await broker.acquire(LeaseProposal(key: "again"))
            Issue.record("A latched or present hazard admitted work")
        } catch {
            #expect(error as? LeaseFailure == .safetyCutout)
        }
    }

    @Test
    func `owner PID must belong to authenticated user`() async throws {
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

    @Test
    func `process birth identity is stable and invalid PI ds are rejected`() throws {
        let first = try #require(SystemProcessIdentity.read(getpid()))
        #expect(first == SystemProcessIdentity.read(getpid()))
        #expect(first.uid == getuid())
        #expect(first.startSeconds > 0)
        #expect(SystemProcessIdentity.read(-1) == nil)
        #expect(SystemProcessIdentity.read(0) == nil)
    }

    @Test
    func `renew cannot keep A dead owner alive`() async throws {
        let identity = ProcessIdentity(pid: 42, uid: 501, startSeconds: 100, startMicroseconds: 0)
        let live = OSAllocatedUnfairLock<ProcessIdentity?>(initialState: identity)
        let broker = LeaseBroker(identify: { _ in live.withLock { $0 } })
        _ = try await broker.acquire(LeaseProposal(key: "job", owner: identity))
        live.withLock { $0 = nil }
        do {
            _ = try await broker.renew(key: "job")
            Issue.record("A heartbeat extended an exited process")
        } catch {}
        #expect(await broker.snapshot().demand == .none)
    }

    @Test
    func `shutdown closes admission without persisting A user pause`() async throws {
        let broker = LeaseBroker()
        _ = try await broker.acquire(LeaseProposal(key: "a"))
        let stopped = await broker.beginShutdown()
        #expect(stopped.demand == .none)
        #expect(!stopped.paused)
        do {
            _ = try await broker.acquire(LeaseProposal(key: "late"))
            Issue.record("A late connection resurrected work during shutdown")
        } catch { #expect(error as? LeaseFailure == .paused) }
    }

    @Test
    func `safety latch survives broker restart`() async throws {
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
