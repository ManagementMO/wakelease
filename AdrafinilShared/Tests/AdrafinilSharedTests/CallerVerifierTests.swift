import Testing
@testable import AdrafinilShared

/// The full XPC authorization path needs a live signed peer, so it can't be unit-tested here. This
/// covers the exact identifier allow-list and rejection of unsigned production callers.
/// Prefix matches and developer product names must not substitute for authenticated roles.
@Suite("CallerVerifier identifier allow-list")
struct CallerVerifierTests {
    @Test
    func `the app bundle id and its sub-identifiers are accepted`() {
        #expect(CallerVerifier.isAdrafinilComponent("org.wakelease"))
        #expect(CallerVerifier.isAdrafinilComponent("org.wakelease.daemon"))
        #expect(CallerVerifier.isAdrafinilComponent("org.wakelease.helper"))
    }

    @Test
    func `unqualified product names and namespace lookalikes are rejected`() {
        #expect(!CallerVerifier.isAdrafinilComponent("AdrafinilDaemon"))
        #expect(!CallerVerifier.isAdrafinilComponent("AdrafinilHelper"))
        #expect(!CallerVerifier.isAdrafinilComponent("org.wakelease.evil"))
        #expect(!CallerVerifier.isAdrafinilComponent("org.wakeleaseevil"))
    }

    @Test
    func `a look-alike that merely starts with Adrafinil is rejected`() {
        #expect(!CallerVerifier.isAdrafinilComponent("AdrafinilEvil"))
        #expect(!CallerVerifier.isAdrafinilComponent("Adrafinil"))
        #expect(!CallerVerifier.isAdrafinilComponent("com.evil.adrafinil"))
        #expect(!CallerVerifier.isAdrafinilComponent(""))
    }

    @Test
    func `a linker ad-hoc identifier (build that skipped codesign) is rejected`() {
        // `xcodebuild … CODE_SIGNING_ALLOWED=NO` skips the codesign step entirely, so the linker's
        // fallback ad-hoc signature stamps tools as `<name>-<hex>` instead of the product name.
        // Such a build must not authorize — and won't function: install a build that went through
        // codesign (identifier = product name), e.g. `CODE_SIGN_IDENTITY=-` for local dev.
        #expect(!CallerVerifier.isAdrafinilComponent("AdrafinilDaemon-55554944572a111aa4e631978f328488fa7c4992"))
    }
}

/// The team check must fail closed: an ad-hoc binary can claim ANY code identifier
/// (`codesign -s - --identifier org.wakelease.helper`), so when we are team-signed,
/// a caller that presents no team — or the wrong one — must be rejected no matter what
/// identifier it claims.
@Suite("CallerVerifier authorization decision")
struct CallerVerifierDecisionTests {
    private let team = "TESTTEAM01"

    @Test
    func `team-signed self rejects a caller with no team even with a valid identifier`() {
        #expect(!CallerVerifier.isAuthorizedDecision(
            ownTeam: team, callerTeam: nil, identifier: "org.wakelease.helper",
        ))
        #expect(!CallerVerifier.isAuthorizedDecision(
            ownTeam: team, callerTeam: nil, identifier: "AdrafinilDaemon",
        ))
    }

    @Test
    func `team-signed self rejects a caller from a different team`() {
        #expect(!CallerVerifier.isAuthorizedDecision(
            ownTeam: team, callerTeam: "EVILTEAM00", identifier: "org.wakelease",
        ))
    }

    @Test
    func `matching team plus component identifier is accepted`() {
        #expect(CallerVerifier.isAuthorizedDecision(
            ownTeam: team, callerTeam: team, identifier: "org.wakelease",
        ))
        #expect(CallerVerifier.isAuthorizedDecision(
            ownTeam: team, callerTeam: team, identifier: "org.wakelease.daemon",
        ))
    }

    @Test
    func `matching team with a foreign identifier is rejected`() {
        #expect(!CallerVerifier.isAuthorizedDecision(
            ownTeam: team, callerTeam: team, identifier: "com.example.other",
        ))
    }

    @Test
    func `ad-hoc self never authorizes production peers`() {
        #expect(!CallerVerifier.isAuthorizedDecision(
            ownTeam: nil, callerTeam: nil, identifier: "org.wakelease.helper",
        ))
        #expect(!CallerVerifier.isAuthorizedDecision(
            ownTeam: nil, callerTeam: nil, identifier: "AdrafinilEvil",
        ))
        // A team-signed caller cannot turn an unsigned host into a production trust anchor.
        #expect(!CallerVerifier.isAuthorizedDecision(
            ownTeam: nil, callerTeam: team, identifier: "org.wakelease.daemon",
        ))
    }
}
