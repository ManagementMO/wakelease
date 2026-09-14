import os
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest


class NativeUISmoke(unittest.TestCase):
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
