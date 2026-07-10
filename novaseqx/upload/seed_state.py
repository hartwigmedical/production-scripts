#!/usr/libexec/platform-python
"""One-off: seed .processed_analysis_files.json, marking every existing
Secondary_Analysis_Complete.txt as completed.

Run once BEFORE enabling fastq_upload.service so runs already uploaded by the
previous service are not re-processed. Safe to re-run: existing entries are kept.
"""

import argparse
import json
import logging
import sys
import time
from pathlib import Path

from config import ConfigError, load_config

LOG = logging.getLogger("novaseqx.seed_state")

SECONDARY_ANALYSIS_FILE = "Secondary_Analysis_Complete.txt"
STATE_FILE = Path(__file__).resolve().parent / ".processed_analysis_files.json"


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Seed the upload state with all currently finished flowcells.")
    parser.add_argument("base_dir", nargs="?", default=None,
                        help="Directory to scan (default: [paths] mnt_runs_root from config).")
    parser.add_argument("--dry-run", action="store_true",
                        help="Show what would be seeded; write nothing.")
    args = parser.parse_args(argv)

    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s %(levelname)s %(message)s",
                        datefmt="%Y-%m-%d %H:%M:%S")

    try:
        config = load_config(require_credentials=False)
    except ConfigError as exc:
        LOG.error("%s", exc)
        return 2

    base = Path((args.base_dir or config.mnt_runs_root).rstrip("/"))
    if not base.is_dir():
        LOG.error("Base directory does not exist: %s", base)
        return 2

    state = {}
    if STATE_FILE.is_file():
        with open(str(STATE_FILE)) as handle:
            content = handle.read().strip()
        if content:  # tolerate a pre-created empty file
            state = json.loads(content)

    now = time.strftime("%Y-%m-%dT%H:%M:%S")
    added = skipped = 0
    for path in sorted(base.rglob(SECONDARY_ANALYSIS_FILE)):
        key = str(path)
        if key in state:
            skipped += 1
            continue
        state[key] = {"status": "completed", "updated": now}
        added += 1

    if args.dry_run:
        LOG.info("Dry run: would seed %d new completed (%d already tracked); not writing", added, skipped)
        return 0

    # Written in place (no temp file); the state file is expected to already exist.
    with open(str(STATE_FILE), "w") as handle:
        json.dump(state, handle, indent=2, sort_keys=True)
    LOG.info("Seeded %d flowcell(s) as completed (%d already tracked) into %s", added, skipped, STATE_FILE)
    return 0


if __name__ == "__main__":
    sys.exit(main())
