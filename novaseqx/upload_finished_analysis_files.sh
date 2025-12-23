#!/bin/bash

# Export the needed server URL and authentication token to make sure the upload script works
export SERVER_URL="https://upload.test.hartwigmedicalfoundation.nl"
export AUTH_TOKEN="enter-your-token"

MAX_PARALLEL_UPLOADS=6
OTHER_FILES=("Quality_Metrics.csv" "SampleSheet.csv" "RunInfo.xml" "Demultiplex_Stats.csv" "Top_Unknown_Barcodes.csv")
FLOWCELL_DATA_DIRECTORY="$1"
FLOWCELL_DATA_DIRECTORY="${FLOWCELL_DATA_DIRECTORY%/}"
FLOWCELL_ID="$2"
FLOWCELL_ID="${FLOWCELL_ID#/}"

if [ -z "$FLOWCELL_DATA_DIRECTORY" ]; then
  echo "Error: Provide a run directory"
  echo "Example: ./upload_finished_analysis_files.sh [FLOWCELL_DATA_DIRECTORY] [FLOWCELL_ID]"
  echo "Specify which analysis should be uploaded in the path e.g. FLOWCELL_DATA_DIRECTORY/Analysis/1/Data"
  exit 1
fi

if [[ -z "$FLOWCELL_ID" ]]; then
    echo "Error: provide a flowcell ID, this must be set and unique otherwise the files will be overridden"
    exit 1
fi

echo "Doing a maximum of ${MAX_PARALLEL_UPLOADS} parallel uploads using server: ${SERVER_URL}"

get_sub_path() {
    local file=$1
    local folder_depth=$2
    if [ -n "$folder_depth" ]; then
        local rel_path=${file#"$FLOWCELL_DATA_DIRECTORY"/}
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
    echo
    echo "----------$pattern------------"
    local uri_base="novaseq/$FLOWCELL_ID/$folder"

    files=()
    while IFS= read -r file; do
        files+=("$file:$(get_sub_path "$file" "$folder_depth")")
    done < <(find "$FLOWCELL_DATA_DIRECTORY" -type f -name "$pattern")

    if [ ${#files[@]} -eq 0 ]; then
        echo "No files found matching $pattern"
        return
    fi

    echo "Starting to upload $pattern (${#files[@]}) files to $uri_base"
    printf "%s\n" "${files[@]}" | parallel -j $MAX_PARALLEL_UPLOADS -C ':' './upload-file.sh' {1} "$uri_base"/{2}
    wait

    echo "Done uploading the $pattern files"
}

upload_files ".fastq.gz" "fastq"

for file in "${OTHER_FILES[@]}"; do
    upload_files "$file" "other"
done

# RunParameters file is in different folder
run_parameters_file=$(echo ${FLOWCELL_DATA_DIRECTORY} | cut -d / -f1-4,6-7)
run_parameters_file=$(echo "${run_parameters_file}/RunParameters.xml")
./upload-file.sh ${run_parameters_file} "novaseq/$FLOWCELL_ID/other/RunParameters.xml"
