import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / ".build/source-testing/debug/WakeLeaseXPCProcessProbe"


class CrossProcessXPCSmoke(unittest.TestCase):
    def run_case(self, scenario):
        with tempfile.TemporaryDirectory(prefix="wakelease-xpc-process-", dir=os.environ["RUNNER_TEMP"]) as temporary:
            directory = Path(temporary).resolve()
            app = directory / "Client.app"
            service = app / "Contents/XPCServices/Probe.xpc"
            entitlements = directory / "entitlements.plist"
            entitlements.write_bytes(plistlib.dumps({}))
            for bundle, identifier, executable, kind in [(app, "org.wakelease", "Client", "APPL"),
                                                          (service, "org.wakelease.helper", "Service", "XPC!")]:
                binary = bundle / "Contents/MacOS" / executable
                binary.parent.mkdir(parents=True)
                shutil.copy2(BIN, binary)
                binary.chmod(0o755)
                info = {"CFBundleIdentifier": identifier, "CFBundleExecutable": executable, "CFBundleName": "WakeLease IPC Fixture",
                        "CFBundlePackageType": kind, "CFBundleVersion": "1", "LSMinimumSystemVersion": "15.4",
                        "WakeLeaseFixtureRoot": str(directory), "WakeLeaseProbeMode": scenario}
                if kind == "XPC!":
                    info["XPCService"] = {"ServiceType": "Application", "RunLoopType": "dispatch_main"}
                else:
                    info["LSUIElement"] = True
                (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
            for bundle, identifier in [(service, "org.wakelease.helper"), (app, "org.wakelease")]:
                subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", "--identifier", identifier, "--options", "runtime",
                                "--entitlements", str(entitlements), str(bundle)], check=True, capture_output=True, timeout=15)
            environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(directory), "TMPDIR": str(directory),
                           "CI": "true", "WAKELEASE_XPC_PROCESS_FIXTURE": "1", "LANG": "en_US.UTF-8"}
            result = subprocess.run([str(app / "Contents/MacOS/Client"), scenario], env=environment,
                                    capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            report = json.loads(result.stdout.strip().splitlines()[-1])
            self.assertEqual(report["scope"], "owned cross-process XPC; no power or persistent registration")
            self.assertEqual(report["scenario"], scenario)
            if scenario == "valid" or scenario.startswith("listener"):
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
                    self.assertLessEqual(report["calls"], 1)
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
    if os.environ.get("CI") != "true" or os.environ.get("WAKELEASE_XPC_PROCESS_FIXTURE") != "1":
        raise SystemExit("Cross-process verification is restricted to the remote CI fixture")
    unittest.main(verbosity=2)
