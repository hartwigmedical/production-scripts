#!/usr/libexec/platform-python
"""Stdlib unittest suite for uploader.py (run under platform-python 3.6).
"""

import http.server
import os
import shutil
import stat
import tempfile
import threading
import unittest
from pathlib import Path

import uploader
from config import load_config


FLOWCELL_ID = "20260101_LH00111_0001_TESTFLOWCELL"
FLOWCELL = "TESTFLOWCELL"

CONFIG_TEMPLATE = """\
[upload]
server_url = https://upload.example/test
auth_token = test-token
max_parallel_uploads = 4
upload_max_attempts = {upload_attempts}
retry_base_delay = 0

[lama]
base_url = http://lama.invalid
lama_max_attempts = 2
http_timeout = 5

[paths]
mnt_runs_root = {mnt_root}
local_runs_root = {local_root}

[monitor]
poll_interval = 900
"""


def _write_executable(path, body):
    path.write_text(body)
    path.chmod(path.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)


class UploaderTestBase(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="novaseqx-test-"))
        self.addCleanup(shutil.rmtree, str(self.tmp), True)

        self.mnt_root = self.tmp / "mnt" / "runs"
        self.local_root = self.tmp / "runs"
        self.mnt = self.mnt_root / FLOWCELL_ID
        self.local = self.local_root / FLOWCELL_ID
        self.analysis = self.mnt / "Analysis" / "1"
        self.data = self.analysis / "Data"
        self.fastq_dir = self.data / "BCLConvert" / "fastq"
        self.reports = self.fastq_dir / "Reports"
        self.demux = self.data / "Demux"
        for folder in (self.fastq_dir, self.reports, self.demux, self.local):
            folder.mkdir(parents=True, exist_ok=True)

        # Fastq source names deliberately do NOT contain the flowcell token; the
        # uploader inserts it (this mirrors the *expected* block of the bash test).
        self.fastq_r1 = self.fastq_dir / "SampleA_S1_L001_R1_001.fastq.gz"
        self.fastq_r2 = self.fastq_dir / "SampleA_S1_L001_R2_001.fastq.gz"
        self.quality_metrics = self.reports / "Quality_Metrics.csv"
        self.demux_stats = self.demux / "Demultiplex_Stats.csv"
        self.top_unknown = self.demux / "Top_Unknown_Barcodes.csv"
        self.samplesheet = self.mnt / "SampleSheet.csv"
        self.runinfo = self.mnt / "RunInfo.xml"
        self.run_parameters = self.local / "RunParameters.xml"
        self.secondary = self.data / "Secondary_Analysis_Complete.txt"
        for f in (self.fastq_r1, self.fastq_r2, self.quality_metrics, self.demux_stats,
                  self.top_unknown, self.samplesheet, self.runinfo, self.run_parameters,
                  self.secondary):
            f.write_text("x")

        config_path = self.tmp / "config.ini"
        config_path.write_text(CONFIG_TEMPLATE.format(
            mnt_root=self.mnt_root, local_root=self.local_root, upload_attempts=3))
        self.config = load_config(str(config_path))
        self.gcp = "novaseq/" + FLOWCELL_ID

    def build_manifest(self, config=None):
        up = uploader.Uploader(config or self.config)
        return up.build_manifest(up.parse_run_paths(str(self.secondary)))


class PlanTests(UploaderTestBase):
    def test_parse_run_paths(self):
        run = uploader.Uploader(self.config).parse_run_paths(str(self.secondary))
        self.assertEqual(run.flowcell_id, FLOWCELL_ID)
        self.assertEqual(run.analysis_number, "1")
        self.assertEqual(run.flowcell, FLOWCELL)
        self.assertEqual(run.mounted, self.mnt)
        self.assertEqual(run.analysis, self.analysis)
        self.assertEqual(run.local, self.local)
        self.assertEqual(run.gcp_uri_base, self.gcp)

    def test_bad_layout_raises(self):
        with self.assertRaises(uploader.UploadError):
            uploader.Uploader(self.config).parse_run_paths("/tmp/not/a/valid/path.txt")

    def test_fastq_rename(self):
        self.assertEqual(
            uploader.Uploader._rename_fastq("SampleA_S1_L001_R1_001.fastq.gz", FLOWCELL),
            "SampleA_TESTFLOWCELL_S1_L001_R1_001.fastq.gz")

    def test_flowcell_leading_ab_is_stripped(self):
        for suffix, expected in (("A01CLVJLT1", "01CLVJLT1"),
                                 ("B22ABCDE", "22ABCDE"),
                                 ("C33NOSTRIP", "C33NOSTRIP")):
            secondary = str(self.mnt.parent / ("20260101_LH00111_0001_" + suffix)
                            / "Analysis" / "1" / "Data" / "Secondary_Analysis_Complete.txt")
            run = uploader.Uploader(self.config).parse_run_paths(secondary)
            self.assertEqual(run.flowcell, expected)

    def test_upload_plan_matches_expected_pairs(self):
        manifest = self.build_manifest()
        actual = sorted("  ./upload-file.sh {} {}".format(i.source, i.dest_uri) for i in manifest.items)
        expected = sorted([
            "  ./upload-file.sh {} {}/fastq/SampleA_TESTFLOWCELL_S1_L001_R1_001.fastq.gz".format(self.fastq_r1, self.gcp),
            "  ./upload-file.sh {} {}/fastq/SampleA_TESTFLOWCELL_S1_L001_R2_001.fastq.gz".format(self.fastq_r2, self.gcp),
            "  ./upload-file.sh {} {}/other/Quality_Metrics.csv".format(self.quality_metrics, self.gcp),
            "  ./upload-file.sh {} {}/other/SampleSheet.csv".format(self.samplesheet, self.gcp),
            "  ./upload-file.sh {} {}/other/Demultiplex_Stats.csv".format(self.demux_stats, self.gcp),
            "  ./upload-file.sh {} {}/other/Top_Unknown_Barcodes.csv".format(self.top_unknown, self.gcp),
            "  ./upload-file.sh {} {}/other/RunInfo.xml".format(self.runinfo, self.gcp),
            "  ./upload-file.sh {} {}/other/RunParameters.xml".format(self.run_parameters, self.gcp),
        ])
        self.assertEqual(actual, expected)

    def test_lama_parts(self):
        manifest = self.build_manifest()
        self.assertEqual(manifest.quality_metrics, str(self.quality_metrics))
        self.assertEqual(manifest.unknown_barcodes, str(self.top_unknown))
        self.assertEqual(manifest.run_parameters, str(self.run_parameters))
        self.assertEqual(manifest.fastq_names, [
            "SampleA_TESTFLOWCELL_S1_L001_R1_001.fastq.gz",
            "SampleA_TESTFLOWCELL_S1_L001_R2_001.fastq.gz",
        ])

    def test_missing_required_file_raises(self):
        self.samplesheet.unlink()
        with self.assertRaises(uploader.UploadError):
            self.build_manifest()


class MultipartTests(UploaderTestBase):
    def test_build_multipart_structure(self):
        parts = [("quality-metrics", "Quality_Metrics.csv", b"col1,col2", "text/csv"),
                 ("fastq-files", "-", b"a\nb\n", "text/plain")]
        boundary, body = uploader.Uploader._build_multipart(parts)
        text = body.decode("utf-8")
        self.assertIn(boundary, text)
        self.assertIn('name="quality-metrics"; filename="Quality_Metrics.csv"', text)
        self.assertIn("Content-Type: text/csv", text)
        self.assertIn('name="fastq-files"; filename="-"', text)
        self.assertTrue(body.endswith(("--" + boundary + "--\r\n").encode("ascii")))


class UploadExecutionTests(UploaderTestBase):
    def _install_stub(self, body):
        stub = self.tmp / "upload-file.sh"
        _write_executable(stub, body)
        original = uploader.UPLOAD_FILE_SCRIPT
        uploader.UPLOAD_FILE_SCRIPT = stub
        self.addCleanup(setattr, uploader, "UPLOAD_FILE_SCRIPT", original)
        return stub

    def _stub_lama(self):
        called = {"count": 0}

        def fake_post(inner_self, manifest):
            called["count"] += 1
            return 200
        original = uploader.Uploader._post_to_lama
        uploader.Uploader._post_to_lama = fake_post
        self.addCleanup(setattr, uploader.Uploader, "_post_to_lama", original)
        return called

    def test_upload_retries_then_succeeds(self):
        counter = self.tmp / "counter"
        stub = self._install_stub(
            "#!/bin/bash\n"
            'n=$(cat "$FAIL_COUNTER" 2>/dev/null || echo 0)\n'
            "n=$((n+1))\n"
            'echo "$n" > "$FAIL_COUNTER"\n'
            'if [ "$n" -le "$FAIL_TIMES" ]; then echo "fail $n" >&2; exit 1; fi\n'
            "exit 0\n")
        os.environ["FAIL_COUNTER"] = str(counter)
        os.environ["FAIL_TIMES"] = "2"
        self.addCleanup(os.environ.pop, "FAIL_COUNTER", None)
        self.addCleanup(os.environ.pop, "FAIL_TIMES", None)

        item = uploader.UploadItem(str(self.fastq_r1), self.gcp + "/fastq/x.fastq.gz")
        result = uploader.Uploader(self.config)._upload_one(item, os.environ.copy())
        self.assertEqual(result, item.dest_uri)
        self.assertEqual(counter.read_text().strip(), "3")  # 2 failures + 1 success

    def test_upload_timeout_retries_then_fails(self):
        counter = self.tmp / "attempts"
        self._install_stub('#!/bin/bash\necho x >> "$TIMEOUT_COUNTER"\nsleep 5\n')
        os.environ["TIMEOUT_COUNTER"] = str(counter)
        self.addCleanup(os.environ.pop, "TIMEOUT_COUNTER", None)
        config = self.config._replace(upload_timeout=0.3, upload_max_attempts=2, retry_base_delay=0)

        item = uploader.UploadItem(str(self.fastq_r1), self.gcp + "/fastq/x.fastq.gz")
        with self.assertRaises(uploader.UploadError):
            uploader.Uploader(config)._upload_one(item, os.environ.copy())
        self.assertEqual(len(counter.read_text().split()), 2)  # hung upload timed out and was retried

    def test_resume_skips_already_uploaded(self):
        log = self.tmp / "uploaded.log"
        self._install_stub("#!/bin/bash\necho \"$2\" >> \"$UPLOAD_LOG\"\nexit 0\n")
        os.environ["UPLOAD_LOG"] = str(log)
        self.addCleanup(os.environ.pop, "UPLOAD_LOG", None)
        self._stub_lama()

        r1_dest = self.gcp + "/fastq/SampleA_TESTFLOWCELL_S1_L001_R1_001.fastq.gz"
        r2_dest = self.gcp + "/fastq/SampleA_TESTFLOWCELL_S1_L001_R2_001.fastq.gz"
        progress = {"uploaded": [r1_dest, r2_dest], "lama_done": False}

        result = uploader.Uploader(self.config).process(str(self.secondary), progress=progress)
        self.assertTrue(result.success)
        self.assertEqual(result.skipped, 2)

        uploaded_now = log.read_text().split()
        self.assertNotIn(r1_dest, uploaded_now)
        self.assertNotIn(r2_dest, uploaded_now)
        self.assertIn(self.gcp + "/other/Quality_Metrics.csv", uploaded_now)
        self.assertTrue(progress["lama_done"])

    def test_failed_upload_still_registers_with_lama_and_marks_failed(self):
        self._install_stub("#!/bin/bash\necho boom >&2\nexit 1\n")
        called = self._stub_lama()
        fast_config = self.config._replace(upload_max_attempts=1)

        result = uploader.Uploader(fast_config).process(
            str(self.secondary), progress={"uploaded": [], "lama_done": False})
        self.assertFalse(result.success)          # failed uploads -> not completed
        self.assertGreater(result.failed, 0)
        self.assertTrue(result.lama_done)         # ...but LAMA is still called
        self.assertEqual(called["count"], 1)      # exactly once, with all discovered files


class _CapturingHandler(http.server.BaseHTTPRequestHandler):
    status_code = 200
    requests = None  # set per-test to a list

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        type(self).requests.append({
            "content_type": self.headers.get("Content-Type", ""),
            "body": body,
        })
        self.send_response(type(self).status_code)
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, *args):
        pass


class LamaPostTests(UploaderTestBase):
    def _start_server(self, status_code):
        requests = []
        handler = type("Handler", (_CapturingHandler,),
                       {"status_code": status_code, "requests": requests})
        server = http.server.HTTPServer(("127.0.0.1", 0), handler)
        thread = threading.Thread(target=server.serve_forever)
        thread.daemon = True
        thread.start()
        self.addCleanup(server.shutdown)
        self.addCleanup(server.server_close)
        port = server.server_address[1]
        return "http://127.0.0.1:{}".format(port), requests

    def test_lama_post_success(self):
        base_url, requests = self._start_server(200)
        config = self.config._replace(lama_base_url=base_url)
        manifest = self.build_manifest(config)
        status = uploader.Uploader(config)._post_to_lama(manifest)
        self.assertEqual(status, 200)
        self.assertEqual(len(requests), 1)
        body = requests[0]["body"].decode("utf-8")
        self.assertTrue(requests[0]["content_type"].startswith("multipart/form-data; boundary="))
        for field in ("quality-metrics", "unknown-barcodes", "run-parameters", "fastq-files"):
            self.assertIn('name="%s"' % field, body)
        self.assertIn("Content-Type: text/xml", body)
        self.assertIn("SampleA_TESTFLOWCELL_S1_L001_R1_001.fastq.gz", body)

    def test_lama_post_non_2xx_retries_then_fails(self):
        base_url, requests = self._start_server(500)
        config = self.config._replace(lama_base_url=base_url, lama_max_attempts=2)
        manifest = self.build_manifest(config)
        with self.assertRaises(uploader.UploadError):
            uploader.Uploader(config)._post_to_lama(manifest)
        self.assertEqual(len(requests), 2)  # retried up to lama_max_attempts


if __name__ == "__main__":
    unittest.main(verbosity=2)
