#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common_utils.sh"

# Export the needed server URL and authentication token to make sure the upload script works
export SERVER_URL="https://upload.test.hartwigmedicalfoundation.nl"
export AUTH_TOKEN="enter-your-token"
export LAMA_API_URL="http://localhost:8080/api/sequencing/sequencing-run-data"

# Validate input
FLOWCELL_FOLDER_NAME="$1}"
FLOWCELL_FOLDER_NAME="${FLOWCELL_FOLDER_NAME%/}"
if [ -z "${FLOWCELL_FOLDER_NAME}" ]; then
  echo "Error: Provide a run directory"
  echo "Example: ./upload_finished_analysis_files.sh [FLOWCELL_FOLDER_NAME] [FLOWCELL_ID]"
  echo "Specify which analysis should be uploaded in the path e.g. [FLOWCELL_FOLDER_NAME]/Analysis/1/Data"
  exit 1
fi

FLOWCELL_ID="$2"
FLOWCELL_ID="${FLOWCELL_ID#/}"
if [[ -z "${FLOWCELL_ID}" ]]; then
    echo "Error: provide a flowcell ID, this must be set and unique otherwise the files will be overridden"
    exit 1
fi

# Settings
MAX_PARALLEL_UPLOADS=6
timed_echo "Doing a maximum of ${MAX_PARALLEL_UPLOADS} parallel uploads using server: ${SERVER_URL}"

MOUNTED_FOLDER="/usr/local/illumina/mnt/runs/${FLOWCELL_FOLDER_NAME}"
MOUNTED_FILES=("Quality_Metrics.csv" "SampleSheet.csv" "Demultiplex_Stats.csv" "Top_Unknown_Barcodes.csv" "RunInfo.xml")

LOCAL_FOLDER="/usr/local/illumina/runs/${FLOWCELL_FOLDER_NAME}"
LOCAL_FILES=("RunParameters.xml")

GCP_URI_BASE="novaseq/${FLOWCELL_ID}"

upload_files() {
    local pattern="*$1"   # The pattern of the files it should match (e.g., *.fastq.gz, RunParameters.xml)
    local folder=$2       # The folder to search for the file
    local cloud_folder=$3 # The base folder in the cloud bucket (e.g., fastq, other)
    echo
    timed_echo "----------$pattern------------"

    files=()
    while IFS= read -r file; do
        if [[ ${folder} == "fastq" ]]; then
            dest_name=$(echo "$(basename ${file} | cut -d_ -f1)_${FLOWCELL_ID}_$(basename ${file} | cut -d_ -f2-)")
        else
            dest_name=$(basename ${file})
        fi
        files+=("${file}:${dest_name}")
    done < <(find "${folder}" -type f -name "${pattern}")

    if [ ${#files[@]} -eq 0 ]; then
        timed_echo "No files found matching ${pattern}"
        return
    fi

    local full_gcp_uri="${GCP_URI_BASE}/${cloud_folder}"
    timed_echo "Starting to upload ${pattern} (${#files[@]}) files to ${full_gcp_uri}"
    printf "%s\n" "${files[@]}" | parallel -j ${MAX_PARALLEL_UPLOADS} -C ':' './upload-file.sh' {1} "${full_gcp_uri}/"{2}
    wait

    timed_echo "Done uploading the ${pattern} files"
}

upload_files ".fastq.gz" "${MOUNTED_FOLDER}" "fastq"

for file in "${MOUNTED_FILES[@]}"; do
    upload_files "${file}" "${MOUNTED_FOLDER}" "other"
done

for file in "${LOCAL_FILES[@]}"; do
    upload_files "${file}" "${LOCAL_FOLDER}" "other"
done


