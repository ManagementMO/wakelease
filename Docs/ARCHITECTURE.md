# WakeLease architecture

WakeLease derives from Adrafinil v1.7.0. Read [UPSTREAM.md](../UPSTREAM.md) for the exact baseline and attribution. Historical source paths and the internal `AdrafinilShared` module are retained to make upstream comparisons practical; the shipped UI and identities are WakeLease-specific.

## Components and authority

```text
agent hook / job / custom producer
              |
       wakelease CLI or local MCP
              |
       private Unix-domain socket
              |
WakeLeaseDaemon — user LaunchAgent
  LeaseBroker actor -> LeaseBook value state
  ownership, deadlines, waiting, admission, cutouts
  serialized LeasePowerReconciler
              |
       exact-role, team-pinned XPC
              |
WakeLeaseHelper — root LaunchDaemon
  per-user mechanical demand ledger
  one process-wide SleepBlocker
  fixed IOPM / pmset operations

WakeLease.app — native menu bar and settings
  reads the same local API; owns no lease registry
  explicit service registration and uninstall controls
```

The app may quit while work continues. The CLI does not register or escalate a helper implicitly. Production daemon startup requires a team signature, a non-root user, and the standard state directory. Unsigned development is explicitly simulation-only.

The helper accepts an exact daemon signing role, an Apple anchor, and the matching team. The daemon pins the helper's role/team, verifies a root peer, and checks the helper version before setting demand. The helper accepts no executable, shell fragment, path, environment, or arbitrary `pmset` argument from an IPC caller.

## Generic lease core

`LeaseBook` is the deterministic state machine. `LeaseBroker` is its actor-owned concurrency boundary. A lease has an opaque UUID, client-chosen work key, source label/kind, wake class, lifecycle state, finite deadline, optional process birth identity, and optional parent relationship.

- Effective leases derive system/display demand; counters are not independently incremented/decremented globals.
- Display demand also requires system wake. Display and system requirements are reconciled independently.
- A duplicate acquire refreshes the existing work unit without multiplying its reference count.
- Release is idempotent. Releasing a parent never cascades into children.
- Process ownership is PID + UID + kernel start time. Dead/reused identities cannot be renewed or restored.
- Deadlines use `mach_continuous_time`, including time asleep. Wall-clock changes cannot extend a lease.
- Waiting defaults to a ten-minute grace, bounded by the lease's own deadline. A heartbeat cannot restart grace; acquire resumes work.
- Lowering lifetime limits bounds existing leases. Changing waiting policy recomputes existing waits from their original start.
- Per-key revisions, terminal records, and persisted global control ordering reject stale lifecycle operations. Capacity limits fail closed rather than forgetting recent replay barriers.

Agent-specific IDs, events, payload parsing, and hook configuration are outside the broker. There is no enabled whole-system process sniffer or CPU-idle guess in the new runtime. Long-lived applications at a prompt do not automatically mean useful work.

## Why two power mechanisms remain

An ordinary `kIOPMAssertPreventUserIdleSystemSleep` assertion prevents idle sleep, not every sleep cause. Apple's API does not promise lid-close protection. WakeLease retains the upstream composition:

1. An IOPM idle-system assertion, released by the kernel if the helper dies.
2. The machine-global `SleepDisabled` preference through the fixed argument vector `/usr/bin/pmset -a disablesleep 1` or `0`.

Upstream reported physical tests on macOS 26.3 where private RootDomain selector 12 returned success without preventing displayless lid-close sleep, direct registry writes failed, and `IOPMSetSystemPowerSetting` alone did not reproduce `pmset`'s preference activation. That is **upstream evidence**, not a WakeLease hardware result. Replacing this mechanism requires physical evidence, not merely a successful API return.

`disablesleep` is persistent and can also be reset by system transitions. Do not run another utility that writes it concurrently. There is no transactional ownership API for this global preference.

## Serialized application and recovery

`LeasePowerReconciler` is the single asynchronous power writer. It records desired and last-confirmed applied state separately. Versioned intents reject old generations. Acquisition during a cue cancels the queued clear; acquisition while an unblock is already in flight is reconciled again to the latest demand. A failed clear is reported and remains retryable even with zero leases.

The pre-sleep cue is optional. The final sleep request requires a known closed lid, known absence of external displays, no remaining helper-global claim, no conflicting public assertions, and a still-current zero-demand state. Unknown conditions do not cause forced sleep. Open-lid final release restores ordinary sleep; it is not an unconditional sleep command.

`DisplayHold` releases both the display assertion and its auxiliary user-activity assertion. Failed assertion releases retain their IDs for retry rather than pretending to be gone.

The helper serializes all mechanical state on one queue. Per-user claims aggregate with OR semantics so one user disconnecting cannot clear another user's live claim. Replaced-connection callbacks cannot retire a newer connection. Claims expire after 90 seconds without a set request, even if XPC remains connected; disconnect grace is 60 seconds. False/expired claims cannot pin the machine awake.

Root subprocesses have fixed executable/arguments, a sanitized environment, bounded output and timeouts. Children are killed/reaped on timeout and stay in launchd's process group. An unreapable mutating child causes helper exit for supervisor cleanup rather than allowing a newer writer to race an old `pmset` operation. Clearing is followed by state read-back. Startup cleanup failure stays observable and retryable.

The daemon closes admission before shutdown, stops the socket, clears its demand, and disconnects. The helper's independent deadlines and launchd startup cleanup remain backstops if daemon teardown fails. These mechanisms are not a guarantee against every kernel, hardware, supervisor, or power failure.

## Safety scheduling

Safety admission and lease mutation are checked together in the broker. Cutout latches persist across daemon restarts and cannot be overridden by another acquire. The provider uses optional fresh SMC readings plus macOS's public thermal state; missing readings do not masquerade as a fresh temperature.

Defaults: closed-lid battery cutoff 20% on battery, temperature cutoff 80 °C, and public serious/critical thermal states. Configurable thresholds remain bounded. Recovery uses hysteresis and repeated cooling observations; a missing sensor cannot clear a temperature-dependent latch. Each user daemon retires its own claims; the helper aggregates demand rather than choosing application safety policy for all users.

Maintenance arms the earliest relevant deadline. Incoming traffic cannot keep postponing expiry or recovery. Active closed-lid work checks at up to 15-second intervals; other live/cutout state at up to 30 seconds, or sooner for an actual lease deadline. No lease/cutout means that maintenance loop is disarmed. Wake and device notifications trigger reconciliation.

## IPC, persistence, and privacy

The versioned framed JSON contract is in [LEASE_PROTOCOL.md](LEASE_PROTOCOL.md). Both ends validate kernel UID/PID credentials. State lives under `~/Library/Application Support/WakeLease`, owned by the user and mode `0700`; the socket is `0600`. Descriptor-relative operations reject symlinks/hard-link surprises. Only macOS's known root path aliases are mapped to `/private`.

- `leases.json`: private recoverable registry, pause/control state and safety latches.
- `config.json`: versioned preferences, normalized within bounds.
- `events.log`: bounded local operational events using opaque lease UUIDs.
- `integrations/`: ownership receipts and private original-file backups.
- `cli-install.json`: exact ownership of the optional `~/.local/bin/wakelease` symlink.

Recovery validates boot identity, finite lifetimes, and owner identity before applying current policy. Corrupt registry/preferences are surfaced and admission is paused. Persistence is not the public protocol.

Reasons and keys are local user-visible data, not operational log fields. Do not put credentials, prompts, transcripts, repository paths or command contents in metadata. There is no telemetry or automatic update service. Same-user processes intentionally share a bounded lease API; this is not a sandbox against malware already controlling the account.

## Native UI and package layout

The new SwiftUI sources are in `WakeLeaseApp/`. Native controls expose leases, waiting, pause/release, settings, service status, and integration change previews. The UI distinguishes requested demand from confirmed protection. Its menu insertion binding ignores unchanged preference writes; a rendered-preview regression caught an otherwise unbounded SwiftUI menu-graph update loop.

The original icon is a stacked lease token/key, with no medication imagery or upstream artwork. The reproducible generator is `Scripts/generate-icon.swift`.

```text
WakeLease.app/Contents/
  MacOS/WakeLease
  Helpers/wakelease
  Library/LaunchAgents/{WakeLeaseDaemon,LaunchAgent.plist}
  Library/LaunchDaemons/{WakeLeaseHelper,LaunchDaemon.plist}
  Resources/{AppIcon.icns,LICENSE,UPSTREAM.md,WakeLeaseBuild.json}
```

Separate `MacOS` and `Helpers` directories avoid a case-insensitive `WakeLease` / `wakelease` collision. The SwiftPM UI product is correspondingly named `WakeLeaseMenu`. The Xcode project/scheme names retain upstream history, but the app source group and product/build identifiers are new. Both build paths target macOS 15.4; complete concurrency checking and hardened-runtime settings are retained.

Installation and removal are explicit user actions. Uninstall confirms cleanup before removing recovery services, then removes only recorded integration content and its owned CLI link. See [INSTALLATION.md](INSTALLATION.md), [THREAT_MODEL.md](THREAT_MODEL.md), and the [remaining verification gates](TESTING.md).
