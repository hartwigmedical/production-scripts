#!/usr/bin/env bash

source message_functions || exit 1

SCRIPT=$(basename "$0")
API_URL="http://api.prod-1/hmf/v1"
FASTQ_BUCKET="fastq-input-prod-1"

if [[ -z "$1" || $1 == "-h" || $1 == "--help" ]]; then
    echo "---"
    echo " Usage: ${SCRIPT} <sequencing_run>"
    echo "        ${SCRIPT} 20251031_LH00984_0004_A23CLVJLT3"
    echo "---"
    exit 1
fi

current_datetime=$(date '+%Y-%m-%dT%H:%M:%S')

sequencing_run=${1}

sequencer=$(echo ${sequencing_run} | cut -d_ -f2)
run=$(echo ${sequencing_run} | cut -d_ -f3)
flowcell=$(echo ${sequencing_run} | cut -d_ -f4 | sed 's/^.\{1\}//')

samplesheet_file="gs://${FASTQ_BUCKET}/novaseq/${sequencing_run}/other/SampleSheet.csv"
name=$(gsutil cat ${samplesheet_file} | grep RunName | cut -d, -f2)

metrics_file="gs://${FASTQ_BUCKET}/novaseq/${sequencing_run}/other/Quality_Metrics.csv"
metrics_data=$(gsutil cat ${metrics_file} | tail -n +2)

seq_platform_data=$(hmf_api_get "platforms/7") # Novaseq X id = 7.
flowcell_undet_req=$(echo "${seq_platform_data}" | jq -r '.undetermined_reads_perc_cutoff * 100') # For correct formatting
flowcell_q30_req=$(echo "${seq_platform_data}" | jq -r '.q30_cutoff')

yield_total=$(echo "${metrics_data}" | awk 'BEGIN {FS=OFS=","} ; {sum+=$6} END {printf "%.0f", sum}')
yield_undetermined=$(echo "${metrics_data}" | grep "Undetermined" | awk 'BEGIN {FS=OFS=","} ; {sum+=$6} END {printf "%.0f",sum}')
percentage_undetermined=$(echo "${yield_undetermined}/${yield_total}*10000" | bc -l | cut -d. -f1)
q30_average=$(echo "${metrics_data}" | awk 'BEGIN {FS=OFS=","} ; {sum+=$10; ++n} END {print sum/n *100}')

if [[ $(echo "${percentage_undetermined} <= ${flowcell_undet_req}" | bc -l) -eq 1 && $(echo "${q30_average} >= ${flowcell_q30_req}" | bc -l) -eq 1 ]]
then
    flowcell_status="true"
else
    flowcell_status="false"
fi

flowcell_object_id=$(hmf_api_get "flowcells?flowcell_id=${flowcell}" |jq -r '.[] | .id')
hmf_api_patch -c flowcells -o ${flowcell_object_id} -f yld -v ${yield_total} -e
hmf_api_patch -c flowcells -o ${flowcell_object_id} -f q30 -v ${q30_average} -e
hmf_api_patch -c flowcells -o ${flowcell_object_id} -f undet_rds -v ${yield_undetermined} -e
hmf_api_patch -c flowcells -o ${flowcell_object_id} -f undet_rds_p -v ${percentage_undetermined} -e
hmf_api_patch -c flowcells -o ${flowcell_object_id} -f undet_rds_p_pass -v ${flowcell_status} -e

# Patch Fastq
echo "${metrics_data}" | while read first_line; read second_line
do
    sample_barcode=$(echo "${first_line}" | cut -d, -f2)
    if [[ ${sample_barcode} == "Undetermined" ]]
    then
        info "Undetermined, thus ignore"
    else
        lane=$(echo "${first_line}" | cut -d, -f1)
        yield_r1=$(echo "${first_line}" | cut -d, -f6)
        q30_r1=$(echo "${first_line}" | cut -d, -f10)
        yield_r2=$(echo "${second_line}" | cut -d, -f6)
        q30_r2=$(echo "${second_line}" | cut -d, -f10)

        yield=$(echo "${yield_r1} + ${yield_r2}" | bc )
        q30=$(echo "scale=2; (${q30_r1} + ${q30_r2}) / 2" | bc | sed 's/^\./0./' -)

        if [[ $(echo "${yield} > 0" | bc -l) -eq 1 && $(echo "${q30} >= 0.85" | bc -l) -eq 1 ]]
        then
            qc_pass="true"
        else
            qc_pass="false"
        fi

        bucket_path="${FASTQ_BUCKET}/novaseq/${sequencing_run}/fastq"
        filename_r1=$(gsutil ls "gs://${bucket_path}/${sample_barcode}_${flowcell_id}_*_L00${lane}_R1_001.fastq.gz" | cut -d/ -f7)
        filename_r2=$(gsutil ls "gs://${bucket_path}/${sample_barcode}_${flowcell_id}_*_L00${lane}_R2_001.fastq.gz" | cut -d/ -f7)

        fastq_object_id=$(hmf_api_get "fastq?name_r1=${filename_r1}" | jq -r '.[].id')

        hmf_api_patch -c "fastq" -o "${fastq_object_id}" -f "yld" -v "${yield}" -e
        hmf_api_patch -c "fastq" -o "${fastq_object_id}" -f "q30" -v "${q30}" -e
        hmf_api_patch -c "fastq" -o "${fastq_object_id}" -f "qc_pass" -v "${qc_pass}" -e
    fi
done

#Patch Sample
for sample_barcode in $(echo "${metrics_data}" | awk -F, '{print $2}' | sort | uniq | grep -v Undetermined) # Keep Undetermined files out of HMF API
do
    sample_api=$(hmf_api_get "samples?barcode=${sample_barcode}")
    sample_id=$(echo "${sample_api}" | jq -r '.[].id')
    sample_yld_req=$(echo "${sample_api}" | jq -r '.[].yld_req')
    sample_q30_req=$(echo "${sample_api}" | jq -r '.[].q30_req')

    fastq_api=$(hmf_api_get "fastq?sample_id=${sample_id}")
    sample_yld=$(echo "${fastq_api}" | jq -r '.[] | select(.qc_pass==true) | select(.bucket!=null) | .yld' | awk '{sum+=$0} END {printf "%.0f", sum}')
    sample_q30=$(echo "${fastq_api}" | jq -r '.[] | select(.qc_pass==true) | select(.bucket!=null) | .q30' | awk '{sum+=$0; ++n} END {print sum/n * 100}')
    if [[ $(echo "${sample_yld} >= ${sample_yld_req}" | bc -l) -eq 1 && $(echo "${sample_q30} >= ${sample_q30_req}" | bc -l) -eq 1 ]]
    then
        sample_status="Ready"
    else
        sample_status="Insufficient Quality"
    fi

    if [[ ${flowcell_status} == "false" ]]
    then
        sample_status="Insufficient Quality"
    fi

    hmf_api_patch -c "samples" -o "${sample_id}" -f "yld" -v "${sample_yld}" -e
    hmf_api_patch -c "samples" -o "${sample_id}" -f "q30" -v "${sample_q30}" -e
    hmf_api_patch -c "samples" -o "${sample_id}" -f "status" -v "${sample_status}" -e
done