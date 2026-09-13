import Foundation

public struct HelperDemandLedger: Sendable {
    private struct Claim: Sendable {
        var token: UUID
        var connected: Bool
        var blocked: Bool
        var deadline: TimeInterval?
    }
    private var claims: [UInt32: Claim] = [:]
    private let heartbeatWindow: TimeInterval
    private let disconnectGrace: TimeInterval

    public init(heartbeatWindow: TimeInterval = 90, disconnectGrace: TimeInterval = 60) {
        self.heartbeatWindow = heartbeatWindow
        self.disconnectGrace = disconnectGrace
    }

    public var shouldBlock: Bool {
        claims.values.contains { $0.blocked }
    }
    public var nextDeadline: TimeInterval? {
        claims.values.compactMap(\.deadline).min()
    }

    public mutating func connect(uid: UInt32, token: UUID) throws {
        guard uid > 0, claims[uid] != nil || claims.count < 32 else { throw LeaseFailure.capacity }
        var claim = claims[uid] ?? Claim(token: token, connected: true, blocked: false, deadline: nil)
        claim.token = token
        claim.connected = true
        claims[uid] = claim
    }

    public mutating func set(uid: UInt32, token: UUID, blocked: Bool, at time: TimeInterval) throws {
        guard var claim = claims[uid], claim.token == token, claim.connected else { throw LeaseFailure.ownerUnavailable }
        claim.blocked = blocked
        claim.deadline = blocked ? time + heartbeatWindow : nil
        claims[uid] = claim
    }

    public mutating func disconnect(uid: UInt32, token: UUID, at time: TimeInterval) {
        guard var claim = claims[uid], claim.token == token else { return }
        if !claim.blocked { claims.removeValue(forKey: uid); return }
        claim.connected = false
        claim.deadline = min(claim.deadline ?? time, time + disconnectGrace)
        claims[uid] = claim
    }

    public mutating func expire(at time: TimeInterval) {
        for (uid, var claim) in claims {
            guard let deadline = claim.deadline, deadline <= time else { continue }
            if !claim.connected { claims.removeValue(forKey: uid) }
            else {
                claim.blocked = false
                claim.deadline = nil
                claims[uid] = claim
            }
        }
    }

    public mutating func clear() {
        claims.removeAll()
    }
}
