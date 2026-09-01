#!/bin/bash
# Is dev3's replication layer doing anything at all?
#
# The 09-01 IOR run found dev3 ~2x faster than dev2 while landing 0-1.3 GiB/node
# on the durable NVMe tier where dev2 lands a metronomic 4.4 GiB/node. If that is
# replication going inert, then asking dev3 for ZERO replicas should change
# neither the throughput nor the tier bytes. This runs num_replicas 1 and 0
# back to back INSIDE ONE ALLOCATION, which is the only sound comparison here.
#
# sbatch -N12 -p datacrumbs --export=ALL,PREFIX=...,SETTLE=120 run_replica_probe.sh
#SBATCH --job-name=repl_probe
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=40
#SBATCH --time=00:45:00
set -u
RUNROOT=/mnt/common/hyoklee/clio886/runs
PREFIX=${PREFIX:-/mnt/common/hyoklee/cliodev3/install}
TAG=${TAG:-dev3}
export SETTLE=${SETTLE:-120}

# Same keepalive rationale as run_multi_paired.sh: logind RemoveIPC wipes the
# user's shm when their last session on a node closes, which can land after the
# next phase's daemon has created its segments.
KEEPALIVE_PIDS=()
for h in $(scontrol show hostnames "$SLURM_JOB_NODELIST"); do
  env -u LD_LIBRARY_PATH ssh -n -o StrictHostKeyChecking=no -o BatchMode=yes \
    "$h" "sleep 100000" > /dev/null 2>&1 &
  KEEPALIVE_PIDS+=($!)
done
trap 'kill "${KEEPALIVE_PIDS[@]}" 2>/dev/null' EXIT
sleep 3

echo "########## replica probe on $SLURM_JOB_NODELIST (prefix=$PREFIX settle=$SETTLE)"
for nr in 1 0; do
  echo
  echo "########## phase r1_${TAG}nr${nr} (num_replicas=$nr)"
  PREFIX=$PREFIX BUILD_TAG="${TAG}nr${nr}" CHAIN=chain RUN_SUFFIX="r1" \
    NUM_REPLICAS=$nr LOG_DIR="" bash "$RUNROOT/run_ior_cliofs.sh"
  echo "########## end phase r1_${TAG}nr${nr}"
  sleep 25
done

echo
echo "########## SUMMARY (job $SLURM_JOB_ID, ${SLURM_JOB_NUM_NODES}n, replica probe)"
for nr in 1 0; do
  d=$RUNROOT/run_${TAG}nr${nr}_chain_${SLURM_JOB_NUM_NODES}n_${SLURM_JOB_ID}_r1
  printf 'num_replicas=%s  ' "$nr"
  awk '/^write +[0-9]/{w=$2} /^read +[0-9]/{r=$2} END{printf "write=%-10s read=%s\n", w, r}' \
    "$d/ior.out" 2>/dev/null || echo "(no ior.out)"
done
