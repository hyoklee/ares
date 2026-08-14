#!/bin/bash
# Run tst_chunks3 against a MULTI-NODE clio-core cluster.
#
# Answers 20260814_claude_netcdf_test.md: can a 4-node clio-core cluster pass
# the 512^3 / chunk 128^3 case that no single-node variant completed in 90
# minutes (20260813_claude_netcdf_test_results.md, "Where it stops")?
#
# Usage:
#   NODES=4 TAG=c256 BENCH_ARGS="6 256 64 256 64 256 64" RUN_TIMEOUT=30m \
#     VARIANTS="clio_vol,clio_vfd" sbatch --export=ALL --nodes=4 \
#     /home/hyoklee/src/hyoklee/ares/bin/nc4_clio_run4.sbatch
#
# Why this does not use hpf's nc4_clio_bench.sh like nc4_clio_run.sbatch does:
# that driver starts the runtime with a bare `"$CLIO_BIN/clio_run" start`, which
# is a single local daemon by construction. A cluster needs one daemon per node
# (`srun --ntasks-per-node=1`), a shared hostfile, readiness counted across all
# of them, and a distributed stop/sweep. The rest of the driver's behaviour that
# matters is reproduced below deliberately, and the output files keep the same
# names and format so parse_nc4_clio_results.py and nc4_clio_table.py read them
# unchanged:
#
#   * per-variant timeout(1), result discarded if it did not produce 18 timings
#   * the exit-hang watchdog: the CLIO VOL measures everything and then wedges in
#     HDF5's atexit teardown, so a variant that has printed all 18 timings and
#     not exited EXIT_GRACE seconds later is killed and its result KEPT
#   * variant_status.tsv, same vocabulary
#
# One deliberate addition: `stdbuf -oL`. tst_chunks3's stdout is a pipe here, so
# glibc block-buffers it and nothing appears until the process exits -- which is
# why the 90-minute single-node runs on 2026-08-13 produced empty result files
# and could not say how FAR they got. Line buffering turns those runs into a
# progress trace, which is the whole question being asked here.
#SBATCH --job-name=nc4run4
#SBATCH --partition=debug
#SBATCH --exclusive
#SBATCH --time=08:00:00
#SBATCH --output=/home/hyoklee/logs/nc4_clio_run4_%j.log
set -uo pipefail

WORK=${WORK:-/mnt/common/hyoklee/nc4-clio-work}
HPF=/home/hyoklee/src/hyoklee/hpf
ARES_BIN=/home/hyoklee/src/hyoklee/ares/bin
MC3=/home/hyoklee/mc3
: "${TAG:=cluster}"
: "${BENCH_ARGS:=6 256 64 256 64 256 64}"
: "${VARIANTS:=clio_vol,clio_vfd}"
: "${RUN_TIMEOUT:=30m}"
: "${EXIT_GRACE:=30}"
EXPECTED_TIMINGS=18

JOB=${SLURM_JOB_ID:-local}
NNODES=${SLURM_JOB_NUM_NODES:-1}
RESULTS="$WORK/results/${TAG}_${JOB}"
JW="$WORK/jobs/${TAG}_${JOB}"
NVME_ROOT=/mnt/nvme/hyoklee/nc4_clio
mkdir -p "$RESULTS" "$JW"

CLIO_BIN="$WORK/clio-build/bin"
export PATH="$WORK/toolbin:$PATH"
export LD_LIBRARY_PATH="$WORK/hdf5-install/lib:$WORK/netcdf-install/lib:$CLIO_BIN:$MC3/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

TST=$(find "$WORK/netcdf-build" -name tst_chunks3 -type f | head -1)
[ -x "$TST" ] || { echo "tst_chunks3 not found under $WORK/netcdf-build"; exit 1; }

echo "=== nc4 clio CLUSTER run: job=$JOB nodes=$NNODES $(date -Is) ==="
echo "nodelist: $SLURM_JOB_NODELIST"
echo "TAG=$TAG VARIANTS=$VARIANTS BENCH_ARGS=$BENCH_ARGS RUN_TIMEOUT=$RUN_TIMEOUT"

# --- cluster config ----------------------------------------------------------
HOSTFILE="$RESULTS/hostfile"
scontrol show hostnames "$SLURM_JOB_NODELIST" > "$HOSTFILE"
echo "hostfile:"; cat "$HOSTFILE"

CLIO_CONF="$RESULTS/clio_runtime.yaml"
# Inject the hostfile under networking:, and match `neighborhood` to the real
# node count so CTE may place buffers on every node in the job.
sed -e "s#^networking:#networking:\n  hostfile: \"$HOSTFILE\"#" \
    -e "s#neighborhood: 4#neighborhood: $NNODES#" \
    "$ARES_BIN/nc4_clio_runtime_cluster.yaml" > "$CLIO_CONF"
export CLIO_SERVER_CONF="$CLIO_CONF"

CLIO_RUN_LOG="$RESULTS/clio_run.log"
STATUS_FILE="$RESULTS/variant_status.tsv"
: >"$STATUS_FILE"
set_status() { printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}" >>"$STATUS_FILE"; }

# --- node-local scratch on every node ----------------------------------------
srun --nodes="$NNODES" --ntasks="$NNODES" --ntasks-per-node=1 --overlap bash -c '
  rm -rf /mnt/nvme/hyoklee/nc4_clio
  mkdir -p /mnt/nvme/hyoklee/nc4_clio/run
  find /dev/shm -maxdepth 1 \( -name "chimaera*" -o -name "clio*" \) -delete 2>/dev/null
  exit 0' >/dev/null 2>&1
rm -rf "$JW/run"; ln -s "$NVME_ROOT/run" "$JW/run"

CLUSTER_UP=0
cluster_stop() {
  [ "$CLUSTER_UP" = 1 ] || return 0
  echo "--- stopping cluster"
  srun --nodes="$NNODES" --ntasks="$NNODES" --ntasks-per-node=1 --overlap \
       "$CLIO_BIN/clio_run" stop >>"$CLIO_RUN_LOG" 2>&1
  sleep 3
  srun --nodes="$NNODES" --ntasks="$NNODES" --ntasks-per-node=1 --overlap bash -c "
    pkill -f '^$CLIO_BIN/clio_run' >/dev/null 2>&1
    sleep 2
    pkill -9 -f '^$CLIO_BIN/clio_run' >/dev/null 2>&1
    find /dev/shm -maxdepth 1 \( -name 'chimaera*' -o -name 'clio*' \) -delete 2>/dev/null
    exit 0" >/dev/null 2>&1
  CLUSTER_UP=0
}
trap cluster_stop EXIT

cluster_start() {
  cluster_stop
  : >"$CLIO_RUN_LOG"
  CLUSTER_UP=1
  srun --nodes="$NNODES" --ntasks="$NNODES" --ntasks-per-node=1 --overlap \
       --export=ALL "$CLIO_BIN/clio_run" start >>"$CLIO_RUN_LOG" 2>&1 &
  CLIO_SRUN=$!
  # Readiness is counted, not matched once: with one log for N daemons, the
  # first "pools created successfully" means one node is up, not the cluster.
  local i n
  for i in $(seq 1 180); do
    n=$(grep -ac "pools created successfully" "$CLIO_RUN_LOG" 2>/dev/null)
    n=${n:-0}
    if [ "$n" -ge "$NNODES" ]; then
      sleep 3
      echo "clio cluster ready ($n/$NNODES nodes reported pools)"
      return 0
    fi
    if grep -qa "Could not start TCP server" "$CLIO_RUN_LOG" 2>/dev/null; then
      echo "ERROR: a daemon could not bind its port"; tail -30 "$CLIO_RUN_LOG"; return 1
    fi
    kill -0 "$CLIO_SRUN" 2>/dev/null || { echo "ERROR: srun exited early"; tail -30 "$CLIO_RUN_LOG"; return 1; }
    sleep 1
  done
  echo "ERROR: cluster not ready in 180s ($n/$NNODES)"; tail -40 "$CLIO_RUN_LOG"; return 1
}

timing_count() {
  grep -cE '^[[:space:]]*(contiguous|chunked|compressed)[[:space:]]+(write|read)[[:space:]].*[[:space:]]sec' \
       "$1" 2>/dev/null || true
}

run_variant() {
  local variant="$1" header="$2"
  local out="$RESULTS/tst_chunks3_${variant}.txt"
  local dir="$NVME_ROOT/run/$variant"
  local rc=0 watchdog

  rm -rf "$dir"; mkdir -p "$dir"
  echo ""
  echo "=== variant $variant ($(date +%H:%M:%S)) ==="
  { echo "=== $header ==="
    echo "Variant: $variant"
    echo "Nodes: $NNODES"
    echo "Testing with deflate level: ${BENCH_ARGS%% *}"
    echo "tst_chunks3 args: $BENCH_ARGS"; } >"$out"

  # Exit-hang watchdog (see header comment).
  ( for _ in $(seq 1 60); do pgrep -f "^$TST" >/dev/null 2>&1 && break; sleep 1; done
    while pgrep -f "^$TST" >/dev/null 2>&1; do
      if [ "$(timing_count "$out")" -ge "$EXPECTED_TIMINGS" ]; then
        sleep "$EXIT_GRACE"
        if pgrep -f "^$TST" >/dev/null 2>&1; then
          echo "[warn] all $EXPECTED_TIMINGS timings measured; process still alive after ${EXIT_GRACE}s -- killing"
          pkill -f "^$TST"; sleep 5; pkill -9 -f "^$TST" 2>/dev/null
        fi
        exit 0
      fi
      sleep 5
    done ) &
  watchdog=$!

  ( cd "$dir" && timeout "$RUN_TIMEOUT" stdbuf -oL "$TST" $BENCH_ARGS ) 2>&1 \
    | sed -u "s/\x1b\[[0-9;]*m//g" | tee -a "$out" || rc=$?

  kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null

  local n; n=$(timing_count "$out")
  if [ "$rc" = 0 ]; then
    echo "variant $variant: ok ($n/$EXPECTED_TIMINGS timings)"
    set_status "$variant" measured "$n timings"
  elif [ "${n:-0}" -ge "$EXPECTED_TIMINGS" ]; then
    echo "variant $variant: ok (measured; unclean exit $rc)"
    set_status "$variant" measured_no_exit "all $EXPECTED_TIMINGS timings; exit $rc"
  else
    echo "variant $variant: FAILED (exit $rc) after $n/$EXPECTED_TIMINGS timings"
    # Unlike the single-node driver the partial file is KEPT: with stdbuf the
    # timings printed before the cap are real measurements and they are the
    # answer to "how far did it get in 90 minutes".
    set_status "$variant" no_result "exit $rc after $n/$EXPECTED_TIMINGS timings (partial output kept)"
  fi
}

# --- run ---------------------------------------------------------------------
T0=$(date +%s)
for variant in $(echo "$VARIANTS" | tr ',' ' '); do
  case "$variant" in
    baseline)
      ( unset HDF5_DRIVER HDF5_DRIVER_CONFIG HDF5_VOL_CONNECTOR HDF5_PLUGIN_PATH
        run_variant baseline "NetCDF-4 with HDF5 develop (baseline, no clio)" )
      ;;
    clio_vfd)
      if cluster_start; then
        ( unset HDF5_VOL_CONNECTOR
          export HDF5_PLUGIN_PATH="$CLIO_BIN"
          export HDF5_DRIVER="clio_vfd" HDF5_DRIVER_CONFIG="cache=1"
          run_variant clio_vfd "NetCDF-4 / HDF5 develop + clio-core VFD, $NNODES-node cluster" )
      else
        set_status clio_vfd no_result "cluster did not start"
      fi
      cluster_stop ;;
    clio_vol)
      if cluster_start; then
        ( unset HDF5_DRIVER HDF5_DRIVER_CONFIG
          export HDF5_PLUGIN_PATH="$CLIO_BIN"
          export HDF5_VOL_CONNECTOR="clio"
          run_variant clio_vol "NetCDF-4 / HDF5 develop + clio-core VOL, $NNODES-node cluster" )
      else
        set_status clio_vol no_result "cluster did not start"
      fi
      cluster_stop ;;
  esac
done
T1=$(date +%s)
echo ""
echo "=== all variants done, wall=$((T1 - T0))s ==="
cat "$STATUS_FILE"

for v in baseline clio_vfd clio_vol; do
  [ -f "$RESULTS/tst_chunks3_${v}.txt" ] || continue
  python3 "$HPF/.github/scripts/parse_nc4_clio_results.py" \
    "$RESULTS/tst_chunks3_${v}.txt" "$RESULTS/nc4_${v}.json" "$v" \
    "ares ${NNODES}-node cluster" >/dev/null
done
echo "results: $RESULTS"
echo "NC4_CLIO_RUN4_DONE"
