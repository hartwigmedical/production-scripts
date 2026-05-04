#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FLOWCELL_FOLDER_NAME="20260101_LH00111_0001_TESTFLOWCELL"
GCP_URI_BASE="novaseq/${FLOWCELL_FOLDER_NAME}"

# Setup temp directory structure
BASE_DIR="/usr/local/illumina"
TEST_DIR=$(mkdir "${BASE_DIR}")
MOUNTED_FOLDER="${BASE_DIR}/mnt/runs/${FLOWCELL_FOLDER_NAME}"
LOCAL_FOLDER="${BASE_DIR}/runs/${FLOWCELL_FOLDER_NAME}"

mkdir -p "${MOUNTED_FOLDER}/Analysis/1/Data/BCLConvert/fastq"

QUALITY_METRICS_FOLDER="${MOUNTED_FOLDER}/Analysis/1/Data/BCLConvert/fastq/Reports"
mkdir -p "${QUALITY_METRICS_FOLDER}"
DEMUX_FOLDER="${MOUNTED_FOLDER}/Analysis/1/Data/Demux"
mkdir -p "${DEMUX_FOLDER}"
mkdir -p "${LOCAL_FOLDER}"

touch "${MOUNTED_FOLDER}/Analysis/1/Data/BCLConvert/fastq/SampleA_TESTFLOWCELL_S1_L001_R1_001.fastq.gz"
touch "${MOUNTED_FOLDER}/Analysis/1/Data/BCLConvert/fastq/SampleA_TESTFLOWCELL_S1_L001_R2_001.fastq.gz"
touch "${MOUNTED_FOLDER}/Analysis/1/Data/BCLConvert/fastq/Reports/Quality_Metrics.csv"
touch "${MOUNTED_FOLDER}/SampleSheet.csv"
touch "${MOUNTED_FOLDER}/Analysis/1/Data/Demux/Demultiplex_Stats.csv"
touch "${MOUNTED_FOLDER}/Analysis/1/Data/Demux/Top_Unknown_Barcodes.csv"
touch "${MOUNTED_FOLDER}/RunInfo.xml"
touch "${LOCAL_FOLDER}/RunParameters.xml"

SECONDARY_ANALYSIS_FILE="${MOUNTED_FOLDER}/Analysis/1/Data/Secondary_Analysis_Complete.txt"

# Run script in dry-run mode, capture only the indented dry-run output lines
actual=$(
    bash "${SCRIPT_DIR}/upload_analysis_files.sh" "${SECONDARY_ANALYSIS_FILE}" --dry-run \
    | grep "^  " | sort
)

expected=$(sort << EOF
  ./upload-file.sh ${MOUNTED_FOLDER}/Analysis/1/Data/BCLConvert/fastq/SampleA_S1_L001_R1_001.fastq.gz ${GCP_URI_BASE}/fastq/SampleA_TESTFLOWCELL_S1_L001_R1_001.fastq.gz
  ./upload-file.sh ${MOUNTED_FOLDER}/Analysis/1/Data/BCLConvert/fastq/SampleA_S1_L001_R2_001.fastq.gz ${GCP_URI_BASE}/fastq/SampleA_TESTFLOWCELL_S1_L001_R2_001.fastq.gz
  ./upload-file.sh ${MOUNTED_FOLDER}/Analysis/1/Data/BCLConvert/fastq/Reports/Quality_Metrics.csv ${GCP_URI_BASE}/other/Quality_Metrics.csv
  ./upload-file.sh ${MOUNTED_FOLDER}/SampleSheet.csv ${GCP_URI_BASE}/other/SampleSheet.csv
  ./upload-file.sh ${MOUNTED_FOLDER}/Analysis/1/Data/Demux/Demultiplex_Stats.csv ${GCP_URI_BASE}/other/Demultiplex_Stats.csv
  ./upload-file.sh ${MOUNTED_FOLDER}/Analysis/1/Data/Demux/Top_Unknown_Barcodes.csv ${GCP_URI_BASE}/other/Top_Unknown_Barcodes.csv
  ./upload-file.sh ${MOUNTED_FOLDER}/RunInfo.xml ${GCP_URI_BASE}/other/RunInfo.xml
  ./upload-file.sh ${LOCAL_FOLDER}/RunParameters.xml ${GCP_URI_BASE}/other/RunParameters.xml
  printf '%s\n' 'SampleA_TESTFLOWCELL_S1_L001_R1_001.fastq.gz' 'SampleA_TESTFLOWCELL_S1_L001_R2_001.fastq.gz' | curl -X POST http://lama.prod-1/api/sequencing/sequencing-run-data -H accept: */* -H Content-Type: multipart/form-data -F quality-metrics=@/usr/local/illumina/mnt/runs/20260101_LH00111_0001_TESTFLOWCELL/Analysis/1/Data/BCLConvert/fastq/Reports/Quality_Metrics.csv;type=text/csv -F unknown-barcodes=@/usr/local/illumina/mnt/runs/20260101_LH00111_0001_TESTFLOWCELL/Analysis/1/Data/Demux/Top_Unknown_Barcodes.csv;type=text/csv -F run-parameters=@/usr/local/illumina/runs/20260101_LH00111_0001_TESTFLOWCELL/RunParameters.xml;type=text/xml -F 'fastq-files=@-;type=text/plain'
EOF
)

if [[ "${actual}" == "${expected}" ]]; then
    echo "PASS: upload_analysis_files.sh dry-run output matches expected"
else
    echo "FAIL: dry-run output mismatch"
    diff <(echo "${expected}") <(echo "${actual}")
fi

echo
echo "To clean up the test directory run: rm -rf \"${BASE_DIR}\""
