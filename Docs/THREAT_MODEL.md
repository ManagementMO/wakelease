# WakeLease threat model

Status: pre-release. The controls below are implemented and regression-tested where safely testable. This is not a security certification: live signed-peer tests, a signed app build, and physical MacBook recovery/sleep tests remain release gates.

## Assets and trust boundaries

The primary asset is normal macOS power management. A stranded `disablesleep=1` can drain a battery or keep a closed laptop computing in an unsafe location. Other assets are the user's configuration, process isolation, and local metadata.

```text
untrusted same-user producer -> unprivileged CLI -> user-only socket
                                                -> lease broker
                                                -> authenticated XPC
                                                -> tiny root helper
                                                -> fixed macOS power operations
```

The UI and hooks never run as root. No producer can supply a privileged executable, shell command, file path, environment, or arbitrary `pmset` argument. The helper is not a general command runner.

Threat actors include other local users, arbitrary same-user processes, untrusted hook input, compromised third-party configurations, malformed clients, and crashes at any boundary. A process already running with the user's privileges can request a bounded lease; this is the intentional integration contract, not authorization to elevate privileges. Root compromise is outside this model.

## Required controls

| Threat | Control | Required verification |
| --- | --- | --- |
| Helper caller spoofing | Apple-anchored signing requirements, exact daemon role for wake control and exact app role for separate maintenance, same signing team, kernel XPC UID; reject unsigned helper execution | Real signed positive/negative XPC tests |
| PID spoofing/reuse | Obtain socket UID/PID from kernel; validate owner UID and process start identity, not just `kill(pid, 0)` | Fake reuse tests and real process-exit integration tests |
| Socket replacement | Private owned directory, no symlink following, singleton lock, socket mode 0600; verify peer credentials on both ends | Foreign file, symlink, second-daemon tests |
| Framing/flooding | Bounded frames, absolute I/O deadlines, limited concurrent clients, structured protocol errors, SIGPIPE handling | Partial/malformed/oversized/disappearing client tests |
| Stale lifecycle events | Idempotency and ordering metadata; finite leases and bounded tombstones | Release-before-acquire and expiry/renew races |
| Stale asynchronous unblock | One serialized power writer; recheck current generation after cue/reconnect; no obsolete completion may commit current state | Delayed-controller deterministic tests |
| Root subprocess hangs | Fixed absolute executable/argv, sanitized environment, bounded output, deadline, terminate then kill and reap | Injected hanging subprocess, never real `pmset` in tests |
| Stranded persistent override | Startup cleanup, shutdown cleanup, renewable helper dead-man deadline, retries on failed clear, reconciliation while needed | Mock failures, restart tests, physical recovery checklist |
| Hazard/reacquire race | Admission and cutout state atomic in the broker; persistent latch; hysteresis; unknown readings cannot clear a hazard | Battery/thermal/heartbeat race tests |
| Config overwrite/injection | Parse supported formats, preserve foreign entries, restrictive backups, atomic replacement, receipt ownership, no unapproved symlink traversal | Temporary-home round trips and external-edit conflicts |
| Wrapper injection | Direct argument vectors, inherited descriptors, correct job control/signals, exact exit status | Quoting, Unicode, TTY, signal, child-process tests |
| Supply-chain update | No automatic updater until a signed release channel is designated and reviewed; never consume Adrafinil releases as WakeLease updates | Artifact provenance and signed update tests |
| Sensitive logs | No prompt, transcript, source, command, repository, session-path, or reason logging; local bounded operational events only | Logging review and fixture checks |

## Safety is not a thermal guarantee

WakeLease cannot make a laptop safe in a sealed bag. Keep an actively computing Mac on a ventilated surface. Public macOS thermal state is a coarse safety signal, not a thermometer or guarantee. SMC readings are supplementary, hardware-dependent, and must not be presented as a stable public sensor API. Missing sensors must be visible.

External-display clamshell use is a distinct situation. On the final lease, restore normal power management. Request prompt sleep only with a confirmed closed lid, confirmed absence of external displays, and evidence that WakeLease was maintaining the wake condition. Unknown display/lid state must not cause forced sleep. A safety cutout may interrupt work; it must not disable macOS's own protection.

## Imported findings and regression status

1. **Failed clear reported as success:** reproduced in `SleepBlockPolicyTests`; clearing now throws, incomplete startup cleanup is observable, and `LeasePowerReconcilerTests` proves zero-demand retries remain active.
2. **Acquire during pre-sleep cue / unblock:** deterministic delayed-controller tests prove the stale queued clear is cancelled or followed by the latest true state. A command wrapper waits for confirmed protection before starting its child.
3. **Unsigned/prefix authorization:** production helper startup refuses unprivileged/unsigned execution. Foundation enforces an Apple-anchored exact daemon requirement before consulting the listener delegate; the client pins the helper. Pure requirement/decision tests and unsigned-execution refusal tests pass. Real signed positive/negative tests are still required.
4. **PID reuse / corrupt recovery:** owners use kernel process birth identity and peer UID. Renewal rechecks owner liveness; recovery drops invalid lifetimes and identities. Unit and CLI process-exit tests cover these paths.
5. **Unsafe integration ownership:** receipt-backed installers refuse symlinks, unknown plugin ownership and modified owned files. Temporary-home tests cover byte-exact restoration, permissions, backups, foreign settings and foreign empty hook groups.
6. **Lost cutout state / stale readings:** latches persist; the production provider uses fresh optional SMC readings plus public thermal state rather than presenting cached temperatures as current. Provider failure cannot clear a temperature-dependent latch.
7. **Leaked display user-activity assertion:** final release clears both assertion slots, retains failed releases for retry, and is covered by `SafetySchedulingTests`.
8. **Daemon remains connected but wedged:** helper claims expire after 90 seconds without a set request, independently of a 60-second disconnect grace. Per-user aggregation preserves another user's live claim and rejects callbacks from replaced connections.
9. **Acquire during uninstall:** removal now reserves admission on the helper's serial executor, refuses another user's existing claim, retires only the initiator's claim, persists a root-owned ticket before acknowledgment, and rejects new claims even after helper restart. Cancellation requires the same UID and transaction. The exact ticket grants its initiating UID read/delete but not write/create rights, allowing cleanup after service removal without a generic privileged filesystem API. Failed rollback remains visible; unit and disposable filesystem fixtures exercise the boundary. Signed ServiceManagement execution remains a release gate.

Safety maintenance uses earliest-deadline scheduling: incoming traffic cannot postpone an already armed sweep or failed-cleanup retry. Root subprocesses inherit launchd's process group; a child that cannot be reaped causes the helper to exit for supervisor cleanup rather than issuing a competing newer setting.

## Remaining release gates and boundaries

- Live code-signing tests must exercise valid peers, different teams, wrong identifiers, unsigned peers, in-place updates and registration approval. Unit strings are not evidence of OS enforcement on a shipped signed artifact.
- Hardware tests must verify closed-lid work, final release, helper/daemon crashes and external displays. Successful IOPM or `pmset` calls alone do not certify physical behavior.
- `disablesleep` is machine-global. Do not run competing closed-lid utilities. Each daemon's cutout retires that user's claims; concurrent users independently monitor the same machine. The helper aggregates mechanical demand without choosing user safety policy.
- Immediate sleep is attempted only after this daemon's protection is removed, with a known closed lid, known absence of external displays, no remaining helper-global claim, and no conflicting public power assertions. The API also requires root or the console user; failure leaves ordinary sleep restored and is reported.
- Same-user malware can invoke the intentionally open bounded lease API and can already edit that user's files. Receipts and permissions protect accidental/external changes and other users; they are not a new sandbox against a process fully controlling the account.
- Config updates use a cooperative lock plus input comparison. Noncooperating external writers can still race a filesystem replacement; avoid simultaneous edits and inspect reported conflicts.

No physical sleep operation, privileged registration, production signing, or publication has been performed during automated verification.
