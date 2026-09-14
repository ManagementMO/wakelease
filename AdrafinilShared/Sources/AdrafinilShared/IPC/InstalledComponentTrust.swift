import Darwin
import Foundation
import Security
import WakeLeaseProcess

public struct InstalledComponentTrust: Codable, Equatable, Sendable {
    public static let standardDirectory = URL(fileURLWithPath: "/Library/PrivilegedHelperTools/org.wakelease", isDirectory: true)
    public let version: Int
    public let build: String
    public let hashes: [String: [String]]

    public func requirement(identifier: String) -> String? {
        guard isValid, let values = hashes[identifier] else { return nil }
        let pins = values.map { "cdhash H\"\($0)\"" }.joined(separator: " or ")
        let text = "identifier \"\(identifier)\" and (\(pins))"
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { return nil }
        return text
    }

    public static func load(directory: URL = standardDirectory, ownerUID: UInt32 = 0) throws -> Self? {
        let storage: SecureDirectory
        do {
            storage = try SecureDirectory(url: directory, create: false, privateDirectory: false, ownerUID: ownerUID, requireProtectedACLs: true)
        } catch LocalIOError.system(ENOENT) {
            return nil
        }
        if try storage.read(name: InstalledPackageTransaction.pendingFilename, maximum: 1_024) != nil { return nil }
        let descriptor = openat(storage.descriptor, "components.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw LocalIOError.unsafePath }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == ownerUID, info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o022 == 0, info.st_nlink == 1, (1 ... 16_384).contains(info.st_size),
              wakelease_acl_allows_writing(descriptor) == 0 else { throw LocalIOError.unsafePath }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let data = try handle.read(upToCount: 16_385), data.count <= 16_384,
              let record = try? JSONDecoder().decode(Self.self, from: data), record.isValid else { throw LocalIOError.unsafePath }
        return record
    }

    public func grantRemoval(to uid: UInt32, directory: URL = Self.standardDirectory, ownerUID: UInt32 = 0) throws {
        guard uid > 0 else { throw LocalIOError.unsafePath }
        try updateAccess(removingUser: uid, directory: directory, ownerUID: ownerUID)
    }

    public func remove(directory: URL = Self.standardDirectory, ownerUID: UInt32 = 0) throws {
        let storage: SecureDirectory
        do {
            storage = try SecureDirectory(url: directory, create: false, privateDirectory: false, ownerUID: ownerUID, requireProtectedACLs: true)
        } catch LocalIOError.system(ENOENT) {
            return
        }
        guard try storage.read(name: InstalledPackageTransaction.pendingFilename, maximum: 1_024) == nil else { throw LocalIOError.alreadyRunning }
        guard let current = try Self.load(directory: directory, ownerUID: ownerUID) else { return }
        guard current == self else { throw LocalIOError.unsafePath }
        guard let data = try storage.read(name: "components.json", maximum: 16_384),
              try JSONDecoder().decode(Self.self, from: data) == self else { throw LocalIOError.unsafePath }
        try storage.remove(name: "components.json", matching: data)
        guard fsync(storage.descriptor) == 0 else { throw LocalIOError.system(errno) }
    }

    public func restore(directory: URL = Self.standardDirectory, ownerUID: UInt32 = 0) throws {
        try updateAccess(removingUser: nil, directory: directory, ownerUID: ownerUID)
    }

    private func updateAccess(removingUser: UInt32?, directory: URL, ownerUID: UInt32) throws {
        guard getuid() == ownerUID, isValid else { throw LocalIOError.unsafePath }
        let storage = try SecureDirectory(url: directory, create: false, privateDirectory: false, ownerUID: ownerUID, requireProtectedACLs: true)
        let lock = try storage.lock(name: "trust.lock")
        defer { SecureDirectory.closeLock(lock) }
        guard try storage.read(name: InstalledPackageTransaction.pendingFilename, maximum: 1_024) == nil else { throw LocalIOError.alreadyRunning }
        if let current = try Self.load(directory: directory, ownerUID: ownerUID) {
            guard current == self else { throw LocalIOError.unsafePath }
        } else {
            guard removingUser == nil else { throw LocalIOError.unsafePath }
            try storage.write(JSONEncoder().encode(self), name: "components.json", permissions: 0o644)
        }
        let descriptor = openat(storage.descriptor, "components.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw LocalIOError.system(errno) }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == ownerUID, info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1 else { throw LocalIOError.unsafePath }
        let result = removingUser.map { wakelease_grant_removal(descriptor, $0) } ?? wakelease_clear_directory_acl(descriptor)
        guard result == 0 else { throw LocalIOError.system(result) }
        guard fsync(descriptor) == 0, fsync(storage.descriptor) == 0 else { throw LocalIOError.system(errno) }
    }

    private var isValid: Bool {
        let identifiers: Set<String> = [WakeLeaseIdentity.appBundleID, WakeLeaseIdentity.cliBundleID, WakeLeaseIdentity.daemonBundleID, WakeLeaseIdentity.helperBundleID]
        return version == 1 && build.range(of: "\\A[0-9a-f]{40}\\z", options: .regularExpression) != nil
            && Set(hashes.keys) == identifiers && hashes.values.allSatisfy { values in
                (1 ... 2).contains(values.count) && Set(values).count == values.count
                    && values.allSatisfy { $0.range(of: "\\A[0-9a-fA-F]{40}\\z", options: .regularExpression) != nil }
            }
    }
}
