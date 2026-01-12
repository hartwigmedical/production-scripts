#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common_utils.sh"
echo $SCRIPT_DIR

DIR_TO_WATCH="$1"
DIR_TO_WATCH="${DIR_TO_WATCH%/}"
if [ -z "$DIR_TO_WATCH" ]; then
  echo "Provide a full path directory to watch";
  echo "The script assumes a structure after the directory to watch as /Analysis/[analysis_num]/Data"
  echo "It will process any folder in the given directory where a Secondary_Analysis_Complete.txt is created"
  echo "Example: monitor_conversion_ready.sh [full path to directory to watch]"
  exit 1
fi

ANALYSIS_COMPLETE_FILE="Secondary_Analysis_Complete.txt"
POLL_INTERVAL=900
PROCESSED_FILES_LOG="$SCRIPT_DIR/.processed_analysis_files.log"

touch "$PROCESSED_FILES_LOG"

is_already_processed() {
    local file_path="$1"
    grep -Fxq "$file_path" "$PROCESSED_FILES_LOG"
}

mark_as_processed() {
    local file_path="$1"
    echo "$file_path" >> "$PROCESSED_FILES_LOG"
}

process_folder() {
    local flowcell_folder="$1"
    local data_dir="${flowcell_folder%%"$ANALYSIS_COMPLETE_FILE"}"
    local run="${data_dir##"$DIR_TO_WATCH"}"
    run="${run#/}"
    local flowcell_name="${run%%/*}"
    local analysis_num=$(echo "$run" | grep -oP 'Analysis/\K\d+' || echo "unknown")

    echo
    timed_echo "Processing flowcell: $flowcell_name (Analysis: $analysis_num)"
    "./upload_finished_analysis_files.sh" "$data_dir" "$flowcell_name"
}

check_for_new_files() {
    timed_echo "Checking for new $ANALYSIS_COMPLETE_FILE files..."

    found_files=$(find "$DIR_TO_WATCH" -name "$ANALYSIS_COMPLETE_FILE" 2>/dev/null)

    for file_path in $found_files; do
        if ! is_already_processed "$file_path"; then
            timed_echo "Found new file: $file_path"
            process_folder "$file_path"
            mark_as_processed "$file_path"
        fi
    done
}

echo
timed_echo "Monitoring $DIR_TO_WATCH for new $ANALYSIS_COMPLETE_FILE files (polling every $POLL_INTERVAL seconds)"
echo

while true; do
    check_for_new_files
    sleep "$POLL_INTERVAL"
done