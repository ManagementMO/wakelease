# Contributing to WakeLease

Read [AGENTS.md](AGENTS.md), [UPSTREAM.md](UPSTREAM.md), and [Docs/THREAT_MODEL.md](Docs/THREAT_MODEL.md) first. Preserve the MIT notice and upstream history. Do not reattribute inherited engineering or claim tests that were not performed.

## Development and verification

Swift 6.2+ and macOS 15.4+ are required by this branch. Full Xcode is a separate build/signing gate; the Command Line Tools path is:

```sh
WAKELEASE_SOURCE_TESTING=1 swift test --scratch-path .build/source-testing \
  --disable-xctest --disable-experimental-prebuilts
python3 Tests/cli_integration.py
python3 Tests/ui_smoke.py
python3 Tests/package_smoke.py
python3 Scripts/lint.py
```

UI rendering needs a logged-in macOS desktop. Tests must use simulation/fake power controllers and temporary homes. Never install actual hooks, register privileged services, change `pmset`, or cause sleep as an automated-test side effect. Physical tests require explicit permission and the [recovery procedure](Docs/RECOVERY.md).

Formatting follows the existing `.swiftformat` configuration. `Scripts/lint.py --format` uses pinned, checksum-verified tools and preserves existing headers/comments; inspect the diff afterward. No global package installation or Git configuration change is required. The lint runner points SourceKitten at an available Command Line Tools framework for that process rather than disabling SourceKit rules.

## Structure

- `WakeLeaseApp/`: native UI, service registration and user-confirmed removal.
- `AdrafinilDaemon/`: user broker runtime, device observation and serialized power coordination.
- `AdrafinilHelper/`: root mechanical boundary; keep it small and command-safe.
- `AdrafinilShared/Sources/AdrafinilShared/Leases`: deterministic registry and actor boundary.
- `AdrafinilShared/.../IPC`: secure local protocol, filesystem operations and component trust.
- `AdrafinilShared/.../Installer`: generic integration contracts, payload adapters and receipt-based writes.
- `Tests/` and `Scripts/`: end-to-end verification and reproducible build/release tools.

Historical Adrafinil UI and model files remain for lineage/regressions; they are not the new app's UI target.

## Changes and reviews

1. Reproduce a bug with a deterministic test before fixing it.
2. Keep demand, applied state, ownership and ordering separate. Recheck generation after asynchronous release/cue work.
3. Prefer native mechanisms and existing abstractions. Do not weaken signing, permissions, timeouts, release-age controls or verification to pass CI.
4. Preserve source comments and legal notices; do not perform broad unrelated cleanup.
5. Run targeted tests during iteration and the full safe suite before a release candidate.
6. Describe limitations plainly, including any unverified hardware or signed-peer path.

New adapters need current primary-source evidence, realistic payload/configuration fixtures, parallel-session/background-work cases, safe install/uninstall tests, and an explicit capability limit. A running terminal or application is not proof of useful work. Never grant a host's trust/approval automatically.

Keep commits focused; small upstreamable bug fixes should be separable from derivative UI/features. Do not push, publish, open an upstream issue, or create a pull request without the maintainer's authorization. Contributions to this project are MIT-licensed.
