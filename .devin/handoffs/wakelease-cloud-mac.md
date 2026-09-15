# WakeLease cloud macOS validation handoff

## Task

Continue the verification work on a confirmed Devin-owned macOS VM. Fix the remaining cross-process XPC fixture failure, complete all safe remote verification, attempt the explicitly approved harmless background-helper approval/startup test, and report precisely what is proven and what still needs a human or physical MacBook. Keep work on `verify/remote-validation` until the full relevant checks pass.

The user explicitly requested this cloud Mac handoff. Do not run project code on their personal computer, connect an outpost to it, or use it as a fallback.

## Repository and branch

- Repository: https://github.com/ManagementMO/wakelease
- Working branch: `verify/remote-validation`
- Latest code checkpoint before this handoff document: `42149a22c4123dfc2203d598289d6fdc5a364e03`
- Stable `main`: `87819c3302aacc95888c596c8372794ad56ddab6`
- The verification branch is already pushed. `main` has NOT received the new test fixture or its currently failing positive control.
- Read `AGENTS.md` and `UPSTREAM.md`. Preserve upstream MIT attribution, project format 77, the macOS 15.4 deployment floor, signing checks and existing comments.

## Environment and permission boundaries

1. First verify that this session really executes on a Devin Cloud macOS VM, not Linux and not a user-owned outpost. Run OS/toolchain inspection ONLY inside that remote VM. Stop if placement is wrong.
2. The user's personal Mac is completely excluded from all builds, lint, typechecks, tests, previews, installers, UI automation and power queries. Local terminal work so far in this round was limited to repository editing, Git/GitHub/Cloud orchestration and reading remote evidence.
3. The user later explicitly authorized a Devin Cloud Mac as an additional remote environment. This supplements the earlier GitHub-hosted-runner preference; it does not authorize execution on the personal Mac.
4. Existing privileged fixture scripts have explicit GitHub-CI guards. Do not spoof CI or remove safety guards merely to run them elsewhere. Keep those tests on GitHub CI, or introduce a separately guarded cloud fixture whose remote placement and owned paths are verified.
5. The user specifically approved this action: approve a harmless, no-power dummy background helper in macOS System Settings on a disposable remote Mac, test startup, then revoke/remove it. Stop at credential prompts rather than bypassing authentication.
6. That approval is not permission to weaken authorization databases, Gatekeeper, SIP, code-signing requirements, or privacy permissions. No credential searching, logging or extraction. Never enter guessed credentials.
7. Do not start the real WakeLease helper or run real `pmset` mutations, sleep, reboot or physical stress operations as an automatic extension of the harmless fixture approval. Obtain specific confirmation before a new disruptive action. The real helper's startup includes persistent-power cleanup, so merely starting it is not a read-only test.
8. No Apple Developer membership purchase, custom trusted certificate installation, or paid model/provider calls. The selected distribution path is no-membership community packaging. Do not revive the abandoned self-issued certificate experiment.
9. Never claim physical lid/charger/battery/thermal behavior from a VM, a dummy helper, or a passing API call. Human VoiceOver usability, exact OS-version coverage and actual provider approval flows remain distinct evidence.

## Product context

WakeLease is a macOS sleep-management application. Full power-management code was retained while adding a no-fee direct-distribution path: a universal DMG containing a standard administrator-approved installer, interrupted-install repair package, and approval-only removal package.

Administrator installation establishes root-owned exact role/code-hash pins. Runtime authentication accepts those protected pins or the optional Apple-anchored matching-team path; ordinary unapproved development remains unable to authorize privileged peers. Package installation does not start wake protection. Users still need explicit macOS installer and background-service approvals. This is not a notarized or hardware-certified release.

`InstalledPackageTransaction` fences authorization during replacement and compares the complete component record, not only a Git revision. The root helper can delegate delete-only removal of an approved record after the global removal fence and confirmed power clear. Unknown power state stays fail-closed.

## Verified evidence before this handoff

### Stable checkpoint

At `87819c3`, the previous engineering round passed 576 Swift tests in debug and release, 28 CLI cases, the offline Pi SDK scenarios and standalone XPC checks. Stable CI links:

- https://github.com/ManagementMO/wakelease/actions/runs/34913476422 — all five regular build/test jobs passed.
- https://github.com/ManagementMO/wakelease/actions/runs/34913475949 — native harmless package lifecycle passed on both architectures.

Do not treat that historical checkpoint as verification of the new cross-process fixture.

### New remote-only package cases

Commit `cb588d6` expanded `Tests/installed_package_smoke.py` to cover:

- A re-signed/damaged installed helper payload must fail activation and retain the pending admission fence.
- A repair package with changed code hashes but the same source revision must not cancel or replace that transaction.
- The matching repair restores valid approval.
- A changed-code upgrade publishes the new pins and rejects the old app copy.
- Rolling back with the original package revokes the replacement app copy.

All these cases passed on Intel/macOS 15 and Apple Silicon/macOS 26:

https://github.com/ManagementMO/wakelease/actions/runs/34931435762

The log explicitly includes both "Damaged payload and wrong-build repair rejected; matching repair restored approval" and "Changed-build upgrade and rollback revoked stale app copies" for each platform. All payloads are harmless stand-ins. No product power controller was run.

### New remote native UI execution

The preview jobs at `cb588d6` ran all SIX existing UI test methods with NO skips on both platforms. That includes 26 keyboard/layout/copy/invalid-input/reopen checks and eight rendered previews. Accessibility was already available on the hosted images; no permission changes were requested.

Run: https://github.com/ManagementMO/wakelease/actions/runs/34931434206

This entire run was later cancelled when the next verification-branch run replaced it, but both completed preview jobs were successful:

- Intel preview job: `104260282658`
- Apple Silicon preview job: `104260282727`

Artifacts are `WakeLease-remote-ui-macos-15-intel` and `WakeLease-remote-ui-macos-26`. They contain screenshots and audit logs. Do not confuse the overall cancelled run with those completed job results. Rerun all required jobs for the final candidate.

## Current failing work: cross-process XPC fixture

Relevant commits:

- `c6f2651` — Python acceptance cases plus an intentionally unimplemented Swift fixture. The first remote run correctly failed all five tests with "Cross-process fixture is not implemented".
- `26bf44d` — implemented an application-scoped embedded XPC service, actual separate-process echo, role/hash requirements built through `InstalledComponentTrust`, and journaled listener admission/call counts.
- `42149a2` — fixed a compiler-reproduced Swift 6 error by explicitly marking the lock mutation callback `@Sendable`. No compiler or signing checks were weakened.

Latest run:

https://github.com/ManagementMO/wakelease/actions/runs/35006728359

The fixture NOW COMPILES on both platforms, but its VALID positive round-trip is rejected. Four negative cases report rejection, yet they MUST NOT be counted as meaningful authorization proof until the positive control works.

Observed on both architectures:

- `test_exact_component_requirement_accepts_a_separate_peer` fails at `Tests/xpc_process_smoke.py` asserting `report["outcome"] == "reply"`; actual outcome is `"rejected"`.
- Negative cases report `errorCode: 4097`, `accepted: 0`, `calls: 0`, a separate nonzero service PID and UID 501.
- Current Python code prints a report only after assertions; add targeted failure diagnostics so the positive report and service-side startup/requirement errors are retained.
- The service writes its initial journal BEFORE building the parent requirement and resuming the listener. A journal with zero calls does not prove the service reached listener resume. Trace that boundary instead of assuming the root cause.
- The positive failure is not yet established as a production trust bug; it may be in the new embedded-service fixture or its assumptions. Investigate first. Do not remove role/hash checks, accept timeouts, or drop the positive test to turn CI green.

Failed job IDs for detailed logs:

- Intel: `104508242950`
- Apple Silicon: `104508242954`

The fixture uses one temporary `Client.app` with `Contents/XPCServices/Probe.xpc`, proper `APPL`/`XPC!` metadata, ad-hoc hardened-runtime signatures and empty entitlements. It connects with `NSXPCConnection(serviceName:)`, listens with `NSXPCListener.service()`, and builds in-memory exact requirements through `InstalledComponentTrust`. This checks transport/requirement construction; protected root-record ownership is covered separately by the package test. It is not the product's privileged helper or ServiceManagement approval workflow.

## Relevant files

- `Tests/XPCProcessProbe/XPCProcessEntry.swift` — current cross-process fixture and positive-control failure. Test-only executable target; no power mutations.
- `Tests/xpc_process_smoke.py` — builds temporary signed app/service bundles and asserts positive peer PID/UID plus wrong-role/hash rejection.
- `Package.swift` — adds `WakeLeaseXPCProcessProbe` only when `WAKELEASE_SOURCE_TESTING=1`.
- `Tests/XPCBoundaryProbe/XPCBoundaryProbe.swift` and `Tests/xpc_smoke.py` — existing same-process anonymous XPC controls, useful reference but not a replacement for the new positive test.
- `AdrafinilShared/Sources/AdrafinilShared/IPC/InstalledComponentTrust.swift` — production installed-pin schema, protected record loading and requirement construction.
- `AdrafinilDaemon/LeaseHelperConnection.swift` — production client probes version before mutation, pins the peer and checks root UID.
- `Tests/installed_package_smoke.py` — expanded native install/repair/upgrade/rollback cases, already passed remotely.
- `Tests/ui_smoke.py` — optional CI-only artifact capture under `.build/ui-evidence`.
- `Tests/ui_accessibility.swift` — existing trusted-AX audit; verifies the exact preview process and uses a separate test pasteboard.
- `.github/workflows/ci.yml` — regular matrix plus `preview` and `process_xpc` jobs on `macos-26` and `macos-15-intel`.
- `.github/workflows/installed-package-probe.yml` — manually dispatched privileged dummy-package test only.
- `Tests/ServiceRegistrationProbe/ProbeMain.swift` — currently registers and immediately unregisters dummy services. No approval-wait workflow exists yet.
- `Tests/ServiceRegistrationProbe/HarmlessHelper.swift` — currently prints that it performs no power operations, then exits.
- `Tests/service_registration_probe.py` — existing dummy app builder and registration runner. Its self-issued-certificate branch is NOT the selected path.
- `.github/workflows/service-registration-probe.yml` — WARNING: its existing matrix includes `self-issued` and certificate trust flags. Do not dispatch it unchanged for this new approval test. Use an explicitly ad-hoc-only path or a separately guarded fixture.
- `Docs/TESTING.md`, `Docs/INSTALLATION.md`, `Docs/RELEASING.md`, `Docs/THREAT_MODEL.md`, `Docs/HARDWARE_TESTS.md` — evidence, release gates, security constraints and human-only cases. They still mostly describe the stable `87819c3` checkpoint and need final updates after new validation.

## Dummy approval/startup test still to implement

The user selected "Allow remote dummy approval" in a specific confirmation. No implementation or execution of that new Settings approval action has happened yet.

Reuse the harmless registration fixture rather than the real helper. Use a unique bundle display name and identifier, verify the exact Settings row, and never toggle an ambiguous or unrelated item. Observe `SMAppService.status` before/after and prove actual dummy helper startup, ideally with scoped PID/UID evidence. Use existing accessibility permission or Cloud Computer Use; do not change privacy permissions to force it through.

Stop if a password, Touch ID, login, MFA or other credential prompt appears. Do not read secure-field contents, guess credentials, search for passwords, or modify authorization databases. Cleanup must unregister/revoke only the exact owned dummy service. A blocked approval result must remain an explicit limitation, not a passed release gate.

## Remote verification commands and workflow

On the confirmed remote Mac, use the project commands in `AGENTS.md`; no local-machine execution:

- `WAKELEASE_SOURCE_TESTING=1 swift test --scratch-path .build/source-testing --disable-xctest --disable-experimental-prebuilts`
- Repeat with `--configuration release` for optimized coverage.
- `python3 Tests/cli_integration.py`
- `python3 Tests/ui_smoke.py` with existing permission; `WAKELEASE_REQUIRE_UI_AUDIT=1` makes unavailable AX explicit rather than silently skipped.
- `python3 Tests/xpc_smoke.py`
- `python3 Scripts/lint.py`, `python3 Tests/release_tools.py`, `python3 Scripts/check-repository.py`
- The new cross-process and privileged package scripts require their explicit CI opt-ins. Use the existing GitHub workflows rather than forging their environment on an unverified machine.
- `gh workflow run ci.yml --repo ManagementMO/wakelease --ref verify/remote-validation`
- `gh workflow run installed-package-probe.yml --repo ManagementMO/wakelease --ref verify/remote-validation`

No new project dependency was added in this round. Preserve pinned dependencies and action SHAs. Never lower security policies, signing requirements or CI controls to work around failures. Do not add/remove code comments unless requested.

## Acceptance criteria

- [ ] Execution placement is verified as an isolated cloud Mac, with no path back to the user's personal computer.
- [ ] Cross-process positive echo proves a separate PID and expected UID; wrong role/hash cases reject for the intended reason.
- [ ] Expanded package damage/repair/upgrade/rollback tests remain green on both GitHub macOS architectures.
- [ ] Native preview and interaction checks run remotely; any skipped/manual cases are reported accurately.
- [ ] Approved dummy-helper Settings approval/startup is attempted with precise targeting, credential-stop handling and cleanup.
- [ ] All relevant debug/release tests, lint, package checks and CI pass for the final code. Capture actual logs and artifacts.
- [ ] Commit and push verified changes; do not move broken verification work onto `main`. Do not force-push or rewrite existing history.
- [ ] Report remaining physical MacBook, human accessibility, provider/account, exact macOS 15.4 and supported-publication prerequisites without requiring paid Apple enrollment.

## Cloud handoff placement reference

Official docs confirm `platform: "macos"` for session creation and `runs-on: macos` for blueprints:

https://docs.devin.ai/onboard-devin/environment/macos-support.md

Devin CLI's built-in `/handoff` transfers current context and branch and asks for an OS when multiple platforms are available. Choose macOS, not an outpost. The local agent did not extract stored credentials or create a fallback Linux session.
