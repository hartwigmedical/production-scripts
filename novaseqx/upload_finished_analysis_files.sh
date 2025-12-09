#!/bin/bash

# Export the needed server URL and authentication token to make sure the upload script works
export SERVER_URL="https://upload.test.hartwigmedicalfoundation.nl"
export AUTH_TOKEN="enter-your-token"

MAX_PARALLEL_UPLOADS=3
OTHER_FILES=("Quality_Metrics.csv" "SampleSheet.csv" "RunInfo.xml")
RUN_DIRECTORY="$1"
RUN_NAME="$2"

if [ -z "$RUN_DIRECTORY" ]; then
  echo "Provide a run directory"
  echo "Example: ./upload_finished_analysis_files.sh /path/to/runfolder" "base_folder_in_bucket"
  exit 1
fi

echo "Doing ${MAX_PARALLEL_UPLOADS} at the same time to server ${SERVER_URL}"

get_sub_path() {
    local file=$1
    local folder_depth=$2
    if [ -n "$folder_depth" ]; then
        local rel_path=${file#"$RUN_DIRECTORY"/}
        echo "$(echo "$rel_path" | rev | cut -d'/' -f1-$((folder_depth+1)) | rev)"
    else
        echo "$(basename "$file")"
    fi
}

upload_files() {
    local pattern="*$1"   # The pattern of the files it should match
    local folder=$2       # The base folder in the cloud bucket
    # Keeps the structure of the folders counting from the end
    # e.g. runfolder/f1/f2/file.txt with depth 1 would keep f2/file.txt
    local folder_depth=$3

    echo "----------$pattern------------"
    local uri_base="novaseq/$RUN_NAME/$folder"
    echo "Starting to upload $pattern files to $uri_base"

    files=()
    while IFS= read -r file; do
        files+=("$file:$(get_sub_path "$file" "$folder_depth")")
    done < <(find "$RUN_DIRECTORY" -type f -name "$pattern")

    echo "Uploading ${#files[@]} file(s)"
    printf "%s\n" "${files[@]}" | parallel -j $MAX_PARALLEL_UPLOADS -C ':' './upload-file.sh' {1} "$uri_base"/{2}
    wait

    echo "Done uploading the $pattern files"
    echo
}

SECONDARY_ANALYSIS_FILE="$RUN_DIRECTORY/Analysis/1/Data/Secondary_Analysis_Complete.txt"

echo "Searching files in $RUN_DIRECTORY"
echo "Searching secondary analysis completion file $SECONDARY_ANALYSIS_FILE"
if [[ -f "$SECONDARY_ANALYSIS_FILE" ]]; then
    echo "Completion file found..."
else
    echo "No secondary analysis complete file found at $RUN_DIRECTORY"
    exit 1
fi

upload_files ".fastq.gz" "fastq"

for file in "${OTHER_FILES[@]}"; do
    upload_files "$file" "other"
done
