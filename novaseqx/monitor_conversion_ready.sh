#!/bin/bash

BASE_DIR="$1"
if [ -z "$BASE_DIR" ]; then
  echo "Provide a base directory to watch";
  echo "Example: monitor_conversion_ready.sh /my/home/dir"
  exit 1
fi

# Kill any existing inotifywait processes watching the same directory
for pid in $(pgrep -x inotifywait); do
    if grep -q "$BASE_DIR" /proc/$pid/cmdline 2>/dev/null; then
        echo "Killing existing inotifywait process (PID: $pid) watching $BASE_DIR..."
        kill $pid
        sleep 1
    fi
done

ANALYSIS_COMPLETE_FILE="Analysis/1/Data/Secondary_Analysis_Complete.txt"

process_folder() {
    local file="$1"
    echo "Processing: $file"
    local dir="${file%%"$ANALYSIS_COMPLETE_FILE"}"
    echo "dir: $dir"
    local run_name="${dir##"$BASE_DIR"/}"
    echo "Processing run: $run_name"
#    "./upload_finished_analysis_files.sh" "$dir" "$run_name"
}

echo "Monitoring $BASE_DIR for new $ANALYSIS_COMPLETE_FILE files"
inotifywait -m -r -e close_write --format '%w%f' "$BASE_DIR" | while read -r full_path; do
  echo "Found file: $full_path"
    if [[ "$full_path" == *"$ANALYSIS_COMPLETE_FILE" ]]; then
        FLOWCELL_FOLDER="${full_path#BASE_PATH}"
        process_folder "$FLOWCELL_FOLDER"
    fi
done