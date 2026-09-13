import Foundation
import Testing
@testable import AdrafinilShared

@Suite("Owned CLI installation")
struct CLILinkManagerTests {
    private func fixture() throws -> (URL, CLILinkManager, URL) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("wl-link-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let target = home.appendingPathComponent("bundle/Contents/Helpers/wakelease")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("test executable".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
        return (home, CLILinkManager(home: home, stateDirectory: home.appendingPathComponent("state")), target)
    }

    @Test
    func `round trip is idempotent and receipt backed`() throws {
        let (home, manager, target) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        try manager.install(target: target)
        try manager.install(target: target)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: manager.destination.path) == target.path)
        try manager.uninstall()
        try manager.uninstall()
        #expect(!FileManager.default.fileExists(atPath: manager.destination.path))
    }

    @Test
    func `foreign executable is never replaced or removed`() throws {
        let (home, manager, target) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: manager.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("foreign".utf8).write(to: manager.destination)
        #expect(throws: (any Error).self) { try manager.install(target: target) }
        try manager.uninstall()
        #expect(try String(contentsOf: manager.destination, encoding: .utf8) == "foreign")
    }

    @Test
    func `changed symlink is not removed`() throws {
        let (home, manager, target) = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        try manager.install(target: target)
        try FileManager.default.removeItem(at: manager.destination)
        try FileManager.default.createSymbolicLink(at: manager.destination, withDestinationURL: home.appendingPathComponent("foreign"))
        #expect(throws: (any Error).self) { try manager.uninstall() }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: manager.destination.path).hasSuffix("foreign"))
    }
}

private actor FakeUninstallEnvironment: UninstallEnvironment {
    struct Refused: Error {}
    let refuseClear: Bool
    var events: [String] = []
    init(refuseClear: Bool = false) {
        self.refuseClear = refuseClear
    }
    func pauseAndVerifySleepAllowed() async throws {
        events.append("clear"); if refuseClear { throw Refused() }
    }
    func removeOwnedIntegrations() async throws {
        events.append("hooks")
    }
    func unregisterServices() async throws {
        events.append("services")
    }
    func removeOwnedCLI() async throws {
        events.append("cli")
    }
    func cleanOwnedState(purge: Bool) async throws {
        events.append(purge ? "purge" : "state")
    }
}

@Suite("Uninstall safety ordering")
struct UninstallCoordinatorTests {
    @Test
    func `requires confirmed cleanup before removing recovery mechanisms`() async throws {
        let environment = FakeUninstallEnvironment()
        try await UninstallCoordinator.run(environment: environment, purge: false)
        #expect(await environment.events == ["clear", "hooks", "services", "cli", "state"])
    }

    @Test
    func `unknown power state prevents destructive teardown`() async {
        let environment = FakeUninstallEnvironment(refuseClear: true)
        do { try await UninstallCoordinator.run(environment: environment, purge: true); Issue.record("Uninstall continued without confirmed cleanup") }
        catch {}
        #expect(await environment.events == ["clear"])
    }
}
