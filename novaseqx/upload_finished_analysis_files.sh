#!/bin/bash

# Export the needed URL and credentials to make sure the upload script works
export SERVER_URL="enter-your-url"
export AUTH_TOKEN="enter-your-token"

MAX_PARALLEL_UPLOADS=6
OTHER_FILES=("Quality_Metrics.csv" "SampleSheet.csv")
RUN_DIRECTORY="$1"
RUN_NAME="$2"

if [ -z "$RUN_DIRECTORY" ]; then
  echo "Provide a run directory"
  echo "Example: ./upload_finished_analysis_files.sh /path/to/base/results/folder"
  exit 1
fi

upload_files() {
    local pattern=$1
    local folder=$2

    echo "----------$pattern------------"
    local uri_base="novaseq/$RUN_NAME/$folder"
    echo "Starting to upload $pattern files to $uri_base"

    files=()
    while IFS= read -r file; do
        files+=("$file")
    done < <(find "$RUN_DIRECTORY" -type f -name "*$pattern")

    echo "Found ${#files[@]} file(s)"

    local count=0
    for f in "${files[@]}"; do
        echo "Copying file: $f"
        "./upload_file_to_gcp.sh" $f
        ((count++))
        if (( count % MAX_PARALLEL_UPLOADS == 0 )); then
            wait
        fi
    done
    wait
    echo "Done uploading the $pattern files"
    echo ""
}

echo "Searching files in $RUN_DIRECTORY"

SECONDARY_ANALYSIS_FILE="$RUN_DIRECTORY/Analysis/1/Data/Secondary_Analysis_Complete.txt"
echo "Searching secondary analysis completion file $SECONDARY_ANALYSIS_FILE"
if [[ -f "$SECONDARY_ANALYSIS_FILE" ]]; then
    echo "Completion file found..."
else
    echo "No secondary analysis complete file found at $RUN_DIRECTORY"
    exit 1
fi

upload_files ".fastq.gz" "fastq"
upload_files ".cbcl" "cbcl"
upload_files ".bcl" "bcl"

for file in "${OTHER_FILES[@]}"; do
    upload_files "$file" "reports"
done
