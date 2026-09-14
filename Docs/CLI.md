# CLI reference

The public executable is `wakelease`. It talks to a same-user Unix-domain socket, not a network service. The [wire contract](LEASE_PROTOCOL.md) is independently versioned.

## Work lifecycle

```text
wakelease acquire KEY [--source NAME] [--reason TEXT] [--ttl DURATION]
                      [--pid PID] [--session ID] [--parent UUID] [--display] [--json]
wakelease renew KEY [--ttl DURATION] [--json]
wakelease heartbeat KEY [--ttl DURATION] [--json]
wakelease wait KEY [--reason TEXT] [--json]
wakelease release KEY [--strict] [--json]
wakelease release --all [--json]
```

Keys are literal and case-sensitive. Use a unique work ID for every concurrent unit. `source` labels the producer; it is not an authorization role. Parent UUIDs express a relationship, not cascading ownership.

Acquire creates or refreshes a lease and resumes a waiting lease. Renew/heartbeat extends its deadline but does not resume it or restart waiting grace. Wait uses the configured policy. Release affects only the matching key; a missing key is a successful no-op unless `--strict` is used.

Durations accept seconds or the duration parser's forms such as `30m` and `2h`. They must be finite and positive. Default lifetime is four hours and the maximum per renewal is 24 hours, subject to the current bounded preference. A PID is resolved to a live kernel process identity and checked against the socket user's UID.

System-only protection is the default. `--display` also requests a display assertion; it does not guarantee a physically useful display behind a closed lid.

## Wrappers and timed work

```text
wakelease hold [--for DURATION | --ttl DURATION] [--source NAME] [--reason TEXT]
               [--pid PID] [--parent UUID] [--display] [--json]
wakelease run [--source NAME] [--reason TEXT] [--parent UUID] [--display]
              -- COMMAND [ARGUMENTS...]
wakelease watch --pid PID [--source NAME] [--reason TEXT] [--parent UUID] [--display]
```

Hold generates and prints a full-UUID key. Release it early when finished. Omitting a duration uses the default finite lifetime.

Run acquires before starting the child and refuses to start if production protection is unconfirmed. Arguments are literal: use an explicit shell only if you want shell behavior. Inherited streams, interactive terminal behavior, process groups, signals and child status are preserved. The wrapper renews a 120-second process-bound lease every 30 seconds. A stopped job is marked waiting. A daemon/renewal failure warns but does not kill the job.

Watch protects an already-running process incarnation. It releases when that process exits or the watcher is cancelled. Cancelling the watcher never kills the watched job. Detached work that outlives its wrapper or parent turn needs an independent lease.

## Status and global controls

```text
wakelease status [--json]
wakelease doctor [--json]
wakelease pause [--json]
wakelease sleep [--json]
wakelease resume [--json]
```

- Status separates effective leases, desired demand, applied state, helper connectivity and errors. Simulation is visibly identified.
- Doctor is read-only and works even when the daemon is absent. It checks available power state, permissions/preferences, component versions, launch registration, CLI ownership, bundle context and integration health. It does not repair or certify hardware.
- Pause and sleep release current work and block new leases until resume. **`sleep` is not unconditional open-lid sleep.** It restores normal sleep policy and only the normal closed-lid final-release rules may request prompt sleep.
- Release-all clears current leases but does not pause future admission. It also sets a replay barrier against old work events.

Doctor JSON uses schema `version: 1`, a `mode`, `productVersion`, and `checks` with `id`, `level`, and `message`. Levels are `success`, `warning`, `failure`, and `skipped`; optional unconfigured integrations are not mandatory failures. Desired demand alone is not proof of actual wake protection.

## Integrations and local MCP

```text
wakelease integrations
wakelease integrations list
wakelease integrations preview NAME
wakelease integrations install NAME [--dry-run] [--yes]
wakelease integrations uninstall NAME [--dry-run] [--yes]
wakelease hooks generate --source ID [--session-variable VARIABLE] [--for DURATION]
wakelease hooks generate --interactive
wakelease hooks generate --source ID --json
wakelease mcp [--source NAME]
```

Applying integration changes needs interactive confirmation or `--yes`. Custom recipes can set `--display`, `--start-event`, `--stop-event`, and an executable-only `--executable` wrapper fallback. Use either `--for` or `--ttl`; lifetimes must be finite and at most 24 hours. `--interactive` requires a TTY and cannot mix prompts with JSON. JSON recipe version 1 describes commands, not an arbitrary host's configuration schema. Source IDs namespace generated work keys, so concurrent tools do not collide merely because their work IDs match. Generated hooks skip absent work IDs, suppress their own output and fail soft. The internal `hook` adapter command emits `{}` and exits zero on unavailable/malformed work so a wake utility cannot break the host's prompt/tool operation.

MCP is optional, local stdio, and explicitly version-limited. See [INTEGRATIONS.md](INTEGRATIONS.md) for tools, approval requirements, and evidence.

## Removal

```text
wakelease uninstall --dry-run
wakelease uninstall [--yes] [--purge] [--remove-app]
```

Actual service removal runs through the owning packaged app. It pauses admission and requires confirmed cleanup before unregistering services. `--purge` removes known local state, preferences, logs and backups; unknown files remain. `--remove-app` moves the application to Trash. Foreign or modified content stops cleanup rather than being deleted. A source checkout can disconnect its integrations but cannot pretend to unregister a missing app bundle.

## Development and output rules

`WAKELEASE_STATE_DIR` or `--state-dir` selects an absolute private directory for isolated CLI/simulation work. Production daemon startup refuses a nonstandard directory. Integration commands and doctor accept `--home` for an isolated configuration home; production uninstall deliberately requires the standard user location.

`--json` is machine output; do not scrape human status prose. Reasons are optional local text. Never put credentials, prompts, transcripts or full commands in keys/metadata. Unknown versions/operations/options fail rather than being guessed.

Exit codes for ordinary CLI commands: `0` success, `1` operational failure or strict missing release, `2` usage error. Doctor returns `1` if any check is a failure. Run preserves the child's exit status, including signal-derived status. The generated adapter `hook` command intentionally remains fail-soft. Development daemon/helper startup refusal uses exit `78`.

A timeout has an unknown outcome: query the key before assuming no lease exists. The broker may have accepted the mutation before the reply was lost.
