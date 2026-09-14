import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import uuid


ROOT = Path(__file__).resolve().parents[1]


def main():
    if os.environ.get("CI") != "true" or os.environ.get("WAKELEASE_REGISTRATION_PROBE") != "approved-disposable-runner":
        raise SystemExit("Refusing registration outside explicitly approved disposable CI")
    temporary = Path(os.environ["RUNNER_TEMP"]).resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="wakelease-registration-", dir=temporary) as directory:
        directory = Path(directory)
        app_binary = directory / "RegistrationProbe"
        helper_binary = directory / "HarmlessHelper"
        for source, output in [("ProbeMain.swift", app_binary), ("HarmlessHelper.swift", helper_binary)]:
            subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", str(ROOT / "Tests/ServiceRegistrationProbe" / source),
                            "-o", str(output)], check=True, timeout=90)
        reports = []
        for launch in ["direct", "launch-services"]:
            identifier = "org.wakelease.registration-probe." + uuid.uuid4().hex
            app = directory / (launch + ".app")
            contents = app / "Contents"
            (contents / "MacOS").mkdir(parents=True)
            executable = contents / "MacOS/RegistrationProbe"
            shutil.copy2(app_binary, executable)
            for kind, folder, filename in [("agent", "LaunchAgents", "ProbeAgent.plist"), ("daemon", "LaunchDaemons", "ProbeDaemon.plist")]:
                location = contents / "Library" / folder
                location.mkdir(parents=True)
                helper = location / "HarmlessHelper"
                shutil.copy2(helper_binary, helper)
                plist = {"Label": identifier + "." + kind, "BundleProgram": "Contents/Library/" + folder + "/HarmlessHelper",
                         "RunAtLoad": True, "KeepAlive": False, "ProcessType": "Background", "AssociatedBundleIdentifiers": [identifier]}
                (location / filename).write_bytes(plistlib.dumps(plist))
                subprocess.run(["codesign", "--force", "--sign", "-", "--identifier", identifier + "." + kind, str(helper)], check=True, timeout=10)
            info = {"CFBundleIdentifier": identifier, "CFBundleExecutable": "RegistrationProbe", "CFBundleName": "WakeLease CI Registration Probe",
                    "CFBundlePackageType": "APPL", "LSUIElement": True, "NSPrincipalClass": "NSApplication", "LSMinimumSystemVersion": "13.0"}
            (contents / "Info.plist").write_bytes(plistlib.dumps(info))
            subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True, timeout=10)
            subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True, timeout=10)
            result = directory / (launch + ".json")
            cleanup = directory / (launch + "-cleanup.json")
            try:
                if launch == "direct":
                    command = [str(executable), "probe", str(result)]
                else:
                    command = ["open", "-n", "-g", "-W", "--env", "CI=true", "--env", "WAKELEASE_REGISTRATION_PROBE=approved-disposable-runner",
                               "--env", "RUNNER_TEMP=" + str(temporary), str(app), "--args", "probe", str(result)]
                process = subprocess.run(command, capture_output=True, text=True, timeout=60)
                if result.is_file():
                    report = json.loads(result.read_text())
                else:
                    report = {"launchError": process.stderr, "returncode": process.returncode}
                report["launch"] = launch
                reports.append(report)
            finally:
                subprocess.run([str(executable), "cleanup", str(cleanup)], check=True, capture_output=True, text=True, timeout=60)
                cleanup_report = json.loads(cleanup.read_text())
                if not cleanup_report["cleanupOK"]:
                    raise SystemExit("Dummy service cleanup failed")
            print(json.dumps(reports[-1], sort_keys=True), flush=True)
        destination = temporary / "wakelease-registration-results.json"
        destination.write_text(json.dumps(reports, indent=2) + "\n")


if __name__ == "__main__":
    main()
