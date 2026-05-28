#!/bin/bash
# Read-bound CA1 benchmark with EXPLICIT PRE-STAGING into the CTE NVMe tier.
#
# Single-process variant: avoid spawning subshells under LD_PRELOAD (each spawn
# re-inits the chimaera client and floods stdout with INFO lines, breaking bash
# arithmetic). All staging + reading happens inside one Python process so the
# adapter only inits once.
#
# Phase 1 (under adapter): cp NFS sources -> $STAGE_DIR/* (writes routed into
#   chimaera NVMe tier).
# Phase 2 (under adapter): h5py read iterations from $STAGE_DIR/*.h5
#   (reads served from the tier).
#
# Usage:
#   sbatch --nodes=1 --ntasks=1 --job-name=cr_staged \
#          --export=ALL,ITERS=3,WSET=raw run_caseread_staged.sbatch
#SBATCH --partition=compute
#SBATCH --exclusive
#SBATCH --time=02:00:00
#SBATCH --output=/home/hyoklee/logs/caseread_staged_%x_%j.log

set -e
: "${ITERS:=3}"
: "${WSET:=raw}"
: "${TAG:=staged}"

. "/home/hyoklee/mc3/etc/profile.d/conda.sh"
conda activate /home/hyoklee/mc3/envs/miv
export LD_LIBRARY_PATH=$CONDA_PREFIX/lib:$LD_LIBRARY_PATH
export MIV_SKIP_MPI_CHECK=1
export HWLOC_HIDE_ERRORS=1

DATA=/home/hyoklee/dataset-staging/MiV_CA1_full
case "$WSET" in
  raw)
    FILES=(
      "$DATA/MiV_Cells_Microcircuit_20220410.h5"
      "$DATA/MiV_Cells_Microcircuit_20220412.h5"
      "$DATA/MiV_Connections_Microcircuit_20220410.h5"
      "$DATA/MiV_Connections_Microcircuit_20220412.h5"
    ) ;;
  one)
    # Single 6 GB file — sanity check that staged read works at all
    FILES=("$DATA/MiV_Connections_Microcircuit_20220410.h5") ;;
  two)
    # 6 + 7 GB — does adding a second tagged file break read of the first?
    FILES=(
      "$DATA/MiV_Connections_Microcircuit_20220410.h5"
      "$DATA/MiV_Connections_Microcircuit_20220412.h5"
    ) ;;
  big)
    FILES=(
      "$DATA/MiV_Cells_Microcircuit_20220412.h5"
      "$DATA/MiV_Connections_Microcircuit_20220412.h5"
      "$DATA/PYR_forest_compressed.h5"
      "$DATA/PYR_connections_compressed.h5"
      "$DATA/PYR_forest_syns_compressed.h5"
    ) ;;
  *) echo "ERROR: unknown WSET=$WSET"; exit 2 ;;
esac

echo "=== caseread_staged: node=$(hostname) WSET=${WSET} ITERS=${ITERS} TAG=${TAG} ==="
echo "free memory at start:"; free -h
echo "NVMe state at start:"; df -h /mnt/nvme 2>/dev/null | tail -2

: "${CORE_INSTALL:=/home/hyoklee/core/install}"
IOW_ENV=/home/hyoklee/mc3/envs/iowarp-build
CORE="$CORE_INSTALL/lib/libclio_cte_posix.so"
: "${CHIMA_CONF:=/home/hyoklee/bin/chimaera_caseread_nvme.yaml}"
: "${NVME_DIR:=/mnt/nvme/hyoklee/cte_caseread}"
: "${STAGE_DIR:=/tmp/cte_stage_${SLURM_JOB_ID}}"
export CLIO_SERVER_CONF="$CHIMA_CONF"
RESULTS=/home/hyoklee/logs/caseread_staged_${TAG}_${SLURM_JOB_ID}_workdir
mkdir -p "$RESULTS"

# --- start runtime (no LD_PRELOAD yet) ---------------------------------------
rm -rf "$NVME_DIR" 2>/dev/null; mkdir -p "$NVME_DIR"
echo "IOWarp: NVMe tier dir=$NVME_DIR ($(df -h "$NVME_DIR" | awk 'NR==2{print $4" free"}'))"
( export PATH="$CORE_INSTALL/bin:$IOW_ENV/bin:$PATH"
  export LD_LIBRARY_PATH="$CORE_INSTALL/lib:$IOW_ENV/lib"
  export CLIO_SERVER_CONF="$CHIMA_CONF"
  clio_run start ) > "$RESULTS/clio_runtime.log" 2>&1 &
CLIO_BG=$!
RUNTIME_UP=0
for i in $(seq 1 120); do
  rc=$(grep -ca 'All .* pools created successfully' "$RESULTS/clio_runtime.log" 2>/dev/null) || true
  rc=${rc:-0}
  if [ "$rc" -ge 1 ]; then
    sleep 2; RUNTIME_UP=1; echo "IOWarp: runtime ready"; break
  fi
  kill -0 "$CLIO_BG" 2>/dev/null || { echo "IOWarp: runtime exited early"; exit 1; }
  sleep 1
done
[ "$RUNTIME_UP" = "1" ] || { echo "IOWarp: runtime not ready"; exit 1; }

stop_runtime() {
  ( export PATH="$CORE_INSTALL/bin:$IOW_ENV/bin:$PATH"
    export LD_LIBRARY_PATH="$CORE_INSTALL/lib:$IOW_ENV/lib"
    export CLIO_SERVER_CONF="$CHIMA_CONF"
    clio_run stop ) >> "$RESULTS/clio_runtime.log" 2>&1 || true
  echo "IOWarp: NVMe tier blob at stop:"
  ls -lh "$NVME_DIR" 2>/dev/null
  du -sh "$NVME_DIR" 2>/dev/null
}
trap stop_runtime EXIT

# --- run staged bench (one Python process, LD_PRELOAD applied only here) -----
# All work inside one Python process so the adapter inits exactly once.
echo "=== STAGE + READ phase ==="
T0=$(date +%s.%N)
LD_LIBRARY_PATH="$CONDA_PREFIX/lib:$CORE_INSTALL/lib:$IOW_ENV/lib" \
LD_PRELOAD="$CORE" \
  python /home/hyoklee/bin/staged_read_bench.py \
    --dest-dir "$STAGE_DIR" --iterations "$ITERS" --label "$TAG" "${FILES[@]}"
RC=$?
T1=$(date +%s.%N)
echo "=== caseread_staged exit=$RC walltime=$(echo "$T1 - $T0" | bc) s ==="
exit $RC
