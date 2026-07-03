<H3>NovaSeq X upload service</H3>
Monitors the NovaSeq X for finished conversions and uploads their output to GCP, then registers the run with the LAMA API.

It polls a directory for `Secondary_Analysis_Complete.txt` (written when BCLConvert finishes) and, for each new one, uploads the FASTQ + metadata files to GCP and POSTs the quality metrics / metadata to LAMA.

Runs on the Python interpreter that already ships with Oracle Linux 8 — **`/usr/libexec/platform-python`** (Python 3.6), standard library only. Nothing is installed on the instrument (no `dnf`/`pip`); GNU `parallel` is not needed (a thread pool does the parallel uploads).

<H3>Files</H3>
- `monitor.py` — poll loop; scans for `Secondary_Analysis_Complete.txt` and tracks per-flowcell state.
- `uploader.py` — the upload engine (`Uploader`); finds files, uploads them, registers with LAMA. Runnable standalone.
- `config.py` — loads and validates `config.ini`.
- `config.ini` — configuration (see below). Committed **without** an auth token.
- `fastq_upload.service` — systemd unit.
- `test_uploader.py`, `test_monitor.py` — stdlib `unittest` suites.
- `upload-file.sh` — **required, not in this repo.** Must sit in this directory and be executable; the Python code shells out to it for the actual GCP transfer (it comes from the `upload-server/scripts` directory of the `portal-api` repository). Follow that repo's README to set up the upload-server URL and auth token.

<H3>Bucket layout</H3>
Uploads land in the output bucket as:
- gs://output-bucket/novaseq/<flowcell_id>/fastq/<file>.fastq.gz
- gs://output-bucket/novaseq/<flowcell_id>/other/Quality_Metrics.csv
- gs://output-bucket/novaseq/<flowcell_id>/other/SampleSheet.csv
- gs://output-bucket/novaseq/<flowcell_id>/other/RunInfo.xml
- gs://output-bucket/novaseq/<flowcell_id>/other/RunParameters.xml
- gs://output-bucket/novaseq/<flowcell_id>/other/Demultiplex_Stats.csv
- gs://output-bucket/novaseq/<flowcell_id>/other/Top_Unknown_Barcodes.csv

Note: `RunParameters.xml` lives under a different runs root than the other files (`/usr/local/illumina/runs/<flowcell_folder>/RunParameters.xml`).

<H3>Configuration</H3>
All settings live in one INI file (`config.ini`), read from the same directory as `monitor.py`/`uploader.py`. Keys are grouped into `[upload]`, `[lama]`, `[paths]`, `[monitor]` and are documented inline in the file.

`config.ini` is committed **without** an auth token; set it on the instrument before a real run (it is not needed for `--dry-run`):
```ini
[upload]
auth_token = <token from the portal-api authentication service>
```
A real run with a blank `server_url`/`auth_token` fails fast with a clear error rather than retrying doomed uploads.

<H3>Running manually</H3>
```bash
# Upload a single flowcell:
/usr/libexec/platform-python uploader.py \
    /usr/local/illumina/mnt/runs/<flowcell_folder>/Analysis/1/Data/Secondary_Analysis_Complete.txt

# See what would happen without uploading (no credentials needed):
/usr/libexec/platform-python uploader.py <secondary_file> --dry-run

# Scan the monitored directory once, or once as a dry run:
/usr/libexec/platform-python monitor.py [base_dir] --once
/usr/libexec/platform-python monitor.py [base_dir] --once --dry-run
```
`base_dir` defaults to `[paths] mnt_runs_root` from the config. `--once` (single scan then exit) and `--dry-run` (no uploads/API calls/state writes) are independent flags.

<H3>Tracking, retries and resume</H3>
- State is kept in `.processed_analysis_files.json` (same directory), one entry per `Secondary_Analysis_Complete.txt`. Completed flowcells store a minimal marker; failed ones keep the resume detail (`attempts`, uploaded dest URIs, `lama_done`, `last_error`).
- A flowcell is only marked `completed` when every file uploaded **and** LAMA registration succeeded; otherwise it is `failed` and retried on the next scan.
- Retries are two-layered: each `upload-file.sh` call and the LAMA POST retry with exponential backoff within a run; a `failed` flowcell is re-attempted on the next poll and **skips files already uploaded** (and skips LAMA if it already succeeded).

<H3>Starting the service</H3>
The unit assumes all scripts live in `/usr/local/hartwig/fastq_upload`. It must be placed in `/etc/systemd/system` on the NovaSeq X (SELinux enforces this). Then:
```bash
sudo systemctl daemon-reload
sudo systemctl enable fastq_upload.service
sudo systemctl start fastq_upload.service
```

<H3>Tests</H3>
Standard-library `unittest`, run on the same interpreter:
```bash
/usr/libexec/platform-python test_uploader.py
/usr/libexec/platform-python test_monitor.py
```
