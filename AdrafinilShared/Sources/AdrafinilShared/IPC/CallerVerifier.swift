import Foundation
import Security

/// Code-signing requirement check on incoming XPC clients.
///
/// Compatibility gate for retained app-facing listeners; the production helper uses
/// its narrower daemon-only listener requirement from `ComponentTrust`.
/// New calls use Foundation's public per-message requirement enforcement. Historical
/// audit-token helpers below are not used by the production authorization path.
public enum CallerVerifier {
    /// The derivative's namespace. Exact role identifiers, not arbitrary children of this prefix,
    /// are accepted. Non-bundle targets must be signed with their explicit reverse-DNS identifier;
    /// a product-name or linker ad-hoc identifier is not a production authorization credential.
    /// Unsigned development uses the simulated transport rather than weakening this requirement.
    public static let allowedPrefix = WakeLeaseIdentity.appBundleID

    /// Authorize an incoming XPC peer.
    ///
    /// Two conditions, both required (when this process is itself signed with a team):
    /// 1. The caller shares **our own Team Identifier** — read from `self` at runtime, so an
    ///    open-source rebuild under a different Developer ID still authorizes its own components
    ///    without code changes.
    /// 2. The caller is a **WakeLease component**, not just any app from the same team
    ///    (the developer may ship others — e.g. sibling menu-bar apps — under the same team).
    ///
    /// A process without a verified Apple-issued team cannot authorize production peers.
    /// The public NSXPC requirement is installed before the connection resumes.
    public static func isAuthorized(_ connection: NSXPCConnection) -> Bool {
        let requirements = [ComponentTrust.Role.app, .daemon, .helper].compactMap { ComponentTrust.requirement(role: $0) }
        guard requirements.count == 3 else { return false }
        connection.setCodeSigningRequirement(requirements.map { "(" + $0 + ")" }.joined(separator: " or "))
        return true
    }

    /// The pure authorization decision, separated from the Security-framework plumbing so it is
    /// unit-testable. When this process is team-signed, a caller without that exact team is
    /// rejected — including a caller with **no** team at all: an ad-hoc binary can claim any code
    /// identifier it likes (`codesign -s - --identifier …`), so the identifier is only
    /// trustworthy once the team check has anchored the caller to a certificate we control.
    static func isAuthorizedDecision(ownTeam: String?, callerTeam: String?, identifier: String) -> Bool {
        guard let ownTeam, !ownTeam.isEmpty, callerTeam == ownTeam else { return false }
        return isAdrafinilComponent(identifier)
    }

    /// Exact identifiers accepted by the compatibility wrapper. Production signing assigns these
    /// explicitly, including to the non-bundle daemon and helper. Neither a product-name match
    /// nor a namespace prefix substitutes for the Apple anchor and team requirement enforced by
    /// Foundation. The helper itself narrows this set further to the daemon role.
    static let componentIdentifiers: Set<String> = [WakeLeaseIdentity.appBundleID, WakeLeaseIdentity.daemonBundleID, WakeLeaseIdentity.helperBundleID]

    static func isAdrafinilComponent(_ identifier: String) -> Bool {
        componentIdentifiers.contains(identifier)
    }

    private struct SigningInfo {
        let identifier: String
        let team: String?
    }

    private static func signingInfo(for connection: NSXPCConnection) -> SigningInfo? {
        // Fail closed: if the peer's audit token can't be read, we can't identify the caller, so
        // there is no safe way to authorize it. A zeroed token would resolve via
        // `SecCodeCopyGuestWithAttributes` to an unintended guest (pid 0 / self), so it must never
        // be substituted for a missing one.
        guard var token = connection.adrafinil_auditToken else { return nil }
        let tokenData = Data(bytes: &token, count: MemoryLayout.size(ofValue: token))
        let attrs = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        var codeRef: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &codeRef) == errSecSuccess,
              let code = codeRef,
              let stat = staticCode(for: code) else { return nil }
        return signingInfo(of: stat)
    }

    /// Team Identifier of the *current* process, used as the reference for the caller's team.
    private static func ownTeamIdentifier() -> String? {
        var selfCode: SecCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess,
              let code = selfCode,
              let stat = staticCode(for: code) else { return nil }
        return signingInfo(of: stat)?.team
    }

    private static func staticCode(for code: SecCode) -> SecStaticCode? {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess else { return nil }
        return staticCode
    }

    private static func signingInfo(of staticCode: SecStaticCode) -> SigningInfo? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let identifier = dict[kSecCodeInfoIdentifier as String] as? String else { return nil }
        return SigningInfo(identifier: identifier, team: dict[kSecCodeInfoTeamIdentifier as String] as? String)
    }
}

private extension NSXPCConnection {
    /// `auditToken` is private on NSXPCConnection; KVC reach is the standard workaround. Returns nil
    /// when the value can't be read so the caller can fail closed rather than trust a zeroed token.
    var adrafinil_auditToken: audit_token_t? {
        (value(forKey: "auditToken") as? NSValue)?.adrafinil_audit_token_t_value
    }
}

private extension NSValue {
    /// NSValue wraps `audit_token_t` in some macOS releases; if not, return nil and the caller falls back.
    var adrafinil_audit_token_t_value: audit_token_t? {
        var token = audit_token_t()
        let size = MemoryLayout<audit_token_t>.size
        let ok = withUnsafeMutableBytes(of: &token) { ptr -> Bool in
            (self as NSValue).getValue(ptr.baseAddress!, size: size)
            return true
        }
        return ok ? token : nil
    }
}
