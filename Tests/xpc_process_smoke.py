import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
import uuid


ROOT = Path(__file__).resolve().parents[1]
BIN = Path(os.environ.get("WAKELEASE_BIN_DIR", ROOT / ".build/source-testing/debug")) / "WakeLeaseXPCProcessProbe"


def remote_fixture_mode():
    mode = os.environ.get("WAKELEASE_XPC_PROCESS_FIXTURE")
    if mode == "1" and os.environ.get("CI") == "true" and os.environ.get("RUNNER_TEMP"):
        return mode
    if mode == "disposable-vm":
        virtualized = subprocess.run(["/usr/sbin/sysctl", "-n", "kern.hv_vmm_present"], capture_output=True, text=True, timeout=10)
        if virtualized.returncode == 0 and virtualized.stdout.strip() == "1":
            return mode
    return None


def launchd_domain():
    manager = subprocess.run(["/bin/launchctl", "managername"], capture_output=True, text=True, timeout=10)
    kind = "gui" if manager.returncode == 0 and manager.stdout.strip() == "Aqua" else "user"
    return f"{kind}/{os.getuid()}"


def launchctl(*arguments):
    return subprocess.run(["/bin/launchctl", *arguments], capture_output=True, text=True, timeout=30)


class CrossProcessXPCSmoke(unittest.TestCase):
    """Disposable ad-hoc Client.app and Service.app exchange one echo over a launchd Mach service that exists only
    while the scenario runs. The service is the production listener shape (`NSXPCListener(machServiceName:)`), the
    only listener kind that honours `setConnectionCodeSigningRequirement`. Nothing is installed under LaunchAgents,
    nothing runs as root and no WakeLease power code is involved."""

    def run_case(self, scenario):
        mode = remote_fixture_mode()
        self.assertIsNotNone(mode, "Cross-process verification is restricted to remote fixtures")
        with tempfile.TemporaryDirectory(prefix="wakelease-xpc-process-", dir=os.environ.get("RUNNER_TEMP")) as temporary:
            directory = Path(temporary).resolve()
            label = "org.wakelease.xpc-fixture." + uuid.uuid4().hex[:12]
            app = directory / "Client.app"
            service = directory / "Service.app"
            entitlements = directory / "entitlements.plist"
            entitlements.write_bytes(plistlib.dumps({}))
            for bundle, identifier, executable in [(app, "org.wakelease", "Client"), (service, "org.wakelease.helper", "Service")]:
                binary = bundle / "Contents/MacOS" / executable
                binary.parent.mkdir(parents=True)
                shutil.copy2(BIN, binary)
                binary.chmod(0o755)
                info = {"CFBundleIdentifier": identifier, "CFBundleExecutable": executable, "CFBundleName": "WakeLease IPC Fixture",
                        "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "LSMinimumSystemVersion": "15.4", "LSUIElement": True,
                        "WakeLeaseFixtureRoot": str(directory), "WakeLeaseProbeMode": scenario, "WakeLeaseMachService": label}
                (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
            for bundle, identifier in [(service, "org.wakelease.helper"), (app, "org.wakelease")]:
                subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", "--identifier", identifier, "--options", "runtime",
                                "--entitlements", str(entitlements), str(bundle)], check=True, capture_output=True, timeout=15)
            environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(directory), "TMPDIR": str(directory),
                           "WAKELEASE_XPC_PROCESS_FIXTURE": mode, "LANG": "en_US.UTF-8"}
            if mode == "1":
                environment["CI"] = "true"
            agent = directory / f"{label}.plist"
            agent.write_bytes(plistlib.dumps({"Label": label, "ProgramArguments": [str(service / "Contents/MacOS/Service"), scenario],
                                              "MachServices": {label: True}, "EnvironmentVariables": environment,
                                              "RunAtLoad": False, "KeepAlive": False, "ExitTimeOut": 5, "ProcessType": "Background"}))
            agent.chmod(0o600)
            domain = launchd_domain()
            bootstrap = launchctl("bootstrap", domain, str(agent))
            self.assertEqual(bootstrap.returncode, 0, f"launchctl bootstrap {domain}: {bootstrap.stdout}{bootstrap.stderr}")
            try:
                result = subprocess.run([str(app / "Contents/MacOS/Client"), scenario], env=environment,
                                        capture_output=True, text=True, timeout=30)
            finally:
                bootout = launchctl("bootout", f"{domain}/{label}")
                gone = launchctl("print", f"{domain}/{label}")
            self.assertEqual(bootout.returncode, 0, f"launchctl bootout: {bootout.stdout}{bootout.stderr}")
            self.assertNotEqual(gone.returncode, 0, "Temporary Mach service must not outlive its scenario")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            report = json.loads(result.stdout.strip().splitlines()[-1])
            try:
                self.assertEqual(report["scope"], "owned cross-process XPC; no power or persistent registration")
                self.assertEqual(report["scenario"], scenario)
                self.assertEqual(report["serverFailure"], "")
                self.assertEqual(report["serverStage"], "listening")
                self.assertGreater(report["serverPID"], 0)
                self.assertNotEqual(report["serverPID"], report["clientPID"])
                self.assertEqual(report["serverUID"], os.getuid())
                if scenario == "valid":
                    self.assertEqual(report["outcome"], "reply")
                    self.assertEqual(report["accepted"], 1)
                    self.assertEqual(report["calls"], 1)
                    self.assertTrue(report["peerIdentityMatched"])
                else:
                    self.assertEqual(report["outcome"], "rejected")
                    if scenario.startswith("listener"):
                        self.assertEqual(report["accepted"], 0)
                        self.assertEqual(report["calls"], 0)
                    else:
                        self.assertEqual(report["accepted"], 1)
                        self.assertLessEqual(report["calls"], 1)
            finally:
                print("Cross-process XPC evidence: " + json.dumps(report, sort_keys=True), flush=True)

    def test_exact_component_requirement_accepts_a_separate_peer(self):
        self.run_case("valid")

    def test_listener_rejects_a_different_role(self):
        self.run_case("listener-role")

    def test_listener_rejects_a_different_code_hash(self):
        self.run_case("listener-hash")

    def test_client_rejects_a_reply_from_the_wrong_role(self):
        self.run_case("server-role")

    def test_client_rejects_a_reply_from_a_different_code_hash(self):
        self.run_case("server-hash")


if __name__ == "__main__":
    if remote_fixture_mode() is None:
        raise SystemExit("Cross-process verification is restricted to remote CI runners or explicitly opted-in disposable VMs")
    unittest.main(verbosity=2)
