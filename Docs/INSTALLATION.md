# Installation and removal

The primary distribution path is a **no-membership community DMG**. It contains an administrator-approved pkg, not a drag-and-drop app. This is implemented engineering work, not a notarized or hardware-certified release. See [TESTING.md](TESTING.md) for the remaining live-product gates. No Homebrew cask is designated.

## Install the community build

1. Build/obtain the exact community DMG described in [RELEASING.md](RELEASING.md). Check the source, commit and SHA-256. No Apple Developer membership or custom trusted certificate is needed. A checksum does not authenticate a malicious download source.
2. Open **Install WakeLease.pkg** and approve administrator installation. If macOS blocks this non-notarized installer, use its per-item approval in Privacy & Security; never disable Gatekeeper globally. The package installs `/Applications/WakeLease.app` and a root-owned record of the exact approved app, CLI, daemon and helper code hashes. It does not start wake protection or register services.
3. Launch that app, then in General settings choose **Enable WakeLease Services**. The app verifies all four component roles and hashes before registering the helper and user LaunchAgent with `SMAppService`. Avoid multiple active copies.
4. Approve the background items in macOS System Settings → General → Login Items & Extensions when requested. An operation-not-permitted response accompanied by the actual `requiresApproval` state is presented as pending approval; other errors remain failures. Pending approval is never confirmed protection. Expect an administrator password prompt for the helper: on a disposable macOS 26 VM, a harmless dummy app with the same agent + daemon shape appeared as one grouped row ("2 items: 1 item affects all users") and switching it on asked for an administrator password, while a user-only agent needed no prompt (see [TESTING.md](TESTING.md)).
5. Service setup creates only a receipt-owned `~/.local/bin/wakelease` link. It never overwrites a foreign file or silently edits your shell startup files. Add `~/.local/bin` to your preferred PATH configuration yourself if necessary.
6. Run `wakelease doctor` and review helper, state, signature/version and integration findings. Physical closed-lid validation is separate.
7. Preview and install only the integrations you want. Complete host-specific approval, especially Codex `/hooks`. See [INTEGRATIONS.md](INTEGRATIONS.md).

The CLI link is a human convenience. Generated integrations use the stable in-bundle CLI path so installer timing does not cause false configuration drift.

An authorized Developer ID bundle remains supported as a separate path. Its components must share the verified Apple-anchored team and exact role identifiers. That optional signing/notarization route is not required by the community installer.

## What gets installed

- Community app at `/Applications/WakeLease.app`, plus `components.json` and the stable `trust.lock` under `/Library/PrivilegedHelperTools/org.wakelease/`. These approval files are root-owned, not user preferences. An incomplete package also leaves `installation.pending`, which prevents component authorization until repaired.
- User LaunchAgent label `org.wakelease.daemon`, sourced from the app's `LaunchAgent.plist`.
- Root LaunchDaemon label/Mach service `org.wakelease.helper`, sourced from `LaunchDaemon.plist`.
- Optional main-app login item, controlled independently in settings.
- `~/.local/bin/wakelease`, only when the exact link is receipt-owned.
- Private per-user state under `~/Library/Application Support/WakeLease`.
- Only the selected, recorded host integration entries/files.

There is no sudoers rule, shared `/tmp` runtime socket, shell-rc alias, background updater or global process sniffer.

## Development is different

The source-testing commands in the README compile unsigned/ad-hoc executables. The packaged development shortcut is also ad-hoc-signed, but does not create root-owned installation approval. It can exercise native previews and simulation, not authorize an unapproved privileged helper. The distinction is administrator-approved exact code, not merely whether `codesign` produced a signature. Do not weaken the checks or install development launch plists to work around this.

A native preview uses `WakeLeaseMenu --preview active`; it is fixture data, has no daemon connection, and disables service-changing controls. The test suite launches simulation explicitly in private temporary directories.

## Upgrade and repair

For a community update, finish/pause work, uninstall the existing services from the owning app, and quit WakeLease in every logged-in account before running the new package. Keep a verified prior complete artifact and the recovery instructions. The installer refuses registered/running helpers, running WakeLease processes, or a power state not confirmed as `SleepDisabled 0`; it does not stop work or alter power settings for you. Do not replace individual component binaries.

The package writes an admission marker before payload replacement, rechecks that services stayed idle, and publishes new root-owned code pins only after signature, exact-role/hash, hardened-runtime and entitlement verification. Recovery compares the complete component record, not just the source commit: rebuilding the same revision can produce different code hashes.

If Installer was interrupted, close it and run **Repair Interrupted Install.pkg from the same DMG**. It clears only the matching interrupted transaction, repeats preflight and reinstalls/verifies the complete payload. It refuses active services and unknown power state. Do not delete the marker manually or use a different build's repair package.

The daemon also checks the helper's version. Retained executable-staleness handling is not a substitute for the community upgrade procedure. Full live product update/approval remains a release gate. If macOS background-task records are stale, use the owning app and Login Items UI for that registration. Do not issue a system-wide `sfltool resetbtm`, remove unrelated launch records, or unlink services while sleep cleanup is unconfirmed.

An installed CLI symlink pointing to a different app path is treated as externally changed, not silently redirected. Review its ownership or use the original app's uninstall before creating a new link. Integration updates likewise require a preview and may require new host approval.

## Uninstall

From native General settings choose **Uninstall WakeLease**, or:

```sh
wakelease uninstall --dry-run
wakelease uninstall --yes
```

The ordered procedure is:

1. Require the owning packaged app and known registration context.
2. Ask the helper's separate, app-authenticated maintenance endpoint for a removal reservation. Any other user's live claim prevents it; the initiating user's claim is retired and new machine-wide wake claims are refused.
3. Persist the reservation before acknowledging it, pause this user's broker, require reported cleanup, and read back `SleepDisabled 0`.
4. Remove only recorded integration content. A modified plugin or foreign replacement is a conflict, not permission to delete it.
5. Unregister the user daemon, root helper and main-app login item.
6. Remove the exact receipt-owned CLI symlink, the matching component approval record and reservation ticket after helper unregistration, and operational state/socket. The root helper grants the initiating user delete—not write—permission for the approval record only after its removal fence and confirmed power clear.
7. Optionally remove known preferences, logs and backups (`--purge`) and move this app to Trash (`--remove-app`). Unknown files are retained.

Without `--yes`, a terminal confirmation is required. Without `--purge`, preferences/logs/backups remain private for review. The app can remain on disk for later reinstall unless you choose Trash. Empty parent directories and a zero-byte private `maintenance.lock` may remain; unrelated user files and shell configuration are not removed. Keeping that lock inode stable prevents overlapping same-user install/removal processes from cancelling each other's transaction. It contains no settings or wake state. For byte-for-byte removal, quit every WakeLease UI/CLI instance after service removal and remove the otherwise empty support folder in Finder.

Removal changes a machine-global helper registration. The helper-owned reservation closes the former check-then-remove gap: a new lease cannot acquire applied protection while removal is reserved, including after a helper restart. Existing work from another user causes reservation to fail rather than being interrupted. A failed uninstall cancels only its own transaction; an unconfirmed cancellation remains visible and requires **Enable WakeLease Services** from the owning app to restore admission. The user's broker stays paused until explicitly resumed.

The durable ticket is a root-owned file under `/Library/Application Support/org.wakelease.helper/`. The initiating UID receives only read/delete rights to that exact ticket, not write rights or permission to create directory entries. After services are unregistered the app removes its ticket; an empty root-owned parent directory can remain. Other users cannot cancel the transaction or edit its contents. Do not manually delete an active ticket while the helper is registered. ServiceManagement's real multi-user approval/removal behavior still requires installed-product live verification; independent administrator changes to registrations and competing power utilities are outside this transaction.

If the privileged helper was never approved, it cannot delegate approval-record deletion. Quit WakeLease and disable its background items, then run **Remove Installer Approval.pkg** from the DMG with administrator approval. It refuses active processes/services and unknown power state, and deletes only the protected approval record—not the app, integrations or preferences. Reopen WakeLease Settings to finish user-owned cleanup and optional Trash removal. A stable, empty `trust.lock` and root-owned parent folder can remain; they grant no identity without `components.json`.

A failure stops the process and reports it. Earlier safe steps may already have completed; rerun after resolving the stated conflict. If power cleanup is unknown, recovery services are deliberately retained. Review [RECOVERY.md](RECOVERY.md)—do not force-delete them to make uninstall look successful.

After removal, inspect Login Items, the CLI link, selected host hook settings, and `pmset -g`. `SleepDisabled` should remain `0` when no other utility is intentionally controlling it. Do not claim clean removal solely from a zero exit code on an unverified platform.
