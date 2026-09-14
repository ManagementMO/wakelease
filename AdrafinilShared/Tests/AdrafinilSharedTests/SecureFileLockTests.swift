import Darwin
import Foundation
import Testing
@testable import AdrafinilShared

@Suite("File lock descriptor lifetime")
struct SecureFileLockTests {
    @Test
    func `releasing a lock works while a descriptor alias remains`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wl-lock-" + UUID().uuidString)
        let directory = try SecureDirectory(url: root, create: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try directory.lock(name: "install.lock")
        let inherited = dup(original)
        guard inherited >= 0 else { Darwin.close(original); throw LocalIOError.system(errno) }
        defer { Darwin.close(inherited) }
        SecureDirectory.closeLock(original)
        let replacement = try directory.lock(name: "install.lock")
        defer { SecureDirectory.closeLock(replacement) }
        #expect(throws: (any Error).self) { try directory.lock(name: "install.lock") }
    }
}
