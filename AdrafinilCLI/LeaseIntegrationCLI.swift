import AdrafinilShared
import Darwin
import Foundation
import OSLog

private let integrationLog = Logger(subsystem: WakeLeaseIdentity.appBundleID, category: "Integrations")

enum LeaseHookCommand {
    static func run(_ arguments: [String]) -> Int32 {
        defer { FileHandle.standardOutput.write(Data("{}\n".utf8)) }
        guard arguments.count == 2,
              arguments[0].range(of: "^[a-z0-9][a-z0-9-]{0,63}$", options: .regularExpression) != nil else { return 0 }
        let issuedAt = SystemLeaseClock().now().continuous
        let source = arguments[0], action = arguments[1]
        guard let payload = CLIStdin.payload() else { return 0 }
        let client = LeaseSocketClient(timeout: 0.5)
        let snapshot = action == "session-end" ? (try? client.send(LeaseRequest(operation: "status")))?.status?.snapshot : nil
        let requests = LeaseHookAdapter.requests(source: source, action: action, payload: payload, snapshot: snapshot)
        for var request in requests {
            request.issuedAt = issuedAt
            do {
                if try !client.send(request).ok { integrationLog.error("integration_error — request rejected for \(source, privacy: .public)") }
            } catch { integrationLog.error("integration_error — broker unavailable for \(source, privacy: .public)") }
        }
        return 0
    }
}

enum LeaseIntegrationCLI {
    static func run(_ plan: LeaseCLIPlan) throws -> Int32 {
        let allowed: Set = ["--home", "--state-dir", "--dry-run", "--yes", "--json", "--help"]
        guard Set(plan.values.keys).union(plan.flags).isSubset(of: allowed) else { throw LeaseCLIUsageError("Unsupported integration option.") }
        let manager = LeaseIntegrationManager(home: URL(fileURLWithPath: plan.values["--home"] ?? NSHomeDirectory(), isDirectory: true), stateDirectory: plan.directory, cliPath: HookCommandSupport.canonicalCLIPath())
        let operation = plan.positionals.first ?? "list"
        if operation == "list" {
            let health = LeaseIntegrations.all.map { manager.health($0.id) }
            if plan.flags.contains("--json") { try print(String(decoding: LeaseJSON.encode(health), as: UTF8.self)) }
            else {
                for item in health {
                    print("\(item.id)  \(item.state)\n  \(item.note)")
                }
            }
            return 0
        }
        guard ["install", "uninstall", "preview"].contains(operation), plan.positionals.count == 2 else {
            throw LeaseCLIUsageError("Use: wakelease integrations install|uninstall|preview <name> [--dry-run] [--yes]")
        }
        let id = plan.positionals[1]
        let descriptor = try LeaseIntegrations.descriptor(id)
        if descriptor.format == .manual {
            print(descriptor.note)
            print("Use wakelease hooks generate --source \(id) for the manual recipe.")
            return operation == "install" ? 2 : 0
        }
        let removing = operation == "uninstall"
        let preview = try removing ? manager.uninstall(id, dryRun: true) : manager.install(id, dryRun: true)
        print(preview.diff)
        if operation == "preview" || plan.flags.contains("--dry-run") || !preview.changed { return 0 }
        if !plan.flags.contains("--yes") {
            guard isatty(STDIN_FILENO) != 0 else { throw LeaseCLIUsageError("Review --dry-run, then pass --yes to apply these changes.") }
            print("Apply these integration changes? [y/N] ", terminator: "")
            guard ["y", "yes"].contains(readLine()?.lowercased() ?? "") else { return 1 }
        }
        let result = try removing ? manager.uninstall(id) : manager.install(id)
        print(result.changed ? "Integration \(removing ? "removed" : "configured")." : "No changes needed.")
        if !removing { print(descriptor.note) }
        return 0
    }

    static func generate(_ plan: LeaseCLIPlan) throws -> Int32 {
        guard plan.positionals == ["generate"] else { throw LeaseCLIUsageError("Use: wakelease hooks generate --source <tool> [--session-variable NAME]") }
        let source: String
        if let supplied = plan.values["--source"] { source = ManualHookSnippet.slug(from: supplied) }
        else if isatty(STDIN_FILENO) != 0 {
            print("Tool name: ", terminator: "")
            source = ManualHookSnippet.slug(from: readLine() ?? "my-tool")
        } else { source = "my-tool" }
        let path = HookCommandSupport.canonicalCLIPath()
        let cli = LeaseIntegrations.quote(path)
        if source == "hermes" {
            func yaml(_ action: String) throws -> String {
                let text = cli + " hook hermes " + action
                return try String(decoding: JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes]), as: UTF8.self)
            }
            print("Merge these entries into your existing hooks mapping; do not replace other hooks. Approve them in Hermes.")
            try print("hooks:\n  pre_llm_call:\n    - command: \(yaml("start"))\n  on_session_end:\n    - command: \(yaml("stop"))")
            return 0
        }
        let variable = plan.values["--session-variable"] ?? "SESSION_ID"
        guard variable.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else { throw LeaseCLIUsageError("Session variable must be a shell variable name.") }
        let key = "\"${\(variable)}\""
        for (label, operation) in [("Start / resume", "acquire"), ("Waiting for input", "wait"), ("Finish / cancel", "release")] {
            let sourceFlag = operation == "acquire" ? " --source " + LeaseIntegrations.quote(source) : ""
            print("\(label):\n  \(cli) \(operation) \(key)\(sourceFlag) >/dev/null 2>&1 || true\n")
        }
        print("Provide a nonempty unique work ID in \(variable). If the tool has no hooks:\n  \(cli) run -- \(LeaseIntegrations.quote(source)) [arguments]")
        print("A process wrapper includes idle prompts. Use semantic hooks where available.")
        return 0
    }
}
