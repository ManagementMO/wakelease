import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest


class PackageSmoke(unittest.TestCase):
    def test_development_bundle_is_complete_signed_and_still_refuses_privilege(self):
        root = Path(__file__).resolve().parents[1]
        binaries = Path(os.environ.get("WAKELEASE_BIN_DIR", root / ".build/source-testing/debug"))
        with tempfile.TemporaryDirectory(prefix="wl-package-") as directory:
            directory = Path(directory)
            app = directory / "WakeLease.app"
            subprocess.run(["python3", str(root / "Scripts/build-app.py"), "--bin-dir", str(binaries), "--configuration", "debug", "--output", str(app)], check=True, timeout=45)
            info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
            self.assertEqual(info["CFBundleIdentifier"], "org.wakelease")
            self.assertEqual(info["LSMinimumSystemVersion"], "15.4")
            self.assertTrue((app / "Contents/Resources/LICENSE").is_file())
            self.assertTrue((app / "Contents/Resources/AppIcon.icns").is_file())
            executable = app / "Contents/MacOS/WakeLease"
            cli = app / "Contents/Helpers/wakelease"
            self.assertIn("WakeLease 0.1.0", subprocess.check_output([str(executable), "--version"], text=True, timeout=5))
            self.assertIn("wakelease 0.1.0", subprocess.check_output([str(cli), "version"], text=True, timeout=5))
            for relative in ["Contents/Library/LaunchAgents/WakeLeaseDaemon", "Contents/Library/LaunchDaemons/WakeLeaseHelper"]:
                rejected = subprocess.run([str(app / relative)], capture_output=True, timeout=5)
                self.assertEqual(rejected.returncode, 78, rejected.stderr.decode(errors="replace"))
            if os.environ.get("WAKELEASE_HEADLESS") != "1":
                image = directory / "preview.png"
                subprocess.run([str(executable), "--preview", "active", "--snapshot", str(image)], check=True, timeout=15)
                self.assertGreater(image.stat().st_size, 5000)


if __name__ == "__main__":
    unittest.main(verbosity=2)
