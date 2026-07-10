#!/usr/libexec/platform-python
"""Stdlib unittest suite for monitor.py state/scan logic (platform-python 3.6).
"""

import json
import shutil
import tempfile
import unittest
from pathlib import Path

import monitor
import uploader
from config import Config


class MonitorTestBase(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="novaseqx-monitor-test-"))
        self.addCleanup(shutil.rmtree, str(self.tmp), True)

        self.state_file = self.tmp / "service" / ".processed_analysis_files.json"
        self.state_file.parent.mkdir()

        # A minimal run tree with one Secondary_Analysis_Complete.txt.
        self.base = self.tmp / "mnt" / "runs"
        self.secondary = (self.base / "20260101_LH00111_0001_TESTFLOWCELL"
                          / "Analysis" / "1" / "Data" / "Secondary_Analysis_Complete.txt")
        self.secondary.parent.mkdir(parents=True)
        self.secondary.write_text("done")

        self.config = Config(
            server_url="u", auth_token="t", max_parallel_uploads=4,
            upload_max_attempts=1, retry_base_delay=0, upload_timeout=5, lama_base_url="http://lama.invalid",
            lama_endpoint="api/sequencing/sequencing-run-data",
            lama_max_attempts=1, http_timeout=5,
            mnt_runs_root=str(self.base), local_runs_root=str(self.tmp / "runs"),
            poll_interval=900)

    def make_service(self):
        return monitor.Monitor(self.config, state_file=self.state_file)

    def _patch(self, obj, name, value):
        original = getattr(obj, name)
        setattr(obj, name, value)
        self.addCleanup(setattr, obj, name, original)

    def stub_process(self, success, calls):
        def fake(inner_self, secondary_file, dry_run=False, progress=None, on_progress=None):
            calls.append(secondary_file)
            if progress is not None:
                progress["uploaded"] = ["novaseq/x/fastq/a"]
                progress["lama_done"] = success
            return uploader.UploadResult(success, 1, ["novaseq/x/fastq/a"], 0,
                                         0 if success else 1, success,
                                         None if success else "error message placeholder")
        self._patch(uploader.Uploader, "process", fake)

    def read_state(self):
        return json.loads(self.state_file.read_text())


class MonitorTests(MonitorTestBase):
    def test_success_marks_completed_and_second_scan_skips(self):
        calls = []
        self.stub_process(True, calls)
        service = self.make_service()
        service.load_state()

        service.check_once(str(self.base))
        self.assertEqual(len(calls), 1)
        entry = self.read_state()[str(self.secondary)]
        self.assertEqual(entry["status"], "completed")
        self.assertNotIn("uploaded", entry)  # completed entries stay minimal

        # Second scan: completed flowcell is skipped, process not called again.
        service.check_once(str(self.base))
        self.assertEqual(len(calls), 1)

    def test_failure_marks_failed_and_is_retried(self):
        calls = []
        self.stub_process(False, calls)
        service = self.make_service()
        service.load_state()

        service.check_once(str(self.base))
        self.assertEqual(self.read_state()[str(self.secondary)]["status"], "failed")

        # A failed flowcell is retried on the next scan.
        service.check_once(str(self.base))
        self.assertEqual(len(calls), 2)
        self.assertEqual(self.read_state()[str(self.secondary)]["attempts"], 2)

    def test_dry_run_writes_no_state(self):
        calls = []
        self.stub_process(True, calls)
        self.make_service().check_once(str(self.base), dry_run=True)
        self.assertEqual(len(calls), 1)
        self.assertFalse(self.state_file.exists())

    def test_unexpected_error_is_caught_and_marked_failed(self):
        # A non-UploadError must not escape check_once and kill the poll loop.
        def fake(inner_self, secondary_file, dry_run=False, progress=None, on_progress=None):
            raise RuntimeError("error")
        self._patch(uploader.Uploader, "process", fake)

        service = self.make_service()
        service.load_state()
        service.check_once(str(self.base))  # must not raise

        entry = self.read_state()[str(self.secondary)]
        self.assertEqual(entry["status"], "failed")
        self.assertIn("unexpected error", entry["last_error"])

    def test_save_progress_checkpoints_without_incrementing_attempts(self):
        service = self.make_service()
        service.state = {str(self.secondary): {"status": "failed", "attempts": 2, "uploaded": []}}

        service._save_progress(str(self.secondary), {"uploaded": ["a", "b"], "lama_done": False})

        entry = self.read_state()[str(self.secondary)]
        self.assertEqual(entry["status"], "in_progress")
        self.assertEqual(entry["uploaded"], ["a", "b"])
        self.assertEqual(entry["attempts"], 2)  # checkpoint must not bump the attempt count


if __name__ == "__main__":
    unittest.main(verbosity=2)
