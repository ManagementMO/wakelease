import Foundation
import Security

public enum ComponentTrust {
    public enum Role: Sendable {
        case app
        case daemon
        case helper
        var identifier: String {
            switch self {
            case .app: WakeLeaseIdentity.appBundleID
            case .daemon: WakeLeaseIdentity.daemonBundleID
            case .helper: WakeLeaseIdentity.helperBundleID
            }
        }
    }

    public static let currentTeam: String? = {
        var code: SecCode?
        var anchor: SecRequirement?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString("anchor apple generic" as CFString, [], &anchor) == errSecSuccess,
              let anchor, SecCodeCheckValidity(code, [], anchor) == errSecSuccess else { return nil }
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any] else { return nil }
        return values[kSecCodeInfoTeamIdentifier as String] as? String
    }()

    public static func requirement(team: String?, role: Role) -> String? {
        guard let team, team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else { return nil }
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"\(role.identifier)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { return nil }
        return text
    }

    public static var installedRecord: InstalledComponentTrust? {
        guard let record = try? InstalledComponentTrust.load() else { return nil }
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any], let identifier = values[kSecCodeInfoIdentifier as String] as? String,
              let text = record.requirement(identifier: identifier) else { return nil }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement,
              SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else { return nil }
        return record
    }

    public static var hasRuntimeIdentity: Bool {
        currentTeam != nil || installedRecord != nil
    }

    public static func requirement(role: Role) -> String? {
        if let currentTeam { return requirement(team: currentTeam, role: role) }
        return installedRecord?.requirement(identifier: role.identifier)
    }
}
