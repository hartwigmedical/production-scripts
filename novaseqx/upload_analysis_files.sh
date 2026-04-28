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
  echo "Error: Provide a run directory" >&2
  echo "Example: ./upload_finished_analysis_files.sh [FLOWCELL_FOLDER_NAME] [FLOWCELL_ID] [--dry-run]" >&2
  echo "Specify which analysis should be uploaded in the path e.g. [FLOWCELL_FOLDER_NAME]/Analysis/1/Data" >&2
  exit 1
fi

FLOWCELL_ID="$2"
FLOWCELL_ID="${FLOWCELL_ID#/}"
if [[ -z "${FLOWCELL_ID}" ]]; then
    echo "Error: provide a flowcell ID, this must be set and unique otherwise the files will be overridden for folder ${FLOWCELL_FOLDER_NAME}" >&2
    exit 1
fi

DRY_RUN=false
[[ "$3" == "--dry-run" ]] && DRY_RUN=true
[[ "${DRY_RUN}" == true ]] && timed_echo "Dry run enabled — no uploads or API calls will be made"

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

upload_files_to_gcp() {
    local pattern="*$1"
    local cloud_folder=$2
    local files=("${@:3}")

    if [ ${#files[@]} -eq 0 ]; then
        timed_echo "No files found matching ${pattern} for flowcell ${FLOWCELL_ID}" >&2
        return
    fi

    local full_gcp_uri="${GCP_URI_BASE}/${cloud_folder}"
    timed_echo "Starting to upload ${pattern} (${#files[@]}) files to ${full_gcp_uri}"
    if [[ "${DRY_RUN}" == true ]]; then
        for file_pair in "${files[@]}"; do
            echo "  ./upload-file.sh ${file_pair%%:*} ${full_gcp_uri}/${file_pair##*:}"
        done
    else
        printf "%s\n" "${files[@]}" | parallel -j ${MAX_PARALLEL_UPLOADS} -C ':' './upload-file.sh' {1} "${full_gcp_uri}/"{2}
        wait
    fi

    timed_echo "Done uploading the ${pattern} files"
}

# Find and upload fastq files - folder = fastq
fastq_pairs=()
fastq_names=()
while IFS= read -r file; do
    uploaded_name="$(basename "${file}" | cut -d_ -f1)_${FLOWCELL_ID}_$(basename "${file}" | cut -d_ -f2-)"
    fastq_pairs+=("${file}:${uploaded_name}")
    fastq_names+=("${uploaded_name}")
done < <(find "${MOUNTED_FOLDER}" -type f -name "*.fastq.gz")

upload_files_to_gcp ".fastq.gz" "fastq" "${fastq_pairs[@]}"

# Find and upload mounted files - folder = other
quality_metrics_full_path=""
unknown_barcodes_full_path=""
for file_name in "${MOUNTED_FILES[@]}"; do
    file_path=$(find "${MOUNTED_FOLDER}" -type f -name "${file_name}" | head -1)
    [[ -z "${file_path}" ]] && continue
    upload_files_to_gcp "${file_name}" "other" "${file_path}:${file_name}"
    [[ "${file_name}" == "${QUALITY_METRICS_NAME}" ]] && quality_metrics_full_path="${file_path}"
    [[ "${file_name}" == "${TOP_UNKNOWN_BARCODES_NAME}" ]] && unknown_barcodes_full_path="${file_path}"
done

# Find and upload local files - folder = other
run_parameters_full_path=""
for file_name in "${LOCAL_FILES[@]}"; do
    file_path=$(find "${LOCAL_FOLDER}" -type f -name "${file_name}" | head -1)
    [[ -z "${file_path}" ]] && continue
    upload_files_to_gcp "${file_name}" "other" "${file_path}:${file_name}"
    [[ "${file_name}" == "${RUN_PARAMETERS_NAME}" ]] && run_parameters_full_path="${file_path}"
done

timed_echo "All GCP uploads completed"

timed_echo "Calling LAMA API with ${#fastq_names[@]} fastq files"
if [[ "${DRY_RUN}" == true ]]; then
    printf '%s\n' "${fastq_names[@]}"
    echo "  curl -X 'POST' '${LAMA_API_ENDPOINT}' \\"
    echo "    -F 'quality-metrics=@${quality_metrics_full_path};type=text/csv' \\"
    echo "    -F 'unknown-barcodes=@${unknown_barcodes_full_path};type=text/csv' \\"
    echo "    -F 'run-parameters=@${run_parameters_full_path};type=text/xml' \\"
    echo "    -F 'fastq-files=<${#fastq_names[@]} fastq filenames>;type=text/plain'"
else
    printf '%s\n' "${fastq_names[@]}" | curl -X 'POST' \
      "${LAMA_API_ENDPOINT}" \
      -H 'accept: */*' \
      -H 'Content-Type: multipart/form-data' \
      -F "quality-metrics=@${quality_metrics_full_path};type=text/csv" \
      -F "unknown-barcodes=@${unknown_barcodes_full_path};type=text/csv" \
      -F "run-parameters=@${run_parameters_full_path};type=text/xml" \
      -F "fastq-files=@-;type=text/plain"
fi

timed_echo "Finished processing flowcell ${FLOWCELL_ID}"

