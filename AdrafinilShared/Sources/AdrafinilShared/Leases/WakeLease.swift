import Foundation

public struct LeaseTime: Codable, Sendable, Equatable {
    public let wall: Date
    public let continuous: TimeInterval

    public init(wall: Date, continuous: TimeInterval) {
        self.wall = wall
        self.continuous = continuous
    }
}

public struct ProcessIdentity: Codable, Sendable, Hashable {
    public let pid: Int32
    public let uid: UInt32
    public let startSeconds: UInt64
    public let startMicroseconds: UInt64

    public init(pid: Int32, uid: UInt32, startSeconds: UInt64, startMicroseconds: UInt64) {
        self.pid = pid
        self.uid = uid
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
    }
}

public enum WakeClass: String, Codable, Sendable, CaseIterable {
    case system, display
}

public enum LeaseSourceKind: String, Codable, Sendable, CaseIterable {
    case custom, hook, command, process, timed, mcp, heuristic
}

public enum LeaseState: String, Codable, Sendable {
    case active, waitingForUser, finishing, expired, released, cutOut
}

public struct LeaseProposal: Codable, Sendable {
    public var key: String
    public var source: String
    public var sourceKind: LeaseSourceKind
    public var wakeClass: WakeClass
    public var ttlSeconds: TimeInterval?
    public var reason: String?
    public var owner: ProcessIdentity?
    public var sessionID: String?
    public var parentLeaseID: UUID?
    public var metadata: [String: String]

    public init(key: String, source: String = "custom", sourceKind: LeaseSourceKind = .custom, wakeClass: WakeClass = .system, ttlSeconds: TimeInterval? = nil, reason: String? = nil, owner: ProcessIdentity? = nil, sessionID: String? = nil, parentLeaseID: UUID? = nil, metadata: [String: String] = [:]) {
        self.key = key
        self.source = source
        self.sourceKind = sourceKind
        self.wakeClass = wakeClass
        self.ttlSeconds = ttlSeconds
        self.reason = reason
        self.owner = owner
        self.sessionID = sessionID
        self.parentLeaseID = parentLeaseID
        self.metadata = metadata
    }
}

public struct WakeLease: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let key: String
    public let source: String
    public let sourceKind: LeaseSourceKind
    public var wakeClass: WakeClass
    public var state: LeaseState
    public var reason: String?
    public var owner: ProcessIdentity?
    public let sessionID: String?
    public let parentLeaseID: UUID?
    public let acquiredAt: Date
    public var lastActivityAt: Date
    public var lastHeartbeatAt: Date?
    public var expiresAt: Date
    public var deadline: TimeInterval
    public var ttlSeconds: TimeInterval
    public var waitingUntil: TimeInterval?
    public var waitingExpiresAt: Date?
    public var waitingStarted: TimeInterval? = nil
    public var metadata: [String: String]

    public func requiresWake(at time: LeaseTime) -> Bool {
        guard deadline > time.continuous else { return false }
        switch state {
        case .active, .finishing: return true
        case .waitingForUser: return waitingUntil.map { $0 > time.continuous } ?? true
        case .expired, .released, .cutOut: return false
        }
    }
}

public struct WakeDemand: Codable, Sendable, Equatable {
    public let system: Bool
    public let display: Bool
    public static let none = WakeDemand(system: false, display: false)

    public init(system: Bool, display: Bool) {
        self.system = system || display
        self.display = display
    }
}

public struct WakeTransition: Sendable, Equatable {
    public let from: WakeDemand
    public let to: WakeDemand
}

public enum LeaseEventKind: String, Codable, Sendable {
    case acquired = "lease_acquired"
    case renewed = "lease_renewed"
    case waiting = "lease_waiting"
    case released = "lease_released"
    case expired = "lease_expired"
    case ownerDied = "lease_owner_died"
    case thermalCutout = "thermal_cutout"
    case batteryCutout = "battery_cutout"
    case recovery = "recovery_performed"
    case paused, resumed
}

public struct LeaseEvent: Codable, Sendable {
    public let kind: LeaseEventKind
    public let leaseID: UUID?
    public let at: Date
}

public struct LeaseChange: Sendable {
    public let changed: Bool
    public let lease: WakeLease?
    public let transition: WakeTransition?
    public let events: [LeaseEvent]
}

public enum LeaseFailure: String, Error, Codable, Sendable, LocalizedError {
    case staleRequest, invalidTTL, invalidField, capacity, unknownLease, paused, safetyCutout, ownerUnavailable

    public var errorDescription: String? {
        switch self {
        case .staleRequest: "A newer lifecycle event superseded this request, or its delivery window expired."
        case .invalidTTL: "TTL must be a finite positive duration."
        case .invalidField: "A lease field is empty, oversized, or contains control characters."
        case .capacity: "The lease or lifecycle-journal capacity has been reached."
        case .unknownLease: "No live lease matches this key. Acquire a new lease to resume work."
        case .paused: "WakeLease is paused. Resume it before acquiring leases."
        case .safetyCutout: "Wake protection is cut out until the safety hazard recedes."
        case .ownerUnavailable: "The requested process identity cannot be verified for this user."
        }
    }
}

public struct LeasePolicy: Codable, Sendable, Equatable {
    public var defaultTTLSeconds: TimeInterval
    public var maximumTTLSeconds: TimeInterval
    public var waitingPolicy: AgentWaitingPolicy
    public var waitingGraceSeconds: TimeInterval
    public var maxLeases: Int
    public var maxLeasesPerOwner: Int
    public var batteryCutoff: Int
    public var thermalCutoff: Double
    public var sleepClosedLidOnFinalRelease: Bool

    public init(defaultTTLSeconds: TimeInterval = 14_400, maximumTTLSeconds: TimeInterval = 86_400, waitingPolicy: AgentWaitingPolicy = .grace, waitingGraceSeconds: TimeInterval = 600, maxLeases: Int = 128, maxLeasesPerOwner: Int = 32, batteryCutoff: Int = 20, thermalCutoff: Double = 80, sleepClosedLidOnFinalRelease: Bool = true) {
        self.maximumTTLSeconds = maximumTTLSeconds.isFinite ? min(86_400, max(1, maximumTTLSeconds)) : 86_400
        self.defaultTTLSeconds = defaultTTLSeconds.isFinite ? min(self.maximumTTLSeconds, max(1, defaultTTLSeconds)) : min(self.maximumTTLSeconds, 14_400)
        self.waitingPolicy = waitingPolicy
        self.waitingGraceSeconds = waitingGraceSeconds.isFinite ? min(7200, max(0, waitingGraceSeconds)) : 600
        self.maxLeases = min(128, max(1, maxLeases))
        self.maxLeasesPerOwner = min(32, max(1, maxLeasesPerOwner))
        self.batteryCutoff = min(50, max(10, batteryCutoff))
        self.thermalCutoff = thermalCutoff.isFinite ? min(95, max(70, thermalCutoff)) : 80
        self.sleepClosedLidOnFinalRelease = sleepClosedLidOnFinalRelease
    }

    public func normalized() -> LeasePolicy {
        LeasePolicy(defaultTTLSeconds: defaultTTLSeconds, maximumTTLSeconds: maximumTTLSeconds, waitingPolicy: waitingPolicy, waitingGraceSeconds: waitingGraceSeconds, maxLeases: maxLeases, maxLeasesPerOwner: maxLeasesPerOwner, batteryCutoff: batteryCutoff, thermalCutoff: thermalCutoff, sleepClosedLidOnFinalRelease: sleepClosedLidOnFinalRelease)
    }

    private enum CodingKeys: String, CodingKey {
        case defaultTTLSeconds, maximumTTLSeconds, waitingPolicy, waitingGraceSeconds, maxLeases, maxLeasesPerOwner, batteryCutoff, thermalCutoff, sleepClosedLidOnFinalRelease
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            defaultTTLSeconds: try values.decodeIfPresent(Double.self, forKey: .defaultTTLSeconds) ?? 14_400,
            maximumTTLSeconds: try values.decodeIfPresent(Double.self, forKey: .maximumTTLSeconds) ?? 86_400,
            waitingPolicy: try values.decodeIfPresent(AgentWaitingPolicy.self, forKey: .waitingPolicy) ?? .grace,
            waitingGraceSeconds: try values.decodeIfPresent(Double.self, forKey: .waitingGraceSeconds) ?? 600,
            maxLeases: try values.decodeIfPresent(Int.self, forKey: .maxLeases) ?? 128,
            maxLeasesPerOwner: try values.decodeIfPresent(Int.self, forKey: .maxLeasesPerOwner) ?? 32,
            batteryCutoff: try values.decodeIfPresent(Int.self, forKey: .batteryCutoff) ?? 20,
            thermalCutoff: try values.decodeIfPresent(Double.self, forKey: .thermalCutoff) ?? 80,
            sleepClosedLidOnFinalRelease: try values.decodeIfPresent(Bool.self, forKey: .sleepClosedLidOnFinalRelease) ?? true
        )
    }
}

public enum LeaseThermalState: String, Codable, Sendable {
    case nominal, fair, serious, critical, unknown
}

public enum LeaseCutout: String, Codable, Sendable {
    case thermal, lowBattery
}

public struct LeaseSafety: Codable, Sendable, Equatable {
    public var lidClosed: Bool?
    public var externalDisplayConnected: Bool?
    public var batteryPercent: Int?
    public var onBattery: Bool?
    public var temperatureCelsius: Double?
    public var thermalState: LeaseThermalState

    public init(lidClosed: Bool? = nil, externalDisplayConnected: Bool? = nil, batteryPercent: Int? = nil, onBattery: Bool? = nil, temperatureCelsius: Double? = nil, thermalState: LeaseThermalState = .nominal) {
        self.lidClosed = lidClosed
        self.externalDisplayConnected = externalDisplayConnected
        self.batteryPercent = batteryPercent.flatMap { (0...100).contains($0) ? $0 : nil }
        self.onBattery = onBattery
        self.temperatureCelsius = temperatureCelsius.flatMap { $0.isFinite && $0 > 0 && $0 < 150 ? $0 : nil }
        self.thermalState = thermalState
    }
}
