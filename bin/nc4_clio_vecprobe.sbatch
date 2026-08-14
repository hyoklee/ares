#!/bin/bash
# How many elements does HDF5 hand the CLIO VFD per vector call, and how big are
# they? That decides whether coalescing can live inside
# H5FD__clio_write_vector (many elements per call -> merge within the call) or
# needs a stateful sieve buffer in the driver (one element per call).
#
# Breaks on the vector entry points and prints `count`, plus the first few
# (addr, size) pairs, on a live run of the operation under investigation.
#SBATCH --job-name=nc4vec
#SBATCH --partition=debug
#SBATCH --nodes=1
#SBATCH --exclusive
#SBATCH --time=00:30:00
#SBATCH --output=/home/hyoklee/logs/nc4_clio_vecprobe_%j.log
set -uo pipefail

WORK=${WORK:-/mnt/common/hyoklee/nc4-clio-work}
ARES_BIN=/home/hyoklee/src/hyoklee/ares/bin
MC3=/home/hyoklee/mc3
: "${BENCH_ARGS:=6 256 64 256 64 256 64}"
: "${WAIT_TIMINGS:=6}"

JOB=${SLURM_JOB_ID:-local}
RESULTS="$WORK/results/vecprobe_${JOB}"
CLIO_BIN="$WORK/clio-build/bin"
NVME=/mnt/nvme/hyoklee/nc4_vec
mkdir -p "$RESULTS"; rm -rf "$NVME"; mkdir -p "$NVME"

export PATH="$WORK/toolbin:$PATH"
export LD_LIBRARY_PATH="$WORK/hdf5-install/lib:$WORK/netcdf-install/lib:$CLIO_BIN:$MC3/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
TST=$(find "$WORK/netcdf-build" -name tst_chunks3 -type f | head -1)

find /dev/shm -maxdepth 1 \( -name 'chimaera*' -o -name 'clio*' \) -delete 2>/dev/null
cp "$ARES_BIN/nc4_clio_runtime_ram.yaml" "$RESULTS/clio_runtime.yaml"
export CLIO_SERVER_CONF="$RESULTS/clio_runtime.yaml"
"$CLIO_BIN/clio_run" start >"$RESULTS/clio_run.log" 2>&1 &
for _ in $(seq 1 90); do grep -qa "pools created successfully" "$RESULTS/clio_run.log" && break; sleep 1; done
echo "runtime ready"
export HDF5_PLUGIN_PATH="$CLIO_BIN" HDF5_DRIVER="clio_vfd" HDF5_DRIVER_CONFIG="cache=1"

OUT="$RESULTS/trace.txt"
cd "$NVME"
stdbuf -oL "$TST" $BENCH_ARGS >"$OUT" 2>&1 &
PID=$!
count_timings() { grep -cE '^[[:space:]]*(contiguous|chunked|compressed)[[:space:]]+(write|read)' "$OUT" 2>/dev/null || echo 0; }
for i in $(seq 1 600); do
  [ "$(count_timings)" -ge "$WAIT_TIMINGS" ] && break
  kill -0 "$PID" 2>/dev/null || break
  sleep 1
done
echo "--- sampling inside operation $((WAIT_TIMINGS + 1)) after ${i}s"
cat "$OUT"

# `count` is the vector length. Also dump the scalar entry point's hit rate:
# if HDF5 is calling the SCALAR write (not the vector one), coalescing has to
# happen elsewhere entirely.
# The Release build has no DWARF, so `print count` cannot work. Read the
# arguments from the SysV x86-64 registers at function entry instead:
#   H5FD__clio_write_vector(file=rdi, dxpl=rsi, count=edx, types=rcx,
#                           addrs=r8, sizes=r9, bufs=[stack])
# gdb sets the breakpoint at the entry address (no prologue skip without
# symbols), so the registers still hold the incoming arguments.
{
  echo "set pagination off"; echo "set confirm off"
  echo "break H5FD__clio_write_vector"
  for k in 1 2 3 4 5; do
    echo "continue"
    echo "printf \"VEC count=%d\\n\", \$edx"
    echo "printf \"  addrs[0..2]:\\n\""; echo "x/3gx \$r8"
    echo "printf \"  sizes[0..2]:\\n\""; echo "x/3gx \$r9"
  done
} > "$RESULTS/gdb_cmds.txt"
gdb -p "$PID" -batch -x "$RESULTS/gdb_cmds.txt" > "$RESULTS/gdb_vec.txt" 2>&1

echo "=== vector-call probe ==="
grep -E "^\\\$|Breakpoint [0-9]+ .*(write|vector)|already hit" "$RESULTS/gdb_vec.txt" | head -40

kill -9 "$PID" 2>/dev/null
"$CLIO_BIN/clio_run" stop >/dev/null 2>&1; pkill -f "^$CLIO_BIN/clio_run"
rm -rf "$NVME"
echo "results: $RESULTS"
echo "NC4_VECPROBE_DONE"
