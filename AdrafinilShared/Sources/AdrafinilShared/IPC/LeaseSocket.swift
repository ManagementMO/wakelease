import Darwin
import Foundation
import os

public enum LeaseFrames {
    public static let maximumRequest = 65_536
    public static let maximumReply = 2 * 1_024 * 1_024

    public static func frame(_ body: Data, maximum: Int) throws -> Data {
        guard !body.isEmpty, body.count <= maximum else { throw LocalIOError.frame }
        var length = UInt32(body.count).bigEndian
        var data = Data(bytes: &length, count: 4)
        data.append(body)
        return data
    }

    public static func decodeLength(_ data: Data, maximum: Int) throws -> Int {
        guard data.count == 4 else { throw LocalIOError.frame }
        let count = data.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard count > 0, count <= maximum else { throw LocalIOError.frame }
        return Int(count)
    }
}

public struct LeaseSocketClient: Sendable {
    public let directory: URL
    public let timeout: TimeInterval

    public init(directory: URL = WakeLeasePaths.directory, timeout: TimeInterval = 2) {
        self.directory = directory
        self.timeout = timeout
    }

    public func sendAsync(_ request: LeaseRequest) async throws -> LeaseReply {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { try continuation.resume(returning: send(request)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    public func send(_ request: LeaseRequest) throws -> LeaseReply {
        let storage = try SecureDirectory(url: directory, create: false)
        var info = stat()
        guard fstatat(storage.descriptor, "cli.sock", &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw LocalIOError.unavailable }
        let fd = try SocketIO.makeSocket()
        defer { Darwin.close(fd) }
        let deadline = SocketIO.now + timeout
        let result = try SocketIO.address(directory.appendingPathComponent("cli.sock").path) { Darwin.connect(fd, $0, $1) }
        if result != 0 {
            guard errno == EINPROGRESS else { throw LocalIOError.unavailable }
            try SocketIO.wait(fd, events: Int16(POLLOUT), deadline: deadline)
            var error: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else { throw LocalIOError.unavailable }
        }
        _ = try SocketIO.peer(fd)
        let data = try LeaseFrames.frame(LeaseJSON.encode(request), maximum: LeaseFrames.maximumRequest)
        try SocketIO.write(fd, data: data, deadline: deadline)
        let reply = try LeaseJSON.decode(LeaseReply.self, from: SocketIO.readFrame(fd, maximum: LeaseFrames.maximumReply, deadline: deadline))
        guard reply.version == 1, reply.requestID == request.requestID else { throw LocalIOError.frame }
        return reply
    }
}

public final class LeaseSocketServer: @unchecked Sendable {
    private struct State {
        var source: DispatchSourceRead?
        var lockFD: Int32 = -1
        var storage: SecureDirectory?
        var socketInode: ino_t = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let queue = DispatchQueue(label: "org.wakelease.socket")
    private let clients = DispatchSemaphore(value: 32)
    private let directory: URL
    private let handler: @Sendable (LeaseRequest, LocalPeer) async -> LeaseReply

    public init(directory: URL = WakeLeasePaths.directory, handler: @escaping @Sendable (LeaseRequest, LocalPeer) async -> LeaseReply) {
        self.directory = directory
        self.handler = handler
    }

    deinit { stop() }

    public func start() throws {
        let storage = try SecureDirectory(url: directory, create: true)
        let lockFD = openat(storage.descriptor, "daemon.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw LocalIOError.unsafePath }
        var info = stat()
        guard fstat(lockFD, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1 else {
            Darwin.close(lockFD)
            throw LocalIOError.unsafePath
        }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(lockFD)
            throw LocalIOError.alreadyRunning
        }
        var keepLock = false
        defer { if !keepLock { SecureDirectory.closeLock(lockFD) } }
        if fstatat(storage.descriptor, "cli.sock", &info, AT_SYMLINK_NOFOLLOW) == 0 {
            guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() else { throw LocalIOError.unsafePath }
            guard unlinkat(storage.descriptor, "cli.sock", 0) == 0 else { throw LocalIOError.system(errno) }
        } else if errno != ENOENT { throw LocalIOError.system(errno) }
        let fd = try SocketIO.makeSocket()
        var keepSocket = false
        defer { if !keepSocket { Darwin.close(fd) } }
        let path = directory.appendingPathComponent("cli.sock").path
        guard try SocketIO.address(path, body: { Darwin.bind(fd, $0, $1) }) == 0 else { throw LocalIOError.system(errno) }
        guard fchmodat(storage.descriptor, "cli.sock", 0o600, 0) == 0, Darwin.listen(fd, 32) == 0 else { throw LocalIOError.system(errno) }
        guard fstatat(storage.descriptor, "cli.sock", &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw LocalIOError.system(errno) }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.accept(fd) }
        source.setCancelHandler { Darwin.close(fd) }
        let inode = info.st_ino
        state.withLock { $0 = State(source: source, lockFD: lockFD, storage: storage, socketInode: inode) }
        keepSocket = true
        keepLock = true
        source.resume()
    }

    public func stop() {
        let previous = state.withLock { state in let previous = state; state = State(); return previous }
        previous.source?.cancel()
        if let storage = previous.storage {
            var info = stat()
            if fstatat(storage.descriptor, "cli.sock", &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_ino == previous.socketInode, info.st_mode & S_IFMT == S_IFSOCK {
                unlinkat(storage.descriptor, "cli.sock", 0)
            }
        }
        if previous.lockFD >= 0 { SecureDirectory.closeLock(previous.lockFD) }
    }

    private func accept(_ listening: Int32) {
        while true {
            let fd = Darwin.accept(listening, nil, nil)
            guard fd >= 0 else { return }
            guard clients.wait(timeout: .now()) == .success else { Darwin.close(fd); continue }
            SocketIO.configure(fd)
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                defer { Darwin.close(fd); clients.signal() }
                do {
                    let peer = try SocketIO.peer(fd)
                    let body = try SocketIO.readFrame(fd, maximum: LeaseFrames.maximumRequest, deadline: SocketIO.now + 2)
                    let request: LeaseRequest
                    do { request = try LeaseJSON.decode(LeaseRequest.self, from: body) }
                    catch {
                        let error = LeaseReply(ok: false, error: LeaseProtocolError(code: "invalid_request", message: "Expected a versioned JSON lease request."))
                        try SocketIO.write(fd, data: LeaseFrames.frame(LeaseJSON.encode(error), maximum: LeaseFrames.maximumReply), deadline: SocketIO.now + 1)
                        return
                    }
                    let box = OSAllocatedUnfairLock<LeaseReply?>(initialState: nil)
                    let finished = DispatchSemaphore(value: 0)
                    let task = Task {
                        let reply = await handler(request, peer)
                        box.withLock { $0 = reply }
                        finished.signal()
                    }
                    guard finished.wait(timeout: .now() + 20) == .success else { task.cancel(); return }
                    guard let reply = box.withLock({ $0 }) else { return }
                    try SocketIO.write(fd, data: LeaseFrames.frame(LeaseJSON.encode(reply), maximum: LeaseFrames.maximumReply), deadline: SocketIO.now + 2)
                } catch {}
            }
        }
    }
}

enum SocketIO {
    static var now: TimeInterval {
        SystemLeaseClock().now().continuous
    }

    static func makeSocket() throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LocalIOError.system(errno) }
        configure(fd)
        return fd
    }

    static func configure(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        var enabled: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    }

    static func address(_ path: String, body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) throws -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path), !path.utf8.contains(0) else { throw LocalIOError.unsafePath }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            bytes.withUnsafeBytes { source in destination.copyBytes(from: source) }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    }

    static func peer(_ fd: Int32) throws -> LocalPeer {
        var uid: uid_t = 0
        var gid: gid_t = 0
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid(),
              getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else { throw LocalIOError.peer }
        return LocalPeer(uid: uid, pid: pid)
    }

    static func wait(_ fd: Int32, events: Int16, deadline: TimeInterval) throws {
        while true {
            let remaining = deadline - now
            guard remaining > 0 else { throw LocalIOError.timeout }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = Darwin.poll(&descriptor, 1, Int32(min(remaining * 1_000 + 1, 20_000)))
            if result < 0, errno == EINTR { continue }
            guard result >= 0 else { throw LocalIOError.system(errno) }
            if result == 0 { throw LocalIOError.timeout }
            if descriptor.revents & Int16(POLLNVAL) != 0 { throw LocalIOError.closed }
            return
        }
    }

    static func read(_ fd: Int32, count: Int, deadline: TimeInterval) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            try wait(fd, events: Int16(POLLIN), deadline: deadline)
            let read = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: offset), count - offset) }
            if read < 0, errno == EAGAIN || errno == EINTR { continue }
            guard read > 0 else { throw LocalIOError.closed }
            offset += read
        }
        return Data(bytes)
    }

    static func readFrame(_ fd: Int32, maximum: Int, deadline: TimeInterval) throws -> Data {
        let count = try LeaseFrames.decodeLength(read(fd, count: 4, deadline: deadline), maximum: maximum)
        return try read(fd, count: count, deadline: deadline)
    }

    static func write(_ fd: Int32, data: Data, deadline: TimeInterval) throws {
        var offset = 0
        while offset < data.count {
            try wait(fd, events: Int16(POLLOUT), deadline: deadline)
            let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), data.count - offset) }
            if count < 0, errno == EAGAIN || errno == EINTR { continue }
            guard count > 0 else { throw LocalIOError.closed }
            offset += count
        }
    }
}
