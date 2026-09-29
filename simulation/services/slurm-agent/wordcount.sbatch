#!/bin/bash
# One word-count job: an array with one task per chunk. slurm_agent.py copies
# this file into the job's folder, replacing @JOB_DIR@, and submits it with
#   sbatch --array=0-(chunks-1) job.sbatch
#SBATCH --job-name=wordcount
#SBATCH --partition=calc
#SBATCH --cpus-per-task=1
#SBATCH --mem=256M
#SBATCH --time=00:05:00
#SBATCH --output=@JOB_DIR@/task-%a.log

i=$(printf '%03d' "$SLURM_ARRAY_TASK_ID")
apptainer exec --bind /shared --env NODE_NAME="$SLURMD_NODENAME" /shared/images/mapper.sif \
    python /app/mapper.py "@JOB_DIR@/chunk-$i.txt" "@JOB_DIR@/result-$i.json"
