import CryptoKit
import Foundation

public enum LeaseHookAdapter {
    private struct Payload: Decodable {
        var session_id: String?
        var sessionId: String?
        var taskId: String?
        var agent_id: String?
        var conversation_id: String?
        var generation_id: String?
        var turn_id: String?
        var source: String?
        var pid: Int32?
    }

    public static func requests(source: String, action: String, payload: Data, snapshot: LeaseSnapshot? = nil) -> [LeaseRequest] {
        guard payload.count <= 4 * 1_024 * 1_024,
              let event = try? JSONDecoder().decode(Payload.self, from: payload),
              let session = event.session_id ?? event.sessionId ?? event.taskId ?? event.conversation_id,
              !session.isEmpty, source.utf8.count <= 64 else { return [] }
        if action == "clear-start", event.source != "clear" { return [] }
        if action == "session-end" {
            return (snapshot?.leases ?? []).filter {
                $0.source == source && $0.sessionID == session && $0.metadata["scope"] != "subagent"
            }.map { LeaseRequest(operation: "release", key: $0.key) }
        }
        let child = action.hasPrefix("subagent-") || (["claude-code", "codex"].contains(source) && event.agent_id != nil)
        let suffix: String
        let scope: String
        if child {
            guard let id = event.agent_id, !id.isEmpty else { return [] }
            suffix = "subagent:" + id
            scope = "subagent"
        } else if source == "cursor" {
            guard let conversation = event.conversation_id, let generation = event.generation_id, !generation.isEmpty else { return [] }
            suffix = "turn:" + conversation + ":" + generation
            scope = "turn"
        } else if source == "codex", let turn = event.turn_id, !turn.isEmpty {
            suffix = "turn:" + session + ":" + turn
            scope = "turn"
        } else {
            suffix = "session:" + session
            scope = "turn"
        }
        let operation: String
        switch action {
        case "start", "resume", "clear-start", "subagent-start": operation = "acquire"
        case "stop", "subagent-stop": operation = "release"
        case "wait": operation = "wait"
        case "heartbeat": operation = "renew"
        default: return []
        }
        var key = source + ":" + suffix
        if key.utf8.count > 256 {
            key = source + ":sha256:" + SHA256.hash(data: Data(suffix.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        var owner: ProcessIdentity?
        if operation == "acquire" {
            if let pid = event.pid {
                guard let identity = SystemProcessIdentity.read(pid) else { return [] }
                owner = identity
            } else if source == "hermes" || source == "cline" {
                owner = SystemProcessIdentity.read(getppid())
            } else if let kind = AgentKind(rawValue: source) {
                let pid = ProcessResolver.owningAgentPID(binaryNames: Set(kind.binaryNames))
                if pid > 0 { owner = SystemProcessIdentity.read(pid) }
            }
        }
        let sessionID = session.utf8.count <= 256 ? session : SHA256.hash(data: Data(session.utf8)).map { String(format: "%02x", $0) }.joined()
        return [LeaseRequest(operation: operation, key: key, source: source, sourceKind: .hook, ttlSeconds: source == "cursor" ? 3_600 : 14_400, reason: operation == "wait" ? "Waiting for user input" : nil, owner: owner, sessionID: sessionID, metadata: ["scope": scope])]
    }
}
