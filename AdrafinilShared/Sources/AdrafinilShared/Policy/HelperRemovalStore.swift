import Darwin
import Foundation
import WakeLeaseProcess

public struct HelperRemovalStore: Sendable {
    public static var standardDirectory: URL {
        URL(fileURLWithPath: "/Library/Application Support", isDirectory: true).appendingPathComponent(WakeLeaseIdentity.helperBundleID, isDirectory: true)
    }

    public let directory: URL
    public let ownerUID: UInt32

    public init(directory: URL = Self.standardDirectory, ownerUID: UInt32 = 0) {
        self.directory = directory
        self.ownerUID = ownerUID
    }

    public func load() throws -> HelperRemovalReservation? {
        let storage: SecureDirectory
        do { storage = try SecureDirectory(url: directory, create: false, privateDirectory: false, ownerUID: ownerUID) }
        catch LocalIOError.system(ENOENT) { return nil }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("removal-") }
        guard names.count <= 1 else { throw HelperRemovalFailure.unsafeStorage }
        guard let name = names.first, let data = try storage.read(name: name, maximum: 4_096) else { return nil }
        let reservation = try JSONDecoder().decode(HelperRemovalReservation.self, from: data)
        guard name == filename(reservation) else { throw HelperRemovalFailure.unsafeStorage }
        return reservation
    }

    public func save(_ reservation: HelperRemovalReservation) throws {
        guard getuid() == ownerUID, reservation.uid > 0 else { throw HelperRemovalFailure.invalidReservation }
        if let current = try load(), current != reservation { throw HelperRemovalFailure.reserved }
        let storage = try SecureDirectory(url: directory, create: true, privateDirectory: false, ownerUID: ownerUID)
        let directoryACL = wakelease_clear_directory_acl(storage.descriptor)
        guard directoryACL == 0 else { throw LocalIOError.system(directoryACL) }
        guard fchmod(storage.descriptor, 0o755) == 0 else { throw LocalIOError.system(errno) }
        let name = filename(reservation)
        try storage.write(JSONEncoder().encode(reservation), name: name)
        let descriptor = openat(storage.descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw LocalIOError.system(errno) }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == ownerUID, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw HelperRemovalFailure.unsafeStorage }
        let result = wakelease_grant_removal(descriptor, reservation.uid)
        guard result == 0 else { throw LocalIOError.system(result) }
        guard fsync(descriptor) == 0, fsync(storage.descriptor) == 0 else { throw LocalIOError.system(errno) }
    }

    public func remove(_ reservation: HelperRemovalReservation) throws {
        guard let current = try load() else { return }
        guard current == reservation, getuid() == ownerUID || getuid() == reservation.uid else { throw HelperRemovalFailure.invalidReservation }
        let storage = try SecureDirectory(url: directory, create: false, privateDirectory: false, ownerUID: ownerUID)
        let name = filename(reservation)
        guard let data = try storage.read(name: name, maximum: 4_096) else { return }
        try storage.remove(name: name, matching: data)
        guard fsync(storage.descriptor) == 0 else { throw LocalIOError.system(errno) }
    }

    private func filename(_ reservation: HelperRemovalReservation) -> String {
        "removal-" + reservation.id.uuidString.lowercased() + ".json"
    }
}
