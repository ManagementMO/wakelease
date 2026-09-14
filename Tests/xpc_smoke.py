import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
BIN = Path(os.environ.get("WAKELEASE_BIN_DIR", ROOT / ".build/source-testing/debug"))


class XPCBoundarySmoke(unittest.TestCase):
    def test_owned_adhoc_identity_and_real_xpc_requirement_boundaries(self):
        with tempfile.TemporaryDirectory(prefix="wl-xpc-") as directory:
            home = Path(directory)
            probe = home / "WakeLeaseXPCProbe"
            shutil.copy2(BIN / "WakeLeaseXPCProbe", probe)
            subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", "--identifier", "org.wakelease.test.xpc", str(probe)],
                           check=True, capture_output=True, timeout=10)
            subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(probe)], check=True, capture_output=True, timeout=10)
            environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(home), "TMPDIR": str(home), "LANG": "en_US.UTF-8"}
            for _ in range(3):
                result = subprocess.run([str(probe)], env=environment, capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                report = json.loads(result.stdout.strip())
                self.assertTrue(report["positiveRoundTrip"])
                self.assertEqual(report["listenerRoleRejections"], 3)
                self.assertTrue(report["untrustedReplyRejected"])
                self.assertEqual(report["scope"], "owned ad-hoc process; anonymous XPC only")
            print("Native XPC evidence: " + json.dumps(report, sort_keys=True))


if __name__ == "__main__":
    unittest.main(verbosity=2)
