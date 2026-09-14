import Darwin
import Foundation

public enum LocalIOError: Error, LocalizedError {
    case unsafePath
    case unavailable
    case alreadyRunning
    case frame
    case timeout
    case closed
    case peer
    case system(Int32)

    public var errorDescription: String? {
        switch self {
        case .unsafePath: "Unsafe path or permissions. Use an owned directory without symlinks."
        case .unavailable: "The WakeLease daemon is not reachable."
        case .alreadyRunning: "Another WakeLease process owns the required state or maintenance lock."
        case .frame: "Invalid or oversized local protocol frame."
        case .timeout: "Local operation timed out; a mutation may already have applied. Check status before retrying."
        case .closed: "The local connection closed before the response was complete."
        case .peer: "Local peer credentials could not be verified."
        case let .system(code): "Local I/O failed (errno \(code))."
        }
    }
}

public enum WakeLeasePaths {
    public static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["WAKELEASE_STATE_DIR"], override.hasPrefix("/") {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return standardDirectory
    }

    public static var standardDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(WakeLeaseIdentity.name, isDirectory: true)
    }
}

public final class SecureDirectory: @unchecked Sendable {
    public let url: URL
    public let descriptor: Int32
    public let ownerUID: UInt32

    public init(url: URL, create: Bool, privateDirectory: Bool = true, ownerUID: UInt32 = getuid()) throws {
        guard !create || ownerUID == getuid() else { throw LocalIOError.unsafePath }
        var components = url.pathComponents.filter { $0 != "/" }
        guard url.path.hasPrefix("/"), !components.isEmpty, !components.contains(".."), !components.contains(".") else { throw LocalIOError.unsafePath }
        if let root = components.first, ["var", "tmp", "etc"].contains(root) {
            components.insert("private", at: 0)
        }
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw LocalIOError.system(errno) }
        do {
            for component in components {
                var next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0, errno == ENOENT, create {
                    guard mkdirat(fd, component, 0o700) == 0 || errno == EEXIST else { throw LocalIOError.system(errno) }
                    next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else {
                    if errno == ENOENT { throw LocalIOError.system(ENOENT) }
                    throw LocalIOError.unsafePath
                }
                Darwin.close(fd)
                fd = next
                var info = stat()
                guard fstat(fd, &info) == 0, info.st_uid == 0 || info.st_uid == ownerUID,
                      info.st_mode & 0o022 == 0 || (info.st_uid == 0 && info.st_mode & 0o1000 != 0) else { throw LocalIOError.unsafePath }
            }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_uid == ownerUID, !privateDirectory || info.st_mode & 0o077 == 0 else { throw LocalIOError.unsafePath }
        } catch {
            Darwin.close(fd)
            throw error
        }
        self.url = url
        self.ownerUID = ownerUID
        descriptor = fd
    }

    deinit { Darwin.close(descriptor) }

    public func read(name: String, maximum: Int = 2 * 1_024 * 1_024) throws -> Data? {
        try validateName(name)
        let fd = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw LocalIOError.unsafePath }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, safeFile(info), info.st_size >= 0, info.st_size <= maximum else { throw LocalIOError.unsafePath }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw LocalIOError.system(errno) }
            if count == 0 { break }
            guard data.count + count <= maximum else { throw LocalIOError.unsafePath }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    public func write(_ data: Data, name: String, permissions: UInt16 = 0o600) throws {
        guard ownerUID == getuid() else { throw LocalIOError.unsafePath }
        try validateName(name)
        try validateExisting(name)
        let temporary = ".write-" + UUID().uuidString
        let fd = openat(descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw LocalIOError.system(errno) }
        defer { Darwin.close(fd); unlinkat(descriptor, temporary, 0) }
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), data.count - offset) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw LocalIOError.system(errno) }
            offset += count
        }
        guard fchmod(fd, permissions & 0o777) == 0, fsync(fd) == 0 else { throw LocalIOError.system(errno) }
        try validateExisting(name)
        guard renameat(descriptor, temporary, descriptor, name) == 0 else { throw LocalIOError.system(errno) }
    }

    public func permissions(name: String) throws -> UInt16? {
        try validateName(name)
        var info = stat()
        if fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }
            throw LocalIOError.system(errno)
        }
        guard safeFile(info) else { throw LocalIOError.unsafePath }
        return info.st_mode & 0o777
    }

    public func remove(name: String, matching expected: Data) throws {
        guard try read(name: name) == expected else { throw LocalIOError.unsafePath }
        try validateExisting(name)
        guard unlinkat(descriptor, name, 0) == 0 else { throw LocalIOError.system(errno) }
    }

    public func symbolicLinkTarget(name: String) throws -> String? {
        try validateName(name)
        var info = stat()
        if fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }
            throw LocalIOError.system(errno)
        }
        guard info.st_mode & S_IFMT == S_IFLNK, info.st_uid == getuid() else { throw LocalIOError.unsafePath }
        var bytes = [UInt8](repeating: 0, count: 4_096)
        let count = readlinkat(descriptor, name, &bytes, bytes.count)
        guard count > 0, count < bytes.count else { throw LocalIOError.unsafePath }
        return String(decoding: bytes.prefix(count), as: UTF8.self)
    }

    public func createSymbolicLink(name: String, target: String) throws {
        try validateName(name)
        guard target.hasPrefix("/"), !target.utf8.contains(0) else { throw LocalIOError.unsafePath }
        guard symlinkat(target, descriptor, name) == 0 else { throw LocalIOError.system(errno) }
    }

    public func removeSymbolicLink(name: String, target: String) throws {
        guard try symbolicLinkTarget(name: name) == target else { throw LocalIOError.unsafePath }
        guard unlinkat(descriptor, name, 0) == 0 else { throw LocalIOError.system(errno) }
    }

    public func removeSocket(name: String) throws {
        try validateName(name)
        var info = stat()
        if fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return }
            throw LocalIOError.system(errno)
        }
        guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid(), unlinkat(descriptor, name, 0) == 0 else { throw LocalIOError.unsafePath }
    }

    public func removeEmptyDirectory(name: String) throws {
        try validateName(name)
        var info = stat()
        if fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return }
            throw LocalIOError.system(errno)
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { throw LocalIOError.unsafePath }
        guard unlinkat(descriptor, name, AT_REMOVEDIR) == 0 || errno == ENOTEMPTY else { throw LocalIOError.system(errno) }
    }

    public func lock(name: String) throws -> Int32 {
        guard ownerUID == getuid() else { throw LocalIOError.unsafePath }
        try validateName(name)
        let fd = openat(descriptor, name, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw LocalIOError.unsafePath }
        var info = stat()
        guard fstat(fd, &info) == 0, safeFile(info), flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            throw LocalIOError.alreadyRunning
        }
        return fd
    }

    public static func closeLock(_ descriptor: Int32) {
        while flock(descriptor, LOCK_UN) != 0, errno == EINTR {}
        Darwin.close(descriptor)
    }

    func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0) else { throw LocalIOError.unsafePath }
    }

    private func validateExisting(_ name: String) throws {
        var info = stat()
        if fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            guard safeFile(info) else { throw LocalIOError.unsafePath }
        } else if errno != ENOENT {
            throw LocalIOError.system(errno)
        }
    }

    private func safeFile(_ info: stat) -> Bool {
        info.st_mode & S_IFMT == S_IFREG && info.st_uid == ownerUID && info.st_nlink == 1
    }
}
