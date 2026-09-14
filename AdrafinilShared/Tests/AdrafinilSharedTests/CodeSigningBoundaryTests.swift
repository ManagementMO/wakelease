import Foundation
import Security
import Testing
@testable import AdrafinilShared

@Suite("OS-enforced signing requirements")
struct CodeSigningBoundaryTests {
    private let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)

    private func staticCode(_ url: URL) throws -> SecStaticCode {
        var code: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
        #expect(status == errSecSuccess)
        return try #require(code)
    }

    private func requirement(_ role: ComponentTrust.Role) throws -> SecRequirement {
        let text = try #require(ComponentTrust.requirement(team: "TESTTEAM01", role: role))
        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString(text as CFString, [], &requirement)
        #expect(status == errSecSuccess)
        return try #require(requirement)
    }

    @Test
    func `an OS signed unrelated binary is not a WakeLease component`() throws {
        let code = try staticCode(URL(fileURLWithPath: "/usr/bin/true"))
        #expect(SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess)
        for role in [ComponentTrust.Role.app, .daemon, .helper] {
            #expect(try SecStaticCodeCheckValidity(code, flags, requirement(role)) != errSecSuccess)
        }
    }

    @Test
    func `ad hoc signatures cannot spoof exact production role identifiers`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wl-signature-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        for role in [ComponentTrust.Role.app, .daemon, .helper] {
            let path = directory.appendingPathComponent(role.identifier)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
            let signed = try BoundedProcess.run(arguments: ["/usr/bin/codesign", "--force", "--sign", "-", "--identifier", role.identifier, path.path], timeout: 5)
            #expect(signed.status == 0)
            let code = try staticCode(path)
            #expect(SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess)
            var information: CFDictionary?
            let infoStatus = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
            #expect(infoStatus == errSecSuccess)
            #expect((information as? [String: Any])?[kSecCodeInfoIdentifier as String] as? String == role.identifier)
            #expect(try SecStaticCodeCheckValidity(code, flags, requirement(role)) != errSecSuccess)
            let unsigned = try BoundedProcess.run(arguments: ["/usr/bin/codesign", "--remove-signature", path.path], timeout: 5)
            #expect(unsigned.status == 0)
            #expect(try SecStaticCodeCheckValidity(staticCode(path), flags, requirement(role)) != errSecSuccess)
        }
    }
}
