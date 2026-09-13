import Foundation

public struct LeaseSnapshot: Codable, Sendable {
    public let daemonBootID: UUID
    public let bootID: String
    public let generation: UInt64
    public let leases: [WakeLease]
    public let effectiveCount: Int
    public let demand: WakeDemand
    public let paused: Bool
    public let cutouts: Set<LeaseCutout>
    public let safety: LeaseSafety
    public let lastCutout: LeaseEvent?
    public let nextDeadline: TimeInterval?
    public let sleepClosedLidOnFinalRelease: Bool

    init(book: LeaseBook, daemonBootID: UUID) {
        self.daemonBootID = daemonBootID
        bootID = book.bootID
        generation = book.generation
        leases = book.leases
        effectiveCount = book.effectiveLeases.count
        demand = book.demand
        paused = book.paused
        cutouts = book.cutouts
        safety = book.safety
        lastCutout = book.lastCutout
        nextDeadline = book.nextDeadline
        sleepClosedLidOnFinalRelease = book.policy.sleepClosedLidOnFinalRelease
    }
}

public actor LeaseBroker {
    private var book: LeaseBook
    private let clock: any LeaseClock
    private let identify: @Sendable (Int32) -> ProcessIdentity?
    private let persist: @Sendable (LeaseBook, [LeaseEvent]) -> Void
    private let runID = UUID()
    public nonisolated let changes: AsyncStream<LeaseSnapshot>
    private let continuation: AsyncStream<LeaseSnapshot>.Continuation

    public init(policy: LeasePolicy = LeasePolicy(), clock: any LeaseClock = SystemLeaseClock(), identify: @escaping @Sendable (Int32) -> ProcessIdentity? = SystemProcessIdentity.read, persist: @escaping @Sendable (LeaseBook, [LeaseEvent]) -> Void = { _, _ in }) {
        self.clock = clock
        self.identify = identify
        self.persist = persist
        self.book = LeaseBook(bootID: clock.bootID, policy: policy)
        let stream = AsyncStream.makeStream(of: LeaseSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        changes = stream.stream
        continuation = stream.continuation
    }

    deinit { continuation.finish() }

    public func snapshot() -> LeaseSnapshot {
        LeaseSnapshot(book: book, daemonBootID: runID)
    }

    public func encodedState() throws -> Data {
        try JSONEncoder().encode(book)
    }

    public func restore(_ data: Data) throws {
        guard data.count <= 2 * 1024 * 1024 else { throw LeaseFailure.capacity }
        var restored = try JSONDecoder().decode(LeaseBook.self, from: data)
        let time = clock.now()
        _ = restored.setPolicy(book.policy, at: time)
        let change = restored.recover(bootID: clock.bootID, at: time, identity: identify)
        book = restored
        publish(change.events)
    }

    @discardableResult
    public func acquire(_ proposal: LeaseProposal, issuedAt: TimeInterval? = nil, peerUID: UInt32? = nil) throws -> LeaseChange {
        if let owner = proposal.owner {
            guard (peerUID == nil || owner.uid == peerUID), identify(owner.pid) == owner else { throw LeaseFailure.ownerUnavailable }
        }
        return try mutate { book, time in try book.acquire(proposal, at: time, issuedAt: issuedAt) }
    }

    @discardableResult
    public func renew(key: String, ttlSeconds: TimeInterval? = nil, issuedAt: TimeInterval? = nil) throws -> LeaseChange {
        try mutate { book, time in try book.renew(key: key, ttlSeconds: ttlSeconds, at: time, issuedAt: issuedAt) }
    }

    @discardableResult
    public func wait(key: String, reason: String? = nil, issuedAt: TimeInterval? = nil) throws -> LeaseChange {
        try mutate { book, time in try book.wait(key: key, reason: reason, at: time, issuedAt: issuedAt) }
    }

    @discardableResult
    public func release(key: String, issuedAt: TimeInterval? = nil) throws -> LeaseChange {
        try mutate { book, time in try book.release(key: key, at: time, issuedAt: issuedAt) }
    }

    @discardableResult
    public func releaseAll() -> LeaseChange {
        mutate { book, time in book.releaseAll(at: time) }
    }

    public func setPaused(_ value: Bool) {
        _ = mutate { book, time in book.setPaused(value, at: time) }
    }

    public func updateSafety(_ value: LeaseSafety) {
        _ = mutate { book, time in book.updateSafety(value, at: time) }
    }

    public func setPolicy(_ value: LeasePolicy) {
        _ = mutate { book, time in book.setPolicy(value, at: time) }
    }

    public func sweep() {
        let change = book.advance(to: clock.now(), identity: identify)
        if change.changed { publish(change.events) }
    }

    private func mutate(_ body: (inout LeaseBook, LeaseTime) throws -> LeaseChange) rethrows -> LeaseChange {
        let before = book.demand
        let generation = book.generation
        let time = clock.now()
        let expired = book.advance(to: time)
        do {
            let result = try body(&book, time)
            let events = expired.events + result.events
            if book.generation != generation || !events.isEmpty { publish(events) }
            else { persist(book, []) }
            return LeaseChange(changed: result.changed || expired.changed, lease: result.lease, transition: before == book.demand ? nil : WakeTransition(from: before, to: book.demand), events: events)
        } catch {
            if book.generation != generation { publish(expired.events) }
            throw error
        }
    }

    private func publish(_ events: [LeaseEvent]) {
        persist(book, events)
        continuation.yield(snapshot())
    }
}
