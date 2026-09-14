import Foundation

public struct CustomIntegrationOptions: Sendable {
    public var source = "my-tool"
    public var sessionVariable = "WORK_ID"
    public var ttlSeconds: TimeInterval = 3_600
    public var wakeClass: WakeClass = .system
    public var executable = ""
    public var startEvent = "Work starts / resumes"
    public var stopEvent = "Work finishes / cancels"

    public init() {}

    public func recipe(cliPath: String) throws -> CustomIntegrationRecipe {
        guard source.range(of: "\\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\\z", options: .regularExpression) != nil else {
            throw LeaseCLIUsageError("Use a source ID of 1–64 letters, numbers, dots, underscores or hyphens, starting with a letter or number.")
        }
        guard sessionVariable.utf8.count <= 128, sessionVariable.range(of: "\\A[A-Za-z_][A-Za-z0-9_]*\\z", options: .regularExpression) != nil else {
            throw LeaseCLIUsageError("Work ID source must be a shell variable name, not an expression.")
        }
        guard ttlSeconds.isFinite, (1 ... 86_400).contains(ttlSeconds) else { throw LeaseCLIUsageError("Choose a finite lifetime from one second to 24 hours.") }
        let command = executable.isEmpty ? source : executable
        for value in [cliPath, command, startEvent, stopEvent] {
            guard !value.isEmpty, value.utf8.count <= 4_096, !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw LeaseCLIUsageError("Executable paths and event labels must be nonempty printable text.")
            }
        }
        guard cliPath.hasPrefix("/"), startEvent.utf8.count <= 128, stopEvent.utf8.count <= 128 else { throw LeaseCLIUsageError("Use an absolute WakeLease path and event labels of at most 128 bytes.") }
        let cli = LeaseIntegrations.quote(cliPath)
        let key = "\(LeaseIntegrations.quote(source + ":"))\"${\(sessionVariable)}\""
        let display = wakeClass == .display ? " --display" : ""
        let steps = [("acquire", startEvent), ("wait", "Waiting for user input"), ("heartbeat", "Periodic heartbeat"), ("release", stopEvent)].map { operation, event in
            let options = operation == "acquire" ? " --source \(LeaseIntegrations.quote(source)) --ttl \(ttlSeconds)\(display)" : ""
            let invocation = "if [ -n \"${\(sessionVariable):-}\" ]; then \(cli) \(operation) \(key)\(options) >/dev/null 2>&1 || :; fi"
            return CustomIntegrationRecipe.Step(operation: operation, event: event, command: invocation)
        }
        return CustomIntegrationRecipe(
            source: source,
            sessionVariable: sessionVariable,
            ttlSeconds: ttlSeconds,
            wakeClass: wakeClass,
            steps: steps,
            wrapper: "\(cli) run --source \(LeaseIntegrations.quote(source))\(display) -- \(LeaseIntegrations.quote(command))",
        )
    }
}

public struct CustomIntegrationRecipe: Encodable, Sendable {
    public struct Step: Encodable, Sendable, Identifiable {
        public var id: String {
            operation
        }
        public let operation: String
        public let event: String
        public let command: String
    }
    public let version = 1
    public let source: String
    public let sessionVariable: String
    public let ttlSeconds: TimeInterval
    public let wakeClass: WakeClass
    public let steps: [Step]
    public let wrapper: String
}
