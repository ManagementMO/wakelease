import hashlib
import json
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
            for arguments in [["--preview-pasteboard", "wakelease-ui-test-00"],
                              ["--preview", "normal", "--preview-pasteboard", "NSGeneralPboard"],
                              ["--preview", "normal", "--preview-pasteboard"],
                              ["--preview", "normal", "--preview-pasteboard", "wakelease-ui-test-00", "--uninstall", "--dry-run"]]:
                rejected = subprocess.run([str(executable), *arguments], capture_output=True, timeout=5)
                self.assertEqual(rejected.returncode, 64, rejected.stderr.decode(errors="replace"))
            for relative in ["Contents/Library/LaunchAgents/WakeLeaseDaemon", "Contents/Library/LaunchDaemons/WakeLeaseHelper"]:
                rejected = subprocess.run([str(app / relative)], capture_output=True, timeout=5)
                self.assertEqual(rejected.returncode, 78, rejected.stderr.decode(errors="replace"))
            if os.environ.get("WAKELEASE_HEADLESS") != "1":
                image = directory / "preview.png"
                subprocess.run([str(executable), "--preview", "active", "--snapshot", str(image)], check=True, timeout=15)
                self.assertGreater(image.stat().st_size, 5000)


@unittest.skipUnless(os.environ.get("WAKELEASE_COMMUNITY_DIST"), "No community artifact directory selected")
class CommunityArtifactSmoke(unittest.TestCase):
    def test_packages_preserve_exact_verified_payloads_and_checksums(self):
        distribution = Path(os.environ["WAKELEASE_COMMUNITY_DIST"]).resolve()
        expected = json.loads((distribution / "components.json").read_text())
        worker_hash = None
        with tempfile.TemporaryDirectory(prefix="wakelease-artifact-inspection-") as temporary:
            for index, name in enumerate(["Install WakeLease.pkg", "Repair Interrupted Install.pkg", "Remove Installer Approval.pkg"]):
                package = distribution / name
                digest = hashlib.sha256(package.read_bytes()).hexdigest()
                self.assertEqual(package.with_suffix(".pkg.sha256").read_text(), digest + "  " + name + "\n")
                expanded = Path(temporary) / str(index)
                subprocess.run(["pkgutil", "--expand-full", str(package), str(expanded)], check=True, timeout=30)
                workers = list(expanded.rglob("WakeLeaseInstaller"))
                self.assertEqual(len(workers), 1)
                worker = workers[0]
                current_hash = hashlib.sha256(worker.read_bytes()).hexdigest()
                if worker_hash is not None:
                    self.assertEqual(current_hash, worker_hash)
                worker_hash = current_hash
                subprocess.run(["codesign", "--verify", "--strict", str(worker)], check=True, timeout=10)
                manifest = worker.with_name("components.json")
                self.assertEqual(json.loads(manifest.read_text()), expected)
                architectures = set(subprocess.check_output(["lipo", "-archs", str(worker)], text=True, timeout=10).split())
                self.assertTrue(architectures and architectures <= {"arm64", "x86_64"})
                for script in [worker.with_name("preinstall"), worker.with_name("postinstall")]:
                    if script.exists():
                        subprocess.run(["/bin/sh", "-n", str(script)], check=True, timeout=5)
                apps = list(expanded.rglob("WakeLease.app"))
                self.assertEqual(len(apps), 0 if name == "Remove Installer Approval.pkg" else 1)
                if apps:
                    app = apps[0]
                    self.assertTrue((app / "Contents/Resources/LICENSE").is_file())
                    actual = set(subprocess.check_output(["lipo", "-archs", str(app / "Contents/MacOS/WakeLease")], text=True, timeout=10).split())
                    self.assertEqual(actual, architectures)
                    subprocess.run([str(worker), "verify", str(app), str(manifest)], check=True, timeout=30)
        image = distribution / "WakeLease.dmg"
        if image.exists():
            digest = hashlib.sha256(image.read_bytes()).hexdigest()
            self.assertEqual(image.with_suffix(".dmg.sha256").read_text(), digest + "  " + image.name + "\n")
            subprocess.run(["hdiutil", "verify", str(image)], check=True, timeout=60)


if __name__ == "__main__":
    unittest.main(verbosity=2)
