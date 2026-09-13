import Darwin
import Foundation
import Testing
@testable import AdrafinilShared

@Suite("Local lease transport")
struct LeaseTransportTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("wl-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    @Test func framedProtocolHandlesRealLocalRoundTrips() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = LeaseProtocolService(broker: LeaseBroker(), mode: "simulation")
        let server = LeaseSocketServer(directory: directory) { request, peer in await service.handle(request, peer: peer) }
        try server.start()
        defer { server.stop() }
        let client = LeaseSocketClient(directory: directory)
        let acquire = try await client.sendAsync(LeaseRequest(operation: "acquire", key: "build:1", source: "build"))
        #expect(acquire.ok)
        #expect(acquire.lease?.key == "build:1")
        #expect(acquire.status?.snapshot.effectiveCount == 1)
        let released = try await client.sendAsync(LeaseRequest(operation: "release", key: "build:1"))
        #expect(released.ok)
        #expect(released.status?.snapshot.demand == WakeDemand.none)
        #expect(try await client.sendAsync(LeaseRequest(operation: "release", key: "build:1")).changed == false)
        let permissions = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("cli.sock").path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test func protocolVersionsAndUnknownOperationsReturnStructuredErrors() async {
        let service = LeaseProtocolService(broker: LeaseBroker(), mode: "simulation")
        let peer = LocalPeer(uid: getuid(), pid: getpid())
        var request = LeaseRequest(operation: "status")
        request.version = 99
        #expect(await service.handle(request, peer: peer).error?.code == "unsupported_version")
        #expect(await service.handle(LeaseRequest(operation: "unknown"), peer: peer).error?.code == "unknown_operation")
        #expect(await service.handle(LeaseRequest(operation: "acquire", key: "a", source: "x"), peer: LocalPeer(uid: getuid() + 1, pid: 1)).error?.code == "unauthorized_peer")
    }

    @Test func concurrentClientsAreReferenceCounted() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = LeaseProtocolService(broker: LeaseBroker(), mode: "simulation")
        let server = LeaseSocketServer(directory: directory) { request, peer in await service.handle(request, peer: peer) }
        try server.start()
        defer { server.stop() }
        let client = LeaseSocketClient(directory: directory)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<12 {
                group.addTask { () async throws -> Void in
                    let reply = try await client.sendAsync(LeaseRequest(operation: "acquire", key: "client-\(index)"))
                    #expect(reply.ok)
                }
            }
            try await group.waitForAll()
        }
        #expect(try await client.sendAsync(LeaseRequest(operation: "status")).status?.snapshot.effectiveCount == 12)
        #expect(try await client.sendAsync(LeaseRequest(operation: "releaseAll")).status?.snapshot.effectiveCount == 0)
    }

    @Test func secondDaemonDoesNotUnlinkFirstDaemonsSocket() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = LeaseProtocolService(broker: LeaseBroker(), mode: "simulation")
        let first = LeaseSocketServer(directory: directory) { request, peer in await service.handle(request, peer: peer) }
        try first.start()
        defer { first.stop() }
        let second = LeaseSocketServer(directory: directory) { request, peer in await service.handle(request, peer: peer) }
        #expect(throws: (any Error).self) { try second.start() }
        #expect(try await LeaseSocketClient(directory: directory).sendAsync(LeaseRequest(operation: "status")).ok)
    }

    @Test func foreignSocketPathIsNeverOverwritten() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("cli.sock")
        try Data("unrelated".utf8).write(to: path)
        let server = LeaseSocketServer(directory: directory) { _, _ in LeaseReply(ok: true) }
        #expect(throws: (any Error).self) { try server.start() }
        #expect(try String(contentsOf: path, encoding: .utf8) == "unrelated")
    }

    @Test func symlinkedStateDirectoryIsRejected() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
        #expect(throws: (any Error).self) { _ = try SecureDirectory(url: link, create: false) }
    }

    @Test func privateStateWritesAreAtomicAndRejectSymlinks() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try SecureDirectory(url: directory, create: false)
        try storage.write(Data("first".utf8), name: "state.json")
        try storage.write(Data("second".utf8), name: "state.json")
        #expect(try storage.read(name: "state.json") == Data("second".utf8))
        try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent("link.json").path, withDestinationPath: "state.json")
        #expect(throws: (any Error).self) { try storage.write(Data("bad".utf8), name: "link.json") }
        #expect(try storage.read(name: "state.json") == Data("second".utf8))
    }

    @Test func replayedReleaseAllCannotReleaseNewWork() async throws {
        let broker = LeaseBroker()
        let service = LeaseProtocolService(broker: broker, mode: "simulation")
        let peer = LocalPeer(uid: getuid(), pid: getpid())
        let releaseAll = LeaseRequest(operation: "releaseAll")
        _ = await service.handle(releaseAll, peer: peer)
        _ = try await broker.acquire(LeaseProposal(key: "new"))
        _ = await service.handle(releaseAll, peer: peer)
        #expect(await broker.snapshot().effectiveCount == 1)
    }

    @Test func aStaleResumeCannotUndoAPause() async {
        let broker = LeaseBroker()
        let service = LeaseProtocolService(broker: broker, mode: "simulation")
        let peer = LocalPeer(uid: getuid(), pid: getpid())
        let oldResume = LeaseRequest(operation: "resume")
        _ = await service.handle(LeaseRequest(operation: "pause"), peer: peer)
        #expect(await service.handle(oldResume, peer: peer).ok == false)
        #expect(await broker.snapshot().paused)
    }

    @Test func malformedFramesAreRejectedBeforeAllocation() {
        #expect(throws: (any Error).self) { try LeaseFrames.decodeLength(Data([255, 255, 255, 255]), maximum: 65536) }
        #expect(throws: (any Error).self) { try LeaseFrames.decodeLength(Data([0, 0]), maximum: 65536) }
        #expect(throws: (any Error).self) { try LeaseFrames.decodeLength(Data([0, 0, 0, 0]), maximum: 65536) }
    }
}
