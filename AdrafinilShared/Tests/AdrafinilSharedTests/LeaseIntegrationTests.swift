import Foundation
import Testing
@testable import AdrafinilShared

@Suite("Lease integration contracts")
struct LeaseIntegrationTests {
    @Test func cursorUsesConversationAndGenerationIdentity() throws {
        let payload = Data(#"{"conversation_id":"chat","generation_id":"turn","prompt":"private","workspace_roots":["/private/repo"]}"#.utf8)
        let start = LeaseHookAdapter.requests(source: "cursor", action: "start", payload: payload)
        let stop = LeaseHookAdapter.requests(source: "cursor", action: "stop", payload: payload)
        #expect(start.first?.key == "cursor:turn:chat:turn")
        #expect(stop.first?.key == start.first?.key)
        let encoded = try String(decoding: LeaseJSON.encode(start), as: UTF8.self)
        #expect(!encoded.contains("private"))
        #expect(start.first?.ttlSeconds == 3600)
    }

    @Test func codexTurnsAndSubagentsHaveIndependentKeys() {
        let parent = Data(#"{"session_id":"s","turn_id":"t"}"#.utf8)
        let child = Data(#"{"session_id":"s","turn_id":"t","agent_id":"child"}"#.utf8)
        #expect(LeaseHookAdapter.requests(source: "codex", action: "start", payload: parent).first?.key == "codex:turn:s:t")
        #expect(LeaseHookAdapter.requests(source: "codex", action: "subagent-start", payload: child).first?.key == "codex:subagent:child")
        #expect(LeaseHookAdapter.requests(source: "codex", action: "subagent-stop", payload: parent).isEmpty)
    }

    @Test func waitingAndResumeUseDifferentOperations() {
        let payload = Data(#"{"session_id":"s"}"#.utf8)
        #expect(LeaseHookAdapter.requests(source: "claude-code", action: "wait", payload: payload).first?.operation == "wait")
        #expect(LeaseHookAdapter.requests(source: "claude-code", action: "resume", payload: payload).first?.operation == "acquire")
    }

    @Test func idleSessionLaunchDoesNotAcquire() {
        let payload = Data(#"{"session_id":"s","source":"startup"}"#.utf8)
        #expect(LeaseHookAdapter.requests(source: "claude-code", action: "clear-start", payload: payload).isEmpty)
    }

    @Test func sessionEndDoesNotReleaseSubagents() async throws {
        let broker = LeaseBroker()
        _ = try await broker.acquire(LeaseProposal(key: "parent", source: "codex", sessionID: "s", metadata: ["scope": "turn"]))
        _ = try await broker.acquire(LeaseProposal(key: "child", source: "codex", sessionID: "s", metadata: ["scope": "subagent"]))
        let requests = await LeaseHookAdapter.requests(source: "codex", action: "session-end", payload: Data(#"{"session_id":"s"}"#.utf8), snapshot: broker.snapshot())
        #expect(requests.map(\.key) == ["parent"])
    }

    @Test func hermesSessionsDoNotCoalesceIntoOneGatewayLease() {
        let a = LeaseHookAdapter.requests(source: "hermes", action: "start", payload: Data(#"{"session_id":"a"}"#.utf8))
        let b = LeaseHookAdapter.requests(source: "hermes", action: "start", payload: Data(#"{"session_id":"b"}"#.utf8))
        #expect(a.first?.key != b.first?.key)
    }

    @Test func malformedHookPayloadsFailSoft() {
        for payload in ["not JSON", "[]", "{}", #"{"session_id":42}"#] {
            #expect(LeaseHookAdapter.requests(source: "claude-code", action: "start", payload: Data(payload.utf8)).isEmpty)
        }
    }

    @Test func knownAdaptersAreDiscoverableWithoutDaemonChanges() {
        #expect(Set(LeaseIntegrations.all.map(\.id)) == ["claude-code", "codex", "cursor", "gemini-cli", "opencode", "pi", "cline", "aider", "hermes"])
        #expect(LeaseIntegrations.all.first { $0.id == "gemini-cli" }?.hooks.first?.event == "BeforeAgent")
    }
}

@Suite("Integration ownership and backups")
struct LeaseIntegrationInstallerTests {
    private func fixture() throws -> (URL, LeaseIntegrationManager) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("wl-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let manager = LeaseIntegrationManager(home: home, stateDirectory: home.appendingPathComponent("state"), cliPath: "/Apps/It's a tool/wakelease")
        return (home, manager)
    }

    @Test func jsonInstallUninstallRestoresOriginalBytesAndPermissions() throws {
        for id in ["claude-code", "codex", "cursor", "gemini-cli"] {
            let (home, manager) = try fixture()
            defer { try? FileManager.default.removeItem(at: home) }
            let path = try manager.configurationURLs(for: id)[0]
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            let original = Data(#"{ "privateSetting": "do-not-print", "hooks": {} }"#.utf8)
            try original.write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: path.path)
            let preview = try manager.install(id, dryRun: true)
            #expect(!preview.diff.contains("do-not-print"))
            #expect(try Data(contentsOf: path) == original)
            _ = try manager.install(id)
            let installed = try Data(contentsOf: path)
            _ = try manager.install(id)
            #expect(try Data(contentsOf: path) == installed)
            #expect(try manager.backupData(for: id, fileIndex: 0) == original)
            _ = try manager.uninstall(id)
            #expect(try Data(contentsOf: path) == original)
            #expect(try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int == 0o640)
            _ = try manager.uninstall(id)
        }
    }

    @Test func unrelatedExternalChangesSurviveUninstall() throws {
        let (home, manager) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try manager.install("claude-code")
        let path = try manager.configurationURLs(for: "claude-code")[0]
        var content = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        content["userSetting"] = 42
        try JSONSerialization.data(withJSONObject: content).write(to: path)
        _ = try manager.uninstall("claude-code")
        let restored = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        #expect(restored["userSetting"] as? Int == 42)
    }

    @Test func malformedHookContainersAreNeverReplaced() throws {
        let (home, manager) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let path = try manager.configurationURLs(for: "claude-code")[0]
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data(#"{"hooks":"not-an-object"}"#.utf8)
        try original.write(to: path)
        #expect(throws: (any Error).self) { _ = try manager.install("claude-code") }
        #expect(try Data(contentsOf: path) == original)
    }

    @Test func pluginFilenameIsNotProofOfOwnership() throws {
        let (home, manager) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let path = try manager.configurationURLs(for: "pi")[0]
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("user-created plugin".utf8).write(to: path)
        #expect(throws: (any Error).self) { _ = try manager.install("pi") }
        _ = try manager.uninstall("pi")
        #expect(try String(contentsOf: path, encoding: .utf8) == "user-created plugin")
    }

    @Test func modifiedOwnedPluginIsNotSilentlyDeleted() throws {
        let (home, manager) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try manager.install("pi")
        let path = try manager.configurationURLs(for: "pi")[0]
        try Data("user modifications".utf8).write(to: path)
        #expect(throws: (any Error).self) { _ = try manager.uninstall("pi") }
        #expect(try String(contentsOf: path, encoding: .utf8) == "user modifications")
    }

    @Test func foreignEmptyGroupsSurviveUninstall() throws {
        let (home, manager) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try manager.install("claude-code")
        let path = try manager.configurationURLs(for: "claude-code")[0]
        var root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        var hooks = try #require(root["hooks"] as? [String: Any])
        var groups = try #require(hooks["Stop"] as? [[String: Any]])
        groups.append(["hooks": [], "label": "foreign-empty"])
        hooks["Stop"] = groups
        root["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: root).write(to: path)
        _ = try manager.uninstall("claude-code")
        let result = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        let remaining = (result["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]]
        #expect(remaining?.first?["label"] as? String == "foreign-empty")
    }

    @Test func symlinkedConfigurationIsRefused() throws {
        let (home, manager) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let path = try manager.configurationURLs(for: "cursor")[0]
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let target = home.appendingPathComponent("unrelated")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: target)
        #expect(throws: (any Error).self) { _ = try manager.install("cursor") }
        #expect(try Data(contentsOf: target) == Data("{}".utf8))
    }
}
