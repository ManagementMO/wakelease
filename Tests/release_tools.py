from pathlib import Path
import subprocess
import unittest


class CaskGeneratorTests(unittest.TestCase):
    def invoke(self, *extra):
        script = Path(__file__).resolve().parents[1] / "Scripts/generate-cask.py"
        return subprocess.run(["python3", str(script), "--url", "https://example.invalid/WakeLease.zip", "--homepage", "https://example.invalid/wakelease", "--version", "0.1.0", "--sha256", "a" * 64, "--arch", "arm64", *extra], capture_output=True, text=True)

    def test_cleanup_failure_is_not_ignored_by_package_manager(self):
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("must_succeed: true", result.stdout)
        self.assertIn('["--uninstall", "--yes"]', result.stdout)
        self.assertNotIn("launchctl:", result.stdout)
        self.assertNotIn("zap", result.stdout)
        self.assertIn('MacOSVersion.new("15.4")', result.stdout)

    def test_invalid_or_credential_bearing_urls_are_refused(self):
        self.assertNotEqual(self.invoke("--url", "http://example.invalid/app.zip").returncode, 0)
        self.assertNotEqual(self.invoke("--url", "https://user:password@example.invalid/app.zip").returncode, 0)
        self.assertNotEqual(self.invoke("--sha256", "not-a-checksum").returncode, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
