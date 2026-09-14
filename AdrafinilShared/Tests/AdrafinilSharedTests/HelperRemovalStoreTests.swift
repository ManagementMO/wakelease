import Darwin
import Foundation
import Testing
@testable import AdrafinilShared

@Suite("Durable removal ownership")
struct HelperRemovalStoreTests {
    @Test
    func `reservation storage survives restart and removes only its own ticket`() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wl-removal-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HelperRemovalStore(directory: url, ownerUID: getuid())
        let reservation = HelperRemovalReservation(id: UUID(), uid: getuid())
        #expect(try store.load() == nil)
        try store.save(reservation)
        #expect(try HelperRemovalStore(directory: url, ownerUID: getuid()).load() == reservation)
        #expect(throws: (any Error).self) { try store.remove(HelperRemovalReservation(id: UUID(), uid: getuid())) }
        #expect(try store.load() == reservation)
        try store.remove(reservation)
        #expect(try store.load() == nil)
    }

    @Test
    func `the delegated delete right does not require a writable directory`() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wl-removal-" + UUID().uuidString)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: url)
        }
        let store = HelperRemovalStore(directory: url, ownerUID: getuid())
        let reservation = HelperRemovalReservation(id: UUID(), uid: getuid())
        try store.save(reservation)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: url.path)
        try store.remove(reservation)
        #expect(try store.load() == nil)
    }

    @Test
    func `corrupt removal data is never treated as open admission`() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wl-removal-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let directory = try SecureDirectory(url: url, create: true)
        try directory.write(Data("not json".utf8), name: "removal-" + UUID().uuidString + ".json")
        #expect(throws: (any Error).self) { try HelperRemovalStore(directory: url, ownerUID: getuid()).load() }
    }

    @Test
    func `same user maintenance is exclusive until the owner exits`() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wl-removal-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let directory = try SecureDirectory(url: url, create: true)
        do {
            let first = try directory.lock(name: "maintenance.lock")
            defer { SecureDirectory.closeLock(first) }
            #expect(throws: (any Error).self) { try directory.lock(name: "maintenance.lock") }
        }
        let next = try directory.lock(name: "maintenance.lock")
        SecureDirectory.closeLock(next)
    }

    @Test
    func `a ticket cannot follow a foreign link`() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wl-removal-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let directory = try SecureDirectory(url: url, create: true)
        let reservation = HelperRemovalReservation(id: UUID(), uid: getuid())
        try directory.createSymbolicLink(name: "removal-" + reservation.id.uuidString.lowercased() + ".json", target: "/dev/null")
        #expect(throws: (any Error).self) { try HelperRemovalStore(directory: url, ownerUID: getuid()).save(reservation) }
    }
}
