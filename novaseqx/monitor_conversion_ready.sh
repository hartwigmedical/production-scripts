#!/bin/bash

BASE_DIR="$1"
if [ -z "$BASE_DIR" ]; then
  echo "Provide a base directory to watch";
  echo "Example: monitor_conversion_ready.sh /my/home/dir"
  exit 1
fi

ANALYSIS_COMPLETE_FILE="/Analysis/1/Data/Secondary_Analysis_Complete.txt"

process_folder() {
    local file="$1"
    local dir="${file%%"$ANALYSIS_COMPLETE_FILE"}"
    local run_name="${dir##"$BASE_DIR"/}"
    echo "Processing run: $run_name"
    "./upload_finished_analysis_files.sh" "$dir" "$run_name"
}

echo "Monitoring $BASE_DIR for new $ANALYSIS_COMPLETE_FILE files"
inotifywait -m -r -e close_write --format '%w%f' "$BASE_DIR" | while read -r file; do
    if [[ $(basename "$file") == "$ANALYSIS_COMPLETE_FILE" ]]; then
        dir="$(dirname "$file")"
        if [[ ! -f "$dir/copy_complete.txt" ]]; then
            process_folder "$file"
            touch "$dir/copy_complete.txt"
        fi
    fi
done