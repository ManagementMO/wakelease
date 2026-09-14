import Darwin
import Foundation
import Security
import Testing
@testable import AdrafinilShared

@Suite("Administrator-installed component pins")
struct InstalledComponentTrustTests {
    private let fixture = Data("""
    {"version":1,"build":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","hashes":{
      "org.wakelease":["1111111111111111111111111111111111111111"],
      "org.wakelease.cli":["2222222222222222222222222222222222222222"],
      "org.wakelease.daemon":["3333333333333333333333333333333333333333"],
      "org.wakelease.helper":["4444444444444444444444444444444444444444"]}}
    """.utf8)

    private func withStore(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wakelease-trust-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        try fixture.write(to: directory.appendingPathComponent("components.json"))
        try body(directory)
    }

    @Test
    func `installed pins build an exact role and code hash requirement`() throws {
        try withStore { directory in
            let loaded = try InstalledComponentTrust.load(directory: directory, ownerUID: getuid())
            let record = try #require(loaded)
            let text = try #require(record.requirement(identifier: "org.wakelease.helper"))
            var requirement: SecRequirement?
            #expect(SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess)
            #expect(text == "identifier \"org.wakelease.helper\" and (cdhash H\"4444444444444444444444444444444444444444\")")
            #expect(record.requirement(identifier: "org.wakelease.evil") == nil)
        }
    }

    @Test
    func `native validation rejects a different binary claiming the approved role`() throws {
        try withStore { directory in
            var codes: [SecStaticCode] = []
            for name in ["true", "false"] {
                let destination = directory.appendingPathComponent(name)
                try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/" + name), to: destination)
                let result = try BoundedProcess.run(arguments: ["/usr/bin/codesign", "--force", "--sign", "-", "--identifier", "org.wakelease.helper", destination.path], timeout: 5)
                #expect(result.status == 0)
                var code: SecStaticCode?
                #expect(SecStaticCodeCreateWithPath(destination as CFURL, [], &code) == errSecSuccess)
                try codes.append(#require(code))
            }
            var information: CFDictionary?
            #expect(SecCodeCopySigningInformation(codes[0], SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess)
            let digest = try #require((information as? [String: Any])?[kSecCodeInfoUnique as String] as? Data)
            let hash = digest.map { String(format: "%02x", $0) }.joined()
            let data = String(decoding: fixture, as: UTF8.self).replacingOccurrences(of: "4444444444444444444444444444444444444444", with: hash)
            try Data(data.utf8).write(to: directory.appendingPathComponent("components.json"))
            let loaded = try InstalledComponentTrust.load(directory: directory, ownerUID: getuid())
            let record = try #require(loaded)
            let text = try #require(record.requirement(identifier: "org.wakelease.helper"))
            var requirement: SecRequirement?
            #expect(SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess)
            let flags = SecCSFlags(rawValue: kSecCSStrictValidate)
            #expect(SecStaticCodeCheckValidity(codes[0], flags, requirement) == errSecSuccess)
            #expect(SecStaticCodeCheckValidity(codes[1], flags, requirement) != errSecSuccess)
        }
    }

    @Test
    func `a user owned trust record cannot stand in for administrator installation`() throws {
        try withStore { directory in
            #expect(throws: LocalIOError.self) { try InstalledComponentTrust.load(directory: directory) }
        }
    }

    @Test
    func `group or world writable records are rejected`() throws {
        try withStore { directory in
            let file = directory.appendingPathComponent("components.json")
            for permissions: mode_t in [0o664, 0o666] {
                #expect(chmod(file.path, permissions) == 0)
                #expect(throws: LocalIOError.self) { try InstalledComponentTrust.load(directory: directory, ownerUID: getuid()) }
            }
        }
    }

    @Test
    func `symlink and hard linked records are rejected`() throws {
        try withStore { directory in
            let file = directory.appendingPathComponent("components.json")
            let saved = directory.appendingPathComponent("saved.json")
            try FileManager.default.moveItem(at: file, to: saved)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: saved)
            #expect(throws: LocalIOError.self) { try InstalledComponentTrust.load(directory: directory, ownerUID: getuid()) }
            try FileManager.default.removeItem(at: file)
            #expect(link(saved.path, file.path) == 0)
            #expect(throws: LocalIOError.self) { try InstalledComponentTrust.load(directory: directory, ownerUID: getuid()) }
        }
    }

    @Test
    func `incomplete or injected pin records fail closed`() throws {
        try withStore { directory in
            for invalid in [
                String(decoding: fixture, as: UTF8.self).replacingOccurrences(of: "\"version\":1", with: "\"version\":2"),
                String(decoding: fixture, as: UTF8.self).replacingOccurrences(of: "org.wakelease.helper", with: "org.wakelease.evil"),
                String(decoding: fixture, as: UTF8.self).replacingOccurrences(of: "4444444444444444444444444444444444444444", with: "bad or true"),
            ] {
                try Data(invalid.utf8).write(to: directory.appendingPathComponent("components.json"))
                #expect(throws: LocalIOError.self) { try InstalledComponentTrust.load(directory: directory, ownerUID: getuid()) }
            }
        }
    }

    @Test
    func `write ACLs cannot bypass protected file modes`() throws {
        try withStore { directory in
            let file = directory.appendingPathComponent("components.json")
            let result = try BoundedProcess.run(arguments: ["/bin/chmod", "+a", "everyone allow write", file.path], timeout: 2)
            #expect(result.status == 0)
            #expect(throws: LocalIOError.self) { try InstalledComponentTrust.load(directory: directory, ownerUID: getuid()) }
        }
    }

    @Test
    func `write ACLs on the containing directory are rejected`() throws {
        try withStore { directory in
            let result = try BoundedProcess.run(arguments: ["/bin/chmod", "+a", "everyone allow add_file", directory.path], timeout: 2)
            #expect(result.status == 0)
            #expect(throws: LocalIOError.self) { try InstalledComponentTrust.load(directory: directory, ownerUID: getuid()) }
        }
    }

    @Test
    func `reserved removal can revoke and restore the same approved record`() throws {
        try withStore { directory in
            let loaded = try InstalledComponentTrust.load(directory: directory, ownerUID: getuid())
            let record = try #require(loaded)
            try record.grantRemoval(to: getuid(), directory: directory, ownerUID: getuid())
            #expect(try InstalledComponentTrust.load(directory: directory, ownerUID: getuid()) == record)
            try record.remove(directory: directory, ownerUID: getuid())
            #expect(try InstalledComponentTrust.load(directory: directory, ownerUID: getuid()) == nil)
            try record.restore(directory: directory, ownerUID: getuid())
            #expect(try InstalledComponentTrust.load(directory: directory, ownerUID: getuid()) == record)
        }
    }

    @Test
    func `stale cleanup cannot replace or delete a newer installation`() throws {
        try withStore { directory in
            let loaded = try InstalledComponentTrust.load(directory: directory, ownerUID: getuid())
            let record = try #require(loaded)
            let newer = String(decoding: fixture, as: UTF8.self).replacingOccurrences(of: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", with: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
            try Data(newer.utf8).write(to: directory.appendingPathComponent("components.json"))
            #expect(throws: LocalIOError.self) { try record.grantRemoval(to: getuid(), directory: directory, ownerUID: getuid()) }
            #expect(throws: LocalIOError.self) { try record.remove(directory: directory, ownerUID: getuid()) }
            #expect(throws: LocalIOError.self) { try record.restore(directory: directory, ownerUID: getuid()) }
            #expect(try InstalledComponentTrust.load(directory: directory, ownerUID: getuid())?.build == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
        }
    }

    @Test
    func `package approval is published only after payload validation`() throws {
        try withStore { directory in
            let loaded = try InstalledComponentTrust.load(directory: directory, ownerUID: getuid())
            let previous = try #require(loaded)
            let next = InstalledComponentTrust(version: 1, build: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", hashes: previous.hashes)
            let transaction = InstalledPackageTransaction(directory: directory, ownerUID: getuid())
            try transaction.begin(next, verifyIdle: {})
            #expect(try InstalledComponentTrust.load(directory: directory, ownerUID: getuid()) == nil)
            #expect(throws: LocalIOError.self) { try transaction.activate(next) { throw LocalIOError.unsafePath } }
            #expect(try InstalledComponentTrust.load(directory: directory, ownerUID: getuid()) == nil)
            try transaction.activate(next, verifyPayload: {})
            #expect(try InstalledComponentTrust.load(directory: directory, ownerUID: getuid()) == next)
        }
    }

    @Test
    func `work starting during installer preflight rolls back the admission fence`() throws {
        try withStore { directory in
            let loaded = try InstalledComponentTrust.load(directory: directory, ownerUID: getuid())
            let record = try #require(loaded)
            let transaction = InstalledPackageTransaction(directory: directory, ownerUID: getuid())
            var checks = 0
            #expect(throws: LocalIOError.self) {
                try transaction.begin(record) {
                    checks += 1
                    if checks == 2 { throw LocalIOError.alreadyRunning }
                }
            }
            #expect(try InstalledComponentTrust.load(directory: directory, ownerUID: getuid()) == record)
        }
    }

    @Test
    func `an older installer cannot finish or cancel a newer transaction`() throws {
        try withStore { directory in
            let loaded = try InstalledComponentTrust.load(directory: directory, ownerUID: getuid())
            let record = try #require(loaded)
            let other = InstalledComponentTrust(version: 1, build: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", hashes: record.hashes)
            let transaction = InstalledPackageTransaction(directory: directory, ownerUID: getuid())
            try transaction.begin(record, verifyIdle: {})
            #expect(throws: LocalIOError.self) { try transaction.begin(other, verifyIdle: {}) }
            #expect(throws: LocalIOError.self) { try transaction.activate(other, verifyPayload: {}) }
            #expect(throws: LocalIOError.self) { try transaction.revoke(other) }
            #expect(throws: LocalIOError.self) { try transaction.cancel(other, verifyIdle: {}) }
            #expect(try InstalledComponentTrust.load(directory: directory, ownerUID: getuid()) == nil)
            try transaction.cancel(record, verifyIdle: {})
            #expect(try InstalledComponentTrust.load(directory: directory, ownerUID: getuid()) == record)
        }
    }

    @Test
    func `a shared source revision does not make different component builds interchangeable`() throws {
        try withStore { directory in
            let loaded = try InstalledComponentTrust.load(directory: directory, ownerUID: getuid())
            let record = try #require(loaded)
            var hashes = record.hashes
            hashes[WakeLeaseIdentity.helperBundleID] = ["ffffffffffffffffffffffffffffffffffffffff"]
            let other = InstalledComponentTrust(version: 1, build: record.build, hashes: hashes)
            let transaction = InstalledPackageTransaction(directory: directory, ownerUID: getuid())
            try transaction.begin(record, verifyIdle: {})
            #expect(throws: LocalIOError.self) { try transaction.activate(other, verifyPayload: {}) }
            #expect(throws: LocalIOError.self) { try transaction.revoke(other) }
            #expect(throws: LocalIOError.self) { try transaction.cancel(other, verifyIdle: {}) }
            try transaction.cancel(record, verifyIdle: {})
            #expect(try InstalledComponentTrust.load(directory: directory, ownerUID: getuid()) == record)
        }
    }

    @Test
    func `an administrator can revoke unused installation approval through its own transaction`() throws {
        try withStore { directory in
            let loaded = try InstalledComponentTrust.load(directory: directory, ownerUID: getuid())
            let record = try #require(loaded)
            let transaction = InstalledPackageTransaction(directory: directory, ownerUID: getuid())
            try transaction.begin(record, verifyIdle: {})
            try transaction.revoke(record)
            #expect(try InstalledComponentTrust.load(directory: directory, ownerUID: getuid()) == nil)
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("installation.pending").path))
            #expect(throws: LocalIOError.self) { try transaction.activate(record, verifyPayload: {}) }
        }
    }

    @Test
    func `removal and rollback cannot mutate pins during package installation`() throws {
        try withStore { directory in
            let loaded = try InstalledComponentTrust.load(directory: directory, ownerUID: getuid())
            let record = try #require(loaded)
            try InstalledPackageTransaction(directory: directory, ownerUID: getuid()).begin(record, verifyIdle: {})
            #expect(throws: LocalIOError.self) { try record.grantRemoval(to: getuid(), directory: directory, ownerUID: getuid()) }
            #expect(throws: LocalIOError.self) { try record.remove(directory: directory, ownerUID: getuid()) }
            #expect(throws: LocalIOError.self) { try record.restore(directory: directory, ownerUID: getuid()) }
        }
    }

    @Test
    func `an unfinished package transaction cannot authorize components`() throws {
        try withStore { directory in
            try Data("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa".utf8).write(to: directory.appendingPathComponent("installation.pending"))
            #expect(try InstalledComponentTrust.load(directory: directory, ownerUID: getuid()) == nil)
        }
    }

    @Test
    func `missing pins do not grant an identity`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wakelease-trust-missing-" + UUID().uuidString)
        #expect(try InstalledComponentTrust.load(directory: directory, ownerUID: getuid()) == nil)
    }
}
