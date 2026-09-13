import Foundation

public struct LeaseCLIUsageError: Error, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct LeaseCLIPlan: Sendable {
    public let command: String
    public let positionals: [String]
    public let values: [String: String]
    public let flags: Set<String>
    public let childArguments: [String]
    private let generatedKey: String
    private let issuedAt: TimeInterval

    public init(arguments: [String]) throws {
        issuedAt = SystemLeaseClock().now().continuous
        let first = arguments.first ?? "help"
        command = ["--help", "-h"].contains(first) ? "help" : (["--version", "-v"].contains(first) ? "version" : first)
        generatedKey = command + ":" + UUID().uuidString.lowercased()
        let booleanOptions: Set<String> = ["--json", "--display", "--all", "--dry-run", "--yes", "--help", "--strict"]
        let valueOptions: Set<String> = ["--source", "--reason", "--ttl", "--for", "--pid", "--parent", "--session", "--state-dir"]
        let args = Array(arguments.dropFirst())
        var values: [String: String] = [:]
        var flags: Set<String> = []
        var positionals: [String] = []
        var child: [String] = []
        var index = 0
        while index < args.count {
            let argument = args[index]
            index += 1
            if argument == "--" { child = Array(args[index...]); break }
            if argument == "-h" { flags.insert("--help"); continue }
            if !argument.hasPrefix("-") { positionals.append(argument); continue }
            let parts = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let key = parts[0]
            if booleanOptions.contains(key), parts.count == 1 {
                flags.insert(key)
            } else if valueOptions.contains(key) {
                guard values[key] == nil else { throw LeaseCLIUsageError("Option \(key) was supplied twice.") }
                if parts.count == 2 { values[key] = parts[1] }
                else {
                    guard index < args.count, !args[index].hasPrefix("--") else { throw LeaseCLIUsageError("Option \(key) requires a value.") }
                    values[key] = args[index]
                    index += 1
                }
            } else { throw LeaseCLIUsageError("Unknown option: \(argument)") }
        }
        if command == "run", !flags.contains("--help"), (child.isEmpty || !positionals.isEmpty) {
            throw LeaseCLIUsageError("Use: wakelease run -- command [arguments]")
        }
        if command != "run", !child.isEmpty { throw LeaseCLIUsageError("Only run accepts a command after --.") }
        self.values = values
        self.flags = flags
        self.positionals = positionals
        childArguments = child
    }

    public var directory: URL {
        values["--state-dir"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? WakeLeasePaths.directory
    }

    public func request() throws -> LeaseRequest {
        let allowed: [String: Set<String>] = [
            "acquire": ["--source", "--reason", "--ttl", "--pid", "--parent", "--session", "--display", "--json"],
            "hold": ["--source", "--reason", "--for", "--ttl", "--pid", "--parent", "--display", "--json"],
            "renew": ["--ttl", "--json"], "heartbeat": ["--ttl", "--json"], "wait": ["--reason", "--json"],
            "release": ["--all", "--json", "--strict"], "status": ["--json"], "doctor": ["--json"],
            "pause": ["--json"], "resume": ["--json"], "sleep": ["--json"],
            "run": ["--source", "--reason", "--display", "--parent"],
            "watch": ["--pid", "--source", "--reason", "--display", "--parent"],
        ]
        guard let permitted = allowed[command] else { throw LeaseCLIUsageError("Unknown command: \(command). Run wakelease help.") }
        let used = Set(values.keys).union(flags).subtracting(["--state-dir", "--help"])
        guard used.isSubset(of: permitted) else { throw LeaseCLIUsageError("An option is not supported by \(command). Run wakelease help.") }
        let needsKey = ["acquire", "renew", "heartbeat", "wait", "release"].contains(command) && !flags.contains("--all")
        guard positionals.count == (needsKey ? 1 : 0) else { throw LeaseCLIUsageError(needsKey ? "A single lease key is required." : "Unexpected positional argument.") }
        if command == "watch", values["--pid"] == nil { throw LeaseCLIUsageError("watch requires --pid.") }
        if values["--for"] != nil, values["--ttl"] != nil { throw LeaseCLIUsageError("Choose either --for or --ttl.") }
        var ttl: TimeInterval?
        if let raw = values["--for"] ?? values["--ttl"] {
            guard let duration = DurationParser.seconds(from: raw), duration.isFinite, duration > 0 else { throw LeaseCLIUsageError("Duration must be positive, for example 30m or 2h.") }
            ttl = duration
        }
        var owner: ProcessIdentity?
        if let raw = values["--pid"] {
            guard let pid = Int32(raw), pid > 0, let identity = SystemProcessIdentity.read(pid) else { throw LeaseCLIUsageError("--pid must identify a live process.") }
            owner = identity
        }
        let parent = values["--parent"].flatMap(UUID.init(uuidString:))
        if values["--parent"] != nil, parent == nil { throw LeaseCLIUsageError("--parent must be a lease UUID.") }
        let operation: String
        switch command {
        case "run", "watch": operation = "acquire"
        case "heartbeat": operation = "renew"
        case "sleep": operation = "pause"
        case "release" where flags.contains("--all"): operation = "releaseAll"
        default: operation = command
        }
        let kind: LeaseSourceKind = command == "hold" ? .timed : (command == "run" ? .command : (command == "watch" ? .process : .custom))
        if command == "run" { owner = SystemProcessIdentity.read(getpid()) }
        let source = values["--source"] ?? (command == "run" ? (childArguments[0] as NSString).lastPathComponent : "custom")
        var request = LeaseRequest(operation: operation, key: needsKey ? positionals[0] : (["hold", "run", "watch"].contains(command) ? generatedKey : nil), source: source, sourceKind: kind, wakeClass: flags.contains("--display") ? .display : .system, ttlSeconds: ["run", "watch"].contains(command) ? 120 : ttl, reason: values["--reason"], owner: owner, sessionID: values["--session"], parentLeaseID: parent)
        request.issuedAt = issuedAt
        return request
    }
}
