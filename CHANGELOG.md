# Changelog

All changes below are unreleased engineering work. Product version `0.1.0` is not a claim of a notarized or hardware-certified public release.

## Unreleased — 0.1.0 development

### Added

- Generic finite wake leases with independent system/display demand, process birth identities, waiting grace, heartbeats, child relationships and stale-event barriers.
- Versioned, user-scoped local IPC and command-safe `acquire`, `renew`, `wait`, `release`, `hold`, `run`, `watch`, `status` and `doctor` workflows.
- Native menu-bar UI, bounded preferences, timed manual holds, integration health and change previews, with an original lease-token icon.
- Receipt-backed integration and CLI installation/removal, optional local stdio MCP, reproducible universal app packaging, checksum verification and CI.
- Public source repository at ManagementMO/wakelease, preserving upstream history, and GitHub private vulnerability reporting.
- Native custom-integration setup and matching interactive/noninteractive CLI generation, with source-separated work IDs, bounded lifetimes, optional display demand, JSON recipe export and literal wrapper commands.
- Helper-owned durable removal reservations, a separately authenticated app maintenance endpoint, exact-owner cancellation, rollback diagnostics and a cross-UID filesystem fixture in CI.
- No-membership community DMG packaging with administrator-approved exact component hashes, native payload verification, interrupted-install repair and approval-only removal packages. Installation itself does not activate wake protection.
- Root-owned trust-record validation, write-ACL rejection, incomplete-package admission fencing and whole-record recovery matching; source revision equality alone cannot substitute for identical component hashes.

### Fixed

- Failed persistent sleep cleanup is observable and retryable instead of being reported as a successful unblock.
- Acquisition during a pre-sleep cue or in-flight unblock cannot commit an obsolete final power state.
- Display release includes the auxiliary user-activity assertion.
- Dead owners, PID reuse and corrupt persisted lifetimes cannot silently renew unbounded protection.
- Replayed global controls cannot release newer work or undo a newer pause.
- Native menu insertion ignores unchanged preference writes, preventing a SwiftUI update loop.
- Custom-integration copy feedback resets when any recipe option changes, preventing an edited command from retaining a stale “Copied” indication.
- An invalid custom executable no longer removes its own editor. Users can correct it in place without losing focus or other fields; invalid commands remain unavailable for copying.
- Status distinguishes zero local demand from another user's helper claim.
- Removal prevents new wake claims during teardown and across helper restart; same-user maintenance cannot cancel an overlapping transaction.
- The CI permission fixture validates its temporary path lexically so Foundation's existing-path `/private` alias rewriting cannot reject its own cleanup.
- File locks are explicitly unlocked before close, preventing a duplicated or inherited descriptor from retaining a finished install/removal lock during parallel subprocess activity.
- Service registration presents the observed permission error as pending only when macOS actually reports `requiresApproval`; unrelated failures stay visible.
- Architecture-specific packaging caches prevent a native-to-universal SwiftPM build-manifest collision without changing signing or deployment settings.
- Read-only power inspection handles an omitted, unset `SleepDisabled` preference only when an explicit kernel boolean is available; unknown/malformed state and conflicting blocking values still fail closed.

### Security and privacy

- Exact role/code-hash authorization from protected administrator-installed pins, with the optional Apple-anchored matching-team path retained. Unapproved development cannot authorize privileged peers.
- Kernel peer credentials, restrictive local storage, bounded protocol frames and subprocess execution, helper heartbeat/disconnect recovery, and persisted safety latches.
- No normal-operation telemetry, cloud account, exposed network port or automatic update feed.

### Verification scope

- Automated tests and simulation exercise the lease, transport, installer, command and power-coordination boundaries without changing host sleep settings.
- CI verifies full unsigned Xcode builds and actual Swift/CLI/host-fixture execution on Apple Silicon/macOS 26 and Intel/macOS 15, including root-owned temporary ticket permissions and universal development packaging.
- Local debug and optimized release suites pass 576 Swift tests plus five standalone XPC scenarios across three fresh explicitly ad-hoc-signed probe processes and 28 CLI cases. Pi's real SDK covers eight offline success/failure/cancellation/retry/queue scenarios. Community bundles and all three package payloads receive read-only signature/hash/architecture/checksum verification.
- Native accessibility, keyboard and layout checks cover 26 preview interactions using a separate clipboard and existing permission only, including hidden-icon close/reopen through macOS, maximum recipe content and invalid-input recovery. Live anonymous NSXPC fixtures verify listener rejection before the delegate and client reply rejection without registering services.
- Disposable macOS CI executes the real installer, repair and approval-removal scripts against harmless stand-in binaries, including running-app refusal, exact identity rejection and delegated read/delete-only cleanup. It never runs the product power controller.
- The Xcode project retains compatible format 77 without relaxing deployment or signing settings. CI artifacts use a pinned Node 24 uploader and fail if expected outputs are absent.
- Full installed-product XPC, ServiceManagement approval/removal and physical MacBook sleep behavior remain separate release gates. Apple signing/notarization is optional for the distinct Developer ID route, not required for community distribution.
- Integration support is scoped by the evidence in [Docs/INTEGRATIONS.md](Docs/INTEGRATIONS.md), not implied by a configured hook.

## Upstream foundation

WakeLease derives from Adrafinil v1.7.0 (`d21e8abd20bb777a3b8efff712a881e836a90598`, released August 24, 2026). The original MIT notice and Git history are retained. See [UPSTREAM.md](UPSTREAM.md) for preserved engineering, intentional divergence and attribution.
