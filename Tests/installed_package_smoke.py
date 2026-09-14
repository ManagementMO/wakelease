import json
import os
from pathlib import Path
import plistlib
import re
import select
import shutil
import subprocess
import sys
import tempfile
import uuid


ROOT = Path(__file__).resolve().parents[1]
DESTINATION = Path("/Library/PrivilegedHelperTools/org.wakelease")
APPLICATION = Path("/Applications/WakeLease.app")
PACKAGE_IDS = ["org.wakelease.community", "org.wakelease.community.repair", "org.wakelease.community.approval-removal"]
NAMES = {"components.json", "trust.lock", "installation.pending"}


def cleanup(identifier):
    if os.getuid() != 0 or not re.fullmatch(r"org\.wakelease\.package-probe\.[a-f0-9]{32}", identifier):
        raise SystemExit("Invalid disposable package cleanup request")
    if APPLICATION.exists() or APPLICATION.is_symlink():
        if APPLICATION.is_symlink() or plistlib.loads((APPLICATION / "Contents/Info.plist").read_bytes()).get("WakeLeaseFixtureID") != identifier:
            raise SystemExit("Refusing to remove an application outside this exact dummy package fixture")
        shutil.rmtree(APPLICATION)
    if DESTINATION.is_dir() and not DESTINATION.is_symlink():
        unexpected = set(path.name for path in DESTINATION.iterdir()) - NAMES
        if unexpected:
            raise SystemExit("Unexpected files in dummy package directory; refusing cleanup")
        for name in NAMES:
            path = DESTINATION / name
            if path.is_symlink():
                raise SystemExit("Unexpected symlink in dummy package directory")
            if path.exists():
                path.unlink()
        DESTINATION.rmdir()
    for package_id in PACKAGE_IDS:
        known = subprocess.run(["pkgutil", "--pkg-info", package_id], capture_output=True, timeout=15)
        if known.returncode == 0:
            subprocess.run(["pkgutil", "--forget", package_id], check=True, timeout=15)


def verify_no_write_access():
    try:
        descriptor = os.open(DESTINATION / "components.json", os.O_WRONLY | os.O_APPEND)
    except PermissionError:
        return
    os.close(descriptor)
    raise AssertionError("The unprivileged runner can modify the trust record")


def build_dummy_app(temporary, identifier, binary):
    app = temporary / "WakeLease.app"
    resources = app / "Contents/Resources"
    resources.mkdir(parents=True)
    info = {"CFBundleIdentifier": "org.wakelease", "CFBundleExecutable": "WakeLease", "CFBundleName": "WakeLease Harmless Package Probe",
            "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0.0", "LSUIElement": True,
            "LSMinimumSystemVersion": "15.4", "WakeLeaseFixtureID": identifier}
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    build = {"version": "1.0.0", "commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
             "dirty": False, "configuration": "release", "developmentOnly": False, "requiresInstallerApproval": True}
    (resources / "WakeLeaseBuild.json").write_text(json.dumps(build))
    entitlements = temporary / "empty-entitlements.plist"
    entitlements.write_bytes(plistlib.dumps({}))
    components = {"org.wakelease": "Contents/MacOS/WakeLease", "org.wakelease.cli": "Contents/Helpers/wakelease",
                  "org.wakelease.daemon": "Contents/Library/LaunchAgents/WakeLeaseDaemon", "org.wakelease.helper": "Contents/Library/LaunchDaemons/WakeLeaseHelper"}
    for component, relative in components.items():
        target = app / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(binary, target)
        target.chmod(0o755)
        subprocess.run(["codesign", "--force", "--sign", "-", "--identifier", component, "--options", "runtime", "--entitlements", str(entitlements), str(target)], check=True, timeout=10)
    subprocess.run(["codesign", "--force", "--sign", "-", "--options", "runtime", "--entitlements", str(entitlements), str(app)], check=True, timeout=10)
    return app


def main():
    if os.environ.get("CI") != "true" or os.environ.get("WAKELEASE_INSTALLER_PROBE") != "approved-disposable-runner":
        raise SystemExit("Dummy package installation is restricted to explicitly approved disposable CI")
    if len(sys.argv) == 3 and sys.argv[1] == "--cleanup":
        cleanup(sys.argv[2])
        return
    if len(sys.argv) != 1 or os.getuid() == 0 or any(path.exists() or path.is_symlink() for path in [DESTINATION, APPLICATION]):
        raise SystemExit("The disposable runner must start without a WakeLease app or trust directory")
    for package_id in PACKAGE_IDS:
        if subprocess.run(["pkgutil", "--pkg-info", package_id], capture_output=True, timeout=15).returncode == 0:
            raise SystemExit("The disposable runner already has a community package receipt")
    binary = ROOT / ".build/source-testing/debug/WakeLeaseInstalledTrustProbe"
    identifier = "org.wakelease.package-probe." + uuid.uuid4().hex
    with tempfile.TemporaryDirectory(prefix="wakelease-package-probe-", dir=os.environ["RUNNER_TEMP"]) as temporary:
        temporary = Path(temporary)
        app = build_dummy_app(temporary, identifier, binary)
        executable = app / "Contents/MacOS/WakeLease"
        subprocess.run([str(executable), "absent"], check=True, timeout=10)
        distribution = temporary / "distribution"
        subprocess.run(["python3", str(ROOT / "Scripts/build-community.py"), "--app", str(app), "--output", str(distribution), "--no-dmg"], check=True, timeout=900)
        package = distribution / "Install WakeLease.pkg"
        attempted = False
        try:
            attempted = True
            subprocess.run(["sudo", "-n", "installer", "-pkg", str(package), "-target", "/"], check=True, timeout=90)
            for name in ["components.json", "trust.lock"]:
                info = (DESTINATION / name).stat()
                if info.st_uid != 0 or info.st_mode & 0o022 or info.st_nlink != 1:
                    raise AssertionError("Dummy package did not establish protected root ownership")
            if (DESTINATION / "installation.pending").exists():
                raise AssertionError("Successful installation left an admission fence behind")
            verify_no_write_access()
            subprocess.run([str(APPLICATION / "Contents/MacOS/WakeLease"), "installed"], check=True, timeout=10)
            held = subprocess.Popen([str(executable), "hold"], stdout=subprocess.PIPE)
            try:
                if not select.select([held.stdout], [], [], 10)[0] or held.stdout.readline() != b"ready\n":
                    raise AssertionError("The owned preflight-rejection process did not start")
                rejected = subprocess.run(["sudo", "-n", "installer", "-pkg", str(package), "-target", "/"], capture_output=True, timeout=90)
                if rejected.returncode == 0 or (DESTINATION / "installation.pending").exists():
                    raise AssertionError("Installer did not refuse the running dummy app cleanly")
            finally:
                held.terminate()
                held.wait(timeout=10)
                held.stdout.close()
            subprocess.run([str(executable), "installed"], check=True, timeout=10)
            expanded = temporary / "expanded-package"
            subprocess.run(["pkgutil", "--expand-full", str(package), str(expanded)], check=True, timeout=30)
            workers = list(expanded.rglob("WakeLeaseInstaller"))
            if len(workers) != 1:
                raise AssertionError("Expected exactly one native installer worker in the package")
            subprocess.run(["sudo", "-n", str(workers[0]), "preflight", "/"], check=True, timeout=30)
            subprocess.run([str(executable), "absent"], check=True, timeout=10)
            subprocess.run(["sudo", "-n", "installer", "-pkg", str(distribution / "Repair Interrupted Install.pkg"), "-target", "/"], check=True, timeout=90)
            subprocess.run([str(executable), "installed"], check=True, timeout=10)
            impostor = temporary / "impostor"
            shutil.copy2(binary, impostor)
            subprocess.run(["codesign", "--force", "--sign", "-", "--identifier", "org.wakelease", "--options", "runtime", str(impostor)], check=True, timeout=10)
            subprocess.run([str(impostor), "absent"], check=True, timeout=10)
            refused = subprocess.run([str(executable), "remove"], capture_output=True, timeout=10)
            if refused.returncode == 0 or not (DESTINATION / "components.json").exists():
                raise AssertionError("Unapproved user removal was not rejected")
            subprocess.run(["sudo", "-n", "env", "CI=true", "WAKELEASE_INSTALLER_PROBE=approved-disposable-runner", str(executable), "grant-delete", str(os.getuid())], check=True, timeout=10)
            verify_no_write_access()
            subprocess.run([str(executable), "remove"], check=True, timeout=10)
            subprocess.run([str(executable), "absent"], check=True, timeout=10)
            subprocess.run(["sudo", "-n", "installer", "-pkg", str(package), "-target", "/"], check=True, timeout=90)
            subprocess.run([str(executable), "installed"], check=True, timeout=10)
            subprocess.run(["sudo", "-n", "installer", "-pkg", str(distribution / "Remove Installer Approval.pkg"), "-target", "/"], check=True, timeout=90)
            subprocess.run([str(executable), "absent"], check=True, timeout=10)
            if not APPLICATION.is_dir() or (DESTINATION / "installation.pending").exists():
                raise AssertionError("Approval-only removal changed the app or left an incomplete transaction")
        finally:
            if attempted:
                subprocess.run(["sudo", "-n", "env", "CI=true", "WAKELEASE_INSTALLER_PROBE=approved-disposable-runner", "/usr/bin/python3",
                                str(Path(__file__).resolve()), "--cleanup", identifier], check=True, timeout=30)
        subprocess.run([str(executable), "absent"], check=True, timeout=10)
        print("Native harmless package activation, protected identity, delegated removal and revocation verified")


if __name__ == "__main__":
    main()
