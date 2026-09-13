# Release procedure

This is a maintainer-run procedure. No production certificate, notarization credential, public repository, release URL or security contact is assigned by this checkout. Do not publish an ad-hoc build or an unverified physical-sleep claim.

## Required decisions and gates

- Designate the public repository and a monitored private vulnerability-reporting channel.
- Recheck the provisional name. See the collision/adjacent-project findings in [UPSTREAM.md](../UPSTREAM.md).
- Use an authorized Developer ID Application identity and its actual Team Identifier. Never commit/export credentials into this repository.
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

## Build from source for distribution

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

Inspect nested signatures, entitlements and deployment targets too. The exact role identifiers must be `org.wakelease`, `org.wakelease.cli`, `org.wakelease.daemon`, and `org.wakelease.helper`, with the same authorized team. Release entitlements must not include `get-task-allow`, unsigned executable memory, disabled library validation or other development exceptions. A valid ad-hoc signature is not a production identity.

`WakeLeaseBuild.json` records the commit, dirty flag, configuration, requested architectures, and inspected slices for each executable. Do not release a dirty or `developmentOnly` artifact. Review the bundle itself for old artwork/branding, unexpected resources, symlinks and accidental private files.

The Xcode path remains independently checked:

```sh
xcodebuild -project Adrafinil.xcodeproj -scheme Adrafinil -configuration Release \
  -destination 'generic/platform=macOS' build
```

Set signing in your authorized Xcode build environment. The project/scheme name is historical; products and the app source group are WakeLease-specific. Do not use compile-only `CODE_SIGNING_ALLOWED=NO` artifacts as releases.

## Notarization and final archive

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

The cask generator deliberately requires real inputs rather than inventing a download domain:

```sh
python3 Scripts/generate-cask.py \
  --url "$WAKELEASE_DOWNLOAD_URL" --homepage "$WAKELEASE_HOMEPAGE" \
  --version "$WAKELEASE_VERSION" --sha256 "$WAKELEASE_ARCHIVE_SHA256" \
  --arch arm64
```

Choose `x86_64` or `universal` only for the corresponding verified artifact. Review and test the printed Ruby before submitting a cask or maintaining a tap. The archive must contain `WakeLease.app`. The script invokes the app's guarded uninstaller with `must_succeed: true`; it does not directly unload the helper or blindly zap user configuration. Verify Homebrew's current rules and an actual install/uninstall before calling this Homebrew-supported. No cask has been submitted.

## Rollback

Keep the previously verified, signed/notarized complete bundle. Quiesce/pause work and confirm `SleepDisabled 0` before replacement. Do not mix component versions or signing teams. Recheck approval, doctor output and integration ownership after rollback. Consult [RECOVERY.md](RECOVERY.md) if cleanup or helper state is uncertain.
