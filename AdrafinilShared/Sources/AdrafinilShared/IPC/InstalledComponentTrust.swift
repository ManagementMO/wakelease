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

    private var isValid: Bool {
        let identifiers: Set<String> = [WakeLeaseIdentity.appBundleID, WakeLeaseIdentity.cliBundleID, WakeLeaseIdentity.daemonBundleID, WakeLeaseIdentity.helperBundleID]
        return version == 1 && build.range(of: "\\A[0-9a-f]{40}\\z", options: .regularExpression) != nil
            && Set(hashes.keys) == identifiers && hashes.values.allSatisfy { values in
                (1 ... 2).contains(values.count) && Set(values).count == values.count
                    && values.allSatisfy { $0.range(of: "\\A[0-9a-fA-F]{40}\\z", options: .regularExpression) != nil }
            }
    }
}
