# WakeLease engineering rules

## Lineage

Read `UPSTREAM.md`. The repository preserves Adrafinil v1.7.0 history. Do not erase upstream MIT notices or misrepresent inherited systems work. Source directory names are intentionally retained during the lease refactor.

## Safety

Never run the real helper, register launch services, install agent hooks into the developer's home, change `pmset`, or put the host to sleep as part of automated tests. Use fake power controllers and temporary home directories. A physical closed-lid test needs explicit approval and a documented recovery procedure.

Production authorization must fail closed. Unsigned development must not weaken the root helper's caller checks. No telemetry or automatic network activity in ordinary operation. Do not log user reasons, command lines, repository paths, or hook payloads.

## Verification

- Upstream shared package: `swift test --package-path AdrafinilShared` (full Xcode includes Swift Testing).
- Root command-line build: `swift build`.
- On Command Line Tools installations without the Testing module: `WAKELEASE_SOURCE_TESTING=1 swift test --scratch-path .build/source-testing --disable-xctest --disable-experimental-prebuilts`. This opt-in builds pinned Swift Testing 6.2.4 and SwiftSyntax 602.0.0 for tests only; they are not product dependencies. Keep a separate scratch directory to avoid stale macro modules after changing SwiftSyntax versions.
- Initial baseline: 416 tests in 41 suites passed with that command on macOS 26.6.2 (25G83) / Apple Swift 6.3.3; CLI, daemon, and helper also compiled. No real power operations were executed.
- Full Xcode app build is a separate verification gate; Command Line Tools cannot perform it.
- End-to-end CLI tests: `python3 Tests/cli_integration.py`. They launch only the explicitly labeled simulation daemon in a temporary private directory and test TTY/signals, concurrent clients, TTL, and restart. `WAKELEASE_BIN_DIR` may select a different built binary directory.
- SwiftSyntax is intentionally a direct test-only dependency to pin the transitive macro version; SwiftPM may warn that no target imports it directly.
- Inspect `git diff --check` and run relevant tests before each commit.

Keep the actor registry as the source of truth. Count effective leases, not process names or UI state. Check stale generations after every suspension point on the sleep-release path. A failed unblock must remain observable and retryable.
