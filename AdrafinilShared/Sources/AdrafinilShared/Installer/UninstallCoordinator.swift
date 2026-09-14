import Foundation

public protocol UninstallEnvironment: Sendable {
    func pauseAndVerifySleepAllowed() async throws
    func removeOwnedIntegrations() async throws
    func unregisterServices() async throws
    func removeOwnedCLI() async throws
    func cleanOwnedState(purge: Bool) async throws
    func cancelPendingRemoval() async throws
}

public extension UninstallEnvironment {
    func cancelPendingRemoval() async throws {}
}

public struct UninstallRecoveryFailure: Error, LocalizedError, Sendable {
    public let cause: String
    public let recovery: String
    public var errorDescription: String? {
        "Uninstall failed: \(cause). The removal reservation remains unconfirmed: \(recovery). Restore services from the owning app before starting new work."
    }
}

public enum UninstallCoordinator {
    public static func run(environment: any UninstallEnvironment, purge: Bool) async throws {
        do {
            try await environment.pauseAndVerifySleepAllowed()
            try await environment.removeOwnedIntegrations()
            try await environment.unregisterServices()
            try await environment.removeOwnedCLI()
            try await environment.cleanOwnedState(purge: purge)
        } catch {
            let original = error
            do { try await environment.cancelPendingRemoval() }
            catch { throw UninstallRecoveryFailure(cause: original.localizedDescription, recovery: error.localizedDescription) }
            throw original
        }
    }
}
