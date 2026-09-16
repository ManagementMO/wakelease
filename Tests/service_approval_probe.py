"""Harmless dummy background-item approval experiment for a disposable Devin Cloud Mac.

Registers a uniquely named, ad-hoc-signed dummy app's LaunchAgent and LaunchDaemon through SMAppService, leaves them
pending so the exact System Settings row can be approved by hand, then reports whether macOS started the dummy helper
(scoped PID/UID evidence written by the helper itself) and removes only that registration. No WakeLease power code is
involved. It refuses to run outside an explicitly opted-in hypervisor-reported VM or a GitHub runner.

    python3 Tests/service_approval_probe.py register            # prints the fixture root, identifier and display name
    python3 Tests/service_approval_probe.py register --agent-only
    python3 Tests/service_approval_probe.py status  --root DIR  # statuses plus helper startup evidence
    python3 Tests/service_approval_probe.py cleanup --root DIR  # unregister the exact dummy services and delete DIR
"""

import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import uuid


ROOT = Path(__file__).resolve().parents[1]
STATUS_NAMES = {0: "notRegistered", 1: "enabled", 2: "requiresApproval", 3: "notFound"}


def disposable_temporary():
    mode = os.environ.get("WAKELEASE_REGISTRATION_PROBE")
    if mode == "approved-disposable-runner" and os.environ.get("CI") == "true" and os.environ.get("RUNNER_TEMP"):
        return Path(os.environ["RUNNER_TEMP"]).resolve(strict=True)
    if mode == "approved-disposable-vm":
        virtualized = subprocess.run(["/usr/sbin/sysctl", "-n", "kern.hv_vmm_present"], capture_output=True, text=True, timeout=10)
        if virtualized.returncode == 0 and virtualized.stdout.strip() == "1":
            return Path(tempfile.gettempdir()).resolve(strict=True)
    raise SystemExit("Refusing dummy service approval outside an explicitly approved disposable runner or VM")


def run_app(root, mode, name):
    manifest = json.loads((root / "fixture.json").read_text())
    report = root / f"{name}.json"
    if report.exists():
        report.unlink()
    environment = dict(os.environ, WAKELEASE_PROBE_TEMP=str(root.parent))
    process = subprocess.run([manifest["executable"], mode, str(report)], env=environment, capture_output=True, text=True, timeout=60)
    if not report.is_file():
        raise SystemExit(f"Dummy app did not report ({mode}): exit {process.returncode} {process.stderr}")
    result = json.loads(report.read_text())
    for service in result["services"]:
        for key in ("before", "afterRegistration", "afterCleanup"):
            service[key] = STATUS_NAMES.get(service[key], service[key])
    result["displayName"] = manifest["displayName"]
    result["root"] = str(root)
    return result


def evidence(root):
    started = {}
    for kind in ("agent", "daemon"):
        path = root / f"{kind}-started.json"
        started[kind] = json.loads(path.read_text()) if path.is_file() else None
    return started


def register(temporary, agent_only):
    root = Path(tempfile.mkdtemp(prefix="wakelease-approval-", dir=temporary))
    root.chmod(0o700)
    token = uuid.uuid4().hex
    identifier = "org.wakelease.registration-probe." + token
    display_name = "WakeLease Dummy Probe " + token[:6]
    app_binary = root / "RegistrationProbe"
    helper_binary = root / "HarmlessHelper"
    for source, output in [("ProbeMain.swift", app_binary), ("HarmlessHelper.swift", helper_binary)]:
        subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", str(ROOT / "Tests/ServiceRegistrationProbe" / source),
                        "-o", str(output)], check=True, timeout=120)
    app = root / (display_name + ".app")
    contents = app / "Contents"
    (contents / "MacOS").mkdir(parents=True)
    executable = contents / "MacOS/RegistrationProbe"
    shutil.copy2(app_binary, executable)
    kinds = [("agent", "LaunchAgents", "ProbeAgent.plist")] + ([] if agent_only else [("daemon", "LaunchDaemons", "ProbeDaemon.plist")])
    for kind, folder, filename in kinds:
        location = contents / "Library" / folder
        location.mkdir(parents=True)
        helper = location / "HarmlessHelper"
        shutil.copy2(helper_binary, helper)
        plist = {"Label": identifier + "." + kind, "BundleProgram": "Contents/Library/" + folder + "/HarmlessHelper",
                 "RunAtLoad": True, "KeepAlive": False, "ProcessType": "Background", "AssociatedBundleIdentifiers": [identifier],
                 "EnvironmentVariables": {"WAKELEASE_PROBE_EVIDENCE": str(root / f"{kind}-started.json"),
                                          "WAKELEASE_PROBE_LABEL": identifier + "." + kind}}
        (location / filename).write_bytes(plistlib.dumps(plist))
        subprocess.run(["codesign", "--force", "--sign", "-", "--identifier", identifier + "." + kind, str(helper)], check=True, timeout=15)
    info = {"CFBundleIdentifier": identifier, "CFBundleExecutable": "RegistrationProbe", "CFBundleName": display_name,
            "CFBundleDisplayName": display_name, "CFBundlePackageType": "APPL", "LSUIElement": True, "NSPrincipalClass": "NSApplication",
            "LSMinimumSystemVersion": "13.0", "CFBundleShortVersionString": "0.0.1", "CFBundleVersion": "1"}
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True, timeout=15)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True, timeout=15)
    (root / "fixture.json").write_text(json.dumps({"identifier": identifier, "displayName": display_name, "executable": str(executable)}))
    result = run_app(root, "register-agent" if agent_only else "register", "register")
    result["startup"] = evidence(root)
    return result


def status(root):
    result = run_app(root, "status", "status")
    result["startup"] = evidence(root)
    return result


def cleanup(root):
    result = run_app(root, "cleanup", "cleanup")
    result["startup"] = evidence(root)
    if not result["cleanupOK"]:
        raise SystemExit("Dummy service cleanup did not reach notRegistered: " + json.dumps(result, sort_keys=True))
    shutil.rmtree(root)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["register", "status", "cleanup"])
    parser.add_argument("--root", type=Path)
    parser.add_argument("--agent-only", action="store_true", help="register only the LaunchAgent (no administrator daemon)")
    arguments = parser.parse_args()
    temporary = disposable_temporary()
    if arguments.command == "register":
        result = register(temporary, arguments.agent_only)
    else:
        if arguments.root is None:
            raise SystemExit("--root is required")
        root = arguments.root.resolve(strict=True)
        if root.parent != temporary or not root.name.startswith("wakelease-approval-") or root.stat().st_uid != os.getuid():
            raise SystemExit("Refusing to touch a directory that this fixture did not create")
        result = status(root) if arguments.command == "status" else cleanup(root)
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
