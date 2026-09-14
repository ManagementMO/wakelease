import Foundation
import Testing
@testable import AdrafinilShared

private actor RollbackEnvironment: UninstallEnvironment {
    struct Failed: Error {}
    var calls: [String] = []
    let failCancellation: Bool
    init(failCancellation: Bool = false) {
        self.failCancellation = failCancellation
    }
    func pauseAndVerifySleepAllowed() async throws {
        calls.append("reserve")
    }
    func removeOwnedIntegrations() async throws {
        calls.append("hooks"); throw Failed()
    }
    func unregisterServices() async throws {
        calls.append("services")
    }
    func removeOwnedCLI() async throws {
        calls.append("cli")
    }
    func cleanOwnedState(purge _: Bool) async throws {
        calls.append("state")
    }
    func cancelPendingRemoval() async throws {
        calls.append("cancel"); if failCancellation { throw Failed() }
    }
}

@Suite("Removal rollback")
struct UninstallRollbackTests {
    @Test
    func `failed cleanup cancels the reservation before propagating failure`() async {
        let environment = RollbackEnvironment()
        do { try await UninstallCoordinator.run(environment: environment, purge: false); Issue.record("Expected cleanup failure") }
        catch {}
        #expect(await environment.calls == ["reserve", "hooks", "cancel"])
    }

    @Test
    func `failed cancellation is reported instead of silently claiming recovery`() async {
        let environment = RollbackEnvironment(failCancellation: true)
        do { try await UninstallCoordinator.run(environment: environment, purge: true); Issue.record("Expected cleanup failure") }
        catch { #expect(error.localizedDescription.contains("reservation remains")) }
        #expect(await environment.calls == ["reserve", "hooks", "cancel"])
    }
}
