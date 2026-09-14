import Foundation
import os
import Security
import Testing
@testable import AdrafinilShared

@objc
private protocol BoundaryEchoProtocol {
    func echo(_ value: String, reply: @escaping @Sendable (String) -> Void)
}

private final class BoundaryEchoServer: NSObject, NSXPCListenerDelegate, BoundaryEchoProtocol, @unchecked Sendable {
    struct State: Sendable {
        var accepted = 0
        var calls = 0
    }
    let state = OSAllocatedUnfairLock(initialState: State())

    func listener(_: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        state.withLock { $0.accepted += 1 }
        connection.exportedInterface = NSXPCInterface(with: BoundaryEchoProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func echo(_ value: String, reply: @escaping @Sendable (String) -> Void) {
        state.withLock { $0.calls += 1 }
        reply(value)
    }
}

@Suite("Live anonymous XPC authorization")
struct XPCBoundaryTests {
    private enum Outcome: Sendable, Equatable {
        case reply(String)
        case rejected(Int)
        case timedOut
    }

    private func selfRequirement() throws -> String {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        var text: CFString?
        let selfStatus = SecCodeCopySelf([], &code)
        #expect(selfStatus == errSecSuccess)
        let staticStatus = try SecCodeCopyStaticCode(#require(code), [], &staticCode)
        #expect(staticStatus == errSecSuccess)
        let requirementStatus = try SecCodeCopyDesignatedRequirement(#require(staticCode), [], &requirement)
        #expect(requirementStatus == errSecSuccess)
        let textStatus = try SecRequirementCopyString(#require(requirement), [], &text)
        #expect(textStatus == errSecSuccess)
        return try #require(text) as String
    }

    private func roundTrip(listenerRequirement: String, clientRequirement: String) throws -> (Outcome, Int, Int) {
        let server = BoundaryEchoServer()
        let listener = NSXPCListener.anonymous()
        listener.delegate = server
        listener.setConnectionCodeSigningRequirement(listenerRequirement)
        listener.resume()
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        defer { connection.invalidate(); listener.invalidate() }
        connection.remoteObjectInterface = NSXPCInterface(with: BoundaryEchoProtocol.self)
        connection.setCodeSigningRequirement(clientRequirement)
        let outcome = OSAllocatedUnfairLock(initialState: Outcome.timedOut)
        let finished = DispatchSemaphore(value: 0)
        let once = OnceResumer<Outcome> { value in outcome.withLock { $0 = value }; finished.signal() }
        connection.resume()
        let proxy = try #require(connection.remoteObjectProxyWithErrorHandler { error in
            once.resume(.rejected((error as NSError).code))
        } as? BoundaryEchoProtocol)
        proxy.echo("owned-test-peer") { once.resume(.reply($0)) }
        _ = finished.wait(timeout: .now() + 5)
        return server.state.withLock { (outcome.withLock { $0 }, $0.accepted, $0.calls) }
    }

    @Test
    func `matching test code can perform a real XPC round trip`() throws {
        let requirement = try selfRequirement()
        let result = try roundTrip(listenerRequirement: requirement, clientRequirement: requirement)
        #expect(result.0 == .reply("owned-test-peer"))
        #expect(result.1 == 1)
        #expect(result.2 == 1)
    }

    @Test(arguments: [ComponentTrust.Role.app, .daemon, .helper])
    func `production listener requirements reject the real test peer`(_ role: ComponentTrust.Role) throws {
        let production = try #require(ComponentTrust.requirement(team: "TESTTEAM01", role: role))
        let result = try roundTrip(listenerRequirement: production, clientRequirement: selfRequirement())
        #expect(result.0 != .timedOut)
        #expect(result.0 != .reply("owned-test-peer"))
        #expect(result.1 == 0)
        #expect(result.2 == 0)
    }

    @Test
    func `client helper pin rejects an untrusted reply to the read only probe`() throws {
        let production = try #require(ComponentTrust.requirement(team: "TESTTEAM01", role: .helper))
        let result = try roundTrip(listenerRequirement: selfRequirement(), clientRequirement: production)
        #expect(result.0 != .timedOut)
        #expect(result.0 != .reply("owned-test-peer"))
        #expect(result.2 == 1)
    }
}
