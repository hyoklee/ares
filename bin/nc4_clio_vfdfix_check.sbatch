#!/bin/bash
# Validate the VFD vector-coalescing fix (iowarp/clio-core#980).
#
# Correctness first: this changes the data path, turning N element writes into
# one read-modify-write of their spanning region. `tst_chunks3` reads its data
# back but never compares it, so it cannot catch a corrupted write -- h5diff
# against a sec2-written file is the actual gate here.
#
#   1. write the same file three ways at 64^3 -- sec2, the ORIGINAL clio_vfd,
#      and the FIXED clio_vfd -- and h5diff each CLIO file against the sec2 one
#   2. only then measure: the full 18 timings at 256^3 with the fixed driver,
#      where the original spends ~1200 s on `contiguous write 256x256x1`
#
# The two plugins live in their own directories (vfd-orig/, vfd-fix/) so
# HDF5_PLUGIN_PATH selects between them; their shared-library dependencies are
# still resolved from clio-build/bin via LD_LIBRARY_PATH.
#SBATCH --job-name=nc4vfdfix
#SBATCH --partition=debug
#SBATCH --nodes=1
#SBATCH --exclusive
#SBATCH --time=01:30:00
#SBATCH --output=/home/hyoklee/logs/nc4_clio_vfdfix_%j.log
set -uo pipefail

WORK=${WORK:-/mnt/common/hyoklee/nc4-clio-work}
ARES_BIN=/home/hyoklee/src/hyoklee/ares/bin
MC3=/home/hyoklee/mc3
: "${SMALL_ARGS:=6 64 16 64 16 64 16}"
: "${PERF_ARGS:=6 256 64 256 64 256 64}"
: "${RUN_TIMEOUT:=30m}"

JOB=${SLURM_JOB_ID:-local}
RESULTS="$WORK/results/vfdfix_${JOB}"
CLIO_BIN="$WORK/clio-build/bin"
NVME=/mnt/nvme/hyoklee/nc4_vfdfix
mkdir -p "$RESULTS"; rm -rf "$NVME"; mkdir -p "$NVME"

export PATH="$WORK/toolbin:$PATH"
export LD_LIBRARY_PATH="$WORK/hdf5-install/lib:$WORK/netcdf-install/lib:$CLIO_BIN:$MC3/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
TST=$(find "$WORK/netcdf-build" -name tst_chunks3 -type f | head -1)
H5DIFF="$WORK/hdf5-install/bin/h5diff"

start_runtime() {
  find /dev/shm -maxdepth 1 \( -name 'chimaera*' -o -name 'clio*' \) -delete 2>/dev/null
  cp "$ARES_BIN/nc4_clio_runtime_ram.yaml" "$RESULTS/clio_runtime.yaml"
  export CLIO_SERVER_CONF="$RESULTS/clio_runtime.yaml"
  "$CLIO_BIN/clio_run" start >>"$RESULTS/clio_run.log" 2>&1 &
  for _ in $(seq 1 90); do
    grep -qa "pools created successfully" "$RESULTS/clio_run.log" && { sleep 2; return 0; }
    sleep 1
  done
  echo "ERROR: runtime not ready"; return 1
}
stop_runtime() {
  "$CLIO_BIN/clio_run" stop >/dev/null 2>&1
  pkill -f "^$CLIO_BIN/clio_run" >/dev/null 2>&1
  sleep 2
  find /dev/shm -maxdepth 1 \( -name 'chimaera*' -o -name 'clio*' \) -delete 2>/dev/null
}
trap stop_runtime EXIT

# run_case <label> <plugin-dir|none> <args> <outdir>
run_case() {
  local label="$1" plugin="$2" args="$3" dir="$NVME/$4"
  rm -rf "$dir"; mkdir -p "$dir"
  ( cd "$dir"
    if [ "$plugin" = none ]; then
      unset HDF5_DRIVER HDF5_DRIVER_CONFIG HDF5_VOL_CONNECTOR HDF5_PLUGIN_PATH
    else
      export HDF5_PLUGIN_PATH="$plugin" HDF5_DRIVER=clio_vfd HDF5_DRIVER_CONFIG="cache=1"
    fi
    timeout "$RUN_TIMEOUT" stdbuf -oL "$TST" $args ) \
    2>&1 | sed -u "s/\x1b\[[0-9;]*m//g" > "$RESULTS/$label.txt"
  echo "--- $label: $(grep -cE '^[[:space:]]*(contiguous|chunked|compressed)' "$RESULTS/$label.txt")/18 timings"
}

echo "=== 1. correctness at ${SMALL_ARGS} ==="
run_case sec2_small none "$SMALL_ARGS" s_sec2
start_runtime || exit 1
run_case vfdorig_small "$WORK/vfd-orig" "$SMALL_ARGS" s_orig
run_case vfdfix_small  "$WORK/vfd-fix"  "$SMALL_ARGS" s_fix
stop_runtime

RC=0
for v in orig fix; do
  echo "--- h5diff sec2 vs vfd-$v"
  if "$H5DIFF" -v "$NVME/s_sec2/tst_chunks3.nc" "$NVME/s_$v/tst_chunks3.nc" \
       > "$RESULTS/h5diff_$v.txt" 2>&1; then
    echo "IDENTICAL"
  else
    echo "DIFFERENCES (see h5diff_$v.txt):"; tail -15 "$RESULTS/h5diff_$v.txt"; RC=1
  fi
done

echo ""
echo "=== 2. performance at ${PERF_ARGS} (fixed driver) ==="
start_runtime || exit 1
T0=$(date +%s)
run_case vfdfix_perf "$WORK/vfd-fix" "$PERF_ARGS" p_fix
T1=$(date +%s)
stop_runtime
echo "wall=$((T1 - T0))s"
grep -E "^[[:space:]]*(contiguous|chunked|compressed)[[:space:]]+(write|read)" \
  "$RESULTS/vfdfix_perf.txt" | tr -s ' '

echo ""
echo "reference (original driver, same args, job 23559): contiguous write 256 256 1 = 1200 s"
rm -rf "$NVME"
echo "results: $RESULTS"
echo "NC4_VFDFIX_DONE rc=$RC"
exit $RC
