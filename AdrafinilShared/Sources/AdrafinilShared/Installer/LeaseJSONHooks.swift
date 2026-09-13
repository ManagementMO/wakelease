import Foundation

struct ManagedLeaseHook: Codable, Sendable, Equatable {
    let event: String
    let matcher: String?
    let command: String
}

public enum LeaseIntegrationFailure: Error, LocalizedError {
    case unreadable, modified, unmanaged, concurrentModification, invalidReceipt, manual(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable: "Configuration has an unsupported or malformed shape. No settings were replaced."
        case .modified: "An owned integration was changed or removed externally. Review it before migrating or uninstalling."
        case .unmanaged: "Matching content exists without a WakeLease receipt. It is not ours to overwrite or remove."
        case .concurrentModification: "The configuration changed during the update. Review the preview and retry."
        case .invalidReceipt: "The integration receipt or backup cannot be verified. Nothing was removed."
        case let .manual(reason): reason
        }
    }
}

struct LeaseJSONHooks {
    private var root: [String: Any]
    private var hooks: [String: Any]
    private let flat: Bool
    private var changed = false

    init(data: Data?, flat: Bool) throws {
        if let data {
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LeaseIntegrationFailure.unreadable }
            self.root = root
        } else { root = [:] }
        if let value = root["hooks"] {
            guard let hooks = value as? [String: Any] else { throw LeaseIntegrationFailure.unreadable }
            self.hooks = hooks
        } else { hooks = [:] }
        self.flat = flat
    }

    mutating func replace(old: [ManagedLeaseHook], new: [ManagedLeaseHook], original: Data?, removing: Bool = false) throws -> Data {
        var remaining = new
        for previous in old {
            guard let replacementIndex = remaining.firstIndex(where: { $0.event == previous.event && $0.matcher == previous.matcher }) else {
                try update(previous, to: nil)
                continue
            }
            let replacement = remaining.remove(at: replacementIndex)
            try update(previous, to: replacement)
        }
        for binding in remaining {
            guard try !contains(binding) else { throw LeaseIntegrationFailure.unmanaged }
            var groups = try array(for: binding.event)
            if flat { groups.append(["command": binding.command]) }
            else {
                var group: [String: Any] = ["hooks": [["type": "command", "command": binding.command]]]
                if let matcher = binding.matcher { group["matcher"] = matcher }
                groups.append(group)
            }
            hooks[binding.event] = groups
            changed = true
        }
        if !changed, let original { return original }
        if hooks.isEmpty, removing { root.removeValue(forKey: "hooks") }
        else { root["hooks"] = hooks }
        if flat, !removing, root["version"] == nil { root["version"] = 1 }
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    func contains(_ binding: ManagedLeaseHook) throws -> Bool {
        let groups = try array(for: binding.event)
        if flat { return groups.contains { ($0["command"] as? String) == binding.command } }
        for group in groups {
            guard (group["matcher"] as? String) == binding.matcher else { continue }
            if try handlers(group).contains(where: { ($0["type"] as? String) == "command" && ($0["command"] as? String) == binding.command }) { return true }
        }
        return false
    }

    private mutating func update(_ old: ManagedLeaseHook, to new: ManagedLeaseHook?) throws {
        var groups = try array(for: old.event)
        var matches = 0
        for index in groups.indices.reversed() {
            if flat {
                guard (groups[index]["command"] as? String) == old.command else { continue }
                matches += 1
                if let new { groups[index]["command"] = new.command }
                else { groups.remove(at: index) }
            } else {
                guard (groups[index]["matcher"] as? String) == old.matcher else { continue }
                var inner = try handlers(groups[index])
                let previousMatches = matches
                for handler in inner.indices.reversed() where (inner[handler]["type"] as? String) == "command" && (inner[handler]["command"] as? String) == old.command {
                    matches += 1
                    if let new { inner[handler]["command"] = new.command }
                    else { inner.remove(at: handler) }
                }
                guard matches != previousMatches else { continue }
                if inner.isEmpty { groups.remove(at: index) }
                else { groups[index]["hooks"] = inner }
            }
        }
        guard matches == 1 else { throw LeaseIntegrationFailure.modified }
        hooks[old.event] = groups.isEmpty ? nil : groups
        changed = changed || old != new
    }

    private func array(for event: String) throws -> [[String: Any]] {
        guard let value = hooks[event] else { return [] }
        guard let groups = value as? [[String: Any]] else { throw LeaseIntegrationFailure.unreadable }
        if !flat {
            for group in groups {
                guard group["matcher"] == nil || group["matcher"] is String else { throw LeaseIntegrationFailure.unreadable }
                _ = try handlers(group)
            }
        }
        return groups
    }

    private func handlers(_ group: [String: Any]) throws -> [[String: Any]] {
        guard let value = group["hooks"] else { return [] }
        guard let handlers = value as? [[String: Any]] else { throw LeaseIntegrationFailure.unreadable }
        return handlers
    }
}
