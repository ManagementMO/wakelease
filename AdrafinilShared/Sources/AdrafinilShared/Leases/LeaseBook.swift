import Foundation

public struct LeaseBook: Codable, Sendable {
    private struct Revision: Codable, Sendable {
        var at: TimeInterval
        var terminal: Bool
    }

    private var entries: [String: WakeLease] = [:]
    private var revisions: [String: Revision] = [:]
    private struct ControlRevision: Codable, Sendable {
        let operation: String
        let issuedAt: TimeInterval
    }
    private var lastControl: ControlRevision?
    private var replayBarrier: TimeInterval = -1
    private var now = LeaseTime(wall: Date(timeIntervalSince1970: 0), continuous: 0)
    private var thermalCoolSince: TimeInterval?
    private var thermalRequiresTemperature = false
    public private(set) var bootID: String
    public private(set) var policy: LeasePolicy
    public private(set) var generation: UInt64 = 0
    public private(set) var paused = false
    public private(set) var cutouts: Set<LeaseCutout> = []
    public private(set) var safety = LeaseSafety()
    public private(set) var lastCutout: LeaseEvent?

    public init(bootID: String, policy: LeasePolicy = LeasePolicy()) {
        self.bootID = bootID
        self.policy = policy
    }

    public var leases: [WakeLease] {
        entries.values.sorted { ($0.acquiredAt, $0.key) < ($1.acquiredAt, $1.key) }
    }

    public var effectiveLeases: [WakeLease] {
        guard !paused, cutouts.isEmpty else { return [] }
        return leases.filter { $0.requiresWake(at: now) }
    }

    public var demand: WakeDemand {
        let effective = effectiveLeases
        return WakeDemand(system: !effective.isEmpty, display: effective.contains { $0.wakeClass == .display })
    }

    public var nextDeadline: TimeInterval? {
        entries.values.flatMap { lease -> [TimeInterval] in
            var deadlines = [lease.deadline]
            if let wait = lease.waitingUntil, wait > now.continuous { deadlines.append(wait) }
            return deadlines
        }.min()
    }

    public mutating func acquire(_ proposal: LeaseProposal, at time: LeaseTime, issuedAt: TimeInterval? = nil) throws -> LeaseChange {
        try validate(proposal)
        guard !paused else { throw LeaseFailure.paused }
        let before = demand
        if !hazards.isEmpty {
            trip(hazards, at: time)
            _ = finish(before: before, changed: true, events: [])
        }
        guard cutouts.isEmpty else { throw LeaseFailure.safetyCutout }
        let stamp = issuedAt ?? time.continuous
        try checkOrder(key: proposal.key, stamp: stamp, at: time, terminal: false)
        if revisions[proposal.key]?.at == stamp, let existing = entries[proposal.key] {
            return finish(before: before, changed: false, lease: existing)
        }
        let ttl = try validatedTTL(proposal.ttlSeconds)
        let current = entries[proposal.key].flatMap { $0.deadline > time.continuous ? $0 : nil }
        let survivors = entries.values.filter { $0.deadline > time.continuous }
        if current == nil {
            guard survivors.count < policy.maxLeases else { throw LeaseFailure.capacity }
        }
        if let owner = proposal.owner ?? current?.owner {
            guard survivors.count(where: { $0.key != proposal.key && $0.owner == owner }) < policy.maxLeasesPerOwner else { throw LeaseFailure.capacity }
        }
        let expired = purge(at: time)
        var lease = current ?? WakeLease(
            id: UUID(), key: proposal.key, source: proposal.source, sourceKind: proposal.sourceKind,
            wakeClass: proposal.wakeClass, state: .active, reason: proposal.reason, owner: proposal.owner,
            sessionID: proposal.sessionID, parentLeaseID: proposal.parentLeaseID, acquiredAt: time.wall,
            lastActivityAt: time.wall, lastHeartbeatAt: nil, expiresAt: time.wall.addingTimeInterval(ttl),
            deadline: time.continuous + ttl, ttlSeconds: ttl, waitingUntil: nil, waitingExpiresAt: nil,
            metadata: proposal.metadata,
        )
        lease.state = .active
        lease.wakeClass = lease.wakeClass == .display ? .display : proposal.wakeClass
        lease.reason = proposal.reason ?? lease.reason
        lease.owner = proposal.owner ?? lease.owner
        lease.lastActivityAt = time.wall
        lease.expiresAt = time.wall.addingTimeInterval(ttl)
        lease.deadline = time.continuous + ttl
        lease.ttlSeconds = ttl
        lease.waitingUntil = nil
        lease.waitingExpiresAt = nil
        lease.waitingStarted = nil
        if !proposal.metadata.isEmpty { lease.metadata = proposal.metadata }
        entries[lease.key] = lease
        revisions[lease.key] = Revision(at: stamp, terminal: false)
        return finish(before: before, changed: true, lease: lease, events: expired + [event(current == nil ? .acquired : .renewed, lease.id)])
    }

    public mutating func renew(key: String, ttlSeconds: TimeInterval? = nil, at time: LeaseTime, issuedAt: TimeInterval? = nil) throws -> LeaseChange {
        guard !paused else { throw LeaseFailure.paused }
        guard cutouts.isEmpty else { throw LeaseFailure.safetyCutout }
        let stamp = issuedAt ?? time.continuous
        try checkOrder(key: key, stamp: stamp, at: time, terminal: false)
        guard var lease = entries[key], lease.deadline > time.continuous else { throw LeaseFailure.unknownLease }
        let before = demand
        if revisions[key]?.at == stamp { return finish(before: before, changed: false, lease: lease) }
        let ttl = try validatedTTL(ttlSeconds ?? lease.ttlSeconds)
        let expired = purge(at: time)
        lease.ttlSeconds = ttl
        lease.expiresAt = time.wall.addingTimeInterval(ttl)
        lease.deadline = time.continuous + ttl
        lease.lastHeartbeatAt = time.wall
        lease.lastActivityAt = time.wall
        entries[key] = lease
        revisions[key] = Revision(at: stamp, terminal: false)
        return finish(before: before, changed: true, lease: lease, events: expired + [event(.renewed, lease.id)])
    }

    public mutating func wait(key: String, reason: String? = nil, at time: LeaseTime, issuedAt: TimeInterval? = nil) throws -> LeaseChange {
        if let reason { try Self.validateText(reason, maximum: 512, emptyAllowed: true) }
        let stamp = issuedAt ?? time.continuous
        try checkOrder(key: key, stamp: stamp, at: time, terminal: false)
        guard var lease = entries[key], lease.deadline > time.continuous else { throw LeaseFailure.unknownLease }
        let before = demand
        let expired = purge(at: time)
        if lease.state != .waitingForUser {
            lease.state = .waitingForUser
            lease.waitingStarted = time.continuous
            let grace: TimeInterval? = switch policy.waitingPolicy {
            case .keepAwake: nil
            case .grace: policy.waitingGraceSeconds
            case .sleep: 0
            }
            lease.waitingUntil = grace.map { time.continuous + $0 }
            lease.waitingExpiresAt = grace.map { time.wall.addingTimeInterval($0) }
        }
        lease.reason = reason ?? lease.reason
        entries[key] = lease
        revisions[key] = Revision(at: stamp, terminal: false)
        return finish(before: before, changed: true, lease: lease, events: expired + [event(.waiting, lease.id)])
    }

    public mutating func release(key: String, at time: LeaseTime, issuedAt: TimeInterval? = nil) throws -> LeaseChange {
        let stamp = issuedAt ?? time.continuous
        try checkOrder(key: key, stamp: stamp, at: time, terminal: true)
        let before = demand
        let expired = purge(at: time)
        let removed = entries.removeValue(forKey: key)
        revisions[key] = Revision(at: stamp, terminal: true)
        return finish(before: before, changed: removed != nil || !expired.isEmpty, events: expired + (removed.map { [event(.released, $0.id)] } ?? []))
    }

    public mutating func advance(to time: LeaseTime, identity: ((Int32) -> ProcessIdentity?)? = nil) -> LeaseChange {
        let before = demand
        var events = purge(at: time)
        if let identity {
            for lease in Array(entries.values) {
                if let owner = lease.owner, identity(owner.pid) != owner {
                    entries.removeValue(forKey: lease.key)
                    revisions[lease.key] = Revision(at: time.continuous, terminal: true)
                    events.append(event(.ownerDied, lease.id))
                }
            }
        }
        return finish(before: before, changed: !events.isEmpty, events: events)
    }

    public mutating func control(_ operation: String, issuedAt: TimeInterval, at time: LeaseTime) throws -> LeaseChange {
        guard ["pause", "resume", "releaseAll"].contains(operation) else { throw LeaseFailure.invalidField }
        guard issuedAt.isFinite, issuedAt >= 0, issuedAt >= time.continuous - 120, issuedAt <= time.continuous + 1 else { throw LeaseFailure.staleRequest }
        if let lastControl {
            if lastControl.issuedAt == issuedAt, lastControl.operation == operation {
                return finish(before: demand, changed: false)
            }
            guard issuedAt > lastControl.issuedAt else { throw LeaseFailure.staleRequest }
        }
        lastControl = ControlRevision(operation: operation, issuedAt: issuedAt)
        if operation == "releaseAll" { return releaseAll(at: time) }
        return setPaused(operation == "pause", at: time)
    }

    public mutating func releaseAll(at time: LeaseTime) -> LeaseChange {
        let before = demand
        now = time
        replayBarrier = max(replayBarrier, time.continuous)
        let events = entries.values.map { event(.released, $0.id) }
        entries.removeAll()
        return finish(before: before, changed: !events.isEmpty, events: events)
    }

    public mutating func setPaused(_ value: Bool, at time: LeaseTime) -> LeaseChange {
        let before = demand
        let changed = paused != value
        now = time
        paused = value
        replayBarrier = max(replayBarrier, time.continuous)
        if value { entries.removeAll() }
        return finish(before: before, changed: changed, events: changed ? [event(value ? .paused : .resumed, nil)] : [])
    }

    public mutating func updateSafety(_ value: LeaseSafety, at time: LeaseTime) -> LeaseChange {
        let before = demand
        let oldCutouts = cutouts
        let oldSafety = safety
        now = time
        safety = value
        if cutouts.contains(.lowBattery), value.onBattery == false || (value.batteryPercent.map { $0 >= policy.batteryCutoff + 5 } ?? false) {
            cutouts.remove(.lowBattery)
        }
        if cutouts.contains(.thermal) {
            let temperatureSafe = value.temperatureCelsius.map { $0 <= policy.thermalCutoff - 5 } ?? !thermalRequiresTemperature
            let systemSafe = value.thermalState == .nominal || value.thermalState == .fair
            if temperatureSafe, systemSafe {
                if thermalCoolSince == nil { thermalCoolSince = time.continuous }
                if time.continuous - (thermalCoolSince ?? time.continuous) >= 60 {
                    cutouts.remove(.thermal)
                    thermalCoolSince = nil
                    thermalRequiresTemperature = false
                }
            } else {
                thermalCoolSince = nil
            }
        }
        let detected = hazards
        var events: [LeaseEvent] = []
        if before.system, !detected.isEmpty {
            events = trip(detected, at: time)
        }
        return finish(before: before, changed: oldCutouts != cutouts || oldSafety != value || !events.isEmpty, events: events)
    }

    public mutating func recover(bootID currentBoot: String, at time: LeaseTime, identity: @escaping (Int32) -> ProcessIdentity?) -> LeaseChange {
        let before = demand
        thermalCoolSince = nil
        if bootID != currentBoot {
            entries.removeAll()
            revisions.removeAll()
            replayBarrier = -1
            lastControl = nil
            now = time
        }
        bootID = currentBoot
        if paused || !cutouts.isEmpty { entries.removeAll() }
        if entries.count > policy.maxLeases || revisions.count > 4_096 || !replayBarrier.isFinite || replayBarrier > time.continuous + 1 {
            entries.removeAll()
            revisions.removeAll()
            replayBarrier = time.continuous
        }
        let recovered = entries.filter { key, lease in
            guard key == lease.key, [.active, .finishing, .waitingForUser].contains(lease.state),
                  lease.deadline.isFinite, lease.ttlSeconds.isFinite, lease.ttlSeconds > 0,
                  lease.ttlSeconds <= policy.maximumTTLSeconds,
                  lease.deadline <= time.continuous + policy.maximumTTLSeconds,
                  lease.acquiredAt.timeIntervalSince1970.isFinite,
                  abs(lease.acquiredAt.timeIntervalSince1970) < 1e11,
                  abs(lease.lastActivityAt.timeIntervalSince1970) < 1e11,
                  lease.lastHeartbeatAt.map({ abs($0.timeIntervalSince1970) < 1e11 }) ?? true,
                  lease.waitingUntil.map({ $0.isFinite && $0 <= time.continuous + policy.maximumTTLSeconds + 7_200 }) ?? true else { return false }
            let proposal = LeaseProposal(key: key, source: lease.source, ttlSeconds: lease.ttlSeconds, reason: lease.reason, owner: lease.owner, sessionID: lease.sessionID, metadata: lease.metadata)
            return (try? validate(proposal)) != nil
        }
        entries = recovered
        revisions = revisions.filter { $0.value.at.isFinite && $0.value.at >= 0 && $0.value.at <= time.continuous + 1 }
        if let control = lastControl, !control.issuedAt.isFinite || control.issuedAt > time.continuous + 1 { lastControl = nil }
        _ = advance(to: time, identity: identity)
        return finish(before: before, changed: true, events: [event(.recovery, nil)])
    }

    public mutating func setPolicy(_ value: LeasePolicy, at time: LeaseTime) -> LeaseChange {
        let before = demand
        let previous = policy
        policy = value.normalized()
        now = time
        for var lease in Array(entries.values) {
            lease.ttlSeconds = min(lease.ttlSeconds, policy.maximumTTLSeconds)
            lease.deadline = min(lease.deadline, time.continuous + policy.maximumTTLSeconds)
            lease.expiresAt = time.wall.addingTimeInterval(lease.deadline - time.continuous)
            if lease.state == .waitingForUser {
                let start = lease.waitingStarted ?? lease.waitingUntil.map { $0 - previous.waitingGraceSeconds } ?? time.continuous
                lease.waitingStarted = start
                switch policy.waitingPolicy {
                case .keepAwake: lease.waitingUntil = nil
                case .grace: lease.waitingUntil = start + policy.waitingGraceSeconds
                case .sleep: lease.waitingUntil = time.continuous
                }
                lease.waitingExpiresAt = lease.waitingUntil.map { time.wall.addingTimeInterval($0 - time.continuous) }
            }
            entries[lease.key] = lease
        }
        let safetyChange = updateSafety(safety, at: time)
        return finish(before: before, changed: previous != policy || safetyChange.changed, events: safetyChange.events)
    }

    private var hazards: Set<LeaseCutout> {
        guard safety.lidClosed == true else { return [] }
        var causes: Set<LeaseCutout> = []
        if safety.thermalState == .serious || safety.thermalState == .critical || (safety.temperatureCelsius.map { $0 >= policy.thermalCutoff } ?? false) {
            causes.insert(.thermal)
        }
        if safety.onBattery == true, let charge = safety.batteryPercent, charge <= policy.batteryCutoff {
            causes.insert(.lowBattery)
        }
        return causes
    }

    @discardableResult
    private mutating func trip(_ causes: Set<LeaseCutout>, at time: LeaseTime) -> [LeaseEvent] {
        now = time
        cutouts.formUnion(causes)
        replayBarrier = max(replayBarrier, time.continuous)
        entries.removeAll()
        if causes.contains(.thermal) {
            thermalCoolSince = nil
            thermalRequiresTemperature = thermalRequiresTemperature || (safety.temperatureCelsius.map { $0 >= policy.thermalCutoff } ?? false)
        }
        let events = causes.sorted { $0.rawValue < $1.rawValue }.map { event($0 == .thermal ? .thermalCutout : .batteryCutout, nil) }
        lastCutout = events.last
        return events
    }

    private mutating func purge(at time: LeaseTime) -> [LeaseEvent] {
        guard time.continuous.isFinite, time.continuous >= now.continuous else { return [] }
        now = time
        var events: [LeaseEvent] = []
        for lease in Array(entries.values) where lease.deadline <= time.continuous {
            entries.removeValue(forKey: lease.key)
            revisions[lease.key] = Revision(at: time.continuous, terminal: true)
            events.append(event(.expired, lease.id))
        }
        revisions = revisions.filter { entries[$0.key] != nil || $0.value.at >= time.continuous - 120 }
        return events
    }

    private func validatedTTL(_ requested: TimeInterval?) throws -> TimeInterval {
        let ttl = requested ?? policy.defaultTTLSeconds
        guard ttl.isFinite, ttl > 0 else { throw LeaseFailure.invalidTTL }
        return min(ttl, policy.maximumTTLSeconds)
    }

    private func checkOrder(key: String, stamp: TimeInterval, at time: LeaseTime, terminal: Bool) throws {
        try Self.validateText(key, maximum: 256)
        guard stamp.isFinite, stamp >= 0, stamp >= time.continuous - 120, stamp <= time.continuous + 1, terminal || stamp > replayBarrier else {
            throw LeaseFailure.staleRequest
        }
        if let previous = revisions[key] {
            guard stamp >= previous.at, !(stamp == previous.at && previous.terminal && !terminal) else { throw LeaseFailure.staleRequest }
        } else if revisions.count(where: { entries[$0.key] != nil || $0.value.at >= time.continuous - 120 }) >= 4_096 {
            throw LeaseFailure.capacity
        }
    }

    private func validate(_ proposal: LeaseProposal) throws {
        try Self.validateText(proposal.key, maximum: 256)
        try Self.validateText(proposal.source, maximum: 64)
        if let reason = proposal.reason { try Self.validateText(reason, maximum: 512, emptyAllowed: true) }
        if let session = proposal.sessionID { try Self.validateText(session, maximum: 256) }
        if let owner = proposal.owner {
            guard owner.pid > 0, owner.startSeconds > 0, owner.startMicroseconds < 1_000_000 else { throw LeaseFailure.ownerUnavailable }
        }
        guard proposal.metadata.count <= 16 else { throw LeaseFailure.invalidField }
        for (key, value) in proposal.metadata {
            try Self.validateText(key, maximum: 64)
            try Self.validateText(value, maximum: 256, emptyAllowed: true)
        }
        _ = try validatedTTL(proposal.ttlSeconds)
    }

    private static func validateText(_ value: String, maximum: Int, emptyAllowed: Bool = false) throws {
        guard value.utf8.count <= maximum, emptyAllowed || !value.trimmingCharacters(in: .whitespaces).isEmpty,
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { throw LeaseFailure.invalidField }
    }

    private func event(_ kind: LeaseEventKind, _ id: UUID?) -> LeaseEvent {
        LeaseEvent(kind: kind, leaseID: id, at: now.wall)
    }

    private mutating func finish(before: WakeDemand, changed: Bool, lease: WakeLease? = nil, events: [LeaseEvent] = []) -> LeaseChange {
        let after = demand
        let transition = before == after ? nil : WakeTransition(from: before, to: after)
        if changed || transition != nil { generation &+= 1 }
        return LeaseChange(changed: changed || transition != nil, lease: lease, transition: transition, events: events)
    }
}
