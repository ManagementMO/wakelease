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


def run(*arguments, env=None):
    subprocess.run([str(argument) for argument in arguments], cwd=ROOT, env=env, check=True)


def output(*arguments, env=None):
    return subprocess.check_output([str(argument) for argument in arguments], cwd=ROOT, env=env, text=True).strip()


def main():
    parser = argparse.ArgumentParser(description="Build a WakeLease app without installing or running services.")
    parser.add_argument("--configuration", choices=["debug", "release"], default="release")
    parser.add_argument("--output", type=Path, default=ROOT / ".build/WakeLease.app")
    parser.add_argument("--bin-dir", type=Path, help="Reuse development binaries; allowed only with ad-hoc signing")
    parser.add_argument("--arch", action="append", choices=["arm64", "x86_64"])
    parser.add_argument("--sign", default=os.environ.get("WAKELEASE_SIGN_IDENTITY", "-"))
    parser.add_argument("--team", default=os.environ.get("WAKELEASE_DEVELOPMENT_TEAM", ""))
    parser.add_argument("--zip", action="store_true")
    parser.add_argument("--community", action="store_true", help="Build an installer-required community bundle without an Apple certificate")
    args = parser.parse_args()
    destination = args.output.expanduser().absolute()
    if destination.exists() or destination.is_symlink():
        parser.error("Output already exists. Choose a new --output path; existing apps are never removed by this script.")
    if destination.suffix != ".app":
        parser.error("--output must end in .app")
    if args.sign != "-" and not re.fullmatch(r"[A-Z0-9]{10}", args.team):
        parser.error("Production signing requires --team with the certificate's 10-character Team Identifier.")
    if args.bin_dir and args.sign != "-":
        parser.error("--bin-dir is a development-only shortcut, not a production release path.")
    if args.community and (args.sign != "-" or args.configuration != "release" or args.bin_dir):
        parser.error("Community bundles require a fresh release build with ad-hoc signing and administrator installation.")

    constants = (ROOT / "AdrafinilShared/Sources/AdrafinilShared/Constants.swift").read_text()
    name = re.search(r'let name = "([^"]+)"', constants)[1]
    namespace = re.search(r'let appBundleID = "([^"]+)"', constants)[1]
    version = re.search(r'let marketingVersion = "([^"]+)"', constants)[1]
    cli_name = re.search(r'let cliBinaryName = "([^"]+)"', constants)[1]
    destination.parent.mkdir(parents=True, exist_ok=True)
    scratch = ROOT / ".build/app-packaging"
    scratch.mkdir(parents=True, exist_ok=True)
    environment = dict(os.environ, WAKELEASE_SOURCE_TESTING="1")
    base = ["swift", "build", "--configuration", args.configuration, "--disable-experimental-prebuilts"]
    architectures = list(dict.fromkeys(args.arch or [None]))

    with tempfile.TemporaryDirectory(prefix="wakelease-package-", dir=scratch) as temporary:
        temporary = Path(temporary)
        component_info = {}
        for role, source in [("daemon", "AdrafinilDaemon"), ("helper", "AdrafinilHelper")]:
            info = plistlib.loads((ROOT / source / "Info.plist").read_bytes())
            info["CFBundleIdentifier"] = namespace + "." + role
            info["CFBundleShortVersionString"] = version
            if role == "helper":
                info["SMAuthorizedClients"] = [entry.replace("$(DEVELOPMENT_TEAM)", args.team or "UNSIGNED00") for entry in info["SMAuthorizedClients"]]
            path = temporary / (role + "-Info.plist")
            path.write_bytes(plistlib.dumps(info))
            component_info[role] = path

        products = [("WakeLeaseMenu", "Contents/MacOS/" + name, namespace),
                    (cli_name, "Contents/Helpers/" + cli_name, namespace + ".cli"),
                    ("WakeLeaseDaemon", "Contents/Library/LaunchAgents/WakeLeaseDaemon", namespace + ".daemon"),
                    ("WakeLeaseHelper", "Contents/Library/LaunchDaemons/WakeLeaseHelper", namespace + ".helper")]
        stage = temporary / (name + ".app")
        architecture_manifest = {}
        for product, relative, identifier in products:
            binaries = []
            if args.bin_dir:
                binaries.append(args.bin_dir.absolute() / product)
            else:
                for architecture in architectures:
                    architecture_base = [*base, "--scratch-path", str(scratch / ("build-" + (architecture or "native"))),
                                         *(["--arch", architecture] if architecture else [])]
                    command = [*architecture_base, "--product", product]
                    if product in ["WakeLeaseDaemon", "WakeLeaseHelper"]:
                        role = "daemon" if product == "WakeLeaseDaemon" else "helper"
                        for value in ["-sectcreate", "__TEXT", "__info_plist", str(component_info[role])]:
                            command.extend(["-Xlinker", value])
                    run(*command, env=environment)
                    binaries.append(Path(output(*architecture_base, "--show-bin-path", env=environment)) / product)
            target = stage / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            if len(binaries) == 1:
                shutil.copy2(binaries[0], target)
            else:
                run("lipo", "-create", *binaries, "-output", target)
            architecture_manifest[identifier] = output("lipo", "-archs", target).split()
            os.chmod(target, 0o755)
            timestamp = "--timestamp=none" if args.sign == "-" else "--timestamp"
            run("codesign", "--force", "--sign", args.sign, "--identifier", identifier, "--options", "runtime", timestamp, target)

        for source, relative in [("AdrafinilDaemon/LaunchAgent.plist", "Contents/Library/LaunchAgents/LaunchAgent.plist"),
                                 ("AdrafinilHelper/LaunchDaemon.plist", "Contents/Library/LaunchDaemons/LaunchDaemon.plist")]:
            shutil.copy2(ROOT / source, stage / relative)
        resources = stage / "Contents/Resources"
        resources.mkdir(parents=True)
        for document in ["LICENSE", "UPSTREAM.md"]:
            shutil.copy2(ROOT / document, resources / document)
        iconset = temporary / "AppIcon.iconset"
        iconset.mkdir()
        for icon in (ROOT / "WakeLeaseApp/Assets.xcassets/AppIcon.appiconset").glob("*.png"):
            shutil.copy2(icon, iconset / icon.name)
        run("iconutil", "--convert", "icns", "--output", resources / "AppIcon.icns", iconset)
        info = {
            "CFBundleIdentifier": namespace, "CFBundleName": name, "CFBundleDisplayName": name,
            "CFBundleExecutable": name, "CFBundlePackageType": "APPL", "CFBundleVersion": "1",
            "CFBundleShortVersionString": version, "CFBundleIconFile": "AppIcon",
            "LSMinimumSystemVersion": "15.4", "LSUIElement": True, "NSHighResolutionCapable": True,
            "NSSupportsAutomaticTermination": False, "NSPrincipalClass": "NSApplication",
            "LSApplicationCategoryType": "public.app-category.utilities",
            "NSHumanReadableCopyright": "WakeLease contributors. Includes MIT-licensed Adrafinil work by kageroumado and contributors.",
        }
        (stage / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        provenance = {"version": version, "commit": output("git", "rev-parse", "HEAD"),
                      "dirty": bool(output("git", "status", "--porcelain")), "developmentOnly": args.sign == "-" and not args.community,
                      "requiresInstallerApproval": args.community, "configuration": args.configuration, "architecturesRequested": args.arch or ["native"], "architecturesBuilt": architecture_manifest}
        (resources / "WakeLeaseBuild.json").write_text(json.dumps(provenance, indent=2) + "\n")
        run("codesign", "--force", "--sign", args.sign, "--options", "runtime", "--timestamp=none" if args.sign == "-" else "--timestamp", stage)
        run("codesign", "--verify", "--deep", "--strict", stage)
        shutil.move(str(stage), destination)

    print("Built:", destination)
    if args.community:
        print("Community bundle built. Administrator-installed component pins are required before services can operate; this is not notarized or hardware-certified.")
    else:
        print("Development-only ad-hoc bundle: privileged services will refuse to operate." if args.sign == "-" else "Signed bundle built. Notarization and hardware release gates still apply.")
    if args.zip:
        archive = destination.with_suffix(".zip")
        if archive.exists() or archive.is_symlink() or archive.with_suffix(".zip.sha256").exists() or archive.with_suffix(".zip.sha256").is_symlink():
            raise SystemExit("Archive or checksum already exists; choose a new output.")
        run("ditto", "-c", "-k", "--keepParent", destination, archive)
        checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
        archive.with_suffix(".zip.sha256").write_text(checksum + "  " + archive.name + "\n")
        print("Archive:", archive)


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        raise SystemExit(f"Build tool failed with exit {error.returncode}; see its diagnostic above. No services were installed.") from None
