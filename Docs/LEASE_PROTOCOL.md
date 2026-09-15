# Local lease protocol — version 1

Development status: the generic broker, local transport, CLI, simulation daemon and production power-controller path are implemented and compile. Real power control requires services authenticated by administrator-installed exact code pins or a matching Apple-issued team, plus ServiceManagement approval. Full installed-product boundary tests and physical sleep certification remain separate release gates; paid Apple enrollment is not required for the community package. A successful **simulation** lease changes no macOS power setting and holds no IOPM assertion.

## Contract

Keys identify independent work units. They are literal, case-sensitive UTF-8 strings; the broker does not prepend a tool name. Choose a distinct key per concurrent work unit. `source` is a display label, not an authorization role. A parent lease UUID records a relationship, never a cascading lifetime.

```sh
wakelease acquire build:42 --source build --reason "release build" --ttl 7200
wakelease renew build:42
wakelease wait build:42 --reason "waiting for approval"
wakelease acquire build:42 --source build
wakelease release build:42
wakelease status --json
```

- `acquire`: create or refresh a lease; reacquiring a waiting lease resumes it. Duplicate acquisition preserves its UUID, original start time and any display requirement.
- `renew` / `heartbeat`: extend the finite deadline and update the heartbeat. A heartbeat **does not resume** a waiting lease or restart its grace period.
- `wait`: mark waiting for a person. Default grace is 600 seconds; a shorter lease deadline still wins. Duplicate waits do not extend the grace.
- `release`: remove only that key. Repeated release is a successful no-op with `changed: false`. The CLI reports the no-match; `--strict` makes it exit nonzero.
- `release --all`: clear current leases and reject delayed acquisitions issued before the reset. It does not pause new work.
- `pause` / `sleep`: clear leases and block admission until `resume`. The current CLI `sleep` is an allow-sleep/pause operation, not an unconditional open-lid sleep command.
- `hold --for 2h`: mint a full-UUID key and acquire a timed lease. The key is printed to stdout.
- `run -- command args...`: acquire before spawning; pass an argv array, inherit terminal/streams, forward signals, preserve the command's exit status, and release on return. The wrapper binds to the child process and renews every 30 seconds against a 120-second lease. A stopped job is marked waiting. Work detached from that command needs its own lease.
- `watch --pid N`: bind to a verified live process incarnation, renew while watching, release on exit or cancellation. Cancelling the watcher does not signal the watched job.

Default lease TTL: four hours. Absolute per-renewal ceiling: 24 hours. Timed holds are finite too. The waiting keep-awake policy does not override the lease's finite lifetime. Processes which need longer protection must renew while work continues.

## Transport and trust

No IP listener exists. The socket is `~/Library/Application Support/WakeLease/cli.sock`, mode `0600`, inside a user-owned `0700` directory. Development may select another private directory with `WAKELEASE_STATE_DIR` or `--state-dir`.

Both ends validate kernel peer credentials (`getpeereid`, `LOCAL_PEERPID`). Only the daemon's UID is admitted. A same-user client may request a bounded lease; it cannot select a privileged command or extend the helper API. A claimed owner is checked against the live kernel process identity and authenticated UID.

The daemon holds an exclusive file lock before replacing a stale socket. A second daemon does not unlink the first one's socket. Foreign regular files and symlinks are refused. Directory traversal uses directory descriptors and `O_NOFOLLOW`; only macOS's root aliases `/var`, `/tmp`, `/etc` are mapped to their `/private` counterparts.

Frames are:

```text
4-byte unsigned big-endian byte length | UTF-8 JSON body
```

Request bodies are limited to 65,536 bytes; replies to 2 MiB. Empty/oversized/partial frames are rejected. Nonblocking descriptors, absolute I/O deadlines, SIGPIPE suppression and a 32-client admission limit bound malformed or stalled clients. One request/reply is exchanged per connection.

## Request

```json
{
  "version": 1,
  "requestID": "490b7d2c-590c-4274-9b65-2856b88c8282",
  "operation": "acquire",
  "bootID": "CURRENT-KERNEL-BOOT-UUID",
  "issuedAt": 12345.25,
  "key": "build:42",
  "source": "build",
  "sourceKind": "custom",
  "reason": "release build",
  "wakeClass": "system",
  "ttlSeconds": 7200
}
```

`bootID` and `issuedAt` in this example are explanatory values, not values to paste into a live request. Mutations require the current `kern.bootsessionuuid` and issue time in **seconds of `mach_continuous_time` converted with `mach_timebase_info`**. Use the CLI unless implementing a native client. Continuous time advances across system sleep; wall-clock corrections cannot extend a deadline.

Read-only operations: `status`, `doctor`, `ping`, `settings`. Mutations: `acquire`, `hold`, `renew`, `wait`, `release`, `releaseAll`, `pause`, `resume`, `configure`.

`settings` returns a versioned `preferences` object. `configure` supplies that object as the optional request `preferences` field and requires the same boot/time metadata as other mutations. Preferences are normalized, atomically saved, and applied to existing waits/lifetime bounds. Unsupported preference versions are rejected. Administrative configuration ordering is bounded within the running daemon; it is not an exactly-once transaction across a crash. The CLI's expanded `doctor --json` report is a separate read-only presentation over protocol status and local observations.

Optional fields: `owner`, `sessionID`, `parentLeaseID`, `metadata`. Owner shape:

```json
{"pid": 12345, "uid": 501, "startSeconds": 1789250000, "startMicroseconds": 123456}
```

These are kernel process birth fields (`PROC_PIDTBSDINFO`), not a client-selected timestamp. A raw PID alone is not an ownership claim. An unverifiable/dead/reused owner is rejected. The daemon periodically revalidates ownership.

Bounds: key/session ID 256 UTF-8 bytes, source 64, reason 512. Control characters are rejected. Metadata is limited to 16 entries, each with a 64-byte key and 256-byte value. Do not send prompts, transcripts, command contents, source code or credentials. Reasons are optional user-visible text stored locally; operational events use opaque lease UUIDs rather than reasons or keys.

## Ordering and idempotency

Capture the issue time before dispatching an operation, and reuse it for retries. A mutation older than 120 seconds, from another boot, or over one second in the future is rejected. Never recompute an old event's issue time to evade replay checks.

Per-key revision records prevent a delayed acquire/renew/release from overwriting a newer lifecycle event. Release wins an equal-timestamp tie. Replaying the same acquire does not extend its deadline. Recent terminal records are bounded; capacity exhaustion fails closed rather than forgetting still-valid replay protection. Global controls have their own persisted ordering record, so replaying `releaseAll` cannot release subsequent work and a stale `resume` cannot undo a newer pause.

No broker can infer ordering that a producer never communicates. Prefer per-turn IDs (for example Cursor's generation ID or Codex's turn ID). If a producer queues an old hook before starting the CLI, include a distinct work key or retain its original issue time in a native client; a fresh CLI invocation cannot know that an event was already stale upstream.

## Reply and status

Replies contain `version`, `requestID`, `ok`, and optional `error`, `changed`, `lease`, `status`. Errors have stable machine-readable `code` and human-readable `message` fields. Unknown versions are rejected as `unsupported_version`; unknown operations as `unknown_operation`.

A status contains:

- `protocolVersion`, product `version`, and `mode` (`simulation` is explicitly non-operational power control).
- `snapshot`: daemon instance UUID, kernel boot UUID, monotonic generation, leases, effective count, derived system/display demand, pause state, cutout latches and safety readings.
- `power`: last reported applied demand, helper connectivity and any application error. **Desired demand is not proof that macOS power protection was applied.**

Dates on the wire are ISO 8601 UTC; deadline calculations use continuous time. Status snapshots are ordered only within a single daemon instance. Clients must not overwrite a newer generation with an older one. Persisted private state is not the public protocol.

A transport timeout has an **unknown outcome**: the daemon may already have committed the mutation. Query the client-chosen key or retry with the same ordering data; do not assume failure means no lease exists. TTL, process revalidation and explicit cleanup bound abandoned requests.

## Evolution

Additive optional fields may be added within version 1. Clients ignore unknown response fields. Unknown enum values or operations are not silently guessed. A semantic change requires a new protocol version and an explicit compatibility path. Keep JSON fixtures and end-to-end CLI tests when evolving this contract.
