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

### Fixed

- Failed persistent sleep cleanup is observable and retryable instead of being reported as a successful unblock.
- Acquisition during a pre-sleep cue or in-flight unblock cannot commit an obsolete final power state.
- Display release includes the auxiliary user-activity assertion.
- Dead owners, PID reuse and corrupt persisted lifetimes cannot silently renew unbounded protection.
- Replayed global controls cannot release newer work or undo a newer pause.
- Native menu insertion ignores unchanged preference writes, preventing a SwiftUI update loop.
- Status distinguishes zero local demand from another user's helper claim.
- Removal prevents new wake claims during teardown and across helper restart; same-user maintenance cannot cancel an overlapping transaction.
- The CI permission fixture validates its temporary path lexically so Foundation's existing-path `/private` alias rewriting cannot reject its own cleanup.
- File locks are explicitly unlocked before close, preventing a duplicated or inherited descriptor from retaining a finished install/removal lock during parallel subprocess activity.

### Security and privacy

- Exact Apple-anchored signing roles, matching teams and strict unsigned-production refusal.
- Kernel peer credentials, restrictive local storage, bounded protocol frames and subprocess execution, helper heartbeat/disconnect recovery, and persisted safety latches.
- No normal-operation telemetry, cloud account, exposed network port or automatic update feed.

### Verification scope

- Automated tests and simulation exercise the lease, transport, installer, command and power-coordination boundaries without changing host sleep settings.
- CI verifies full unsigned Xcode builds and actual Swift/CLI/host-fixture execution on Apple Silicon/macOS 26 and Intel/macOS 15, including root-owned temporary ticket permissions and universal development packaging.
- Local debug and optimized release suites pass 550 Swift tests; 28 CLI cases and eight native preview cases also pass. Pi's real SDK is exercised with an offline mock model, and OS signing fixtures reject spoofed roles.
- The Xcode project retains compatible format 77 without relaxing deployment or signing settings. CI artifacts use a pinned Node 24 uploader and fail if expected outputs are absent.
- Live Apple-issued signing, ServiceManagement approval/removal and physical MacBook sleep behavior remain separate release gates.
- Integration support is scoped by the evidence in [Docs/INTEGRATIONS.md](Docs/INTEGRATIONS.md), not implied by a configured hook.

## Upstream foundation

WakeLease derives from Adrafinil v1.7.0 (`d21e8abd20bb777a3b8efff712a881e836a90598`, released August 24, 2026). The original MIT notice and Git history are retained. See [UPSTREAM.md](UPSTREAM.md) for preserved engineering, intentional divergence and attribution.
