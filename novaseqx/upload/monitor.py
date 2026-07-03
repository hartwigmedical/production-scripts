#!/usr/libexec/platform-python
"""Poll a directory for Secondary_Analysis_Complete.txt files and upload them.
"""

import argparse
import json
import logging
import sys
import time
from pathlib import Path

import uploader
from config import ConfigError, load_config

LOG = logging.getLogger("novaseqx.monitor")

SCRIPT_DIR = Path(__file__).resolve().parent
STATE_FILE = SCRIPT_DIR / ".processed_analysis_files.json"

class Monitor:
    """Scans a directory for finished conversions and uploads them, tracking the state."""

    def __init__(self, config, state_file=None):
        self.config = config
        self.state_file = state_file or STATE_FILE
        self.state = {}
        self.uploader = uploader.Uploader(config)

    def load_state(self):
        self.state = {}
        if self.state_file.is_file():
            try:
                with open(str(self.state_file)) as handle:
                    self.state = json.load(handle)
            except (ValueError, OSError) as exc:
                LOG.error("Could not read state file %s: %s — starting fresh", self.state_file, exc)
                self.state = {}
        return self.state

    def save_state(self):
        tmp = self.state_file.parent / (self.state_file.name + ".tmp")
        with open(str(tmp), "w") as handle:
            json.dump(self.state, handle, indent=2, sort_keys=True)
        tmp.replace(self.state_file)

    def check_once(self, base_dir, dry_run=False):
        base = Path(base_dir)
        if not base.is_dir():
            LOG.error("Base directory does not exist: %s", base_dir)
            return

        for path in sorted(base.rglob(uploader.SECONDARY_ANALYSIS_FILE)):
            key = str(path)
            previous = self.state.get(key)
            if previous and previous.get("status") == "completed":
                continue

            LOG.info("Found %s file: %s%s", uploader.SECONDARY_ANALYSIS_FILE, key," (retry)" if previous else " (new)")
            progress = {
                "uploaded": (previous or {}).get("uploaded", []),
                "lama_done": (previous or {}).get("lama_done", False),
            }
            try:
                result = self.uploader.process(key, dry_run=dry_run, progress=progress)
            except uploader.UploadError as exc:
                LOG.error("Error processing %s: %s", key, exc)
                if not dry_run:
                    self._record(key, previous, "failed", progress, str(exc))
                    self.save_state()
                continue

            if dry_run:
                continue

            status = "completed" if result.success else "failed"
            self._record(key, previous, status, progress, result.error)
            self.save_state()
            if result.success:
                LOG.info("Completed %s", key)
            else:
                LOG.error("Marked %s as failed; it will be retried on the next scan", key)

    def run(self, base_dir):
        LOG.info("Monitoring %s for new %s files (polling every %ds)",
                 base_dir, uploader.SECONDARY_ANALYSIS_FILE, self.config.poll_interval)
        while True:
            self.check_once(base_dir)
            time.sleep(self.config.poll_interval)

    def _record(self, key, previous, status, progress, error):
        # Only keep full details of failed uploads
        now =  time.strftime("%Y-%m-%dT%H:%M:%S")
        if status == "completed":
            self.state[key] = {"status": "completed", "updated": now}
            return
        attempts = (previous or {}).get("attempts", 0) + 1
        self.state[key] = {
            "status": status,
            "attempts": attempts,
            "uploaded": progress.get("uploaded", []),
            "lama_done": progress.get("lama_done", False),
            "last_error": error,
            "updated": now,
        }

def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Monitor a directory for NovaSeq X secondary-analysis completion and upload.")
    parser.add_argument("base_dir", nargs="?", default=None,
                        help="Directory to scan (default: [paths] mnt_runs_root from config).")
    parser.add_argument("--once", action="store_true", help="Scan once and exit (no polling).")
    parser.add_argument("--dry-run", action="store_true",
                        help="Show what would happen; make no uploads/API calls or state writes. "
                             "Implies a single pass.")
    args = parser.parse_args(argv)

    uploader.setup_logging()
    try:
        config = load_config(require_credentials=not args.dry_run)
    except ConfigError as exc:
        LOG.error("%s", exc)
        return 2

    base_dir = (args.base_dir or config.mnt_runs_root).rstrip("/")
    if not base_dir:
        LOG.error("No base_dir given and no [paths] mnt_runs_root in config")
        return 2

    service = Monitor(config)
    if not args.dry_run:
        service.load_state()

    if args.once or args.dry_run:
        LOG.info("Scanning %s once for %s files%s", base_dir, uploader.SECONDARY_ANALYSIS_FILE, " (dry run)" if args.dry_run else "")
        service.check_once(base_dir, dry_run=args.dry_run)
        return 0

    service.run(base_dir)

if __name__ == "__main__":
    sys.exit(main())
