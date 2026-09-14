import os
from pathlib import Path
import subprocess
import unittest
import uuid


ROOT = Path(__file__).resolve().parents[1]
BIN = Path(os.environ.get("WAKELEASE_BIN_DIR", ROOT / ".build/source-testing/debug"))


class ProbePathValidation(unittest.TestCase):
    def test_non_fixture_paths_and_traversal_are_rejected(self):
        identifier = str(uuid.uuid4())
        for path in ["/tmp/wakelease-removal-test-" + identifier,
                     "/private/tmp/../tmp/wakelease-removal-test-" + identifier,
                     "/private/tmp/wakelease-removal-test-" + identifier + "/child",
                     "/private/tmp/wakelease-removal-test-invalid"]:
            with self.subTest(path=path):
                result = subprocess.run([str(BIN / "WakeLeaseRemovalProbe"), "validate", path, str(os.getuid()), identifier], capture_output=True, timeout=10)
                self.assertEqual(result.returncode, 64)

    def test_fixture_path_is_stable_before_and_after_creation(self):
        path = Path("/private/tmp/wakelease-removal-test-" + str(uuid.uuid4()))
        command = [str(BIN / "WakeLeaseRemovalProbe"), "validate", str(path), str(os.getuid()), str(uuid.uuid4())]
        try:
            before = subprocess.run(command, capture_output=True, timeout=10)
            self.assertEqual(before.returncode, 0, before.stderr)
            path.mkdir()
            after = subprocess.run(command, capture_output=True, timeout=10)
            self.assertEqual(after.returncode, 0, after.stderr)
        finally:
            if path.exists():
                path.rmdir()


@unittest.skipUnless(os.environ.get("CI") == "true" and os.environ.get("WAKELEASE_ROOT_FIXTURE") == "1", "Opt-in disposable CI root-owned filesystem fixture only")
class RootRemovalSmoke(unittest.TestCase):
    def test_root_owned_reservation_has_narrow_delegated_cleanup(self):
        probe = BIN / "WakeLeaseRemovalProbe"
        path = "/private/tmp/wakelease-removal-test-" + str(uuid.uuid4())
        arguments = [path, str(os.getuid()), str(uuid.uuid4())]
        create = ["sudo", "-n", str(probe), "create", *arguments]
        try:
            subprocess.run(create, check=True, timeout=15)
            subprocess.run([str(probe), "verify-delete", *arguments], check=True, timeout=15)
        finally:
            subprocess.run(["sudo", "-n", str(probe), "cleanup", *arguments], check=True, timeout=15)


if __name__ == "__main__":
    unittest.main(verbosity=2)
