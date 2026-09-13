import Darwin
import Foundation

public struct LocalPeer: Sendable {
    public let uid: UInt32
    public let pid: Int32
    public init(uid: UInt32, pid: Int32) { self.uid = uid; self.pid = pid }
}

public struct LeaseRequest: Codable, Sendable {
    public var version: Int
    public var requestID: UUID?
    public var operation: String
    public var bootID: String?
    public var issuedAt: TimeInterval?
    public var key: String?
    public var source: String?
    public var sourceKind: LeaseSourceKind?
    public var wakeClass: WakeClass?
    public var ttlSeconds: TimeInterval?
    public var reason: String?
    public var owner: ProcessIdentity?
    public var sessionID: String?
    public var parentLeaseID: UUID?
    public var metadata: [String: String]?

    public init(operation: String, key: String? = nil, source: String? = nil, sourceKind: LeaseSourceKind? = nil, wakeClass: WakeClass? = nil, ttlSeconds: TimeInterval? = nil, reason: String? = nil, owner: ProcessIdentity? = nil, sessionID: String? = nil, parentLeaseID: UUID? = nil, metadata: [String: String]? = nil) {
        version = 1
        requestID = UUID()
        self.operation = operation
        bootID = SystemLeaseClock().bootID
        issuedAt = SystemLeaseClock().now().continuous
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

public struct LeaseProtocolError: Codable, Sendable {
    public let code: String
    public let message: String
    public init(code: String, message: String) { self.code = code; self.message = message }
}

public struct LeasePowerReport: Codable, Sendable {
    public var applied: WakeDemand?
    public var error: String?
    public var helperConnected: Bool

    public init(applied: WakeDemand? = nil, error: String? = nil, helperConnected: Bool = false) {
        self.applied = applied
        self.error = error
        self.helperConnected = helperConnected
    }
}

public struct LeaseServiceStatus: Codable, Sendable {
    public let protocolVersion: Int
    public let version: String
    public let mode: String
    public let snapshot: LeaseSnapshot
    public let power: LeasePowerReport
}

public struct LeaseReply: Codable, Sendable {
    public var version: Int
    public var requestID: UUID?
    public var ok: Bool
    public var error: LeaseProtocolError?
    public var changed: Bool?
    public var lease: WakeLease?
    public var status: LeaseServiceStatus?

    public init(ok: Bool, requestID: UUID? = nil, error: LeaseProtocolError? = nil, changed: Bool? = nil, lease: WakeLease? = nil, status: LeaseServiceStatus? = nil) {
        version = 1
        self.ok = ok
        self.requestID = requestID
        self.error = error
        self.changed = changed
        self.lease = lease
        self.status = status
    }
}

public enum LeaseJSON {
    public static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}

public struct LeaseProtocolService: Sendable {
    public let broker: LeaseBroker
    public let mode: String
    private let onMutation: @Sendable (LeaseSnapshot) async -> Void
    private let power: @Sendable () async -> LeasePowerReport

    public init(broker: LeaseBroker, mode: String, onMutation: @escaping @Sendable (LeaseSnapshot) async -> Void = { _ in }, power: @escaping @Sendable () async -> LeasePowerReport = { LeasePowerReport() }) {
        self.broker = broker
        self.mode = mode
        self.onMutation = onMutation
        self.power = power
    }

    public func handle(_ request: LeaseRequest, peer: LocalPeer) async -> LeaseReply {
        guard peer.uid == getuid() else { return failure(request, "unauthorized_peer", "Only the daemon's user may access this socket.") }
        guard request.version == 1 else { return failure(request, "unsupported_version", "Supported protocol versions: 1.") }
        let operations: Set<String> = ["acquire", "hold", "renew", "wait", "release", "releaseAll", "pause", "resume", "status", "doctor", "ping"]
        guard operations.contains(request.operation) else { return failure(request, "unknown_operation", "Unknown lease operation.") }
        let mutates = !["status", "doctor", "ping"].contains(request.operation)
        let initial = await broker.snapshot()
        if mutates {
            guard request.bootID == initial.bootID, let stamp = request.issuedAt, stamp.isFinite else {
                return failure(request, "stale_boot", "Mutations require the current boot identity and monotonic issue time.")
            }
        }
        do {
            var result: LeaseChange?
            switch request.operation {
            case "acquire", "hold":
                guard let key = request.key else { return failure(request, "invalid_request", "A client-chosen key is required.") }
                let proposal = LeaseProposal(key: key, source: request.source ?? "custom", sourceKind: request.sourceKind ?? (request.operation == "hold" ? .timed : .custom), wakeClass: request.wakeClass ?? .system, ttlSeconds: request.ttlSeconds, reason: request.reason, owner: request.owner, sessionID: request.sessionID, parentLeaseID: request.parentLeaseID, metadata: request.metadata ?? [:])
                result = try await broker.acquire(proposal, issuedAt: request.issuedAt, peerUID: peer.uid)
            case "renew", "wait", "release":
                guard let key = request.key else { return failure(request, "invalid_request", "A lease key is required.") }
                switch request.operation {
                case "renew": result = try await broker.renew(key: key, ttlSeconds: request.ttlSeconds, issuedAt: request.issuedAt)
                case "wait": result = try await broker.wait(key: key, reason: request.reason, issuedAt: request.issuedAt)
                default: result = try await broker.release(key: key, issuedAt: request.issuedAt)
                }
            case "releaseAll", "pause", "resume":
                guard let issuedAt = request.issuedAt else { throw LeaseFailure.staleRequest }
                result = try await broker.control(request.operation, issuedAt: issuedAt)
            default: break
            }
            if mutates { await onMutation(broker.snapshot()) }
            return await reply(request, result: result)
        } catch let error as LeaseFailure {
            if mutates { await onMutation(broker.snapshot()) }
            return failure(request, error.rawValue, error.localizedDescription)
        } catch {
            return failure(request, "internal_error", "The lease operation failed.")
        }
    }

    private func reply(_ request: LeaseRequest, result: LeaseChange?) async -> LeaseReply {
        let snapshot = await broker.snapshot()
        let status = await LeaseServiceStatus(protocolVersion: 1, version: WakeLeaseIdentity.marketingVersion, mode: mode, snapshot: snapshot, power: power())
        return LeaseReply(ok: true, requestID: request.requestID, changed: result?.changed, lease: result?.lease, status: status)
    }

    private func failure(_ request: LeaseRequest, _ code: String, _ message: String) -> LeaseReply {
        LeaseReply(ok: false, requestID: request.requestID, error: LeaseProtocolError(code: code, message: message))
    }
}
