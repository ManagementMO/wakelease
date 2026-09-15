# Release procedure

This is a maintainer-run procedure for [ManagementMO/wakelease](https://github.com/ManagementMO/wakelease). GitHub private vulnerability reporting is enabled. The primary path is a no-membership, administrator-approved community pkg distributed in a DMG. Developer ID signing/notarization is optional and separate. Do not publish an unapproved development bundle as an operational product, or claim physical-sleep validation from a build or dummy-package test.

## Required decisions and gates

- Keep private vulnerability reporting enabled on the public repository and designate a maintainer responsible for reviewing reports.
- Recheck the provisional name. See the collision/adjacent-project findings in [UPSTREAM.md](../UPSTREAM.md).
- Select the community installer path unless an authorized Developer ID environment is explicitly available and desired. Community distribution needs no Apple enrollment, private certificate or notarization credential. Never commit/export credentials into this repository.
- Choose the version and supported architectures based on actual build/runtime evidence.
- Complete the signed-peer, registration, update, removal, accessibility and hardware checklist in [TESTING.md](TESTING.md).
- Start from a reviewed commit and clean worktree. Retain the full upstream MIT notice and lineage document.

The runtime has no automatic update feed. Do not point it at Adrafinil's release channel. A future updater needs its own signed channel, provenance, rollback and ownership review.

## Safe development package

After building the source-testing executables:

```sh
python3 Scripts/build-app.py --configuration debug \
  --bin-dir .build/source-testing/debug \
  --output .build/WakeLease-development.app
```

This shortcut produces an ad-hoc-signed bundle whose privileged services intentionally refuse to run. The builder does not install or launch anything. It refuses an existing output path rather than deleting a prior app. Native previews and disposable package tests can use it without production credentials.

## Primary path: no-fee community installer

Run safe tests and lint, commit the reviewed work, and start from a clean checkout. Choose new output paths; builders refuse existing artifacts rather than deleting them.

```sh
python3 Scripts/build-app.py --community --configuration release --sign - \
  --arch arm64 --arch x86_64 --output .build/community/WakeLease.app
python3 Scripts/build-community.py --app .build/community/WakeLease.app \
  --output .build/community-downloads
```

`--community` requires a source-built release configuration and ad-hoc signing; it refuses the `--bin-dir` shortcut. The second builder requires clean/current-commit provenance and matching architecture slices for all four products. It builds a native installer worker, measures per-architecture code hashes, verifies signatures/hardened runtime/entitlements, and emits:

- `WakeLease.dmg` and SHA-256.
- `Install WakeLease.pkg`, `Repair Interrupted Install.pkg`, and `Remove Installer Approval.pkg`, each with SHA-256.
- The public component-pin record and installation instructions.

The install package places the app at `/Applications/WakeLease.app`. Its administrator-run preflight refuses active services/processes or power state not confirmed off, writes a protected admission marker, and rechecks. The marker remains on interrupted or invalid payloads. Activation publishes root-owned pins only after verifying the complete installed bundle. Repair must come from the same artifact and cannot override a different component record. Approval-only removal neither deletes the app/preferences nor stops running work.

Inspect artifacts without installing or mounting them:

```sh
WAKELEASE_COMMUNITY_DIST=.build/community-downloads WAKELEASE_HEADLESS=1 \
  python3 Tests/package_smoke.py
```

This expands packages in a disposable directory, verifies checksums and worker signatures, checks script syntax, compares component records, validates both app payloads through the native read-only verifier, and verifies the DMG checksum. It never executes package pre/post-install scripts. The separate, explicitly approved `installed-package-probe.yml` executes those scripts only on disposable CI with harmless substitute binaries, not the real power controller.

Community artifacts are **not notarized** and carry no Apple publisher attestation. Users may need macOS's per-installer approval. Do not disable Gatekeeper/SIP or require a custom trusted root certificate. Administrator approval establishes local trust in the selected bytes; protect the download origin and publish checksums and provenance. Full product XPC/service approval and physical MacBook checks still apply before a supported release. `developmentOnly: false` with `requiresInstallerApproval: true` is not hardware certification or permission to bypass those gates.

CI retains `WakeLease-community-installer-preview` for review; artifact retention is not a supported release announcement. Builders and CI do not publish a GitHub release automatically.

## Optional path: Developer ID distribution

First run all safe tests and lint checks. Set `WAKELEASE_SIGN_IDENTITY` to an authorized **Developer ID Application** identity and `WAKELEASE_DEVELOPMENT_TEAM` to its ten-character team ID in your private build environment. The following command reads those environment values:

```sh
python3 Scripts/build-app.py --configuration release \
  --arch arm64 --arch x86_64 --output .build/distribution/WakeLease.app --zip
```

Do not request an architecture and assume it built: inspect the actual binary slices. If distributing a single-architecture build, supply only that `--arch` and label the release/cask accordingly. Cross-compilation is not execution evidence on Intel hardware.

The normal builder compiles all four products separately for each requested architecture and combines multiple slices with the system `lipo` tool, avoiding an unnecessary XCBuild dependency for that assembly step. It embeds component Info.plists, substitutes the selected team requirement, preserves separate app/CLI paths, signs inner executables before the app, enables hardened runtime, and uses secure timestamps for non-ad-hoc signing. It packages only the new icon and required attribution/provenance resources. `--bin-dir` is refused for production signing.

Inspect at least:

```sh
codesign --verify --deep --strict .build/distribution/WakeLease.app
codesign --display --verbose=4 .build/distribution/WakeLease.app
lipo -archs .build/distribution/WakeLease.app/Contents/MacOS/WakeLease
lipo -archs .build/distribution/WakeLease.app/Contents/Helpers/wakelease
lipo -archs .build/distribution/WakeLease.app/Contents/Library/LaunchAgents/WakeLeaseDaemon
lipo -archs .build/distribution/WakeLease.app/Contents/Library/LaunchDaemons/WakeLeaseHelper
```

Inspect nested signatures, entitlements and deployment targets too. The exact role identifiers must be `org.wakelease`, `org.wakelease.cli`, `org.wakelease.daemon`, and `org.wakelease.helper`, with the same authorized team. Release entitlements must not include `get-task-allow`, unsigned executable memory, disabled library validation or other development exceptions. An ad-hoc signature alone is not a publisher identity; the separate community path additionally requires protected administrator-installed code pins.

`WakeLeaseBuild.json` records the commit, dirty flag, configuration, requested architectures, and inspected slices for each executable. Do not release a dirty or `developmentOnly` artifact. Review the bundle itself for old artwork/branding, unexpected resources, symlinks and accidental private files.

The Xcode path remains independently checked:

```sh
xcodebuild -project Adrafinil.xcodeproj -scheme Adrafinil -configuration Release \
  -destination 'generic/platform=macOS' build
```

Set signing in your authorized Xcode build environment. The project/scheme name is historical; products and the app source group are WakeLease-specific. Do not use compile-only `CODE_SIGNING_ALLOWED=NO` artifacts as releases.

## Optional Developer ID notarization and final archive

Use full Xcode's current `notarytool`/`stapler`, not deprecated `altool`. Store credentials in an authorized keychain profile rather than passing passwords in scripts. `WAKELEASE_NOTARY_PROFILE` below is the name of that existing private profile.

These commands submit software to Apple and require explicit maintainer authorization:

```sh
xcrun notarytool submit .build/distribution/WakeLease.zip \
  --keychain-profile "$WAKELEASE_NOTARY_PROFILE" --wait
```

Record the returned submission ID and inspect the notary log **even when accepted**. Do not continue on an invalid or unknown result. After acceptance:

```sh
xcrun stapler staple .build/distribution/WakeLease.app
xcrun stapler validate .build/distribution/WakeLease.app
codesign --verify --deep --strict .build/distribution/WakeLease.app
ditto -c -k --keepParent .build/distribution/WakeLease.app .build/distribution/WakeLease-notarized.zip
shasum -a 256 .build/distribution/WakeLease-notarized.zip
```

The pre-stapling ZIP/checksum is not the final distribution. Archive the stapled app into a new path and compute the final checksum. Verify Gatekeeper/install behavior from the actual downloaded/quarantined artifact on a clean test machine. Do not remove quarantine or weaken system security to make that test pass.

Primary Apple references: [notarization requirements](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) and [custom workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

## Public release and Homebrew

Publish only after the maintainer approves the repository, artifact, release notes and all required evidence. Use the actual designated repository with `gh`; no release operation is automated by the build script or CI. Include final SHA-256, version/commit, architecture/OS support, MIT attribution, safety caveats and known limitations. Retain the notarization log privately where appropriate.

The existing cask generator targets an app-containing archive, **not the community pkg-in-DMG layout**. Do not claim that its output installs the community package correctly. A pkg-based cask needs separate install/uninstall review and an approved test environment after a release destination is selected. The current generator deliberately requires real inputs rather than inventing a download domain:

```sh
python3 Scripts/generate-cask.py \
  --url "$WAKELEASE_DOWNLOAD_URL" --homepage "$WAKELEASE_HOMEPAGE" \
  --version "$WAKELEASE_VERSION" --sha256 "$WAKELEASE_ARCHIVE_SHA256" \
  --arch arm64
```

Choose `x86_64` or `universal` only for the corresponding verified artifact. Review and test the printed Ruby before submitting a cask or maintaining a tap. The archive must contain `WakeLease.app`. The script invokes the app's guarded uninstaller with `must_succeed: true`; it does not directly unload the helper or blindly zap user configuration. Verify Homebrew's current rules and an actual install/uninstall before calling this Homebrew-supported. No cask has been submitted.

## Rollback

Keep the previously verified complete artifact. For community builds, use its matching administrator-approved installer after services are removed and `SleepDisabled 0` is confirmed; do not copy back old binaries under newer pins. For Developer ID builds, retain the signed/notarized complete bundle and matching team. Do not mix component versions or signing identities. Recheck approval, doctor output and integration ownership after rollback. Consult [RECOVERY.md](RECOVERY.md) if cleanup or helper state is uncertain.
