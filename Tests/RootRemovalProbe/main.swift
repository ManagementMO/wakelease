import AdrafinilShared
import Darwin
import Foundation

struct ProbeFailure: Error, CustomStringConvertible {
    let description: String
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 4, let uid = UInt32(arguments[2]), uid > 0, let id = UUID(uuidString: arguments[3]) else { exit(64) }
let directory = URL(fileURLWithPath: arguments[1], isDirectory: true).standardizedFileURL
let prefix = "wakelease-removal-test-"
guard directory.deletingLastPathComponent().path == "/private/tmp",
      directory.lastPathComponent.hasPrefix(prefix),
      UUID(uuidString: String(directory.lastPathComponent.dropFirst(prefix.count))) != nil else { exit(64) }
let store = HelperRemovalStore(directory: directory)
let reservation = HelperRemovalReservation(id: id, uid: uid)

do {
    switch arguments[0] {
    case "create":
        guard getuid() == 0, !FileManager.default.fileExists(atPath: directory.path) else { throw ProbeFailure(description: "Root fixture must start at a new temporary path") }
        try store.save(reservation)
        guard try store.load() == reservation else { throw ProbeFailure(description: "Root reservation was not durable") }
    case "verify-delete":
        guard getuid() == uid, try store.load() == reservation else { throw ProbeFailure(description: "Delegated reader could not verify the root-owned reservation") }
        let file = directory.appendingPathComponent("removal-" + id.uuidString.lowercased() + ".json")
        let writable = open(file.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
        if writable >= 0 { close(writable); throw ProbeFailure(description: "Delegated reader unexpectedly obtained write access") }
        guard errno == EACCES || errno == EPERM else { throw ProbeFailure(description: "Unexpected write-denial error") }
        let foreign = directory.appendingPathComponent("unowned")
        let created = open(foreign.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        if created >= 0 { close(created); unlink(foreign.path); throw ProbeFailure(description: "Delegated reader unexpectedly created a root-directory entry") }
        guard errno == EACCES || errno == EPERM else { throw ProbeFailure(description: "Unexpected create-denial error") }
        try store.remove(reservation)
        guard try store.load() == nil else { throw ProbeFailure(description: "Delegated removal did not remove its ticket") }
        print("Root fixture verified: read allowed, write/create denied, exact ticket deletion allowed.")
    case "cleanup":
        guard getuid() == 0 else { throw ProbeFailure(description: "Root fixture cleanup requires its creator") }
        if FileManager.default.fileExists(atPath: directory.path) {
            try store.remove(reservation)
            guard try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty else { throw ProbeFailure(description: "Foreign content prevents fixture cleanup") }
            try FileManager.default.removeItem(at: directory)
        }
    default: exit(64)
    }
} catch {
    FileHandle.standardError.write(Data((String(describing: error) + "\n").utf8))
    exit(1)
}
