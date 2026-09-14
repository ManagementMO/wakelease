import json
import os
from pathlib import Path
import platform
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class CommunityPackageSmoke(unittest.TestCase):
    def test_community_bundle_is_installer_required_and_exactly_verifiable(self):
        installer = Path(os.environ.get("WAKELEASE_BIN_DIR", ROOT / ".build/source-testing/debug")) / "WakeLeaseInstaller"
        with tempfile.TemporaryDirectory(prefix="wakelease-community-") as directory:
            directory = Path(directory)
            app = directory / "WakeLease.app"
            result = subprocess.run(["python3", str(ROOT / "Scripts/build-app.py"), "--community", "--configuration", "release",
                                     "--arch", platform.machine(), "--output", str(app)], timeout=900)
            self.assertEqual(result.returncode, 0)
            build = json.loads((app / "Contents/Resources/WakeLeaseBuild.json").read_text())
            self.assertFalse(build["developmentOnly"])
            self.assertTrue(build["requiresInstallerApproval"])
            hashes = {}
            for identifier, relative in [("org.wakelease", "Contents/MacOS/WakeLease"), ("org.wakelease.cli", "Contents/Helpers/wakelease"),
                                         ("org.wakelease.daemon", "Contents/Library/LaunchAgents/WakeLeaseDaemon"),
                                         ("org.wakelease.helper", "Contents/Library/LaunchDaemons/WakeLeaseHelper")]:
                output = subprocess.run(["codesign", "--display", "--verbose=4", str(app / relative)], capture_output=True, text=True, check=True, timeout=10).stderr
                hashes[identifier] = [re.search(r"^CDHash=([a-f0-9]{40})$", output, re.MULTILINE)[1]]
            record = {"version": 1, "build": build["commit"], "hashes": hashes}
            manifest = directory / "components.json"
            manifest.write_text(json.dumps(record))
            subprocess.run([str(installer), "verify", str(app), str(manifest)], check=True, timeout=20)
            record["hashes"]["org.wakelease.helper"] = ["0000000000000000000000000000000000000000"]
            manifest.write_text(json.dumps(record))
            rejected = subprocess.run([str(installer), "verify", str(app), str(manifest)], capture_output=True, timeout=20)
            self.assertNotEqual(rejected.returncode, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
