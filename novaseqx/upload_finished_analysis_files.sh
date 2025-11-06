#!/bin/bash

# Export the needed server URL and authentication token to make sure the upload script works
export SERVER_URL="https://upload.test.hartwigmedicalfoundation.nl"
export AUTH_TOKEN="enter-your-token"

MAX_PARALLEL_UPLOADS=6
OTHER_FILES=("Quality_Metrics.csv" "SampleSheet.csv" "RunInfo.xml" "RunParameters.xml")
RUN_DIRECTORY="$1"
RUN_NAME="$2"

if [ -z "$RUN_DIRECTORY" ]; then
  echo "Provide a run directory"
  echo "Example: ./upload_finished_analysis_files.sh /path/to/runfolder" "runfolder"
  exit 1
fi

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
    local folder_depth=$3 # Keeps the structure of the folders counting from the end, e.g. runfolder/f1/f2/file.txt with depth 1 would keep f2/file.txt

    echo "----------$pattern------------"
    local uri_base="novaseq/$RUN_NAME/$folder"
    echo "Starting to upload $pattern files to $uri_base"

    files=()
    while IFS= read -r file; do
        files+=("$file:$(get_sub_path "$file" "$folder_depth")")
    done < <(find "$RUN_DIRECTORY" -type f -name "$pattern")

    echo "Found ${#files[@]} file(s)"

    local count=0
    for f in "${files[@]}"; do
        IFS=':' read -r filepath sub_path <<< "$f"
        echo "Copying file: $filepath to $uri_base/$sub_path"
        "./upload_file_to_gcp.sh" "$filepath" "$uri_base/$sub_path"
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
upload_files ".cbcl" "cbcl" 2

for file in "${OTHER_FILES[@]}"; do
    upload_files "$file" "other"
done
