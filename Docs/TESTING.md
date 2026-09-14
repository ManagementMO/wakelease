# Verification and release gates

## Safe automated suite

```sh
WAKELEASE_SOURCE_TESTING=1 swift test --scratch-path .build/source-testing \
  --disable-xctest --disable-experimental-prebuilts
python3 Tests/cli_integration.py
python3 Tests/ui_smoke.py
python3 Tests/package_smoke.py
python3 Scripts/lint.py
```

All power controllers used by unit/integration tests are fake or explicitly simulated. Integration configuration lives in temporary homes. The unsigned-execution tests verify rejection before any power mutation. Package smoke tests assemble a disposable ad-hoc bundle, verify integrity, exercise version/preview paths, and confirm privileged-mode refusal. They do not install the bundle or register services.

The SwiftPM root builds all four executables. The source-testing opt-in uses pinned Swift Testing 6.2.4 and SwiftSyntax 602.0.0 to support Command Line Tools installations missing the bundled Testing module. Keep its scratch directory separate from other toolchain/macro versions.

UI smoke tests require a logged-in macOS desktop and exercise fixture windows, not real services. Their timeout detects the regression where writing unchanged observable preferences from `MenuBarExtra(isInserted:)` caused a main-menu graph loop. PNG existence is not an accessibility or human visual-review certification.

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
- Explicit flock release while a duplicated descriptor remains alive, including repeated parallel-suite verification.
- Actual generated hook/script execution and a real pinned Pi SDK lifecycle using a mock model, an isolated home and network denial.
- Durable helper removal admission, owner/transaction cancellation, restart fencing, rollback failure visibility and same-user maintenance exclusion.
- In explicitly opted-in disposable CI only, `python3 Tests/root_removal_smoke.py` checks root-owned ticket permissions with a temporary fixture. It does not register services or call power APIs.

## Additional offline host and performance checks

```sh
python3 Scripts/install-host-fixtures.py
python3 Tests/pi_host_smoke.py
python3 Tests/idle_smoke.py
```

The Pi fixture installs the checksum-pinned official `@earendil-works/pi-coding-agent@0.83.0` archive (published July 29, 2026), with package scripts disabled and a conservative dependency cutoff. It lives only under `.build/pi-host`, not in the product. The real SDK loads our generated extension in an isolated home/workspace with no inherited credentials. A mock stream replaces the provider; Node network entry points are blocked, and the test requires zero attempts. This verifies host lifecycle integration, not a paid provider or the interactive Pi UI.

The idle check measures only its owned simulation daemon through `proc_pidinfo`, converting Mach ticks with `mach_timebase_info` rather than assuming nanoseconds. It reports CPU/resident memory and catches gross idle loops (>2% CPU) or excessive resident growth (>256 MiB); those regression ceilings are not advertising targets or production-helper measurements.

## Evidence recorded so far

The inherited baseline was **416 tests in 41 suites**. The current checkpoint is **550 Swift tests in 64 suites**, **28 CLI end-to-end cases**, the offline Pi SDK fixture, and package/repository checks. All five jobs for `6303ec6` passed in [GitHub Actions run 34809565795](https://github.com/ManagementMO/wakelease/actions/runs/34809565795) on September 14, 2026:

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
| Full Xcode bundle build | Clean unsigned compile of app and embedded products | Passed on both architectures for `6303ec6`; see the recorded CI checkpoint above. Project format 77 remains readable by Xcode 26.3; deployment/signing settings were not weakened. |
| Signed XPC authorization | Correct team/role accepted; wrong team, wrong role and unsigned peers rejected by the OS | Requirement construction, OS rejection of signed wrong-role and ad-hoc spoofed-role binaries, plus unsigned-start rejection covered; positive production-signed XPC peers unverified |
| Registration and approval | Fresh install, denial, approval, login and service restart | Not executed on the development Mac |
| In-place upgrade | Coherent update, old callbacks, version mismatch, idle helper relaunch, rollback | Source/fake paths covered; signed live workflow unverified |
| Uninstall | Active work paused, `SleepDisabled 0`, services/owned hooks/link removed, foreign edits preserved, coordinated multi-user removal | Coordinator/ownership fakes covered; live removal unverified |
| Closed-lid work | Observable progress with no external display, on AC and battery | Requires explicit physical test |
| Final release | Actual prompt closed-lid sleep, while preserving clamshell/external-display use | Fake policy checks only |
| Crash/recovery | Daemon crash, helper crash, helper wedge, relaunch, interrupted clear | Simulated/fake coverage; physical verification required |
| Battery/thermal | Safe admission, hysteresis, unknown sensors, user-visible degradation | Fake sensor coverage; no deliberate hardware stress |
| OS/architecture | macOS 15.4 floor through current release, Apple Silicon and Intel | Both architectures compiled and executed in CI; universal slices/minimum 15.4, ad-hoc integrity and ZIP checksums verified. Runtime evidence covers 26.6.2 ARM64 and 15.7.9 Intel; exact 15.4 and physical Intel MacBook sleep behavior remain unverified |
| Live integrations | Paid/free host sessions, approvals, cancellation, retry, background tasks | Generated program fixtures and real Pi SDK with a mocked offline model; live provider/interactive host approval still unverified; see INTEGRATIONS.md |
| Accessibility/UX | VoiceOver, keyboard-only navigation, large text, hidden icon/reopen, real settings | Native primitives and visual previews; full manual audit pending |

Use the supervised [A–K hardware procedure](HARDWARE_TESTS.md) for actual MacBook validation. Do not mark a gate passed by extrapolating from a compiler, a fake controller, a screenshot, or upstream's physical results. Record exact artifact and platform evidence. See [RECOVERY.md](RECOVERY.md) before any physical work.
