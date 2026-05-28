#!/bin/bash
# SLURM run script for the MiV CA1 READ-BOUND benchmark on ares.
# Usage:
#   sbatch --nodes=1 --ntasks=1 --job-name=... \
#          --export=ALL,IOWARP=0,ITERS=3,TAG=base run_caseread.sbatch
# Env knobs:
#   IOWARP=0|1    0 = native HDF5 → NFS (baseline); 1 = LD_PRELOAD IOWarp CTE adapter
#   ITERS         number of read iterations (default 3 — iter 1 cold, iter 2/3 re-read)
#   TAG           label used in log paths
#   WSET          working set selector: "big" (~48 GB, defeats 46 GB cache) or
#                 "small" (~35 GB, fits cache for sanity check). Default big.
#   CHIMA_CONF    chimaera runtime config (default RAM tier; *_nvme.yaml for NVMe)
#   NVME_DIR      parent dir for the file-backed NVMe CTE tier
#   CORE_INSTALL  IOWarp build root (default ~/core/install)
#
# Design: read the full CA1 working set sequentially with h5py for N iterations.
# Iter 1 is cold. Iter 2+ is the re-read regime where CTE wins: baseline must
# re-fetch from NFS (page cache is 46 GB; working set is >46 GB so previous reads
# were evicted) while CTE serves from the node-local tier (NVMe ~1.5 GB/s).
#SBATCH --partition=compute
#SBATCH --exclusive
#SBATCH --time=02:00:00
#SBATCH --output=/home/hyoklee/logs/caseread_%x_%j.log

set -e
: "${IOWARP:=0}"
: "${ITERS:=3}"
: "${TAG:=run}"
: "${WSET:=big}"

. "/home/hyoklee/mc3/etc/profile.d/conda.sh"
conda activate /home/hyoklee/mc3/envs/miv
export LD_LIBRARY_PATH=$CONDA_PREFIX/lib:$LD_LIBRARY_PATH
export MIV_SKIP_MPI_CHECK=1
export HWLOC_HIDE_ERRORS=1

DATA=/home/hyoklee/dataset-staging/MiV_CA1_full
case "$WSET" in
  big)
    # ~48 GB: above 46 GB page cache, below ~55 GB NVMe tier.
    FILES=(
      "$DATA/MiV_Cells_Microcircuit_20220412.h5"
      "$DATA/MiV_Connections_Microcircuit_20220412.h5"
      "$DATA/PYR_forest_compressed.h5"
      "$DATA/PYR_connections_compressed.h5"
      "$DATA/PYR_forest_syns_compressed.h5"
    )
    ;;
  small)
    # ~35 GB: fits in 46 GB page cache (sanity: baseline should win on iter 2+).
    FILES=(
      "$DATA/MiV_Connections_Microcircuit_20220412.h5"
      "$DATA/PYR_forest_compressed.h5"
      "$DATA/PYR_connections_compressed.h5"
      "$DATA/PYR_forest_syns_compressed.h5"
    )
    ;;
  raw)
    # ~48 GB of UNCOMPRESSED MiV files: pure I/O test (no gzip CPU bottleneck).
    # Defeats the 46 GB page cache, fits in 55 GB NVMe tier.
    FILES=(
      "$DATA/MiV_Cells_Microcircuit_20220410.h5"
      "$DATA/MiV_Cells_Microcircuit_20220412.h5"
      "$DATA/MiV_Connections_Microcircuit_20220410.h5"
      "$DATA/MiV_Connections_Microcircuit_20220412.h5"
    )
    ;;
  *)
    echo "ERROR: unknown WSET=$WSET (use big|small)"; exit 2 ;;
esac

NTASKS=${SLURM_NTASKS:-1}
echo "=== caseread run: node=$(hostname) WSET=${WSET} IOWARP=${IOWARP} ITERS=${ITERS} TAG=${TAG} ==="
echo "files (${#FILES[@]}):"
printf '  %s\n' "${FILES[@]}"
echo "working set bytes:"
du -bc "${FILES[@]}" | tail -1
echo "free memory at start:"
free -h
echo "NVMe state at start:"
df -h /mnt/nvme 2>/dev/null | tail -2
T0=$(date +%s.%N)

# --- IOWarp core (CTE) setup --------------------------------------------------
: "${CORE_INSTALL:=/home/hyoklee/core/install}"
IOW_ENV=/home/hyoklee/mc3/envs/iowarp-build
CORE="$CORE_INSTALL/lib/libclio_cte_posix.so"
[ -f "$CORE" ] || CORE=$(find /home/hyoklee/core/build -name 'libclio_cte_posix.so' 2>/dev/null | head -1)
NNODES=${SLURM_JOB_NUM_NODES:-1}
: "${CHIMA_CONF:=/home/hyoklee/bin/chimaera_caseread.yaml}"
export CLIO_SERVER_CONF="$CHIMA_CONF"
: "${NVME_DIR:=}"
RESULTS=/home/hyoklee/logs/caseread_${TAG}_${SLURM_JOB_ID}_workdir
mkdir -p "$RESULTS"

RUNTIME_UP=0
start_runtime() {
  if [ "$NNODES" -le 1 ]; then
    if [ -n "$NVME_DIR" ]; then
      rm -rf "$NVME_DIR" 2>/dev/null; mkdir -p "$NVME_DIR"
      echo "IOWarp: node-local NVMe tier dir=$NVME_DIR ($(df -h "$NVME_DIR" | awk 'NR==2{print $4" free on "$6}'))"
    fi
    echo "IOWarp: starting single-node runtime ($CHIMA_CONF)"
    ( export PATH="$CORE_INSTALL/bin:$IOW_ENV/bin:$PATH"
      export LD_LIBRARY_PATH="$CORE_INSTALL/lib:$IOW_ENV/lib"
      export CLIO_SERVER_CONF="$CHIMA_CONF"
      clio_run start ) > "$RESULTS/clio_runtime.log" 2>&1 &
    CLIO_BG=$!
  else
    echo "ERROR: multi-node not implemented for caseread"; return 1
  fi
  for i in $(seq 1 120); do
    rc=$(grep -ca 'All .* pools created successfully' "$RESULTS/clio_runtime.log" 2>/dev/null)
    rc=${rc:-0}
    if [ "$rc" -ge "$NNODES" ]; then
      sleep 2; RUNTIME_UP=1; echo "IOWarp: runtime ready ($rc/$NNODES nodes)"; return 0
    fi
    kill -0 "$CLIO_BG" 2>/dev/null || { echo "IOWarp: runtime exited early"; return 1; }
    sleep 1
  done
  echo "IOWarp: runtime did not become ready in time"; return 1
}
stop_runtime() {
  [ "$RUNTIME_UP" = "1" ] || return 0
  ( export PATH="$CORE_INSTALL/bin:$IOW_ENV/bin:$PATH"
    export LD_LIBRARY_PATH="$CORE_INSTALL/lib:$IOW_ENV/lib"
    export CLIO_SERVER_CONF="$CHIMA_CONF"
    clio_run stop ) >> "$RESULTS/clio_runtime.log" 2>&1 || true
  if [ -n "$NVME_DIR" ] && [ -d "$NVME_DIR" ]; then
    echo "IOWarp: NVMe tier contents at stop:" ; ls -la "$NVME_DIR" 2>/dev/null | tail -n +2
    du -sh "$NVME_DIR" 2>/dev/null
    rm -rf "$NVME_DIR" 2>/dev/null || true
  fi
  RUNTIME_UP=0
}
trap stop_runtime EXIT

if [ "$IOWARP" = "1" ]; then
  if [ -n "$CORE" ] && [ -f "$CORE" ]; then
    if start_runtime; then
      export LD_LIBRARY_PATH="$CONDA_PREFIX/lib:$CORE_INSTALL/lib:$IOW_ENV/lib"
      export LD_PRELOAD="$CORE"
      echo "IOWarp ON: adapter=$CORE"
    else
      echo "WARNING: IOWARP=1 but runtime failed to start; running native"
    fi
  else
    echo "WARNING: IOWARP=1 but libclio_cte_posix.so not found; running native"
  fi
fi

set +e
python /home/hyoklee/bin/read_bench_ca1.py --iterations "$ITERS" --label "$TAG" "${FILES[@]}"
RC=$?
unset LD_PRELOAD
T1=$(date +%s.%N)
stop_runtime
echo "=== caseread exit=$RC walltime=$(echo "$T1 - $T0" | bc) s ==="
echo "free memory at end:"; free -h
echo "end=$(date +%s.%N)"
exit $RC
