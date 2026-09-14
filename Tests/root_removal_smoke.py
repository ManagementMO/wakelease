import os
from pathlib import Path
import subprocess
import unittest
import uuid


ROOT = Path(__file__).resolve().parents[1]
BIN = Path(os.environ.get("WAKELEASE_BIN_DIR", ROOT / ".build/source-testing/debug"))


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
