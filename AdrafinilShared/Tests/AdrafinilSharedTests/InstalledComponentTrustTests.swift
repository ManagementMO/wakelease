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
    func `missing pins do not grant an identity`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wakelease-trust-missing-" + UUID().uuidString)
        #expect(try InstalledComponentTrust.load(directory: directory, ownerUID: getuid()) == nil)
    }
}
