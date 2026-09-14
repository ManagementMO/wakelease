import json
import os
from pathlib import Path
import select
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SDK = ROOT / ".build/pi-host/node_modules/@earendil-works/pi-coding-agent"
BIN = Path(os.environ.get("WAKELEASE_BIN_DIR", ROOT / ".build/source-testing/debug"))


class PiHostSmoke(unittest.TestCase):
    def test_real_sdk_extension_lifecycle_with_no_network_or_paid_provider(self):
        if not (SDK / "package.json").is_file():
            if os.environ.get("WAKELEASE_REQUIRE_PI_HOST") == "1":
                self.fail("Install the pinned test-only Pi 0.83.0 SDK before running this fixture")
            self.skipTest("Optional pinned Pi SDK fixture is not installed")
        self.assertEqual(json.loads((SDK / "package.json").read_text())["version"], "0.83.0")
        node = shutil.which("node")
        self.assertIsNotNone(node)
        with tempfile.TemporaryDirectory(prefix="wl-pi-host-") as temporary:
            home = Path(temporary)
            workspace = home / "work"
            workspace.mkdir()
            (home / "tmp").mkdir()
            state = home / "state"
            environment = {"PATH": str(Path(node).parent) + ":/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(home), "TMPDIR": str(home / "tmp"),
                           "XDG_CONFIG_HOME": str(home / "config"), "XDG_CACHE_HOME": str(home / "cache"), "PI_CODING_AGENT_DIR": str(home / ".pi/agent"),
                           "PI_OFFLINE": "1", "AWS_EC2_METADATA_DISABLED": "true", "TERM": "dumb", "LANG": "en_US.UTF-8", "WAKELEASE_STATE_DIR": str(state)}
            daemon = subprocess.Popen([str(BIN / "WakeLeaseDaemon"), "--simulate", "--state-dir", str(state)], env=environment,
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                self.assertTrue(select.select([daemon.stdout], [], [], 10)[0])
                self.assertIn("ready (simulation)", daemon.stdout.readline())
                install = subprocess.run([str(BIN / "wakelease"), "integrations", "install", "pi", "--home", str(home), "--yes"], env=environment,
                                         capture_output=True, text=True, timeout=10)
                self.assertEqual(install.returncode, 0, install.stderr)
                run = subprocess.run([node, str(ROOT / "Tests/pi_host_smoke.mjs"), str(SDK), str(home), str(BIN / "wakelease")], cwd=workspace,
                                     env=environment, capture_output=True, text=True, timeout=40)
                self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
                report = json.loads(run.stdout.strip().splitlines()[-1])
                self.assertEqual(report["networkAttempts"], 0)
                self.assertEqual(len(report["verified"]), 8)
                print("Pi host evidence: " + json.dumps(report, sort_keys=True))
            finally:
                daemon.terminate()
                try:
                    daemon.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    daemon.kill()
                    daemon.wait(timeout=5)
                daemon.stdout.close()
                daemon.stderr.close()


if __name__ == "__main__":
    unittest.main(verbosity=2)
