# Verification and release gates

## Safe automated suite

```sh
WAKELEASE_SOURCE_TESTING=1 swift test --scratch-path .build/source-testing \
  --disable-xctest --disable-experimental-prebuilts
python3 Tests/cli_integration.py
python3 Tests/xpc_smoke.py
python3 Tests/ui_smoke.py
python3 Tests/package_smoke.py
python3 Scripts/lint.py
```

All power controllers used by unit/integration tests are fake or explicitly simulated. Integration configuration lives in temporary homes. The unsigned-execution tests verify rejection before any power mutation. Package smoke tests assemble a disposable ad-hoc bundle, verify integrity, exercise version/preview paths, and confirm privileged-mode refusal. They do not install the bundle or register services.

The SwiftPM root builds the app, CLI, daemon, helper and native installer worker. The source-testing opt-in uses pinned Swift Testing 6.2.4 and SwiftSyntax 602.0.0 to support Command Line Tools installations missing the bundled Testing module. Keep its scratch directory separate from other toolchain/macro versions. Packaging also uses a separate scratch directory for each architecture; a native-to-universal build sequence exposed a SwiftPM target-manifest collision when architecture caches were shared.

UI smoke tests require a logged-in macOS desktop and exercise fixture windows, not real services. Their timeout detects the regression where writing unchanged observable preferences from `MenuBarExtra(isInserted:)` caused a main-menu graph loop. Eight PNG preview cases remain distinct from interaction testing.

The native accessibility client uses the existing macOS Accessibility permission; it never requests or changes permission. It verifies the exact child executable under this checkout's `.build`, targets only that PID, and uses a separate `wakelease-ui-test-*` clipboard. A tree check verifies custom-setup labels. **26 interaction checks** cover settings sections, menu-bar preferences, Tab/Shift-Tab, current command/JSON copying, invalid-input recovery and Escape/Return dismissal, plus:

- A disposable, uniquely identified preview app bundle hides its actual menu item, closes settings, remains running, and reopens through `NSWorkspace` in the same process. Reopening visible settings reuses the window and preserves the hidden preference. No real installation or application is targeted; launch prompting and recent-item additions are disabled.
- Maximum supported source/work IDs, spaced and unbroken 128-byte event labels, and a 4,096-byte executable round-trip through the generated recipe. Native element geometry checks wrapping, horizontal bounds and copy-button separation; scrolling exposes the final copy action.
- A 4,097-byte executable previously removed its own editor when validation failed. The editor now stays present and focused, invalid copy actions stay hidden, and correcting the value restores the recipe without discarding other fields. Empty source IDs and invalid work-variable edits also recover in place.

The suite also retains the stale “Copied” feedback regression: changing recipe options clears only the feedback, not the clipboard. All of these checks use preview data and do not certify real service approval or physical sleep.

Use `WAKELEASE_REQUIRE_UI_AUDIT=1 python3 Tests/ui_smoke.py` to require those native audits rather than skip when permission is unavailable. CI typechecks the audit client but does not claim headless interactive execution. This is not a manual VoiceOver, large-text or live service-approval certification.

The lint script uses fixed, checksum-verified SwiftFormat/SwiftLint releases. SourceKitten otherwise skips the Command Line Tools framework location; the runner supplies its supported toolchain override for that process. No lint rule is disabled for this. Existing size/complexity/style warnings remain distinguishable from errors.

Additional fixed-program C check:

```sh
clang -fsyntax-only -Wall -Wextra -Werror \
  -I AdrafinilShared/Sources/WakeLeaseProcess/include \
  AdrafinilShared/Sources/WakeLeaseProcess/WakeLeaseProcess.c \
  AdrafinilShared/Sources/WakeLeaseProcess/BoundedProcess.c \
  AdrafinilShared/Sources/WakeLeaseProcess/RemovalPermissions.c
```

## Regression areas

- Zero-demand invariants, independent reference counts, duplicate release/acquire, child survival.
- Finite lifetime validation, expiry without new traffic, waiting grace, heartbeat semantics, live policy changes.
- PID death/reuse, user ownership, boot epochs, corrupt persisted state and cutout latches.
- Acquire during cue/unblock, stale callback/generation rejection, failed clear retries with no leases.
- Helper replacement/disconnect ownership, wedged-connection deadlines, and auxiliary assertion cleanup.
- Framing limits, invalid versions/operations, peer credentials, private paths, stale sockets and second-daemon refusal.
- Literal command arguments, stdin, exit codes, signals, controlling terminals and watcher cancellation.
- Malformed/foreign hook configuration, receipt ownership, backups, byte-exact restoration and modified plugins.
- Read-only doctor semantics and refusal to uninstall recovery mechanisms before confirmed cleanup.
- OS Security.framework rejection of unrelated signed binaries, unsigned binaries, and valid ad-hoc binaries spoofing all three production role identifiers.
- `Tests/xpc_smoke.py` exercises live anonymous NSXPC round trips with an explicitly ad-hoc-signed copy of the standalone `WakeLeaseXPCProbe`, listener rejection before delegate admission for all three production roles, and client rejection of an untrusted reply. It repeats the five scenarios across three fresh processes, registers no launch service, and executes no power operation. SwiftPM loads unit-test bundles inside a toolchain helper whose signing varies by installation; do not use that helper as the identity fixture or modify its signature. The probe awaits callbacks without blocking its executor and explicitly marks XPC error callbacks `@Sendable`.
- Once-only continuation completion from a background callback created on the main actor, plus concurrent reply/timeout/error completion races.
- Explicit flock release while a duplicated descriptor remains alive, including repeated parallel-suite verification.
- Actual generated hook/script execution and a real pinned Pi SDK lifecycle using a mock model, an isolated home and network denial.
- Durable helper removal admission, owner/transaction cancellation, restart fencing, rollback failure visibility and same-user maintenance exclusion.
- In explicitly opted-in disposable CI only, `python3 Tests/root_removal_smoke.py` checks root-owned ticket permissions with a temporary fixture. It does not register services or call power APIs.

## Community package verification

`InstalledComponentTrustTests` covers protected path traversal, root-owner enforcement, write ACLs, hard links, schema/role injection, native code-hash rejection, delegated removal, rollback, stale records and incomplete package transactions. The marker binds the complete canonical record, including hashes—not just a source revision. `ServiceRegistrationPolicyTests` distinguishes the observed pending-approval permission error from unrelated failures.

`python3 Tests/community_package_smoke.py` builds an installer-required release bundle and verifies its exact component pins through the native verifier. It also supplies a wrong helper pin and requires rejection. It never installs or launches the community power path.

For already-built distribution artifacts:

```sh
WAKELEASE_COMMUNITY_DIST=<artifact-directory> WAKELEASE_HEADLESS=1 \
  python3 Tests/package_smoke.py
```

This checks all three pkg checksums, expands their contents into a temporary directory, verifies the common worker signature and architecture, checks shell syntax, compares pin records, verifies the app payloads, and checks the DMG checksum. It executes only the worker's read-only `verify` mode—not installer scripts—and never mounts the image.

`installed-package-probe.yml` is separately approved **only on disposable GitHub macOS runners**. It uses the actual package builder and native installer scripts but substitutes harmless CLI-only binaries for all app/daemon/helper payloads. It refuses pre-existing product paths/receipts. Its scope is root-owned publication, denied user writes, exact installed identity, rejection while the dummy app is running, interrupted-install repair, delegated deletion and administrator approval-only removal. Cleanup checks the fixture's unique identity. No WakeLease power controller or real service registration is included; consult the exact run before claiming a scenario passed. Installer output uses `-verboseR -dumplog` to retain script diagnostics.

These tests do not certify a downloaded/quarantined package's human Gatekeeper dialogs, approved product helper startup, real user-session lifecycle, or closed-lid behavior. Apple enrollment is not a prerequisite for those community-path tests; an approved separate Mac and any required human approvals are.

## Cross-process XPC fixture

`Tests/xpc_process_smoke.py` (CI job `process_xpc`, or `WAKELEASE_XPC_PROCESS_FIXTURE=disposable-vm` on a hypervisor-reported disposable Mac) builds two separately ad-hoc-signed hardened-runtime bundles, bootstraps the service into the current user launchd domain under a unique `org.wakelease.xpc-fixture.` Mach service, and runs five client scenarios in fresh processes. Exact role/hash requirements are built through `InstalledComponentTrust`, exactly as the product does. The valid case must receive a reply from a different PID with the same UID, with exactly one accepted connection and one call and a matched peer identity; wrong listener role/hash must reject before the delegate runs (zero accepted connections); wrong client role/hash must reject the reply-side trust check. The fixture boots the service out and confirms it no longer exists before asserting.

The earlier embedded `Contents/XPCServices/*.xpc` variant rejected its own valid peer: Apple's SDK documents `setConnectionCodeSigningRequirement(_:)` for anonymous and Mach-service listeners only, so `NSXPCListener.service()` never reached `resume`. The corrected fixture uses the production listener shape (`NSXPCListener(machServiceName:)`), not a weakened requirement. On the Devin Cloud Mac (macOS 26.5.2 arm64 VM) all five cases passed with a separate service PID and UID 501; consult the branch's `process_xpc` jobs for both GitHub architectures. This proves transport and requirement enforcement between two processes, not the installed product's root helper or ServiceManagement approval.

## Disposable dummy approval experiment

`Tests/service_approval_probe.py` extends the harmless registration fixture for a hypervisor-reported disposable Mac (`WAKELEASE_REGISTRATION_PROBE=approved-disposable-vm`). It registers a uniquely named ad-hoc dummy app (`WakeLease Dummy Probe <token>`, identifier `org.wakelease.registration-probe.<uuid>`) whose LaunchAgent/LaunchDaemon run a helper that only records its PID/UID/parent into a private fixture directory. `register`, `register --agent-only`, `status --root` and `cleanup --root` leave the registration pending so the exact System Settings row can be exercised; the fixture refuses foreign directories and deletes only its own. No WakeLease power code is involved.

Observed on the Devin Cloud Mac (macOS 26.5.2 VM, standard non-root user):

- Agent + daemon app: `SMAppService.agent.register()` returned and briefly reported `enabled`; launchd started the dummy agent once (PID with parent 1, UID 501, evidence written by the helper). `SMAppService.daemon.register()` threw `SMAppServiceErrorDomain` code 1 "Operation not permitted" while its status was `requiresApproval`—the exact pattern `ServiceRegistrationPolicy` classifies as pending approval. Both statuses then settled at `requiresApproval`, and Login Items showed one grouped row "2 items: 1 item affects all users", switched off.
- Toggling that row on produced a macOS **administrator password prompt** ("Login Items is trying to modify your system settings"). Per the approved boundary the prompt was cancelled, nothing was entered, and approval of the daemon therefore remains **unverified**.
- Agent-only app: registration reported `enabled` with no prompt at all; Login Items showed "1 item" already on; the dummy agent started under launchd (parent PID 1, UID 501).
- `cleanup` returned both fixtures to `notRegistered`, `launchctl print` no longer finds the labels, and the rows disappeared after System Settings was reopened. launchd retains only its per-label enable override entries, which is a normal artifact of unregistered labels on that disposable VM.

This matches the product's expectation that helper (daemon) approval requires an administrator, while the user-domain daemon (agent) does not. It does not prove the real WakeLease helper's approved startup, its power cleanup, or behavior on a physical Mac or macOS 15.4.

## Additional offline host and performance checks

```sh
python3 Scripts/install-host-fixtures.py
python3 Tests/pi_host_smoke.py
python3 Tests/idle_smoke.py
```

The Pi fixture installs the checksum-pinned official `@earendil-works/pi-coding-agent@0.83.0` archive (published July 29, 2026), with package scripts disabled and a conservative dependency cutoff. It lives only under `.build/pi-host`, not in the product. The real SDK loads our generated extension in an isolated home/workspace with no inherited credentials. A mock stream replaces the provider; Node network entry points are blocked, and the test requires zero attempts. This verifies host lifecycle integration, not a paid provider or the interactive Pi UI.

The idle check measures only its owned simulation daemon through `proc_pidinfo`, converting Mach ticks with `mach_timebase_info` rather than assuming nanoseconds. It reports CPU/resident memory and catches gross idle loops (>2% CPU) or excessive resident growth (>256 MiB); those regression ceilings are not advertising targets or production-helper measurements.

## Evidence recorded so far

The community-installation changes pass **576 Swift tests in 67 suites** locally in debug and release, plus **28 CLI cases**, **five standalone XPC scenarios across three fresh processes**, **eight offline Pi SDK lifecycle scenarios**, and the read-only community-bundle/distribution checks. The 24 added Swift cases cover installed component trust, package transactions/removal, service-approval error classification and read-only inspection of unset/malformed power preferences. A universal community DMG was built and its three package payloads, worker signatures, checksums and image integrity were inspected without installation.

The native package lifecycle passed on **both architectures** at `b81238a` in [disposable package run 34912512996](https://github.com/ManagementMO/wakelease/actions/runs/34912512996). It verified the actual installer scripts against harmless stand-ins: activation, running-app refusal, interrupted-install repair, exact identity/impostor rejection, root-only writes, delegated deletion and administrator approval-only removal. Both hosts omitted the unset preference from `pmset -g` but exported an explicit live kernel `false`; no power setting was changed. All dummy app/approval files and package receipts created by the test were cleaned up. This is not full product service or physical sleep evidence.

The regular **five-job CI matrix also passed at `b81238a`** in [run 34912513288](https://github.com/ManagementMO/wakelease/actions/runs/34912513288), including both full-Xcode builds, both architecture test executions, universal packaging and community artifact inspection. The CI-built community DMG was downloaded and its three packages, exact component records, worker signatures, architecture slices and checksums were reverified locally without installation.

The prior native-UI checkpoint at `6bdb332` passed **six UI test methods** covering eight rendered previews, accessibility-tree checks and 26 interactions in debug/release. Those tests were not re-run by changing this Mac's system settings or interacting with real services during community-installer work. XPC transport checks remain in the explicitly signed standalone probe, not the SwiftPM toolchain helper. The packaged-preview argument guards and repository/lint checks also pass.

The inherited baseline was **416 tests in 41 suites**. The earlier published CI checkpoint covered **550 Swift tests in 64 suites**, 28 CLI cases and packaging. All five jobs for `6303ec6` passed in [GitHub Actions run 34809565795](https://github.com/ManagementMO/wakelease/actions/runs/34809565795) on September 14, 2026; consult the current commit's CI run for subsequent additions:

| Execution environment | Toolchain | Verified scope |
| --- | --- | --- |
| Apple Silicon, macOS 26.6.2 (25G83) | Xcode 26.6 / Swift 6.3.3 | Full Xcode app build, Swift/CLI/host fixtures, root-owned ticket fixture, universal development packaging |
| Intel, macOS 15.7.9 (24G830) | Xcode 26.3 / Swift 6.2.4 | The same build, execution and filesystem checks; not merely cross-compilation |

Locally, the Swift suite also passed in **release configuration**, and the 28 CLI cases, Pi lifecycle fixture and eight native preview cases passed against optimized release executables. The descriptor-alias lock fix passed eight consecutive full parallel-suite runs. To repeat optimized Swift verification, add `--configuration release` to the source-testing command; `WAKELEASE_BIN_DIR` selects the corresponding executables for Python checks.

Five-second simulation-daemon idle samples (not the production helper, real sensors or UI):

| Sample | CPU | Resident memory |
| --- | --- | --- |
| Local debug | 0.0006% | 8.36 MiB |
| Local release | 0.0027% | 8.27 MiB |
| Apple Silicon CI | 0.0021% | 10.20 MiB |
| Intel CI | 0.0012% | 3.57 MiB |

Concurrent CLI latency is load-sensitive and includes process startup and persistence. One local release sample was 16.2 ms median / 23.6 ms p95. The shared debug CI runners measured 52.4 / 113.0 ms on Apple Silicon and 64.4 / 74.1 ms on Intel. These are not certified privileged transition timings and do **not** establish an unconditional sub-50-ms guarantee. Subsequent counts and measurements must come from fresh output, not be treated as permanent certification.

## Remaining release gates

| Gate | Required evidence | Current scope |
| --- | --- | --- |
| Full Xcode bundle build | Clean unsigned compile of app and embedded products | Passed on both architectures for `b81238a` and the earlier checkpoints above. Project format 77 remains readable by Xcode 26.3; deployment/signing settings were not weakened. |
| Installed XPC authorization | Correct pinned code/role accepted; modified hashes, missing approval and wrong roles rejected; optional Developer ID team checks | Static-code, root-pin, anonymous NSXPC and separate-process Mach-service fixtures covered (positive reply from a different PID; wrong role/hash rejected on both sides). Full installed product peers after administrator/service approval remain unverified |
| Registration and approval | Fresh install, Gatekeeper/administrator decisions, denial, service approval, login and restart | Harmless disposable probes are separate evidence: dummy agent approval/startup observed on a cloud VM; dummy daemon approval stopped at the administrator password prompt. The actual product was not installed on the development Mac |
| Community upgrade/repair | Coherent complete-package replacement, inactive services, interrupted installation, wrong-build recovery and rollback | Protected transaction/record tests and read-only package inspection covered; full live product lifecycle remains unverified |
| Uninstall | Active work paused, `SleepDisabled 0`, services/owned hooks/link and matching approval removed, foreign edits preserved, coordinated multi-user removal | Coordinator/ownership/pin-removal fixtures covered; real approved-product removal remains unverified |
| Closed-lid work | Observable progress with no external display, on AC and battery | Requires explicit physical test |
| Final release | Actual prompt closed-lid sleep, while preserving clamshell/external-display use | Fake policy checks only |
| Crash/recovery | Daemon crash, helper crash, helper wedge, relaunch, interrupted clear | Simulated/fake coverage; physical verification required |
| Battery/thermal | Safe admission, hysteresis, unknown sensors, user-visible degradation | Fake sensor coverage; no deliberate hardware stress |
| OS/architecture | macOS 15.4 floor through current release, Apple Silicon and Intel | Both architectures compiled and executed in CI; universal slices/minimum 15.4, ad-hoc integrity and ZIP checksums verified. Runtime evidence covers 26.6.2 ARM64 and 15.7.9 Intel; exact 15.4 and physical Intel MacBook sleep behavior remain unverified |
| Live integrations | Paid/free host sessions, approvals, cancellation, retry, background tasks | Generated program fixtures and real Pi SDK with a mocked offline model; live provider/interactive host approval still unverified; see INTEGRATIONS.md |
| Accessibility/UX | VoiceOver, keyboard-only navigation, large text, hidden icon/reopen, real settings | Native AX tree and 26 keyboard/action/layout checks pass in debug/release preview, including hidden-icon close/reopen in the same process, maximum content and in-place error recovery; eight visual previews pass. Manual VoiceOver/system large-text and production-permission workflows remain pending |

Use the supervised [A–K hardware procedure](HARDWARE_TESTS.md) for actual MacBook validation. Do not mark a gate passed by extrapolating from a compiler, a fake controller, a screenshot, or upstream's physical results. Record exact artifact and platform evidence. See [RECOVERY.md](RECOVERY.md) before any physical work.
