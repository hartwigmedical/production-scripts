#!/bin/bash

DIR_TO_WATCH="$1"
DIR_TO_WATCH="${DIR_TO_WATCH%/}"
if [ -z "$DIR_TO_WATCH" ]; then
  echo "Provide a base directory to watch";
  echo "Example: monitor_conversion_ready.sh /my/home/data_dir"
  exit 1
fi

# Kill any existing inotifywait processes watching the same directory
for pid in $(pgrep -x inotifywait); do
    if grep -q "$DIR_TO_WATCH" /proc/$pid/cmdline 2>/dev/null; then
        echo "Killing existing inotifywait process (PID: $pid) watching $DIR_TO_WATCH..."
        kill -9 $pid
        sleep 1
    fi
done

ANALYSIS_COMPLETE_FILE="Secondary_Analysis_Complete.txt"

process_folder() {
    local flowcell_folder="$1"
    echo "Processing: $flowcell_folder"
    local data_dir="${flowcell_folder%%"$ANALYSIS_COMPLETE_FILE"}"
    echo "data_dir: $data_dir"
    local run_name="${data_dir##"$DIR_TO_WATCH"}"
    echo "Processing run: $run_name"
    "./upload_finished_analysis_files.sh" "$data_dir" "$run_name"
}

echo "Monitoring $DIR_TO_WATCH for new $ANALYSIS_COMPLETE_FILE files"
inotifywait -m -r -e close_write --format '%w%f' "$DIR_TO_WATCH" | while read -r full_path; do
  echo "Found flowcell_folder: $full_path"
    if [[ "$full_path" == *"$ANALYSIS_COMPLETE_FILE" ]]; then
        FLOWCELL_FOLDER="${full_path#"$DIR_TO_WATCH"}"
        echo "${FLOWCELL_FOLDER}"
        process_folder "$FLOWCELL_FOLDER"
    fi
done