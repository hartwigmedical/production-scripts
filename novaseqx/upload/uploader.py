#!/usr/libexec/platform-python
"""Upload NovaSeq X secondary-analysis output to GCP and register it with LAMA."""

import argparse
import binascii
import logging
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from typing import List, NamedTuple, Optional

from config import ConfigError, load_config

LOG = logging.getLogger("novaseqx.uploader")

SCRIPT_DIR = Path(__file__).resolve().parent
UPLOAD_FILE_SCRIPT = SCRIPT_DIR / "upload-file.sh"

SECONDARY_ANALYSIS_FILE = "Secondary_Analysis_Complete.txt"

class UploadError(Exception):
    pass

class RunPaths(NamedTuple):
    flowcell_id: str
    analysis_number: str
    flowcell: str
    mounted: Path
    analysis: Path
    local: Path
    gcp_uri_base: str

class UploadItem(NamedTuple):
    source: str
    dest_uri: str

class UploadManifest(NamedTuple):
    items: List[UploadItem]
    fastq_names: List[str]
    quality_metrics: Optional[str]
    unknown_barcodes: Optional[str]
    run_parameters: Optional[str]


class UploadResult(NamedTuple):
    success: bool
    found: int
    uploaded: List[str]
    skipped: int
    failed: int
    lama_done: bool
    error: Optional[str]


def setup_logging(level=logging.INFO):
    """Timestamped logging; INFO to stdout, WARNING+ to stderr (systemd splits them)."""
    root = logging.getLogger()
    if root.handlers:
        return
    fmt = logging.Formatter("%(asctime)s %(levelname)s %(message)s", datefmt="%Y-%m-%d %H:%M:%S")

    out = logging.StreamHandler(sys.stdout)
    out.setLevel(level)
    out.addFilter(lambda record: record.levelno < logging.WARNING)
    out.setFormatter(fmt)

    err = logging.StreamHandler(sys.stderr)
    err.setLevel(logging.WARNING)
    err.setFormatter(fmt)

    root.addHandler(out)
    root.addHandler(err)
    root.setLevel(level)

class Uploader:

    def __init__(self, config):
        self.config = config

    def process(self, secondary_file, dry_run=False, progress=None):
        """Process one Secondary_Analysis_Complete.txt; mutates ``progress`` for resume."""
        if progress is None:
            progress = {"uploaded": [], "lama_done": False}
        already_uploaded = set(progress.get("uploaded") or [])
        lama_done = bool(progress.get("lama_done", False))

        run = self.parse_run_paths(secondary_file)
        LOG.info("Flowcell ID: %s, Analysis: %s, flowcell token: %s",
                 run.flowcell_id, run.analysis_number, run.flowcell)
        manifest = self.build_manifest(run)
        LOG.info("Planned %d file(s) to upload for %s", len(manifest.items), run.flowcell_id)

        if dry_run:
            self._print_dry_run(manifest)
            return UploadResult(True, len(manifest.items), sorted(already_uploaded), 0, 0, lama_done, None)

        env = os.environ.copy()
        if self.config.server_url:
            env["SERVER_URL"] = self.config.server_url
        if self.config.auth_token:
            env["AUTH_TOKEN"] = self.config.auth_token

        pending = [item for item in manifest.items if item.dest_uri not in already_uploaded]
        skipped = len(manifest.items) - len(pending)
        if skipped:
            LOG.info("Resuming %s: %d file(s) already uploaded, skipping them", run.flowcell_id, skipped)

        uploaded, failed = self._upload_all(pending, env)
        all_uploaded = sorted(already_uploaded.union(uploaded))
        progress["uploaded"] = all_uploaded

        if failed:
            LOG.error("%d file(s) failed to upload for %s; the flowcell will be retried on the next scan",
                      len(failed), run.flowcell_id)

        # LAMA always receives every discovered fastq (the expected manifest), regardless of
        # whether each upload succeeded. It is registered once; failed uploads are retried
        # separately on the next scan without re-posting to LAMA.
        lama_error = None
        if lama_done:
            LOG.info("LAMA already registered for %s, skipping", run.flowcell_id)
        else:
            try:
                self._post_to_lama(manifest)
                lama_done = True
                LOG.info("Registered %s with LAMA (%d fastq files)", run.flowcell_id, len(manifest.fastq_names))
            except UploadError as exc:
                lama_error = str(exc)
                LOG.error("LAMA registration failed for %s: %s", run.flowcell_id, exc)
        progress["lama_done"] = lama_done

        success = (not failed) and lama_done
        error = "{} upload(s) failed".format(len(failed)) if failed else lama_error
        LOG.info("Summary for %s: found=%d uploaded=%d skipped=%d failed=%d lama_done=%s",
                 run.flowcell_id, len(manifest.items), len(uploaded), skipped, len(failed), lama_done)
        return UploadResult(success, len(manifest.items), all_uploaded, skipped, len(failed), lama_done, error)

    def parse_run_paths(self, secondary_file):
        """Derive flowcell/analysis ids and folders from .../<fc>/Analysis/<n>/Data/<secondary>."""
        path = Path(secondary_file)
        parts = path.parts
        if len(parts) < 5 or parts[-4] != "Analysis" or parts[-2] != "Data":
            raise UploadError(
                "Unexpected path layout for {}; expected .../<flowcell>/Analysis/<n>/Data/{}".format(
                    secondary_file, path.name))

        flowcell_id = parts[-5]
        analysis_number = parts[-3]
        fields = flowcell_id.split("_")
        if len(fields) < 4:
            raise UploadError("Cannot derive flowcell token from flowcell id: {}".format(flowcell_id))
        flowcell = fields[3]
        if flowcell[:1] in ("A", "B"):
            flowcell = flowcell[1:]

        mounted = path.parents[3]
        analysis = path.parents[1]
        local = Path(self.config.local_runs_root) / flowcell_id
        return RunPaths(flowcell_id, analysis_number, flowcell, mounted, analysis, local,
                        "novaseq/" + flowcell_id)

    def build_manifest(self, run):
        items = []
        fastq_names = []

        if run.analysis.is_dir():
            for fastq in sorted(p for p in run.analysis.rglob("*.fastq.gz") if p.is_file()):
                uploaded = self._rename_fastq(fastq.name, run.flowcell)
                items.append(UploadItem(str(fastq), run.gcp_uri_base + "/fastq/" + uploaded))
                fastq_names.append(uploaded)
        else:
            LOG.warning("Analysis folder not found: %s", run.analysis)

        quality_metrics = self._other_item(run, run.analysis, "Quality_Metrics.csv")
        demux_stats = self._other_item(run, run.analysis, "Demultiplex_Stats.csv")
        unknown_barcodes = self._other_item(run, run.analysis, "Top_Unknown_Barcodes.csv")
        sample_sheet = self._other_item(run, run.mounted, "SampleSheet.csv")
        run_info = self._other_item(run, run.mounted, "RunInfo.xml")
        run_parameters = self._other_item(run, run.local, "RunParameters.xml")

        items.extend((quality_metrics, demux_stats, unknown_barcodes, sample_sheet, run_info, run_parameters))

        return UploadManifest(items, fastq_names,
                              quality_metrics.source, unknown_barcodes.source, run_parameters.source)

    def _other_item(self, run, folder, name):
        """Locate one required metadata file under ``folder`` and return its UploadItem.

        These files are mandatory for downstream processing, so a missing one aborts
        the whole flowcell (raises UploadError) rather than uploading a partial set.
        """
        match = self._find_first(folder, name)
        if match is None:
            raise UploadError("Required file {} not found under {}".format(name, folder))
        return UploadItem(str(match), run.gcp_uri_base + "/other/" + name)

    def _upload_all(self, pending_items, env):
        uploaded = []
        failed = []
        if not pending_items:
            return uploaded, failed

        workers = max(1, min(self.config.max_parallel_uploads, len(pending_items)))
        with ThreadPoolExecutor(max_workers=workers) as pool:
            futures = {pool.submit(self._upload_one, item, env): item for item in pending_items}
            for future in as_completed(futures):
                item = futures[future]
                try:
                    uploaded.append(future.result())
                    LOG.info("Uploaded %s", item.dest_uri)
                except Exception as exc:
                    failed.append(item.dest_uri)
                    LOG.error("Giving up on %s: %s", item.dest_uri, exc)
        return uploaded, failed

    def _upload_one(self, item, env):
        return self._run_with_retry(self._attempt_upload, "upload " + item.dest_uri,
                                    self.config.upload_max_attempts, self.config.retry_base_delay,
                                    item, env)

    def _attempt_upload(self, item, env):
        cmd = [str(UPLOAD_FILE_SCRIPT), item.source, item.dest_uri]
        try:
            proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                  universal_newlines=True, env=env, timeout=self.config.upload_timeout)
        except subprocess.TimeoutExpired:
            raise UploadError("upload-file.sh timed out after {:.0f}s".format(self.config.upload_timeout))
        if proc.returncode != 0:
            raise UploadError("upload-file.sh exit {}: {}".format(
                proc.returncode, (proc.stdout or "").strip()))
        return item.dest_uri

    @staticmethod
    def _lama_required(manifest):
        """The metadata files LAMA needs, as (field name, path, content type) triples."""
        return (
            ("quality-metrics", manifest.quality_metrics, "text/csv"),
            ("unknown-barcodes", manifest.unknown_barcodes, "text/csv"),
            ("run-parameters", manifest.run_parameters, "text/xml"),
        )

    def _post_to_lama(self, manifest):
        required = self._lama_required(manifest)
        parts = []
        for name, path, content_type in required:
            with open(path, "rb") as handle:
                parts.append((name, os.path.basename(path), handle.read(), content_type))
        parts.append(("fastq-files", "-", ("\n".join(manifest.fastq_names) + "\n").encode("utf-8"), "text/plain"))

        boundary, body = self._build_multipart(parts)
        return self._run_with_retry(self._attempt_lama_post, "LAMA POST",
                                    self.config.lama_max_attempts, self.config.retry_base_delay,
                                    body, boundary)

    def _attempt_lama_post(self, body, boundary):
        request = urllib.request.Request(self._lama_url(), data=body, method="POST")
        request.add_header("accept", "*/*")
        request.add_header("Content-Type", "multipart/form-data; boundary=" + boundary)
        try:
            with urllib.request.urlopen(request, timeout=self.config.http_timeout) as response:
                status = response.getcode()
                response.read()
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", "replace")[:500]
            raise UploadError("LAMA returned HTTP {}: {}".format(exc.code, detail))
        except urllib.error.URLError as exc:
            raise UploadError("LAMA request failed: {}".format(exc.reason))
        if not (200 <= status < 300):
            raise UploadError("LAMA returned HTTP {}".format(status))
        return status

    def _print_dry_run(self, manifest):
        for item in manifest.items:
            print("  ./upload-file.sh {} {}".format(item.source, item.dest_uri))
        print("  LAMA POST {}".format(self._lama_url()))
        for name, path, content_type in self._lama_required(manifest):
            print("    {}=@{};type={}".format(name, path if path else "<MISSING>", content_type))
        print("    fastq-files=@- ({} names);type=text/plain".format(len(manifest.fastq_names)))

    def _lama_url(self):
        return self.config.lama_base_url + "/" + self.config.lama_endpoint

    @staticmethod
    def _rename_fastq(basename, flowcell):
        """Insert the flowcell token as the 2nd underscore field of the fastq name."""
        fields = basename.split("_")
        return fields[0] + "_" + flowcell + "_" + "_".join(fields[1:])

    @staticmethod
    def _find_first(folder, name):
        if not folder.is_dir():
            return None
        for match in sorted(p for p in folder.rglob(name) if p.is_file()):
            return match
        return None

    @staticmethod
    def _build_multipart(parts):
        boundary = "----NovaSeqXBoundary" + binascii.hexlify(os.urandom(16)).decode("ascii")
        crlf = b"\r\n"
        buf = bytearray()
        for name, filename, data, content_type in parts:
            buf += b"--" + boundary.encode("ascii") + crlf
            disposition = 'Content-Disposition: form-data; name="%s"; filename="%s"' % (name, filename)
            buf += disposition.encode("utf-8") + crlf
            buf += ("Content-Type: %s" % content_type).encode("ascii") + crlf
            buf += crlf
            buf += data
            buf += crlf
        buf += b"--" + boundary.encode("ascii") + b"--" + crlf
        return boundary, bytes(buf)

    def _run_with_retry(self, action, description, max_attempts, base_delay, *args):
        for attempt in range(1, max_attempts + 1):
            try:
                return action(*args)
            except Exception as exc:
                if attempt >= max_attempts:
                    LOG.error("%s failed after %d attempt(s): %s", description, attempt, exc)
                    raise
                delay = base_delay * (2 ** (attempt - 1))
                LOG.warning("%s failed (attempt %d/%d): %s — retrying in %.0fs",
                            description, attempt, max_attempts, exc, delay)
                time.sleep(delay)


def _build_arg_parser():
    parser = argparse.ArgumentParser(
        description="Upload NovaSeq X secondary-analysis output to GCP and register with LAMA.")
    parser.add_argument("secondary_analysis_file_path", help="Path to a Secondary_Analysis_Complete.txt file.")
    parser.add_argument("--dry-run", action="store_true",
                        help="Show what would happen; make no uploads or API calls.")
    return parser


def main(argv=None):
    args = _build_arg_parser().parse_args(argv)
    setup_logging()
    try:
        config = load_config(require_credentials=not args.dry_run)
    except ConfigError as exc:
        LOG.error("%s", exc)
        return 2

    secondary = args.secondary_analysis_file_path.rstrip("/")

    LOG.info("Received request for: %s", secondary)
    try:
        result = Uploader(config).process(secondary, dry_run=args.dry_run)
    except UploadError as exc:
        LOG.error("Failed to process %s: %s", secondary, exc)
        return 1
    return 0 if result.success else 1


if __name__ == "__main__":
    sys.exit(main())
