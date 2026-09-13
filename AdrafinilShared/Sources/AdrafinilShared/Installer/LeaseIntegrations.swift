import Foundation

public struct LeaseHookSpec: Codable, Sendable, Equatable {
    public let event: String
    public let action: String
    public let matcher: String?
    public init(_ event: String, _ action: String, matcher: String? = nil) {
        self.event = event; self.action = action; self.matcher = matcher
    }
}

public struct LeaseIntegrationDescriptor: Sendable, Identifiable {
    public enum Format: String, Codable, Sendable { case nestedJSON, flatJSON, piPlugin, openCodePlugin, scripts, manual }
    public let id: String
    public let displayName: String
    public let relativePath: String
    public let format: Format
    public let hooks: [LeaseHookSpec]
    public let capabilities: [String]
    public let note: String
    public let requiresApproval: Bool

    public var relativeFiles: [String] {
        format == .scripts ? hooks.map { relativePath + "/" + $0.event } : [relativePath]
    }
}

public enum LeaseIntegrations {
    public static let all: [LeaseIntegrationDescriptor] = [
        .init(id: "claude-code", displayName: "Claude Code", relativePath: ".claude/settings.json", format: .nestedJSON, hooks: [
            .init("UserPromptSubmit", "start"), .init("Stop", "stop"), .init("SessionEnd", "session-end"),
            .init("SessionStart", "clear-start", matcher: "clear"),
            .init("SubagentStart", "subagent-start"), .init("SubagentStop", "subagent-stop"),
            .init("Notification", "wait", matcher: "permission_prompt|idle_prompt"),
            .init("PostToolUse", "resume"), .init("PostToolUseFailure", "resume"),
        ], capabilities: ["turn", "subagents", "waiting-best-effort", "session-retirement"], note: "Hook contract checked against current documentation; live agent execution not yet certified.", requiresApproval: false),
        .init(id: "codex", displayName: "Codex", relativePath: ".codex/hooks.json", format: .nestedJSON, hooks: [
            .init("UserPromptSubmit", "start"), .init("Stop", "stop"), .init("Interrupt", "stop"), .init("SessionEnd", "session-end"),
            .init("SubagentStart", "subagent-start"), .init("SubagentStop", "subagent-stop"),
            .init("PermissionRequest", "wait"), .init("PostToolUse", "resume"),
        ], capabilities: ["turn", "turn-identifier", "subagents", "waiting-best-effort"], note: "Approve each installed handler in Codex /hooks. Use run for modes whose hook execution has not been verified.", requiresApproval: true),
        .init(id: "cursor", displayName: "Cursor", relativePath: ".cursor/hooks.json", format: .flatJSON, hooks: [
            .init("beforeSubmitPrompt", "start"), .init("stop", "stop"), .init("sessionEnd", "session-end"),
        ], capabilities: ["turn", "generation-identifier"], note: "Uses conversation_id + generation_id, not the lifetime of the Cursor application. One-hour backstop.", requiresApproval: false),
        .init(id: "gemini-cli", displayName: "Gemini CLI", relativePath: ".gemini/settings.json", format: .nestedJSON, hooks: [
            .init("BeforeAgent", "start"), .init("AfterAgent", "stop"), .init("SessionEnd", "session-end"), .init("AfterTool", "resume"),
        ], capabilities: ["turn", "session-retirement"], note: "BeforeAgent/AfterAgent are turn-scoped. Automatic retry and interactive approval behavior needs live validation.", requiresApproval: false),
        .init(id: "opencode", displayName: "OpenCode", relativePath: ".config/opencode/plugins/wakelease.ts", format: .openCodePlugin, hooks: [], capabilities: ["turn", "waiting-best-effort", "independent-sessions"], note: "Uses session.status busy/retry/idle. Plugin contract checked; live execution is experimental.", requiresApproval: false),
        .init(id: "pi", displayName: "Pi", relativePath: ".pi/agent/extensions/wakelease.ts", format: .piPlugin, hooks: [], capabilities: ["turn", "process-identity"], note: "Requires agent_settled support (upstream device verification used Pi 0.83+). Older installations should use run until upgraded.", requiresApproval: false),
        .init(id: "cline", displayName: "Cline", relativePath: "Documents/Cline/Hooks", format: .scripts, hooks: [
            .init("TaskStart", "start"), .init("TaskResume", "start"), .init("UserPromptSubmit", "start"),
            .init("TaskComplete", "stop"), .init("TaskCancel", "stop"), .init("PostToolUse", "resume"),
        ], capabilities: ["task", "session-identifier"], note: "Experimental VS Code hook path: executable extensionless files. Existing user scripts are never overwritten. The newer SDK/CLI plugin system is separate.", requiresApproval: false),
        .init(id: "aider", displayName: "Aider", relativePath: ".aider.conf.yml", format: .manual, hooks: [], capabilities: ["command-wrapper"], note: "Use wakelease run -- aider. This is explicit process-lifetime protection, including idle prompts, not verified turn detection.", requiresApproval: false),
        .init(id: "hermes", displayName: "Hermes", relativePath: ".hermes/config.yaml", format: .manual, hooks: [], capabilities: ["manual-hooks", "independent-sessions"], note: "Generate pre_llm_call/on_session_end entries and merge them manually. Hermes must approve them. No blind YAML editing or gateway-wide coalescing.", requiresApproval: true),
    ]

    public static func descriptor(_ id: String) throws -> LeaseIntegrationDescriptor {
        guard let integration = all.first(where: { $0.id == id }) else { throw LeaseCLIUsageError("Unknown integration: \(id)") }
        return integration
    }

    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func literal(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    static func command(cliPath: String, id: String, action: String) -> String {
        quote(cliPath) + " hook " + quote(id) + " " + quote(action)
    }

    static func plugin(_ integration: LeaseIntegrationDescriptor, cliPath: String) -> String {
        let common = """
        import { execFileSync } from "node:child_process"
        const send = (action, id) => {
          if (!id) return
          try {
            execFileSync(\(literal(cliPath)), ["hook", \(literal(integration.id)), action], {
              input: JSON.stringify({ session_id: String(id), pid: process.pid }),
              stdio: ["pipe", "ignore", "ignore"], timeout: 1500
            })
          } catch {}
        }
        """
        if integration.format == .piPlugin {
            return common + """

            export default function (pi) {
              const id = ctx => ctx?.sessionManager?.getSessionId?.() ?? String(process.pid)
              pi.on("agent_start", async (_event, ctx) => send("start", id(ctx)))
              pi.on("agent_settled", async (_event, ctx) => send("stop", id(ctx)))
              pi.on("session_shutdown", async (_event, ctx) => send("stop", id(ctx)))
              pi.on("tool_result", async (_event, ctx) => send("heartbeat", id(ctx)))
            }

            """
        }
        return common + """

        export const WakeLease = async () => ({
          event: async ({ event }) => {
            const p = event.properties ?? event.data ?? {}
            const id = p.sessionID ?? p.info?.id
            if (event.type === "session.status") {
              if (["busy", "retry"].includes(p.status?.type)) send("start", id)
              else if (p.status?.type === "idle") send("stop", id)
            } else if (event.type === "session.deleted") send("stop", id)
            else if (["permission.asked", "question.asked"].includes(event.type)) send("wait", id)
            else if (["permission.replied", "question.replied", "question.rejected"].includes(event.type)) send("resume", id)
          },
          "tool.execute.after": async (input) => send("heartbeat", input.sessionID)
        })

        """
    }
}
