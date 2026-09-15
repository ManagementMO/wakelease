# Sleep recovery and physical-test precautions

These are operator instructions, not commands to run automatically. Normal tests use simulation and fake controllers. `disablesleep` is machine-global and can persist through a crash or reboot; an API return is not a physical-sleep guarantee.

## Before a physical test

- Obtain explicit permission for that Mac and test. Save work and stop irreplaceable jobs.
- Keep the lid open initially, use AC power, and keep the computer on a ventilated surface.
- Do not run another utility that controls clamshell sleep. Record baseline `pmset -g` and `pmset -g assertions` output.
- Have a local administrator and this procedure available. Remote-only access may disappear when the test succeeds and the Mac sleeps.
- Use a short finite test lease and a harmless observable workload, not an indefinite production task.
- Never use a sealed bag as a thermal test fixture and never deliberately overheat or deeply discharge hardware.

## First response to unexpected awake state

1. Open the lid and reconnect AC. Keep the machine ventilated.
2. Run `wakelease status --json` and `wakelease doctor`. Do not publish raw private state or user reasons.
3. Deliberately allow sleep with `wakelease pause`. This releases current work and blocks new acquires. `release --all` alone does not block future work.
4. Read `pmset -g` and inspect `SleepDisabled`. Check `pmset -g assertions` for other applications. Do not clear another utility's intentional work by guessing that every assertion belongs to WakeLease.
5. If the daemon was lost, its helper claim has a 60-second disconnect grace and a 90-second heartbeat deadline. Cleanup itself can still fail; waiting is not proof. Read the state again and inspect the reported failure.

Normal clear failures stay visible and retryable. The helper clears stale persistent state at startup and on termination. Do not unregister or delete the helper merely because the UI is unavailable; that can remove the recovery mechanism.

## Interrupted community installation

The community installer creates a protected admission marker while replacing files. An incomplete or mismatched package intentionally leaves services unauthorized; this is not fixed by editing the code-hash record.

1. Keep the lid open, confirm no active WakeLease services/work, and quit the failed Installer process and WakeLease in every logged-in account.
2. Open **Repair Interrupted Install.pkg from the same DMG**. Approve the administrator request. Repair checks that the full component record matches the pending transaction, repeats idle checks, and reinstalls/verifies the complete bundle before restoring authorization.
3. If repair reports active services, an unknown power state, or a different pending build, stop and resolve that specific condition. Do not delete `installation.pending`, change its ownership, disable Gatekeeper, or copy individual binaries to force acceptance.
4. After successful repair, enable and approve services from the app, then check doctor and applied protection. Repair itself does not start wake protection.

If services were never approved and you want to remove the unused installation approval instead, quit WakeLease and disable its background items, then use **Remove Installer Approval.pkg**. It refuses active processes/services or unknown power state. It removes only the protected approval record; reopen the app to finish ordinary user-data cleanup and optional Trash removal. See [INSTALLATION.md](INSTALLATION.md).

## Interrupted removal

`doctor` reports persisted helper removal separately from ordinary power state. A valid reservation intentionally denies new wake claims, including after helper restart; it never means `SleepDisabled` should stay enabled.

1. Use the same user account and a coherent, installer-approved or Developer ID-signed WakeLease app.
2. Either retry uninstall, or choose **Enable WakeLease Services** to cancel that user's pending reservation and restore service availability.
3. Resume the user broker explicitly if it remains paused. Confirm doctor/applied protection before relying on new work.
4. If another account owns the reservation, ask that user to complete or restore it. Do not cancel another user's transaction.

A malformed or inaccessible root ticket is not treated as an absent ticket. Preserve the error and get administrator assistance; do not delete live reservation files to silence doctor. During a successful uninstall, narrowly delegated read/delete permissions allow the initiating account to remove its root-owned ticket after helper unregistration. The parent directory is not writable by that account, and a stable zero-byte per-user maintenance lock can remain to prevent concurrent management races.

## Manual administrator recovery

Use this only after confirming that you intend to cancel wake protection and no legitimate competing utility owns the global override. It may interrupt local work.

First stop new producers and, if the user daemon cannot be paused, unload **only your own** WakeLease agent:

```sh
launchctl bootout "gui/$(id -u)/org.wakelease.daemon"
```

Allow the helper's claim deadline/cleanup path to run and check its state. If an explicit administrator reset is needed:

```sh
sudo /usr/bin/pmset -a disablesleep 0
/usr/bin/pmset -g
/usr/bin/pmset -g assertions
```

The operator, not an automated agent, runs this and supplies any requested administrator authorization. Confirm `SleepDisabled 0`; do not infer success from the absence of shell output. A competing daemon or utility can set it again, so resolve the writer rather than repeatedly toggling it.

Do not reset all power preferences, change `hibernatemode`, unload unrelated jobs, or disable SIP/Gatekeeper. If a root subprocess or the system power service is wedged, retain evidence and seek platform/administrator assistance. A reboot alone is not proof that a persistent override was cleared.

Once normal power behavior is verified, use the guarded uninstaller or re-enable the coherent approved app through ServiceManagement. Never repair production by removing XPC identity checks or trusting a user-writable pin record.

## What a passing physical result means

For each test, record hardware, macOS version, power source, external-display state, exact artifact commit/signature and starting/ending power state. Observe actual job progress while the lid is closed and actual sleep after final release. Record cutout and recovery behavior separately.

A passing test on one Mac/OS is scoped evidence, not a guarantee for every model. Safety sensors and watchdogs do not make closed-lid computing safe in an enclosed bag.
