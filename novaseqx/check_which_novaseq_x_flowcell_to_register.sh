#!/usr/bin/env bash

source message_functions || exit 1

TMP_ALL="/tmp/tmp_all.txt"
GCP_ALL="gs://fastq-input-prod-1/novaseq"
TMP_PROCESSED="/tmp/tmp_processed.txt"
GCP_PROCESSED="gs://hmf-ops-data/ops/novaseqx/processed.txt"

info "Listing all folders in ${GCP_ALL}"
gsutil ls ${GCP_ALL} | cut -d / -f 5 > ${TMP_ALL}
info "Copying ${GCP_PROCESSED} to ${TMP_PROCESSED}"
gsutil cp ${GCP_PROCESSED} ${TMP_PROCESSED}

info "Determining new folders"
new_folders=$(awk 'NR == FNR {seen[$1]; next} !($0 in seen)' ${TMP_PROCESSED} ${TMP_ALL})
for folder in ${new_folders}; do
    info "Start registering ${folder} into Hartwig API"
    bash /data/repos/production-scripts/novaseqx/register_novaseq_x_flowcell_and_fastq.sh ${folder}
    echo ${folder} >> ${TMP_PROCESSED}
    info "Finished registering ${folder} into Hartwig API"
done

info "Copying ${TMP_PROCESSED} to ${GCP_PROCESSED}"
gsutil cp ${TMP_PROCESSED} ${GCP_PROCESSED}}
info "Remove tmp files"
rm ${TMP_PROCESSED} ${TMP_ALL}