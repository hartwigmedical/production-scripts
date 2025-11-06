<H3>Monitoring Service</H3>
The `monitor_conversion_ready.sh` script will be used to trigger uploads from the NovaSeq X through the portal_api upload-server to GCP.<br>
It will trigger an uploading process in case it finds a new folder with the `Secondary_Analysis_Complete.txt` file in it.
This file indicates that the BCLConvert has completed and the files are ready to be uploaded.

It uses `upload_finished_analysis_files.sh` to upload the files.
- **Input**: Takes a run directory path as an argument
    - E.g, format: `/base/dir/20250101_LH00001_0001_A01CLVJLT1`
  
- **Files**: Recursively searches for the following file types:
    - FASTQ
    - BCL
    - CBCL
    - Quality metrics, SampleSheet, RunInfo, RunParameters

- **Upload Process**: Files are uploaded to GCP buckets organized by type
    - Each file type is stored in its dedicated folder
    - Upload functionality is handled by the script located in the `upload-server` directory of the `portal-api` repository

The script `upload-server/scripts/upload-file.sh` is used for this purpose.
This script should be in the same directory as the `upload_finished_analysis_files.sh` script and executable as this communicates with the upload-server.

- **Starting the Monitoring Service**
The monitoring service is started by adding the `monitor_conversion.service`.
This will ensure that when the machine is restarted, so does the monitoring service.
To add the service, run the following commands on the machine:
```bash
sudo systemctl daemon-reload
sudo systemctl enable sync_fastq_files.service
sudo systemctl start sync_fastq_files.service
```

<H3>Uploading Manually</H3>
Running the `upload_finished_analysis_files.sh` is also possible by calling:
```bash
upload_finished_analysis_files.sh /base/folder/runname runname
```
It will create file(s) in the output bucket in the format of:
- gs://output-bucket/novaseq/runname/fastq/file.fastq.gz
- gs://output-bucket/novaseq/runname/cbcl/L00X/CX.X/file.cbcl
- gs://output-bucket/novaseq/runname/other/Quality_Metrics.csv
- gs://output-bucket/novaseq/runname/other/SampleSheet.csv
- gs://output-bucket/novaseq/runname/other/RunInfo.xml
- gs://output-bucket/novaseq/runname/other/RunParameters.xml

<H3>Requirements</H3>
Make sure to follow the readme in the portal-api repository to setup authentication and server url `upload-server/scripts/README.md`.
- **Required Environment Variables**:
    - `SERVER_URL`, url to the upload-server
    - `AUTH_TOKEN`, token generated from the portal-api authentication service
  
- **Required packages**:
    - `inotify-tools`, used to monitor the file system for new files in the given base directory
      - Oracle Linux 8: `sudo dnf install inotify-tools` and test if installed `inotifywait --version`<br>
        In case EPEL is not enabled yet: `sudo dnf install oracle-epel-release-el8`


