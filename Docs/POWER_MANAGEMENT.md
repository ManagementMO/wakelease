# Power-management contract

WakeLease removes its own wake requirement when effective work reaches zero. That is not a promise that macOS must sleep despite user activity, an external-display desktop session, another program's assertion, or administrator changes. Physical closed-lid results must be recorded for each supported platform; no WakeLease hardware certification is claimed by unit tests or source publication.

## Demand and confirmation

```text
work producers -> finite leases -> effective demand -> serialized writer
                                                       |
                                          authenticated root helper
                                                       |
                                             assertions + pmset
```

- Every effective system or display lease contributes to system demand.
- Only an effective display lease contributes to display demand.
- Another live lease prevents final release. Parent and child leases are independent.
- Waiting work contributes according to the selected policy and its original grace deadline. The default grace is ten minutes; repeated waits and heartbeats do not restart it.
- The default lifetime is four hours; no renewal grants more than 24 hours. An opted-in keep-awake waiting policy is still bounded by the lease deadline.
- Ownership includes UID and kernel process birth identity. A dead/reused PID is not an owner.

Requested demand and confirmed applied protection are separate states. `wakelease run` waits for confirmation before starting its child. A fail-soft third-party hook may allow its host to continue without protection; users must not interpret host success as a successful lease acquisition.

## Why an assertion is not enough

The helper retains upstream's two-part mechanism:

| Mechanism | Purpose | Lifetime |
| --- | --- | --- |
| `kIOPMAssertPreventUserIdleSystemSleep` | Prevent idle system sleep | Kernel releases it when its owning process exits |
| `/usr/bin/pmset -a disablesleep 1` | Retained upstream mechanism for standalone closed-lid operation | Persistent machine-global preference; requires explicit cleanup |
| Display and user-activity assertions | Explicit display-class requests only | Released independently from system demand, including the auxiliary assertion |

Ordinary `caffeinate`/IOPM idle assertions do not establish standalone closed-lid reliability. WakeLease does not substitute a private API merely because it returns success. Upstream's experiments are described in [ARCHITECTURE.md](ARCHITECTURE.md); they are provenance, not certification of this derivative.

The helper executes only fixed argument vectors with a sanitized environment. No caller supplies a privileged executable, path, environment or arbitrary power-setting argument. A `pmset` operation has a ten-second subprocess deadline, bounded captured output, termination/kill/reaping, and a subsequent read-back. An unreapable child causes helper exit so launchd can clean up the process group.

## Final effective lease

The broker derives demand; integrations do not directly toggle the helper. On an effective `1 -> 0` transition, the reconciler:

1. Records the new generation and release intent.
2. Plays the optional configured cue when appropriate.
3. Revalidates that no new demand superseded the release.
4. Releases display/user-activity assertions and this user's helper requirement.
5. Requires the power layer to confirm cleanup; failures remain visible and retryable.
6. Optionally requests prompt sleep only when the conditions below still hold.

A lease arriving during the cue cancels a queued clear. A lease arriving during an already-running clear is reconciled again to the newest demand; a stale asynchronous callback is not the source of truth.

Prompt sleep requires a known closed lid, known absence of an external display, no remaining helper-global claim, no conflicting public power assertion, and a still-current zero-demand state. Unknown display/lid state does not cause forced sleep. An open-lid final release never means unconditional immediate sleep. Failure of a sleep request does not re-enable a cleared override.

`wakelease sleep` deliberately pauses admission and restores ordinary policy; it does not forcibly sleep an actively used open-lid Mac. `wakelease resume` explicitly permits new leases.

## Crash and stale-state recovery

- Helper startup attempts to clear a stale persistent override before accepting new work.
- Graceful helper/daemon shutdown attempts bounded cleanup.
- A disconnected daemon gets at most a 60-second helper grace. A connected-but-wedged daemon loses its claim after 90 seconds without renewal.
- Per-user aggregation prevents one user's disconnect from dropping another user's live claim.
- Failed clears retain their error/applied state and schedule reconciliation. New traffic cannot postpone an already armed safety/retry deadline.
- A wake event rechecks owners, hazards and current demand, then reapplies protection if still warranted.
- Continuous-clock deadlines include time asleep and are not extended by wall-clock rollback. Reboot identities and persistence validation prevent stale work from being resurrected blindly.
- Corrupt lease/preferences state pauses admission. Corrupt removal state also denies new helper wake claims instead of assuming it is safe to proceed.

These are recovery mechanisms, not a claim that software can recover while macOS itself is frozen, powered off, or unable to run the helper. Do not run another utility that writes `disablesleep` concurrently: that global preference has no transactional per-application ownership API.

## Battery and temperature

With the lid closed, work admission and periodic safety sampling apply:

- Battery cutoff defaults to **20%**, configurable from 10% to 50%. On battery at/below the threshold, effective leases are removed and acquisition is latched off. AC power or charge at least five percentage points above the threshold clears the battery latch.
- Thermal cutoff defaults to **80°C**, configurable within 70–95°C. A valid temperature at/above the threshold, or public `.serious`/`.critical` thermal state, triggers a thermal cutout.
- Thermal recovery requires nominal/fair public state and, when temperature caused the cutout, a fresh reading at least five degrees below the threshold. Safe conditions must persist for 60 seconds. Missing sensor readings do not clear a temperature-dependent latch.

The public thermal state is retained alongside the optional SMC temperature provider; stale temperature is not presented as a fresh sample. Latches and cutout reasons survive daemon recovery and are visible on return.

**Never put an actively running closed-lid Mac in a sealed or unventilated bag.** A temperature sensor and a software cutout are not ventilation, fire protection, or a hardware safety certification.

## Removal is an admission transaction

A signed app uses a separate, app-only maintenance endpoint. The helper refuses reservation while another user has an active claim, retires only the initiating user's claim, closes new admission, and persists a root-owned transaction ticket before acknowledgment. That fence survives helper restart. The app then pauses its broker, confirms `SleepDisabled 0`, removes owned configuration and unregisters services.

The initiating UID can read/delete only its ticket, not modify its bytes or create root-directory entries. The ticket is removed after helper unregistration. Cancellation matches UID and transaction; stale cancellation cannot reopen a newer reservation. Same-user install/removal shares a stable private lock. A failed rollback remains an actionable error, not a reported success. See [INSTALLATION.md](INSTALLATION.md) for retained empty locking artifacts and [RECOVERY.md](RECOVERY.md) for interrupted removal.

## Evidence

Use [TESTING.md](TESTING.md) to distinguish automated/fake-controller evidence, real filesystem/IPC checks and the remaining physical MacBook matrix. Inspect `wakelease doctor`, `wakelease status --json` and read-only `pmset -g` output before relying on a newly installed build. No automatic test in this repository is authorized to alter a developer Mac's sleep preferences.
