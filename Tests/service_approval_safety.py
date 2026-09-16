import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True

import service_approval_probe as probe


class ApprovalCleanupSafety(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="wakelease-approval-safety-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "fixture"
        self.root.mkdir()
        self.files = {
            "fixture.json": b'{"identifier":"org.wakelease.registration-probe.test","displayName":"Owned fixture","executable":"unused"}',
            "recovery-binary": b"owned harmless recovery fixture",
            "agent-started.json": b'{"pid":123,"uid":501,"parentPID":1}',
        }
        for name, contents in self.files.items():
            (self.root / name).write_bytes(contents)

    def response(self, clean):
        return {
            "scope": "approved disposable CI or Devin Cloud Mac only; no power operations",
            "bundleIdentifier": "org.wakelease.registration-probe.test",
            "mode": "cleanup", "cleanupOnly": True, "cleanupOK": clean,
            "services": [{"kind": "daemon", "before": "requiresApproval", "afterRegistration": "requiresApproval",
                          "afterCleanup": "notRegistered" if clean else "requiresApproval"}],
            "displayName": "Owned fixture", "root": str(self.root),
        }

    def assert_fixture_preserved(self):
        self.assertTrue(self.root.is_dir(), "Failed cleanup must retain the recovery directory")
        for name, contents in self.files.items():
            self.assertEqual((self.root / name).read_bytes(), contents)

    def test_failed_unregistration_preserves_recovery_and_allows_retry(self):
        with patch.object(probe, "run_app", return_value=self.response(False)):
            with self.assertRaises(SystemExit):
                probe.cleanup(self.root)
        self.assert_fixture_preserved()
        with patch.object(probe, "run_app", return_value=self.response(True)):
            result = probe.cleanup(self.root)
        self.assertTrue(result["cleanupOK"])
        self.assertFalse(self.root.exists())

    def test_native_timeout_does_not_delete_recovery_files(self):
        error = subprocess.TimeoutExpired(["owned-dummy", "cleanup"], 1)
        with patch.object(probe, "run_app", side_effect=error):
            with self.assertRaises(subprocess.TimeoutExpired):
                probe.cleanup(self.root)
        self.assert_fixture_preserved()

    def test_missing_native_report_does_not_delete_recovery_files(self):
        with patch.object(probe, "run_app", side_effect=SystemExit("No cleanup report")):
            with self.assertRaises(SystemExit):
                probe.cleanup(self.root)
        self.assert_fixture_preserved()

    def test_unreadable_evidence_is_retained_for_diagnosis(self):
        self.files["agent-started.json"] = b"["
        (self.root / "agent-started.json").write_bytes(b"[")
        with patch.object(probe, "run_app", return_value=self.response(True)):
            with self.assertRaises(json.JSONDecodeError):
                probe.cleanup(self.root)
        self.assert_fixture_preserved()

    def test_confirmed_cleanup_returns_evidence_and_removes_only_its_directory(self):
        sibling = Path(self.temporary.name) / "unrelated"
        sibling.write_bytes(b"keep")
        with patch.object(probe, "run_app", return_value=self.response(True)):
            result = probe.cleanup(self.root)
        self.assertEqual(result["startup"], {"agent": {"pid": 123, "uid": 501, "parentPID": 1}, "daemon": None})
        self.assertFalse(self.root.exists())
        self.assertEqual(sibling.read_bytes(), b"keep")

    @unittest.skipIf(os.geteuid() == 0, "Permission failure requires an unprivileged runner")
    def test_file_removal_failure_is_not_reported_as_success(self):
        parent = Path(self.temporary.name)
        parent.chmod(0o500)
        try:
            with patch.object(probe, "run_app", return_value=self.response(True)):
                with self.assertRaises(PermissionError):
                    probe.cleanup(self.root)
            self.assertTrue(self.root.exists())
        finally:
            parent.chmod(0o700)


if __name__ == "__main__":
    if os.environ.get("CI") != "true":
        raise SystemExit("Run diagnostic cleanup verification on disposable CI only")
    unittest.main(verbosity=2)
