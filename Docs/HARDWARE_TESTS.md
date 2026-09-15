# Supervised MacBook verification

This procedure changes real power behavior. Run it only on an explicitly approved test Mac with a coherent administrator-installed community build or authorized Developer ID build, and a recovery operator present. It is not executed by CI or ordinary unit tests. Do not run it over valuable unattended work, in a bag, or where losing a remote connection would prevent recovery.

An unapproved development build and `--simulate` cannot pass this matrix. The community package needs administrator-approved exact pins and explicit service approval, not paid Apple enrollment. A successful API result is not evidence that the closed Mac kept computing or actually slept. Neither are results from virtual machines or GitHub-hosted runners: the remote fixtures in [TESTING.md](TESTING.md) run on `VirtualMac2,1`-class VMs with no lid, battery, charger or thermal sensors, so every row below still needs this physical procedure.

## Record the environment

Record the exact app version, commit, architecture, installed component record (or signing team) and artifact checksum. Record only necessary hardware information; do not publish serial numbers, hardware UUIDs, account names or private logs.

Read-only platform commands:

```sh
sw_vers
uname -m
sysctl -n hw.model
wakelease version
wakelease doctor --json
wakelease status --json
pmset -g
pmset -g assertions
```

Record AC/battery state, battery charge, external displays/dock, thermal reading availability, configured waiting/lifetime/cutoff policies, and the initial `SleepDisabled` value. Resolve conflicting power utilities first. Leave ordinary macOS sleep timers unchanged.

## Prerequisites

1. Install the signed app through its native service flow. Verify approval, versions and applied-state reporting.
2. Read [RECOVERY.md](RECOVERY.md), keep local access available, and agree who may authorize recovery commands.
3. Confirm no valuable jobs or unrelated wake leases are running. Obtain separate consent for kill, logout, reboot, upgrade and removal cases.
4. Put the Mac on a ventilated hard surface. Keep the charger available.
5. Use a harmless finite job that records progress to a disposable local file, plus an independent observation channel if available. Do not add a second wake utility merely to keep that observation channel connected.

One possible supervised job, started from a disposable directory:

```sh
wakelease run -- python3 -u -c 'import datetime,time; [(print(datetime.datetime.now().isoformat(), flush=True), time.sleep(1)) for _ in range(180)]'
```

Redirect its output into that disposable directory if useful. Continued log timestamps alone are insufficient if they were produced after reopening the lid: corroborate with elapsed time, work progress and macOS sleep/wake history. A remote observer can help, but network disconnection alone does not establish sleep.

## Required matrix

| Case | Action | Required observation |
| --- | --- | --- |
| A — idle baseline | With no leases, leave the lid open and stop interacting for the configured macOS idle interval | WakeLease adds no requirement; ordinary sleep remains possible; `SleepDisabled 0` |
| B — open-lid work | Start the finite job with a confirmed lease and leave the Mac idle | Work progresses without system idle sleep; display may sleep for system-only work |
| C — standalone closed lid | With no external display, start confirmed work, then close the lid | Work advances while closed, on both AC and a separately supervised battery run |
| D — final release | Keep the lid closed through the finite job's completion | Final lease disappears, override clears, and macOS records actual sleep without reopening the lid; record timestamps |
| E — concurrent leases | Start two independently keyed finite jobs with different completion times, then close the lid | The first ending does not remove the second's applied protection or stop its progress |
| F — last concurrent lease | Let the second job finish with the lid still closed | The final transition clears WakeLease's requirement and permits prompt sleep |
| G — recovery | In separate, approved runs, kill only the WakeLease user daemon, then only the helper; test a restart with legitimate work and without work | No permanently stranded override; version/reconnect state is honest; abandoned claims expire and failed cleanup remains visible. Record interruptions rather than hiding them |
| H — battery cutoff | Use naturally available low battery or a permitted threshold near the current charge; disconnect AC only with approval | Closed-lid wake protection releases at cutoff, reacquisition is latched, and AC/charge hysteresis restores eligibility. Do not deliberately drain to shutdown |
| I — thermal cutoff | Observe ordinary supervised work with valid sensors and a conservative permitted threshold | Unsafe thermal input releases protection, cause is visible, repeated acquisitions do not bypass the latch, and cooldown/hysteresis apply. Never obstruct cooling or force overheating; leave unverified if safe conditions cannot exercise it |
| J — waiting | Use a unique lease, mark it waiting and keep the lid closed through its configured grace | Heartbeats do not reset grace; effective wake requirement ends on schedule; explicit resume/acquire reactivates work after waking |
| K — external-display desktop | Establish a normal external-monitor clamshell session, then finish WakeLease work | WakeLease does not forcibly destroy the legitimate desktop session; compare against the no-WakeLease baseline |

Observe actual system sleep/wake events after the run using macOS power logs. Keep evidence private and sanitize before sharing. Report exact timings and failures, not simply “seemed awake.”

## Additional lifecycle and security cases

- Test signed positive and negative peers: correct app/daemon roles and team, wrong role, wrong team, tampered executable and unsigned executable. Confirm unauthorized peers cannot reserve removal or set wake demand.
- Test fresh service denial/approval, login, logout, coherent update, interrupted update and rollback. Rebuild or restore whole matching bundles rather than mixing component versions.
- With two user accounts, verify one user's shutdown/cutout does not release the other's claim. Uninstall while the other has work must fail without interrupting it.
- Reserve uninstall with no other user's work, attempt a new claim from another account, and verify it is refused before applied protection. Restart the helper during reservation and repeat. Complete removal and verify ticket cleanup, or abort and verify exact-owner cancellation.
- Start overlapping same-user install/removal operations; the second must refuse the maintenance lock rather than cancelling the first transaction.
- Verify RootDomain/public sensor behavior on each target hardware generation. Missing readings must be reported as unknown, not safe fabricated temperatures.
- Verify keyboard-only use, VoiceOver labels, light/dark appearance, hidden-icon reopen, copy actions, confirmation dialogs and permission-denied errors with real windows.

## Result record

For each case record: artifact/commit, platform, prerequisite state, command/action, expected behavior, actual behavior, timestamps, ending power state, supporting evidence and pass/fail/unverified. Mark a case unverified when a safe test was not possible. Include failures and unexplained transitions as release blockers.

After every case, stop its test jobs, release only their leases, inspect doctor and `SleepDisabled`, and restore any explicitly changed WakeLease preferences. After a recovery/removal failure, retain the recovery mechanisms until the power state is confirmed. Never modify SIP, Gatekeeper, hibernation settings or unrelated launch jobs to make a test pass.
