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
  AdrafinilShared/Sources/WakeLeaseProcess/BoundedProcess.c
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

## Evidence recorded so far

The inherited baseline was **416 tests in 41 suites**. After the production/UI/installer additions, **529 Swift tests in 58 suites** passed on Apple Silicon, macOS 26.6.2 (25G83), Apple Swift 6.3.3, using the source-testing path. Twenty-two CLI end-to-end cases, six UI preview cases and a disposable package smoke test also passed at that checkpoint. Subsequent counts should be taken from fresh command output rather than treated as a permanent certification.

Observed concurrent CLI latency in simulation varied with load: examples ranged from roughly 14–19 ms median and 18–30 ms p95, with an earlier burst above 60 ms p95. This includes CLI startup and persistence, not certified privileged transition latency. Do not advertise an unconditional sub-50-ms result or zero idle CPU from these samples.

## Remaining release gates

| Gate | Required evidence | Current scope |
| --- | --- | --- |
| Full Xcode bundle build | Clean unsigned compile of app and embedded products | Command Line Tools cannot perform it locally; CI remains required |
| Signed XPC authorization | Correct team/role accepted; wrong team, wrong role and unsigned peers rejected by the OS | Pure requirements and unsigned-start rejection covered; live signed peers unverified |
| Registration and approval | Fresh install, denial, approval, login and service restart | Not executed on the development Mac |
| In-place upgrade | Coherent update, old callbacks, version mismatch, idle helper relaunch, rollback | Source/fake paths covered; signed live workflow unverified |
| Uninstall | Active work paused, `SleepDisabled 0`, services/owned hooks/link removed, foreign edits preserved, coordinated multi-user removal | Coordinator/ownership fakes covered; live removal unverified |
| Closed-lid work | Observable progress with no external display, on AC and battery | Requires explicit physical test |
| Final release | Actual prompt closed-lid sleep, while preserving clamshell/external-display use | Fake policy checks only |
| Crash/recovery | Daemon crash, helper crash, helper wedge, relaunch, interrupted clear | Simulated/fake coverage; physical verification required |
| Battery/thermal | Safe admission, hysteresis, unknown sensors, user-visible degradation | Fake sensor coverage; no deliberate hardware stress |
| OS/architecture | macOS 15.4 floor through current release, Apple Silicon and Intel | ARM64, x86_64 and assembled universal release binaries compiled; inspected both slices and minimum 15.4; ad-hoc integrity and ZIP checksum verified. Execution evidence is Apple Silicon on 26.6.2; Intel hardware unverified |
| Live integrations | Paid/free host sessions, approvals, cancellation, retry, background tasks | Contracts/fixtures only; see INTEGRATIONS.md |
| Accessibility/UX | VoiceOver, keyboard-only navigation, large text, hidden icon/reopen, real settings | Native primitives and visual previews; full manual audit pending |

Do not mark a gate passed by extrapolating from a compiler, a fake controller, a screenshot, or upstream's physical results. Record exact artifact and platform evidence. See [RECOVERY.md](RECOVERY.md) before any physical work.
