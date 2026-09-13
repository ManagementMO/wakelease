# Installation and removal

No public WakeLease download, signing account, notarized release or Homebrew cask has been designated yet. This procedure describes the implemented path and the manual gates that a maintainer must validate before distribution.

## Install a production build

1. Build/obtain the exact team-signed bundle described in [RELEASING.md](RELEASING.md). Verify its provenance. Do not mix helper, daemon, CLI and app versions or signing teams.
2. Place the app in a stable location, normally `/Applications/WakeLease.app`. Avoid keeping multiple active copies. Launching the app alone does not register privileged services.
3. In General settings, choose **Enable WakeLease Services**. The app verifies its bundled role signatures before registering the root helper and user LaunchAgent with `SMAppService`.
4. Approve the background items in macOS System Settings → General → Login Items & Extensions when requested. A pending approval is not confirmed protection.
5. The installer creates only a receipt-owned `~/.local/bin/wakelease` link. It never overwrites a foreign file or silently edits your shell startup files. Add `~/.local/bin` to your preferred PATH configuration yourself if necessary.
6. Run `wakelease doctor` and review helper, state, signature/version and integration findings. Physical closed-lid validation is separate.
7. Preview and install only the integrations you want. Complete host-specific approval, especially Codex `/hooks`. See [INTEGRATIONS.md](INTEGRATIONS.md).

The CLI link is a human convenience. Generated integrations use the stable in-bundle CLI path so installer timing does not cause false configuration drift.

## What gets installed

- User LaunchAgent label `org.wakelease.daemon`, sourced from the app's `LaunchAgent.plist`.
- Root LaunchDaemon label/Mach service `org.wakelease.helper`, sourced from `LaunchDaemon.plist`.
- Optional main-app login item, controlled independently in settings.
- `~/.local/bin/wakelease`, only when the exact link is receipt-owned.
- Private per-user state under `~/Library/Application Support/WakeLease`.
- Only the selected, recorded host integration entries/files.

There is no sudoers rule, shared `/tmp` runtime socket, shell-rc alias, background updater or global process sniffer.

## Development is different

The source-testing commands in the README compile unsigned/ad-hoc executables. The packaged development shortcut is also ad-hoc-signed. These can exercise native previews and the simulation daemon, but production helper startup rejects them. Do not weaken the signing checks or install development launch plists to work around this.

A native preview uses `WakeLeaseMenu --preview active`; it is fixture data, has no daemon connection, and disables service-changing controls. The test suite launches simulation explicitly in private temporary directories.

## Upgrade and repair

Quiesce work before replacing an application bundle. Keep a verified prior artifact and the recovery instructions available. Replace the app as a coherent unit, retaining the same identity and team. Do not copy individual old/new helper binaries together.

The daemon checks the helper's version. Retained executable-staleness handling can relaunch an idle changed helper, but live signed in-place upgrade remains a release gate. If macOS background-task records are stale, use the owning app and Login Items UI to review that specific registration. Do not issue a system-wide `sfltool resetbtm`, remove unrelated launch records, or unlink services while sleep cleanup is unconfirmed.

An installed CLI symlink pointing to a different app path is treated as externally changed, not silently redirected. Review its ownership or use the original app's uninstall before creating a new link. Integration updates likewise require a preview and may require new host approval.

## Uninstall

From native General settings choose **Uninstall WakeLease**, or:

```sh
wakelease uninstall --dry-run
wakelease uninstall --yes
```

The ordered procedure is:

1. Require the owning packaged app and known registration context.
2. Pause admission and release this user's leases if services are enabled.
3. Require reported cleanup, no other user's helper claim, and a read-back of `SleepDisabled 0`.
4. Remove only recorded integration content. A modified plugin or foreign replacement is a conflict, not permission to delete it.
5. Unregister the user daemon, root helper and main-app login item.
6. Remove the exact receipt-owned CLI symlink and operational state/socket.
7. Optionally remove known preferences, logs and backups (`--purge`) and move this app to Trash (`--remove-app`). Unknown files are retained.

Without `--yes`, a terminal confirmation is required. Without `--purge`, preferences/logs/backups remain private for review. The app can remain on disk for later reinstall unless you choose Trash. Empty parent directories may remain; unrelated user files and shell configuration are not removed.

Removal changes a machine-global helper registration. Coordinate with every logged-in user: another user must not start new wake-requiring work between the cleanup check and service removal. The read-back is not a global transaction against future claims; live multi-user removal remains a release gate.

A failure stops the process and reports it. Earlier safe steps may already have completed; rerun after resolving the stated conflict. If power cleanup is unknown, recovery services are deliberately retained. Review [RECOVERY.md](RECOVERY.md)—do not force-delete them to make uninstall look successful.

After removal, inspect Login Items, the CLI link, selected host hook settings, and `pmset -g`. `SleepDisabled` should remain `0` when no other utility is intentionally controlling it. Do not claim clean removal solely from a zero exit code on an unverified platform.
