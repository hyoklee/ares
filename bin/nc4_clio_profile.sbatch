#!/bin/bash
# Profile ONE operation of tst_chunks3 in isolation, on a running process.
# Used for both walls documented in 20260814_claude_netcdf_test_results.md:
#   WAIT_TIMINGS=2  -> `compressed write 1xNxN`, the chunk-cache thrash
#                      (~3900 s of CPU at 512^3/128^3 on stock HDF5)
#   WAIT_TIMINGS=6  -> `contiguous write NxNx1`, the unchunked strided write
#                      (~200x on the CLIO VFD)
#
# The run is not profiled end to end -- that would take an hour and spend almost
# all of it in the one operation anyway. Instead the workload is started, the
# script waits until it has printed WAIT_TIMINGS timings (so the next one, the
# one under investigation, is what is executing), and only then samples. That
# keeps the job to a few minutes and guarantees every sample lands in the right
# operation.
#
# Four views, because no single one answers "which calls":
#   gdb           real backtraces -- what the call chain actually is
#   strace -c     syscall counts: distinguishes CPU-bound from call-rate-bound
#   strace raw    the SIZE of each pread/pwrite, which is how the sieve buffer
#                 (64 KB blocks) is told apart from element-at-a-time I/O (4 B)
#   perf record   CPU attribution with call chains. Note perf on these nodes is
#                 built against a different kernel than the one running and has
#                 produced nothing; gdb sampling carried the results.
#
# Usage:
#   VARIANT=baseline|clio_vol|clio_vfd [WAIT_TIMINGS=N] [BENCH_ARGS="..."] \
#     sbatch --export=ALL nc4_clio_profile.sbatch
#SBATCH --job-name=nc4prof
#SBATCH --partition=debug
#SBATCH --nodes=1
#SBATCH --exclusive
#SBATCH --time=00:40:00
#SBATCH --output=/home/hyoklee/logs/nc4_clio_profile_%j.log
set -uo pipefail

WORK=${WORK:-/mnt/common/hyoklee/nc4-clio-work}
ARES_BIN=/home/hyoklee/src/hyoklee/ares/bin
MC3=/home/hyoklee/mc3
: "${VARIANT:=baseline}"
: "${BENCH_ARGS:=6 512 128 512 128 512 128}"
: "${SAMPLE_SECS:=120}"
: "${STRACE_SECS:=60}"
# How many timings to let pass before sampling: sampling starts inside timing
# WAIT_TIMINGS+1. 2 lands in `compressed write 1xNxN` (the chunk-cache thrash);
# 6 lands in `contiguous write NxNx1`, the unchunked strided write.
: "${WAIT_TIMINGS:=2}"

JOB=${SLURM_JOB_ID:-local}
RESULTS="$WORK/results/prof_${VARIANT}_${JOB}"
CLIO_BIN="$WORK/clio-build/bin"
NVME=/mnt/nvme/hyoklee/nc4_prof
mkdir -p "$RESULTS"
rm -rf "$NVME"; mkdir -p "$NVME"

export PATH="$WORK/toolbin:$PATH"
export LD_LIBRARY_PATH="$WORK/hdf5-install/lib:$WORK/netcdf-install/lib:$CLIO_BIN:$MC3/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
TST=$(find "$WORK/netcdf-build" -name tst_chunks3 -type f | head -1)

echo "=== profile: variant=$VARIANT host=$(hostname) job=$JOB $(date -Is) ==="
echo "args: $BENCH_ARGS"

CLIO_PID=""
if [ "$VARIANT" = clio_vol ] || [ "$VARIANT" = clio_vfd ]; then
  find /dev/shm -maxdepth 1 \( -name 'chimaera*' -o -name 'clio*' \) -delete 2>/dev/null
  cp "$ARES_BIN/nc4_clio_runtime_ram.yaml" "$RESULTS/clio_runtime.yaml"
  export CLIO_SERVER_CONF="$RESULTS/clio_runtime.yaml"
  "$CLIO_BIN/clio_run" start >"$RESULTS/clio_run.log" 2>&1 &
  CLIO_PID=$!
  for _ in $(seq 1 90); do
    grep -qa "pools created successfully" "$RESULTS/clio_run.log" && break
    sleep 1
  done
  echo "clio runtime ready"
  export HDF5_PLUGIN_PATH="$CLIO_BIN"
  if [ "$VARIANT" = clio_vol ]; then
    export HDF5_VOL_CONNECTOR="clio"
  else
    export HDF5_DRIVER="clio_vfd" HDF5_DRIVER_CONFIG="cache=1"
  fi
fi

OUT="$RESULTS/trace.txt"
cd "$NVME"
stdbuf -oL "$TST" $BENCH_ARGS >"$OUT" 2>&1 &
PID=$!
echo "workload pid=$PID"

# Wait for WAIT_TIMINGS timing lines; the next operation is the one sampled.

count_timings() {
  grep -cE '^[[:space:]]*(contiguous|chunked|compressed)[[:space:]]+(write|read)' "$OUT" 2>/dev/null || echo 0
}
for i in $(seq 1 600); do
  n=$(count_timings)
  [ "${n:-0}" -ge "$WAIT_TIMINGS" ] && break
  kill -0 "$PID" 2>/dev/null || { echo "workload exited early"; break; }
  sleep 1
done
echo "--- entering operation 3 after ${i}s; timings so far:"
cat "$OUT"

# ---- gdb backtraces (cheap, exact) ----
echo ""
echo "=== gdb backtraces ==="
# No `head` here: under the CLIO VOL the process has 13 threads and the main
# one -- the only thread doing the work -- is not the first listed, so any
# truncation drops exactly the stack this job exists to capture.
for k in 1 2 3 4 5 6 7 8 9 10; do
  echo "--- sample $k"
  gdb -p "$PID" -batch -ex "thread apply all bt 30" 2>/dev/null \
    | grep -vE "^\[|^warning|^Reading|^\(gdb\)|^$"
  sleep 3
done > "$RESULTS/gdb_backtraces.txt" 2>&1
grep -c "^#" "$RESULTS/gdb_backtraces.txt" | sed 's/^/frames captured: /'

# ---- strace syscall profile ----
echo ""
echo "=== strace -c (${STRACE_SECS}s) ==="
timeout "$STRACE_SECS" strace -c -f -p "$PID" 2>"$RESULTS/strace.txt"
tail -25 "$RESULTS/strace.txt"

# ---- raw I/O sizes ----
# strace -c gives counts, not sizes, and the size is the question when data
# sieving is supposed to be coalescing a strided selection: 4-byte calls mean
# no coalescing, ~64 KB calls mean the sieve buffer is doing its job.
echo ""
echo "=== raw pwrite/pread sizes (5s) ==="
timeout 5 strace -f -e trace=pwrite64,pread64 -p "$PID" 2>"$RESULTS/strace_raw.txt"
grep -oE "(pwrite64|pread64)\([0-9]+, [^,]*, [0-9]+" "$RESULTS/strace_raw.txt" \
  | awk '{print $1, $NF}' | sed 's/(.*,//' | sort | uniq -c | sort -rn | head -8

# ---- perf ----
echo ""
echo "=== perf record (${SAMPLE_SECS}s) ==="
perf record -F 99 --call-graph dwarf,16384 -o "$NVME/perf.data" -p "$PID" \
  -- sleep "$SAMPLE_SECS" 2>&1 | tail -3

kill -9 "$PID" 2>/dev/null
[ -n "$CLIO_PID" ] && { "$CLIO_BIN/clio_run" stop >/dev/null 2>&1; pkill -f "^$CLIO_BIN/clio_run"; }

echo ""
echo "=== flat profile (self time) ==="
perf report -i "$NVME/perf.data" --no-children --percent-limit 0.5 --stdio 2>/dev/null \
  | grep -vE "^#|^$" | head -25 | tee "$RESULTS/perf_flat.txt"

echo ""
echo "=== call graph (cumulative) ==="
perf report -i "$NVME/perf.data" --children --percent-limit 2 --stdio 2>/dev/null \
  | grep -vE "^#|^$" | head -60 | tee "$RESULTS/perf_children.txt"

cp "$NVME/perf.data" "$RESULTS/" 2>/dev/null
rm -rf "$NVME"
echo "results: $RESULTS"
echo "NC4_CLIO_PROFILE_DONE"
