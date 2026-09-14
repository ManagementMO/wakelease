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
        let allowed: Set = ["--source", "--session-variable", "--for", "--ttl", "--display", "--json", "--interactive", "--start-event", "--stop-event", "--executable"]
        guard plan.positionals == ["generate"], Set(plan.values.keys).union(plan.flags).isSubset(of: allowed) else {
            throw LeaseCLIUsageError("Use: wakelease hooks generate [--source <id>] [--session-variable NAME] [--for 1h] [--display] [--json | --interactive]")
        }
        let interactive = plan.flags.contains("--interactive") || (plan.values["--source"] == nil && isatty(STDIN_FILENO) != 0 && !plan.flags.contains("--json"))
        guard !interactive || (isatty(STDIN_FILENO) != 0 && !plan.flags.contains("--json")) else { throw LeaseCLIUsageError("Interactive generation requires a terminal and cannot be combined with --json.") }
        func value(_ flag: String, _ prompt: String, _ fallback: String) -> String {
            if let supplied = plan.values[flag] { return supplied }
            guard interactive else { return fallback }
            print("\(prompt) [\(fallback)]: ", terminator: "")
            let text = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? fallback : text
        }
        var options = CustomIntegrationOptions()
        options.source = value("--source", "Source ID", "my-tool")
        let path = HookCommandSupport.canonicalCLIPath()
        let cli = LeaseIntegrations.quote(path)
        if options.source.lowercased() == "hermes" {
            guard Set(plan.values.keys).union(plan.flags).isSubset(of: ["--source", "--interactive"]) else { throw LeaseCLIUsageError("The Hermes recipe is a manual YAML merge. Use hooks generate --source hermes without generic recipe options.") }
            func yaml(_ action: String) throws -> String {
                let text = cli + " hook hermes " + action
                return try String(decoding: JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes]), as: UTF8.self)
            }
            print("Merge these entries into your existing hooks mapping; do not replace other hooks. Approve them in Hermes.")
            try print("hooks:\n  pre_llm_call:\n    - command: \(yaml("start"))\n  on_session_end:\n    - command: \(yaml("stop"))")
            return 0
        }
        options.sessionVariable = value("--session-variable", "Unique work ID variable", "WORK_ID")
        guard plan.values["--for"] == nil || plan.values["--ttl"] == nil else { throw LeaseCLIUsageError("Use either --for or --ttl, not both.") }
        let duration = plan.values["--ttl"] ?? value("--for", "Lease lifetime", "1h")
        guard let seconds = DurationParser.seconds(from: duration) else { throw LeaseCLIUsageError("Invalid lifetime. Use seconds or a duration such as 15m or 2h.") }
        options.ttlSeconds = seconds
        options.startEvent = value("--start-event", "Start / resume event label", options.startEvent)
        options.stopEvent = value("--stop-event", "Finish / cancel event label", options.stopEvent)
        options.executable = value("--executable", "Executable for wrapper fallback", options.source)
        let display = plan.flags.contains("--display") || (interactive && ["y", "yes"].contains(value("--display", "Display-dependent work? y/N", "n").lowercased()))
        options.wakeClass = display ? .display : .system
        let recipe = try options.recipe(cliPath: path)
        if plan.flags.contains("--json") { try print(String(decoding: LeaseJSON.encode(recipe), as: UTF8.self)); return 0 }
        for step in recipe.steps {
            print("\(step.event) [\(step.operation)]:\n  \(step.command)\n")
        }
        print("Use a unique nonempty \(recipe.sessionVariable) per concurrent job/turn. Keys are namespaced by \(recipe.source).")
        print("Copy start for resume; attach waiting only if supported, and heartbeat before expiry. Nothing was installed.")
        print("Without lifecycle hooks:\n  \(recipe.wrapper) [arguments]\nThe wrapper includes idle prompts; it does not infer semantic work.")
        return 0
    }
}
