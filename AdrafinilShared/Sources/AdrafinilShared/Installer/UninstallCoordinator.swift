public protocol UninstallEnvironment: Sendable {
    func pauseAndVerifySleepAllowed() async throws
    func removeOwnedIntegrations() async throws
    func unregisterServices() async throws
    func removeOwnedCLI() async throws
    func cleanOwnedState(purge: Bool) async throws
}

public enum UninstallCoordinator {
    public static func run(environment: any UninstallEnvironment, purge: Bool) async throws {
        try await environment.pauseAndVerifySleepAllowed()
        try await environment.removeOwnedIntegrations()
        try await environment.unregisterServices()
        try await environment.removeOwnedCLI()
        try await environment.cleanOwnedState(purge: purge)
    }
}
