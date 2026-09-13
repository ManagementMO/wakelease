# WakeLease

<img src="WakeLeaseApp/Assets.xcassets/AppIcon.appiconset/icon_128x128%402x.png" alt="WakeLease lease-token icon" width="96" height="96">

**Keep your Mac working only while work holds a lease.**

WakeLease is a native macOS menu-bar utility for local jobs, coding agents, builds, downloads, and custom workflows. Independent work holds independent, finite wake leases. When the final effective lease ends, WakeLease restores normal sleep behavior.

It is an **MIT-licensed derivative of [Adrafinil](https://github.com/kageroumado/adrafinil)** by kageroumado and contributors. The upstream power-management work, helper architecture, monitors, and regression tests are the foundation—not inventions of this project. See [UPSTREAM.md](UPSTREAM.md) and [LICENSE](LICENSE). This is an independent project without upstream endorsement.

> **Pre-release engineering build.** The CLI, broker, native UI, and production power path compile and have automated coverage. Live signed-peer authorization, service approval/update/uninstall, Intel execution, and physical closed-lid recovery remain release gates. No signed/notarized public WakeLease download or Homebrew cask is available from this checkout.

## The model

- **One lease per work unit.** Concurrent jobs do not release each other's protection. Child/background leases can outlive a parent turn.
- **Waiting is not working.** A producer can report that it needs a person. The default grace is ten minutes, then normal sleep is allowed. Heartbeats do not restart that grace.
- **Every lease expires.** The default lifetime is four hours; the maximum per renewal is 24 hours. Process-bound leases also track the owner's kernel birth identity, not just a PID.
- **Safety outranks work.** Closed-lid battery and thermal cutouts release this user's leases and latch against immediate reacquisition.
- **Requested is not confirmed.** Status distinguishes desired demand, applied protection, helper connectivity, and failures.
- **Timed manual work.** The menu bar can create a finite 15-minute, one-hour or two-hour hold, with its own countdown and release control.
- **The menu bar is a view, not the broker.** Quitting it does not silently release a running job. Use **Allow Sleep Now** to release and pause deliberately.

## Quick examples

After installing a correctly signed app and approving its services:

```sh
wakelease run -- npm run build
wakelease watch --pid 12345
wakelease hold --for 2h --source download --reason "large download"

wakelease acquire build:42 --source build --ttl 7200
wakelease wait build:42 --reason "waiting for approval"
wakelease acquire build:42 --source build
wakelease release build:42

wakelease status
wakelease doctor
```

`run` passes a literal argument vector—no shell interpolation—and preserves stdin, terminal behavior, signals, and the child's exit status. It refuses to start the command if production wake protection is unconfirmed. A watched process is not killed when its watcher is cancelled.

`hold` prints its generated key. Release that key early when the work finishes. `release --all` clears current leases but permits new work; `pause` blocks new leases until `resume`.

## Agent integrations

The daemon understands generic leases, not agent brands. Tool knowledge lives in adapters and installers.

```sh
wakelease integrations
wakelease integrations preview claude-code
wakelease integrations install claude-code --yes
wakelease hooks generate --source my-tool --session-variable JOB_ID
```

Built-in formats cover Claude Code, Codex, Cursor, Gemini CLI, OpenCode, Pi, and an experimental Cline VS Code hook convention. Aider uses an explicit command wrapper; Hermes has a manual YAML recipe. Configured does **not** mean live-agent-certified. Codex requires its own hook approval; Pi requires `agent_settled`. See the [capability matrix and primary evidence](Docs/INTEGRATIONS.md).

Installers preview intended changes, retain private backups, preserve foreign settings, and refuse symlinks or unowned/modified plugins. No shell startup file is edited automatically. An optional local stdio MCP server is available; there is no IP listener or cloud account.

## Requirements and build status

- Runtime/build deployment floor: **macOS 15.4**. The retained isolated-deinitialization runtime is the reason for this floor; an older minimum would need a deliberate backport.
- Swift **6.2 or newer**. Full Xcode is needed for the Xcode build/signing workflow. Command Line Tools can build the SwiftPM executables and development bundle.
- Production power control requires an Apple-issued team signature and user-approved ServiceManagement registration. The root helper is not usable through an unsigned fallback.
- Automated verification was run on Apple Silicon, macOS 26.6.2, with Apple Swift 6.3.3. This is not a claim of physical certification on every supported OS or architecture.

### Safe development loop

These commands build and test without installing services or changing power settings:

```sh
WAKELEASE_SOURCE_TESTING=1 swift test --scratch-path .build/source-testing \
  --disable-xctest --disable-experimental-prebuilts
python3 Tests/cli_integration.py
python3 Tests/ui_smoke.py
python3 Tests/package_smoke.py
python3 Scripts/lint.py
```

The source-testing opt-in pins Swift Testing 6.2.4 and SwiftSyntax 602.0.0 for tests only. They are not runtime dependencies. UI smoke tests require a logged-in macOS desktop.

To experiment with the API, launch `.build/source-testing/debug/WakeLeaseDaemon --simulate --state-dir <private-directory>` and point the CLI at the same absolute directory with `WAKELEASE_STATE_DIR`. **Simulation holds no power assertions and changes no macOS power setting.**

Build a development app bundle:

```sh
python3 Scripts/build-app.py --configuration debug \
  --bin-dir .build/source-testing/debug --output .build/WakeLease-dev.app
```

That shortcut is ad-hoc-signed and deliberately cannot operate privileged services. For source-built, team-signed packages and notarization, use the [release procedure](Docs/RELEASING.md). The internal Xcode project/scheme still uses the upstream name to preserve history; it now builds WakeLease products and the new `WakeLeaseApp` sources.

## Sleep safety

Ordinary idle assertions do not guarantee closed-lid execution. WakeLease retains Adrafinil's two mechanisms: an IOPM idle assertion plus the machine-global `pmset -a disablesleep` override. The latter can survive a crash or reboot if it is not cleared.

The helper has startup/shutdown cleanup, bounded subprocesses, read-back verification, failed-clear retries, and renewable per-user claims with disconnect and wedged-daemon deadlines. These reduce risk; they do not make failures impossible. Do not run competing closed-lid utilities. **Never put an actively computing Mac in a sealed or unventilated bag.** SMC temperatures are supplementary, hardware-dependent readings—not a stable public thermometer or thermal guarantee.

Read [recovery instructions](Docs/RECOVERY.md) before testing physical sleep behavior. `doctor` is read-only: it never installs services, changes power settings, or puts the Mac to sleep.

## Uninstall

```sh
wakelease uninstall --dry-run
wakelease uninstall --yes
```

Uninstall first pauses admission and requires confirmed cleanup before removing recovery services. It then removes recorded integrations and its receipt-owned CLI link. Modified or foreign content is preserved and reported. `--purge` additionally removes known local preferences, logs, and backups; `--remove-app` moves the app to Trash. The native settings window offers the same explicit choices. See [installation and removal](Docs/INSTALLATION.md).

## Documentation

- [Architecture and inherited platform lessons](Docs/ARCHITECTURE.md)
- [Local lease protocol](Docs/LEASE_PROTOCOL.md)
- [CLI reference](Docs/CLI.md)
- [Integration capabilities](Docs/INTEGRATIONS.md)
- [Threat model](Docs/THREAT_MODEL.md) and [security reporting](SECURITY.md)
- [Tests and outstanding hardware gates](Docs/TESTING.md)
- [Contributing](CONTRIBUTING.md)

WakeLease has no telemetry, automatic update feed, or normal-operation network dependency. A public repository, security contact, signing identity, notarization account, and release channel must be designated by the maintainer before publication.
