# WakeLease threat model

Status: pre-release engineering requirements. This document is not a security certification. Imported Adrafinil code is being evaluated against these requirements; a release must close the gaps listed below.

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
| Helper caller spoofing | Apple-anchored signing requirement, exact daemon identifier, same signing team; reject unsigned helper execution | Real signed positive/negative XPC tests |
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

## Release-blocking audit findings in the imported baseline

1. Failed clamshell clearing is swallowed and reported as unblocked; the daemon retry path only retries `true`.
2. A queued false transition can execute after an acquire arrives during a pre-sleep cue. Reconciliation can overlap the stream consumer.
3. Helper authorization permits an identifier-only fallback when ad-hoc signed, and prefix matching is broader than an exact component role. The helper plist also contains an upstream-specific team identifier.
4. Socket clients supply unverified owner PIDs; process restoration compares executable substrings rather than process birth identity.
5. Configuration writes follow symlinks and do not create backups. Filename/substr ownership is insufficient for uninstalling modified or foreign content.
6. Cutout latch state is not persisted, and some thermal failures reuse stale readings.

These findings must be reproduced where testable, fixed, and linked to regression tests before the project can be called public-release-ready. Unit tests alone cannot certify the signing boundary or physical closed-lid behavior.
