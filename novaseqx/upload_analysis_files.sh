#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common_utils.sh"

# Export the needed server URL and authentication token to make sure the upload script works
export SERVER_URL="https://upload.test.hartwigmedicalfoundation.nl"
export AUTH_TOKEN="enter-your-token"

LAMA_BASE_URL="http://localhost:8080"
LAMA_API_ENDPOINT="${LAMA_BASE_URL}/api/sequencing/sequencing-run-data"

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

# Folders
MOUNTED_FOLDER="/usr/local/illumina/mnt/runs/${FLOWCELL_FOLDER_NAME}"
LOCAL_FOLDER="/usr/local/illumina/runs/${FLOWCELL_FOLDER_NAME}"
GCP_URI_BASE="novaseq/${FLOWCELL_ID}"

# Files
QUALITY_METRICS_NAME="Quality_Metrics.csv"
TOP_UNKNOWN_BARCODES_NAME="Top_Unknown_Barcodes.csv"
RUN_PARAMETERS_NAME="RunParameters.xml"

MOUNTED_FILES=("${QUALITY_METRICS_NAME}" "SampleSheet.csv" "Demultiplex_Stats.csv" "${TOP_UNKNOWN_BARCODES_NAME}" "RunInfo.xml")
LOCAL_FILES=("${RUN_PARAMETERS_NAME}")

find_files() {
    local -n _result=$1
    local pattern="*$2"
    local folder=$3
    timed_echo
    timed_echo "----------$pattern------------"

    _result=()
    while IFS= read -r file; do
        if [[ ${folder} == "fastq" ]]; then
            uploaded_file_name=$(echo "$(basename ${file} | cut -d_ -f1)_${FLOWCELL_ID}_$(basename ${file} | cut -d_ -f2-)")
        else
            uploaded_file_name=$(basename ${file})
        fi
        _result+=("${file}:${uploaded_file_name}")
    done < <(find "${folder}" -type f -name "${pattern}")
}

upload_files_to_gcp() {
    local pattern="*$1"
    local cloud_folder=$2
    local files=("${@:3}")

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

# Find fastq files upfront — needed by both GCP upload and LAMA API call
find_files fastq_pairs ".fastq.gz" "${MOUNTED_FOLDER}"

fastq_names=()
for pair in "${fastq_pairs[@]}"; do
    fastq_names+=("${pair##*:}")
done

# Upload all files to GCP
upload_files_to_gcp ".fastq.gz" "fastq" "${fastq_pairs[@]}"
for file in "${MOUNTED_FILES[@]}"; do
    find_files pairs "${file}" "${MOUNTED_FOLDER}"
    upload_files_to_gcp "${file}" "other" "${pairs[@]}"
done
for file in "${LOCAL_FILES[@]}"; do
    find_files pairs "${file}" "${LOCAL_FOLDER}"
    upload_files_to_gcp "${file}" "other" "${pairs[@]}"
done
timed_echo "All GCP uploads completed"

# Make LAMA API call after GCP uploads finish
quality_metrics=$(find "${MOUNTED_FOLDER}" -type f -name "${QUALITY_METRICS_NAME}" | head -1)
unknown_barcodes=$(find "${MOUNTED_FOLDER}" -type f -name "${TOP_UNKNOWN_BARCODES_NAME}" | head -1)
run_parameters=$(find "${LOCAL_FOLDER}" -type f -name "${RUN_PARAMETERS_NAME}" | head -1)

timed_echo "Calling LAMA API with ${#fastq_names[@]} fastq files"
printf '%s\n' "${fastq_names[@]}" | curl -X 'POST' \
  "${LAMA_API_ENDPOINT}" \
  -H 'accept: */*' \
  -H 'Content-Type: multipart/form-data' \
  -F "quality-metrics=@${quality_metrics};type=text/csv" \
  -F "unknown-barcodes=@${unknown_barcodes};type=text/csv" \
  -F "run-parameters=@${run_parameters};type=text/xml" \
  -F "fastq-files=@-;type=text/plain"

timed_echo "Finished processing flowcell ${FLOWCELL_ID}"

