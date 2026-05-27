#!/bin/bash
# SLURM run script for MiV-Simulator case 4 (opsin) on ares.
# Usage:
#   sbatch --nodes=N --ntasks=T --job-name=... \
#          --export=ALL,IOWARP=0,TSTOP=500,TAG=base run_case4.sbatch
# Env knobs:
#   IOWARP=0|1    0 = native HDF5 (baseline); 1 = LD_PRELOAD IOWarp CTE posix adapter
#   TSTOP         simulation stop time in ms (default 500)
#   TAG           label used in result/log paths
#   CORE_INSTALL  which IOWarp build (default ~/core; ~/core.iowarp/install for upstream)
#   CHIMA_CONF    runtime config (default RAM tier; *_nvme.yaml for node-local NVMe tier)
#   NVME_DIR      parent dir for a file-backed NVMe tier (created/cleaned per run)
#
# Case 4 (opsin) reuses the same Microcircuit_Small datasets as case 6 (its
# datasets/ is a symlink to 6-gapjunctions/datasets); the only model difference
# is that case 4 has no gap junctions. Opsin light stimulation is a TODO in
# miv_simulator (env.opsin_config is commented out), so run-network runs the
# base Microcircuit_Small network here.
#SBATCH --partition=compute
#SBATCH --exclusive
#SBATCH --time=02:00:00
#SBATCH --output=/home/hyoklee/logs/case4_%x_%j.log
# --exclusive: one job per node so each run is isolated with a cold page cache
# (the compute partition otherwise packs multiple 4-task jobs onto a 40-core node).

set -e
: "${IOWARP:=0}"
: "${TSTOP:=500}"
: "${TAG:=run}"

. "/home/hyoklee/mc3/etc/profile.d/conda.sh"
conda activate /home/hyoklee/mc3/envs/miv
export LD_LIBRARY_PATH=$CONDA_PREFIX/lib:$LD_LIBRARY_PATH
export PATH=/home/hyoklee/neuroh5/build/bin:$PATH
export MIV_SKIP_MPI_CHECK=1
export HWLOC_HIDE_ERRORS=1

CASE=/home/hyoklee/MiV-Simulator-Cases/4-opsin
cd "$CASE"
# Avoid NEURON auto-loading a stale nrnivmodl x86_64/ build (would double-register
# mechanisms vs run-network's own compile_and_load).
rm -rf x86_64
RESULTS="results/${TAG}_${SLURM_JOB_ID}"
mkdir -p "$RESULTS"

NTASKS=${SLURM_NTASKS:-1}
echo "=== case4 run: nodes=${SLURM_JOB_NUM_NODES} ntasks=${NTASKS} IOWARP=${IOWARP} TSTOP=${TSTOP} TAG=${TAG} ==="
echo "host=$(hostname) start=$(date +%s.%N)"
# Capture the wall-clock start BEFORE any LD_PRELOAD is set: under the adapter,
# command substitutions like $(date) can be contaminated by runtime init output.
T0=$(date +%s.%N)

# --- IOWarp core (CTE) setup --------------------------------------------------
# The POSIX adapter (LD_PRELOAD) intercepts file I/O and routes it to the
# chimaera runtime's storage tier. The runtime (clio_run) and adapter link the
# iowarp-build conda env; the app links the miv env. Both envs share an
# identical libstdc++, and the adapter does not link HDF5/MPI, so placing miv
# first on LD_LIBRARY_PATH keeps the app on its own HDF5/MPI while the adapter
# still resolves its core+iowarp deps.
: "${CORE_INSTALL:=/home/hyoklee/core/install}"
IOW_ENV=/home/hyoklee/mc3/envs/iowarp-build
CORE="$CORE_INSTALL/lib/libclio_cte_posix.so"
[ -f "$CORE" ] || CORE=$(find /home/hyoklee/core/build -name 'libclio_cte_posix.so' 2>/dev/null | head -1)
NNODES=${SLURM_JOB_NUM_NODES:-1}
# CHIMA_CONF knob lets a caller swap the runtime config (e.g. a node-local NVMe
# tier instead of the default RAM tier).
: "${CHIMA_CONF:=/home/hyoklee/bin/chimaera_case4.yaml}"
export CLIO_SERVER_CONF="$CHIMA_CONF"
# NVME_DIR (optional): parent dir for a file-backed CTE tier on node-local NVMe.
# The file bdev opens its tier path with O_CREAT, so the parent must exist; we
# create it before the runtime starts and remove it after so each run starts
# from a cold tier (single-node only).
: "${NVME_DIR:=}"

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
    # Distributed: write hostfile + a config that references it, then launch one
    # daemon per node as a SLURM step (--overlap so it shares cores with mpirun).
    scontrol show hostnames "$SLURM_JOB_NODELIST" > "$RESULTS/hostfile"
    CHIMA_CONF="$RESULTS/chimaera_job.yaml"
    sed "s#^networking:#networking:\n  hostfile: \"$RESULTS/hostfile\"#" \
        /home/hyoklee/bin/chimaera_case4.yaml > "$CHIMA_CONF"
    export CLIO_SERVER_CONF="$CHIMA_CONF"
    echo "IOWarp: starting $NNODES-node distributed runtime (hostfile=$RESULTS/hostfile)"
    ( export PATH="$CORE_INSTALL/bin:$IOW_ENV/bin:$PATH"
      export LD_LIBRARY_PATH="$CORE_INSTALL/lib:$IOW_ENV/lib"
      export CLIO_SERVER_CONF="$CHIMA_CONF"
      srun --nodes="$NNODES" --ntasks="$NNODES" --ntasks-per-node=1 --overlap \
        clio_run start ) > "$RESULTS/clio_runtime.log" 2>&1 &
    CLIO_BG=$!
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
  local STOP="clio_run stop"
  [ "$NNODES" -gt 1 ] && STOP="srun --nodes=$NNODES --ntasks=$NNODES --ntasks-per-node=1 --overlap clio_run stop"
  ( export PATH="$CORE_INSTALL/bin:$IOW_ENV/bin:$PATH"
    export LD_LIBRARY_PATH="$CORE_INSTALL/lib:$IOW_ENV/lib"
    export CLIO_SERVER_CONF="$CHIMA_CONF"
    $STOP ) >> "$RESULTS/clio_runtime.log" 2>&1 || true
  # Record NVMe tier usage before cleanup, then remove it for a cold next run.
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

# OpenMPI 5 + SLURM: use mpirun inside the allocation (srun lacks PMIx here).
# mpirun reads the SLURM node list automatically; -x propagates env to all ranks.
set +e
mpirun -np "$NTASKS" \
  -x PATH -x LD_LIBRARY_PATH -x LD_PRELOAD -x CLIO_SERVER_CONF \
  -x MIV_SKIP_MPI_CHECK -x HWLOC_HIDE_ERRORS \
  run-network \
    --config-file=Microcircuit_Small.yaml --config-prefix=config \
    --arena-id=A --stimulus-id=Diag --template-paths=templates \
    --dataset-prefix=./datasets --results-path=$RESULTS \
    --io-size=1 --tstop=$TSTOP --v-init=-75 --dt 0.025 \
    --results-write-time=60 --stimulus-onset=0.0 --verbose
RC=$?
unset LD_PRELOAD
T1=$(date +%s.%N)
stop_runtime
echo "=== run-network exit=$RC walltime=$(echo "$T1 - $T0" | bc) s ==="
echo "end=$(date +%s.%N)"
exit $RC
