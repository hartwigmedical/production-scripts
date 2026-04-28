#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common_utils.sh"

# Export the needed server URL and authentication token to make sure the upload script works
export SERVER_URL="https://upload.test.hartwigmedicalfoundation.nl"
export AUTH_TOKEN="enter-your-token"

LAMA_BASE_URL="http://lama.prod-1"
LAMA_API_ENDPOINT="${LAMA_BASE_URL}/api/sequencing/sequencing-run-data"

# Validate input
SECONDARY_ANALYSIS_COMPLETED_LOCATION="$1"
SECONDARY_ANALYSIS_COMPLETED_LOCATION="${SECONDARY_ANALYSIS_COMPLETED_LOCATION%/}"
if [ -z "${SECONDARY_ANALYSIS_COMPLETED_LOCATION}" ]; then
  echo "Error: Provide a run directory" >&2
  echo "Example: ./upload_analysis_files.sh [SECONDARY_ANALYSIS_COMPLETED_LOCATION] [--dry-run]" >&2
  echo "Specify which where the secondary analysis was found e.g /usr/local/illumina/mnr/runs/[flowcell_id]/Analysis/1/Data/Secondary_Analysis_Completed.txt" >&2
  exit 1
fi
timed_echo "Received request for: ${SECONDARY_ANALYSIS_COMPLETED_LOCATION}"

FLOWCELL_ID=$(echo "${SECONDARY_ANALYSIS_COMPLETED_LOCATION}" | cut -d / -f7) # e.g. 20260101_LH0001_0001_FLOWCELL
ANALYSIS_NUMBER=$(echo "${SECONDARY_ANALYSIS_COMPLETED_LOCATION}" | cut -d / -f9)
FLOWCELL=$(echo "${FLOWCELL_ID}" | cut -d _ -f4)
timed_echo "Flowcell ID: ${FLOWCELL_ID}, Analysis Number: ${ANALYSIS_NUMBER}"

DRY_RUN=false
[[ "$2" == "--dry-run" ]] && DRY_RUN=true
[[ "${DRY_RUN}" == true ]] && timed_echo "Dry run enabled — no uploads or API calls will be made"

# Settings
MAX_PARALLEL_UPLOADS=6
timed_echo "Doing a maximum of ${MAX_PARALLEL_UPLOADS} parallel uploads using server: ${SERVER_URL}"

# Folders
MOUNTED_FOLDER="/usr/local/illumina/mnt/runs/${FLOWCELL_ID}"
ANALYSIS_MOUNTED_FOLDER="/usr/local/illumina/mnt/runs/${FLOWCELL_ID}/Analysis/${ANALYSIS_NUMBER}"
LOCAL_FOLDER="/usr/local/illumina/runs/${FLOWCELL_ID}"
GCP_URI_BASE="novaseq/${FLOWCELL_ID}"

# Files
RUN_PARAMETERS_NAME="RunParameters.xml"
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
    timed_echo "#----------------------------------------------------#"
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
    uploaded_name="$(basename "${file}" | cut -d _ -f1)_${FLOWCELL}_$(basename "${file}" | cut -d _ -f2-)"
    fastq_pairs+=("${file}:${uploaded_name}")
    fastq_names+=("${uploaded_name}")
done < <(find "${ANALYSIS_MOUNTED_FOLDER}" -type f -name "*.fastq.gz")

upload_files_to_gcp ".fastq.gz" "fastq" "${fastq_pairs[@]}"

# Find and upload mounted files - GCP folder = other
QUALITY_METRICS_NAME="Quality_Metrics.csv"
TOP_UNKNOWN_BARCODES_NAME="Top_Unknown_Barcodes.csv"
ANALYSIS_MOUNTED_FILES=("${QUALITY_METRICS_NAME}" "Demultiplex_Stats.csv" "${TOP_UNKNOWN_BARCODES_NAME}")

quality_metrics_full_path=""
unknown_barcodes_full_path=""
for file_name in "${ANALYSIS_MOUNTED_FILES[@]}"; do
    file_path=$(find "${ANALYSIS_MOUNTED_FOLDER}" -type f -name "${file_name}" | head -1)
    [[ -z "${file_path}" ]] && continue
    upload_files_to_gcp "${file_name}" "other" "${file_path}:${file_name}"
    [[ "${file_name}" == "${QUALITY_METRICS_NAME}" ]] && quality_metrics_full_path="${file_path}"
    [[ "${file_name}" == "${TOP_UNKNOWN_BARCODES_NAME}" ]] && unknown_barcodes_full_path="${file_path}"
done

MOUNTED_FILES=("SampleSheet.csv" "RunInfo.xml")
for file_name in "${MOUNTED_FILES[@]}"; do
    file_path=$(find "${MOUNTED_FOLDER}" -type f -name "${file_name}" | head -1)
    [[ -z "${file_path}" ]] && continue
    upload_files_to_gcp "${file_name}" "other" "${file_path}:${file_name}"
done

# Find and upload local files - GCP folder = other
run_parameters_full_path=""
for file_name in "${LOCAL_FILES[@]}"; do
    file_path=$(find "${LOCAL_FOLDER}" -type f -name "${file_name}" | head -1)
    [[ -z "${file_path}" ]] && continue
    upload_files_to_gcp "${file_name}" "other" "${file_path}:${file_name}"
    [[ "${file_name}" == "${RUN_PARAMETERS_NAME}" ]] && run_parameters_full_path="${file_path}"
done

timed_echo "All GCP uploads completed"

curl_args=(
    -X 'POST' "${LAMA_API_ENDPOINT}"
    -H 'accept: */*'
    -H 'Content-Type: multipart/form-data'
    -F "quality-metrics=@${quality_metrics_full_path};type=text/csv"
    -F "unknown-barcodes=@${unknown_barcodes_full_path};type=text/csv"
    -F "run-parameters=@${run_parameters_full_path};type=text/xml"
)

timed_echo "Calling LAMA API with ${#fastq_names[@]} fastq files"
if [[ "${DRY_RUN}" == true ]]; then
    echo -n "  printf '%s\\n'"
    for name in "${fastq_names[@]}"; do printf " '%s'" "${name}"; done
    echo " | curl ${curl_args[*]} -F 'fastq-files=@-;type=text/plain'"
else
    printf '%s\n' "${fastq_names[@]}" | curl "${curl_args[@]}" -F "fastq-files=@-;type=text/plain"
fi

timed_echo "Finished processing flowcell ${FLOWCELL_ID}"

