#!/bin/bash
# SLURM run script for MiV-Simulator case 7 (optimization / optimize-network) on ares.
# Usage:
#   sbatch --nodes=1 --ntasks=T --job-name=... \
#          --export=ALL,IOWARP=0,TAG=base run_case7.sbatch
# Env knobs:
#   IOWARP=0|1    0 = native HDF5 (baseline); 1 = LD_PRELOAD IOWarp CTE posix adapter
#   TAG           label used in result/log paths
#   CORE_INSTALL  which IOWarp build (default ~/core; ~/core.iowarp/install for upstream)
#   CHIMA_CONF    runtime config (default RAM tier; *_nvme.yaml for node-local NVMe tier)
#   NVME_DIR      parent dir for a file-backed NVMe tier (created/cleaned per run)
#   OPTCONF       optimize config (default optimize_network_ares.yaml)
#   NPW           --nprocs-per-worker (default 4); workers = (NTASKS-1)/NPW
#   NINIT         --n-initial   (default 8)   initial sampling evaluations
#   POP           --population-size (default 8)
#   NGEN          --num-generations (default 1)
#
# Case 7 runs dmosopt weight optimization (optimize-network) with PR (Bilash)
# neurons via distwq workers, standard NEURON (use_coreneuron: False). This is a
# repeated-evaluation, repeated-read workload — the regime where the IOWarp CTE
# tier could plausibly help, unlike the read-once run-network cases 4/6.
#SBATCH --partition=compute
#SBATCH --exclusive
#SBATCH --time=02:00:00
#SBATCH --output=/home/hyoklee/logs/case7_%x_%j.log
# --exclusive: one job per node so each run is isolated with a cold page cache.

set -e
: "${IOWARP:=0}"
: "${TAG:=run}"
: "${OPTCONF:=optimize_network_ares.yaml}"
: "${NPW:=4}"
: "${NINIT:=8}"
: "${POP:=8}"
: "${NGEN:=1}"
# Surrogate model for the optimization phase. The dmosopt default "megp" needs
# GPyTorch (not installed in the miv env); "gpr" uses scikit-learn and completes
# cleanly. The I/O comparison only depends on the deterministic initial-sampling
# phase (n_initial*dim network evaluations), which runs identically regardless.
: "${SURR:=gpr}"

. "/home/hyoklee/mc3/etc/profile.d/conda.sh"
conda activate /home/hyoklee/mc3/envs/miv
export LD_LIBRARY_PATH=$CONDA_PREFIX/lib:$LD_LIBRARY_PATH
export PATH=/home/hyoklee/neuroh5/build/bin:$PATH
export MIV_SKIP_MPI_CHECK=1
export HWLOC_HIDE_ERRORS=1

CASE=/home/hyoklee/MiV-Simulator-Cases/7-optimization
cd "$CASE"
# Python cell templates (templates.PRN_neuron etc.) are imported as a package
# relative to the case dir.
export PYTHONPATH="$CASE:$PYTHONPATH"
# Avoid NEURON auto-loading a stale nrnivmodl x86_64/ build.
rm -rf x86_64
RESULTS="results/${TAG}_${SLURM_JOB_ID}"
mkdir -p "$RESULTS"

# Pre-compile mechanisms ONCE (serial) before the parallel run. optimize-network
# gives each distwq worker its own sub-communicator, so multiple worker-leader
# rank-0s would otherwise race on os.makedirs of the shared mechanisms/compiled/
# <hash> dir (compile_and_load has no exist_ok guard) and MPI_ABORT. This is
# idempotent: it reuses the hashed dir if already built. Runs before any
# LD_PRELOAD so it is not part of the measured I/O workload.
echo "Pre-compiling mechanisms (serial)..."
if python -c "from miv_simulator.mechanisms import compile_and_load; compile_and_load(directory='mechanisms')" > "$RESULTS/precompile.log" 2>&1; then
  echo "  mechanisms ready"
else
  echo "  pre-compile FAILED"; tail -8 "$RESULTS/precompile.log"
fi

NTASKS=${SLURM_NTASKS:-1}
echo "=== case7 run: nodes=${SLURM_JOB_NUM_NODES} ntasks=${NTASKS} IOWARP=${IOWARP} OPTCONF=${OPTCONF} NPW=${NPW} NINIT=${NINIT} POP=${POP} NGEN=${NGEN} TAG=${TAG} ==="
echo "host=$(hostname) start=$(date +%s.%N)"
T0=$(date +%s.%N)

# --- IOWarp core (CTE) setup --------------------------------------------------
: "${CORE_INSTALL:=/home/hyoklee/core/install}"
IOW_ENV=/home/hyoklee/mc3/envs/iowarp-build
CORE="$CORE_INSTALL/lib/libclio_cte_posix.so"
[ -f "$CORE" ] || CORE=$(find /home/hyoklee/core/build -name 'libclio_cte_posix.so' 2>/dev/null | head -1)
NNODES=${SLURM_JOB_NUM_NODES:-1}
: "${CHIMA_CONF:=/home/hyoklee/bin/chimaera_case7.yaml}"
export CLIO_SERVER_CONF="$CHIMA_CONF"
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
    scontrol show hostnames "$SLURM_JOB_NODELIST" > "$RESULTS/hostfile"
    CHIMA_CONF="$RESULTS/chimaera_job.yaml"
    sed "s#^networking:#networking:\n  hostfile: \"$RESULTS/hostfile\"#" \
        /home/hyoklee/bin/chimaera_case7.yaml > "$CHIMA_CONF"
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

# distwq runs in collective ("gather") mode under a static mpirun allocation:
# rank 0 is the controller, the remaining ranks form workers of NPW ranks each.
set +e
mpirun -np "$NTASKS" \
  -x PATH -x LD_LIBRARY_PATH -x LD_PRELOAD -x CLIO_SERVER_CONF -x PYTHONPATH \
  -x MIV_SKIP_MPI_CHECK -x HWLOC_HIDE_ERRORS \
  optimize-network \
    --config-path="./config/${OPTCONF}" \
    --optimize-file-dir="$RESULTS" \
    --nprocs-per-worker="$NPW" \
    --n-initial="$NINIT" \
    --population-size="$POP" \
    --num-generations="$NGEN" \
    --surrogate-method="$SURR" \
    --verbose
RC=$?
unset LD_PRELOAD
T1=$(date +%s.%N)
stop_runtime
echo "=== optimize-network exit=$RC walltime=$(echo "$T1 - $T0" | bc) s ==="
echo "end=$(date +%s.%N)"
exit $RC
