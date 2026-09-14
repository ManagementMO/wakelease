import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import uuid


ROOT = Path(__file__).resolve().parents[1]
DESTINATION = Path("/Library/PrivilegedHelperTools/org.wakelease")
NAMES = ["components.json", "probe-app", "probe-cli", "probe-daemon", "probe-helper"]


def cleanup(identifier):
    if os.getuid() != 0 or not re.fullmatch(r"org\.wakelease\.package-probe\.[a-f0-9]{32}", identifier):
        raise SystemExit("Invalid disposable package cleanup request")
    if DESTINATION.is_dir() and not DESTINATION.is_symlink():
        unexpected = set(path.name for path in DESTINATION.iterdir()) - set(NAMES)
        if unexpected:
            raise SystemExit("Unexpected files in dummy package directory; refusing cleanup")
        for name in NAMES:
            path = DESTINATION / name
            if path.is_symlink():
                raise SystemExit("Unexpected symlink in dummy package directory")
            if path.exists():
                path.unlink()
        DESTINATION.rmdir()
    subprocess.run(["pkgutil", "--forget", identifier], check=True, timeout=15)


def main():
    if os.environ.get("CI") != "true" or os.environ.get("WAKELEASE_INSTALLER_PROBE") != "approved-disposable-runner":
        raise SystemExit("Dummy package installation is restricted to explicitly approved disposable CI")
    if len(sys.argv) == 3 and sys.argv[1] == "--cleanup":
        cleanup(sys.argv[2])
        return
    if len(sys.argv) != 1 or os.getuid() == 0 or DESTINATION.exists() or DESTINATION.is_symlink():
        raise SystemExit("The disposable runner must start without an installed WakeLease trust directory")
    binary = ROOT / ".build/source-testing/debug/WakeLeaseInstalledTrustProbe"
    identifier = "org.wakelease.package-probe." + uuid.uuid4().hex
    with tempfile.TemporaryDirectory(prefix="wakelease-package-probe-", dir=os.environ["RUNNER_TEMP"]) as temporary:
        temporary = Path(temporary)
        payload = temporary / "payload"
        stage = payload
        stage.mkdir()
        hashes = {}
        for role, component in [("app", "org.wakelease"), ("cli", "org.wakelease.cli"), ("daemon", "org.wakelease.daemon"), ("helper", "org.wakelease.helper")]:
            target = stage / ("probe-" + role)
            shutil.copy2(binary, target)
            target.chmod(0o755)
            subprocess.run(["codesign", "--force", "--sign", "-", "--identifier", component, str(target)], check=True, timeout=10)
            signature = subprocess.run(["codesign", "--display", "--verbose=4", str(target)], check=True, capture_output=True, text=True, timeout=10).stderr
            hashes[component] = [re.search(r"^CDHash=([a-f0-9]{40})$", signature, re.MULTILINE)[1]]
        record = {"version": 1, "build": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(), "hashes": hashes}
        (stage / "components.json").write_text(json.dumps(record) + "\n")
        (stage / "components.json").chmod(0o644)
        stage.chmod(0o755)
        executable = temporary / "owned-probe"
        shutil.copy2(stage / "probe-app", executable)
        subprocess.run([str(executable), "absent"], check=True, timeout=10)
        package = temporary / "HarmlessWakeLeaseProbe.pkg"
        subprocess.run(["pkgbuild", "--root", str(payload), "--identifier", identifier, "--version", "1", "--ownership", "recommended", "--install-location", str(DESTINATION), str(package)], check=True, timeout=30)
        attempted = False
        try:
            attempted = True
            subprocess.run(["sudo", "-n", "installer", "-pkg", str(package), "-target", "/"], check=True, timeout=90)
            for name in NAMES:
                info = (DESTINATION / name).stat()
                if info.st_uid != 0 or info.st_mode & 0o022 or info.st_nlink != 1:
                    raise AssertionError("Dummy package did not establish protected root ownership")
            try:
                descriptor = os.open(DESTINATION / "components.json", os.O_WRONLY | os.O_APPEND)
            except PermissionError:
                pass
            else:
                os.close(descriptor)
                raise AssertionError("The unprivileged runner can modify the trust record")
            subprocess.run([str(executable), "installed"], check=True, timeout=10)
            impostor = temporary / "impostor"
            shutil.copy2(binary, impostor)
            subprocess.run(["codesign", "--force", "--sign", "-", "--identifier", "org.wakelease", "--options", "runtime", str(impostor)], check=True, timeout=10)
            subprocess.run([str(impostor), "absent"], check=True, timeout=10)
        finally:
            if attempted:
                subprocess.run(["sudo", "-n", "env", "CI=true", "WAKELEASE_INSTALLER_PROBE=approved-disposable-runner", "/usr/bin/python3",
                                str(Path(__file__).resolve()), "--cleanup", identifier], check=True, timeout=30)
        subprocess.run([str(executable), "absent"], check=True, timeout=10)
        print("Harmless package approval, impostor rejection, removal and revocation verified")


if __name__ == "__main__":
    main()
