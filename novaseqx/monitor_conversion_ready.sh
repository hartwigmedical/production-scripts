#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common_utils.sh"

# Validate input
BASE_DIR="${1}"
BASE_DIR="${BASE_DIR%/}"
if [ -z "${BASE_DIR}" ]; then
  echo "Provide a full path base directory to monitor for the creation of Secondary_Analysis_Complete.txt"
  echo "The script assumes a structure after the directory to watch as /Analysis/[analysis_num]/Data"
  echo "It will process any folder in the given directory where a Secondary_Analysis_Complete.txt is created"
  echo "Example: monitor_conversion_ready.sh [full path to directory to monitor] [--once] [--dry-run]"
  exit 1
fi

DRY_RUN=false
for arg in "${@:2}"; do
    [[ "${arg}" == "--dry-run" ]] && DRY_RUN=true
done

# Settings
ANALYSIS_COMPLETE_FILE="Secondary_Analysis_Complete.txt"
POLL_INTERVAL=900
PROCESSED_FILES_LOG="${SCRIPT_DIR}/.processed_analysis_files.log"

touch "${PROCESSED_FILES_LOG}"

is_already_processed() {
    local file_path="$1"
    grep -Fxq "${file_path}" "${PROCESSED_FILES_LOG}"
}

mark_as_processed() {
    local file_path="$1"
    echo "${file_path}" >> "${PROCESSED_FILES_LOG}"
}

process_folder() {
    local secondary_analysis_file_location="$1"
    if [[ "${DRY_RUN}" == true ]]; then
        timed_echo "Starting to process using './upload_analysis_files.sh', dry run enabled"
        "./upload_analysis_files.sh" "${secondary_analysis_file_location}" "--dry-run"
    else
        timed_echo "Starting to process using './upload_analysis_files.sh'"
        "./upload_analysis_files.sh" "${secondary_analysis_file_location}"
    fi
}

check_for_new_files() {
    found_files=$(find "${BASE_DIR}" -name "${ANALYSIS_COMPLETE_FILE}" 2>/dev/null)

    for file_path in ${found_files}; do
        if ! is_already_processed "${file_path}"; then
            timed_echo "Found new file: ${file_path}"
            process_folder "${file_path}"
            [[ "${DRY_RUN}" == false ]] && mark_as_processed "${file_path}"
        fi
    done
}

echo
if [[ "${DRY_RUN}" == true ]]; then
    timed_echo "Running once on ${BASE_DIR} for ${ANALYSIS_COMPLETE_FILE} files"
    check_for_new_files
else
    timed_echo "Monitoring ${BASE_DIR} for new ${ANALYSIS_COMPLETE_FILE} files (polling every ${POLL_INTERVAL} seconds)"
    echo
    while true; do
        check_for_new_files
        sleep "${POLL_INTERVAL}"
    done
fi