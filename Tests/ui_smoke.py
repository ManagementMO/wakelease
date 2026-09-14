import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import tempfile
import unittest
import uuid


class NativeUISmoke(unittest.TestCase):
    def audit(self, surface="custom-integration", mode="inspect", executable=None):
        root = Path(__file__).resolve().parents[1]
        executable = executable or Path(os.environ.get("WAKELEASE_BIN_DIR", root / ".build/source-testing/debug")) / "WakeLeaseMenu"
        clipboard = "wakelease-ui-test-" + uuid.uuid4().hex
        process = subprocess.Popen([str(executable), "--preview", "normal", "--" + surface, "--preview-pasteboard", clipboard, "-ApplePersistenceIgnoreState", "YES"],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            result = subprocess.run(["swift", str(root / "Tests/ui_accessibility.swift"), str(process.pid), str(executable), clipboard, mode],
                                    capture_output=True, text=True, timeout=60)
            if result.returncode == 77:
                if os.environ.get("WAKELEASE_REQUIRE_UI_AUDIT") == "1":
                    self.fail(result.stderr.strip())
                self.skipTest(result.stderr.strip())
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            report = json.loads(result.stdout.strip().splitlines()[-1])
            self.assertEqual(report["scope"], "preview-only")
            self.assertTrue(report["clipboardIsolated"])
            self.assertGreater(len(report["nodes"]), 10)
            return report
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
            process.stdout.close()
            process.stderr.close()

    def test_custom_setup_exports_native_accessibility_elements(self):
        report = self.audit()
        labels = {node.get("label") for node in report["nodes"]}
        self.assertIn("Source identifier", labels)
        self.assertIn("Work identifier environment variable", labels)
        self.assertIn("Copy Work starts / resumes command", labels)

    def test_native_settings_keyboard_and_copy_workflows(self):
        report = self.audit("settings", "workflow")
        self.assertEqual(set(report["checks"]), {"native-accessibility-labels", "tab-navigation", "isolated-copy-command",
                                             "copy-feedback-invalidated-on-edit", "display-and-json-recipe", "invalid-recipe-blocks-copy",
                                             "menu-visibility-toggle", "settings-section-navigation", "escape-closes-custom-sheet", "return-closes-custom-sheet"})

    def test_maximum_recipe_content_wraps_and_remains_usable(self):
        report = self.audit("settings", "content")
        self.assertEqual(set(report["checks"]), {"long-event-labels-wrap", "long-label-copy-buttons-fit", "maximum-recipe-content-round-trips",
                                               "long-command-text-stays-in-sheet", "oversized-content-scrolls-to-actions"})

    def test_invalid_recipe_fields_remain_editable_and_recover(self):
        report = self.audit("settings", "validation")
        self.assertEqual(set(report["checks"]), {"invalid-executable-remains-editable", "invalid-recipe-clears-copy-actions",
                                               "error-focus-preserved", "recipe-recovers-after-edit", "invalid-identity-fields-recover"})

    def test_hidden_icon_close_and_reopen_uses_the_same_app_process(self):
        root = Path(__file__).resolve().parents[1]
        binaries = Path(os.environ.get("WAKELEASE_BIN_DIR", root / ".build/source-testing/debug"))
        with tempfile.TemporaryDirectory(prefix="wl-ui-reopen-", dir=root / ".build") as directory:
            app = Path(directory) / "WakeLease UI Test.app"
            executable = app / "Contents/MacOS/WakeLeaseMenu"
            executable.parent.mkdir(parents=True)
            shutil.copy2(binaries / "WakeLeaseMenu", executable)
            info = {"CFBundleIdentifier": "org.wakelease.ui-test." + uuid.uuid4().hex,
                    "CFBundleName": "WakeLease UI Test", "CFBundleExecutable": "WakeLeaseMenu", "CFBundlePackageType": "APPL",
                    "LSUIElement": True, "NSPrincipalClass": "NSApplication", "NSSupportsAutomaticTermination": False,
                    "LSMinimumSystemVersion": "15.4", "NSHighResolutionCapable": True}
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
            subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True, capture_output=True, timeout=10)
            report = self.audit("settings", "reopen", executable)
            self.assertEqual(set(report["checks"]), {"menu-item-removed", "hidden-app-stays-running", "reopen-restores-settings",
                                                   "reopen-preserves-hidden-preference", "reopen-reuses-window", "menu-item-restored"})

    def test_isolated_preview_windows_render_and_exit(self):
        root = Path(__file__).resolve().parents[1]
        executable = Path(os.environ.get("WAKELEASE_BIN_DIR", root / ".build/source-testing/debug")) / "WakeLeaseMenu"
        with tempfile.TemporaryDirectory(prefix="wl-ui-") as directory:
            for state, surface, appearance in [("active", "menu", "dark"), ("normal", "menu", "light"), ("waiting", "menu", "dark"), ("cutout", "menu", "light"), ("normal", "settings", "dark"), ("normal", "settings", "light"), ("normal", "custom-integration", "light"), ("normal", "custom-integration", "dark")]:
                with self.subTest(state=state, surface=surface, appearance=appearance):
                    image = Path(directory) / (state + "-" + surface + "-" + appearance + ".png")
                    command = [str(executable), "--preview", state, "--snapshot", str(image), "--" + appearance]
                    if surface != "menu":
                        command.append("--" + surface)
                    result = subprocess.run(command, capture_output=True, timeout=15)
                    self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
                    data = image.read_bytes()
                    self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n")
                    width, height = struct.unpack(">II", data[16:24])
                    self.assertGreaterEqual(width, 300)
                    self.assertGreaterEqual(height, 250)
                    self.assertGreater(len(data), 5000)


if __name__ == "__main__":
    unittest.main(verbosity=2)
