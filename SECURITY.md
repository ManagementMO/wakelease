# WakeLease security policy

WakeLease includes a root LaunchDaemon that changes machine-global sleep behavior. A stranded sleep override is security-relevant, not just an inconvenience. This is a pre-release derivative of Adrafinil; see [UPSTREAM.md](UPSTREAM.md).

## Reporting

A WakeLease public repository and private security contact have **not yet been designated**. A public release is blocked until the maintainer enables private vulnerability reporting or publishes a monitored private contact.

For an engineering build, contact its distributor through the private channel used to obtain it. Do not publish exploit details, user configuration, prompts, transcripts, tokens, or private logs in an issue. Do not send WakeLease-only reports to Adrafinil's maintainer as though the projects were the same product. If a minimal reproducer also affects unmodified upstream, coordinate an appropriately scoped upstream report.

Include the build commit/version, macOS version, architecture, sanitized doctor findings, expected/actual behavior, and a safe reproducer. State whether a result came from fixtures, simulation, a signed build, or physical hardware. No response-time commitment is claimed before a reporting team exists.

## Important boundaries

- Only the exact Apple-anchored, team-matching daemon role may call the helper. There is no unsigned production fallback.
- The helper accepts fixed mechanical operations, not commands, paths, environment variables, or arbitrary privileged arguments.
- The user-only socket checks kernel peer credentials. Process ownership includes UID and birth identity, not just a reusable PID.
- Finite lifetimes, waiting semantics, stale-event barriers, capacity bounds, and cutout latches limit abandoned or replayed work.
- Cleanup failure is observable and retried. Connected-but-wedged daemon claims expire independently of XPC disconnect.
- Configuration writers preserve foreign entries and require ownership receipts for plugin/CLI removal.
- No telemetry, cloud account, or automatic update feed operates in the runtime.

The full [threat model](Docs/THREAT_MODEL.md) includes remaining risks. Same-user malware can already edit that user's files and invoke the intentionally open bounded lease API. Root compromise is outside the model.

## Safety and recovery

Never run physical sleep tests on critical work or a Mac in an enclosed bag. Do not run competing `disablesleep` utilities. `doctor` is read-only, and a successful build or IOPM call is not closed-lid certification. Read [RECOVERY.md](Docs/RECOVERY.md) before testing.

Do not remove the helper/launch registration while a persistent override is unconfirmed. The supported uninstaller pauses admission and requires confirmed cleanup first. If cleanup cannot be confirmed, it stops and retains recovery mechanisms.

## Supported builds

There is no certified public release yet. Maintainers should reproduce defects on the current engineering branch and isolate inherited fixes where possible. Signing, service approval, in-place upgrade, clean removal and physical recovery must be validated before declaring a supported release.
