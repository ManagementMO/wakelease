import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
COMPONENTS = {"org.wakelease": "Contents/MacOS/WakeLease", "org.wakelease.cli": "Contents/Helpers/wakelease",
              "org.wakelease.daemon": "Contents/Library/LaunchAgents/WakeLeaseDaemon",
              "org.wakelease.helper": "Contents/Library/LaunchDaemons/WakeLeaseHelper"}


def run(arguments, **options):
    return subprocess.run([str(value) for value in arguments], cwd=ROOT, check=True, **options)


def output(arguments, **options):
    return subprocess.check_output([str(value) for value in arguments], cwd=ROOT, text=True, **options).strip()


def main():
    parser = argparse.ArgumentParser(description="Package a reviewed community app into an administrator-approved pkg and direct-download DMG. Never installs or runs services.")
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True, help="New output directory; existing artifacts are never overwritten")
    parser.add_argument("--no-dmg", action="store_true", help="Build only the pkg for archive inspection")
    args = parser.parse_args()
    app = args.app.expanduser().absolute()
    destination = args.output.expanduser().absolute()
    if app.suffix != ".app" or not app.is_dir() or app.is_symlink():
        parser.error("--app must identify a real community app bundle")
    if destination.exists() or destination.is_symlink() or destination.is_relative_to(app):
        parser.error("Choose a new output directory outside the application bundle")
    if any(path.is_symlink() for path in app.rglob("*")):
        parser.error("Community packages do not accept symlinks inside the application bundle")
    provenance = json.loads((app / "Contents/Resources/WakeLeaseBuild.json").read_text())
    if (provenance.get("developmentOnly") is not False or provenance.get("requiresInstallerApproval") is not True
            or provenance.get("configuration") != "release" or provenance.get("dirty") is not False
            or provenance.get("commit") != output(["git", "rev-parse", "HEAD"]) or output(["git", "status", "--porcelain"])):
        parser.error("Package a fresh, clean --community release build from the current reviewed commit")
    version = provenance["version"]
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        parser.error("Invalid package version")
    architectures = None
    hashes = {}
    for identifier, relative in COMPONENTS.items():
        binary = app / relative
        built = set(output(["lipo", "-archs", binary]).split())
        if not built or not built <= {"arm64", "x86_64"} or (architectures is not None and built != architectures):
            parser.error("All package components must have the same supported architecture slices")
        architectures = built
        hashes[identifier] = []
        for architecture in sorted(built):
            result = run(["codesign", "--display", "--verbose=4", "--arch", architecture, binary], capture_output=True, text=True)
            match = re.search(r"^CDHash=([a-f0-9]{40})$", result.stderr, re.MULTILINE)
            if not match:
                parser.error("A component has no inspectable code hash")
            hashes[identifier].append(match[1])
    destination.parent.mkdir(parents=True, exist_ok=True)
    environment = dict(os.environ, WAKELEASE_SOURCE_TESTING="1")
    scratch = ROOT / ".build/app-packaging"
    scratch.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="wakelease-community-package-", dir=scratch) as temporary:
        temporary = Path(temporary)
        scripts = temporary / "scripts"
        scripts.mkdir()
        binaries = []
        for architecture in sorted(architectures):
            base = ["swift", "build", "--scratch-path", scratch / ("build-" + architecture), "--configuration", "release", "--arch", architecture, "--disable-experimental-prebuilts"]
            run([*base, "--product", "WakeLeaseInstaller"], env=environment)
            binary = Path(output([*base, "--show-bin-path"], env=environment)) / "WakeLeaseInstaller"
            copied = temporary / ("installer-" + architecture)
            shutil.copy2(binary, copied)
            binaries.append(copied)
        installer = scripts / "WakeLeaseInstaller"
        if len(binaries) == 1:
            shutil.copy2(binaries[0], installer)
        else:
            run(["lipo", "-create", *binaries, "-output", installer])
        installer.chmod(0o755)
        run(["codesign", "--force", "--sign", "-", "--identifier", "org.wakelease.installer", "--options", "runtime", "--timestamp=none", installer])
        record = {"version": 1, "build": provenance["commit"], "hashes": hashes}
        manifest = scripts / "components.json"
        manifest.write_text(json.dumps(record, indent=2) + "\n")
        for name, phase in [("preinstall", "preflight"), ("postinstall", "activate")]:
            script = scripts / name
            script.write_text('#!/bin/sh\nset -eu\nexec "$(dirname "$0")/WakeLeaseInstaller" ' + phase + ' "$3"\n')
            script.chmod(0o755)
        run([installer, "verify", app, manifest])
        payload = temporary / "payload"
        installed_app = payload / "Applications/WakeLease.app"
        installed_app.parent.mkdir(parents=True)
        shutil.copytree(app, installed_app)
        component_list = temporary / "components.plist"
        component_list.write_bytes(plistlib.dumps([{"RootRelativeBundlePath": "Applications/WakeLease.app", "BundleIsRelocatable": False,
                                                   "BundleHasStrictIdentifier": True, "BundleIsVersionChecked": False, "BundleOverwriteAction": "upgrade"}]))
        image = temporary / "image"
        image.mkdir()
        package = image / "Install WakeLease.pkg"
        run(["pkgbuild", "--root", payload, "--scripts", scripts, "--component-plist", component_list, "--identifier", "org.wakelease.community",
             "--version", version, "--ownership", "recommended", "--install-location", "/", package])
        repair = temporary / "repair-scripts"
        shutil.copytree(scripts, repair)
        (repair / "preinstall").write_text('#!/bin/sh\nset -eu\nworker="$(dirname "$0")/WakeLeaseInstaller"\n"$worker" cancel "$3"\nexec "$worker" preflight "$3"\n')
        (repair / "preinstall").chmod(0o755)
        run(["pkgbuild", "--root", payload, "--scripts", repair, "--component-plist", component_list, "--identifier", "org.wakelease.community.repair",
             "--version", version, "--ownership", "recommended", "--install-location", "/", image / "Repair Interrupted Install.pkg"])
        removal = temporary / "removal-scripts"
        removal.mkdir()
        shutil.copy2(installer, removal / installer.name)
        shutil.copy2(manifest, removal / manifest.name)
        (removal / "postinstall").write_text('#!/bin/sh\nset -eu\nexec "$(dirname "$0")/WakeLeaseInstaller" remove-approval "$3"\n')
        (removal / "postinstall").chmod(0o755)
        run(["pkgbuild", "--nopayload", "--scripts", removal, "--identifier", "org.wakelease.community.approval-removal", "--version", version,
             "--install-location", "/", image / "Remove Installer Approval.pkg"])
        (image / "INSTALL.txt").write_text(
            "WakeLease community installer\n\n"
            "No Apple Developer membership is needed. This download is not notarized. macOS may require you to explicitly approve this installer in Privacy & Security. Do not disable Gatekeeper globally.\n\n"
            "1. Stop WakeLease services through the existing app before upgrading, and quit WakeLease in every logged-in account.\n"
            "2. Open Install WakeLease.pkg and approve the administrator installation.\n"
            "3. Open /Applications/WakeLease.app, enable its services, and approve its background helper in Login Items & Extensions.\n\n"
            "The installer approves exact component code hashes. A modified or mixed-version bundle is rejected. Installation does not itself enable wake protection.\n\n"
            "If an installation was interrupted, close Installer and run Repair Interrupted Install.pkg from this same DMG. It refuses active services or work; it is not a forced reset.\n\n"
            "Normally uninstall from WakeLease Settings. If services were never approved, quit the app and disable its background items before using Remove Installer Approval.pkg, then reopen Settings to finish user-data cleanup and move the app to Trash. The approval-removal package deletes only the protected code approval record, not your application or preferences.\n\n"
            "This engineering build has not completed the physical MacBook release gates. Test supervised, with local recovery access. Never put an operating laptop in a bag or obstruct its ventilation.\n\n"
            "Source, recovery instructions and verification limits: https://github.com/ManagementMO/wakelease\n")
        stage = temporary / "distribution"
        stage.mkdir()
        for package in image.glob("*.pkg"):
            shutil.copy2(package, stage / package.name)
        shutil.copy2(manifest, stage / "components.json")
        shutil.copy2(image / "INSTALL.txt", stage / "INSTALL.txt")
        if not args.no_dmg:
            disk_image = stage / "WakeLease.dmg"
            run(["hdiutil", "create", "-volname", "WakeLease", "-fs", "HFS+", "-format", "UDZO", "-srcfolder", image, disk_image])
            run(["hdiutil", "verify", disk_image])
        for artifact in stage.iterdir():
            if artifact.suffix in [".pkg", ".dmg"]:
                checksum = hashlib.sha256(artifact.read_bytes()).hexdigest()
                artifact.with_suffix(artifact.suffix + ".sha256").write_text(checksum + "  " + artifact.name + "\n")
        shutil.move(str(stage), destination)
    print("Community distribution built:", destination)
    print("Not notarized. Administrator approval and separate service/hardware validation remain required. No services were installed.")


if __name__ == "__main__":
    main()
