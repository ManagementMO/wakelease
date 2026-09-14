import Darwin
import Foundation
import WakeLeaseProcess

public struct InstalledPackageTransaction {
    static let pendingFilename = "installation.pending"
    public let directory: URL
    public let ownerUID: UInt32

    public init(directory: URL = InstalledComponentTrust.standardDirectory, ownerUID: UInt32 = 0) {
        self.directory = directory
        self.ownerUID = ownerUID
    }

    public func begin(_ record: InstalledComponentTrust, verifyIdle: () throws -> Void) throws {
        guard record.requirement(identifier: WakeLeaseIdentity.appBundleID) != nil else { throw LocalIOError.unsafePath }
        let storage = try openStorage(create: true)
        let lock = try storage.lock(name: "trust.lock")
        defer { SecureDirectory.closeLock(lock) }
        guard try storage.read(name: Self.pendingFilename, maximum: 1_024) == nil else { throw LocalIOError.alreadyRunning }
        try verifyIdle()
        let marker = try encodedMarker(for: record)
        try storage.write(marker, name: Self.pendingFilename, permissions: 0o644)
        guard fsync(storage.descriptor) == 0 else { throw LocalIOError.system(errno) }
        do {
            try verifyIdle()
        } catch {
            try storage.remove(name: Self.pendingFilename, matching: marker)
            guard fsync(storage.descriptor) == 0 else { throw LocalIOError.system(errno) }
            throw error
        }
    }

    public func activate(_ record: InstalledComponentTrust, verifyPayload: () throws -> Void) throws {
        guard record.requirement(identifier: WakeLeaseIdentity.appBundleID) != nil else { throw LocalIOError.unsafePath }
        let storage = try openStorage(create: false)
        let lock = try storage.lock(name: "trust.lock")
        defer { SecureDirectory.closeLock(lock) }
        let marker = try encodedMarker(for: record)
        guard try storage.read(name: Self.pendingFilename, maximum: 1_024) == marker else { throw LocalIOError.unsafePath }
        try verifyPayload()
        try storage.write(JSONEncoder().encode(record), name: "components.json", permissions: 0o644)
        guard fsync(storage.descriptor) == 0 else { throw LocalIOError.system(errno) }
        try storage.remove(name: Self.pendingFilename, matching: marker)
        guard fsync(storage.descriptor) == 0 else { throw LocalIOError.system(errno) }
    }

    public func revoke(_ record: InstalledComponentTrust) throws {
        let storage = try openStorage(create: false)
        let lock = try storage.lock(name: "trust.lock")
        defer { SecureDirectory.closeLock(lock) }
        let marker = try encodedMarker(for: record)
        guard try storage.read(name: Self.pendingFilename, maximum: 1_024) == marker else { throw LocalIOError.unsafePath }
        if let data = try storage.read(name: "components.json", maximum: 16_384) {
            guard try JSONDecoder().decode(InstalledComponentTrust.self, from: data) == record else { throw LocalIOError.unsafePath }
            try storage.remove(name: "components.json", matching: data)
            guard fsync(storage.descriptor) == 0 else { throw LocalIOError.system(errno) }
        }
        try storage.remove(name: Self.pendingFilename, matching: marker)
        guard fsync(storage.descriptor) == 0 else { throw LocalIOError.system(errno) }
    }

    public func cancel(_ record: InstalledComponentTrust, verifyIdle: () throws -> Void) throws {
        let storage = try openStorage(create: false)
        let lock = try storage.lock(name: "trust.lock")
        defer { SecureDirectory.closeLock(lock) }
        let marker = try encodedMarker(for: record)
        guard try storage.read(name: Self.pendingFilename, maximum: 1_024) == marker else { throw LocalIOError.unsafePath }
        try verifyIdle()
        try storage.remove(name: Self.pendingFilename, matching: marker)
        guard fsync(storage.descriptor) == 0 else { throw LocalIOError.system(errno) }
    }

    private func encodedMarker(for record: InstalledComponentTrust) throws -> Data {
        guard record.requirement(identifier: WakeLeaseIdentity.appBundleID) != nil else { throw LocalIOError.unsafePath }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(record)
    }

    private func openStorage(create: Bool) throws -> SecureDirectory {
        guard getuid() == ownerUID else { throw LocalIOError.unsafePath }
        let storage = try SecureDirectory(url: directory, create: create, privateDirectory: false, ownerUID: ownerUID, requireProtectedACLs: true)
        if create {
            let result = wakelease_clear_directory_acl(storage.descriptor)
            guard result == 0 else { throw LocalIOError.system(result) }
            guard fchmod(storage.descriptor, 0o755) == 0 else { throw LocalIOError.system(errno) }
        }
        return storage
    }
}
