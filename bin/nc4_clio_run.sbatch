#!/bin/bash
# Run the three NetCDF-4 variants (baseline / clio_vfd / clio_vol) on one ares
# compute node, against the trees built by nc4_clio_build.sbatch.
#
# Usage:
#   sbatch --export=ALL,TAG=ram_512,TIER=ram,BENCH_ARGS="6 512 64 512 64 512 64" \
#          /home/hyoklee/src/hyoklee/ares/bin/nc4_clio_run.sbatch
#
# Env knobs:
#   TAG          label for the results directory (default: run)
#   TIER         ram | nvme -- which CTE storage medium the clio runtime uses
#                (default: ram). Selects nc4_clio_runtime_<TIER>.yaml.
#   FILEDIR      nvme | shared -- where tst_chunks3 writes tst_chunks3.nc
#                (default: nvme, the node-local disk). "shared" puts it on
#                /mnt/common, which measures NFS and is not comparable.
#   BENCH_ARGS   "<deflate> <d1> <c1> <d2> <c2> <d3> <c3>"
#                (default: "6 512 64 512 64 512 64")
#   VARIANTS     subset of baseline,clio_vfd,clio_vol
#   RUN_TIMEOUT  per-variant timeout (default 20m)
#
# Three things this wrapper adds on top of hpf's nc4_clio_bench.sh:
#
#   1. A per-run copy of the driver. The driver reads its clio_runtime.yaml from
#      its own directory with no override, so swapping the RAM tier for the NVMe
#      one means giving it a directory of its own rather than editing hpf's tree.
#   2. The run directory. The driver puts tst_chunks3's cwd at <work>/run, which
#      is on the shared /mnt/common here -- i.e. NFS. Measuring an HDF5 baseline
#      against NFS while CLIO buffers in node-local DRAM would not be a
#      comparison of adapters, so <work>/run is redirected to node-local storage
#      (the driver only ever mkdir/rm -rf's underneath it, so a symlink is
#      transparent to it).
#   3. Parsing. The same parse/combine scripts CI uses, so the JSON this
#      produces is the format create_nc4_clio_plots.py already reads.
#
# Jobs are isolated from each other by a private work directory per job
# (jobs/<tag>_<id>), so two runs can measure on two nodes at once. It points at
# the one shared build tree: symlinks for the install/build directories the
# driver only ever reads through, and a HARD link for tst_chunks3 -- the driver
# locates it with `find <work>/netcdf-build ... -type f`, and find neither
# descends into a symlinked directory nor matches a symlink as -type f.
# --exclusive is for measurement isolation, not politeness: a shared node gives
# a cold-cache baseline no meaning.
#SBATCH --job-name=nc4run
#SBATCH --partition=debug
#SBATCH --nodes=1
#SBATCH --exclusive
#SBATCH --time=04:00:00
#SBATCH --output=/home/hyoklee/logs/nc4_clio_run_%j.log
set -uo pipefail

WORK=${WORK:-/mnt/common/hyoklee/nc4-clio-work}
HPF=/home/hyoklee/src/hyoklee/hpf
ARES_BIN=/home/hyoklee/src/hyoklee/ares/bin
MC3=/home/hyoklee/mc3
: "${TAG:=run}"
: "${TIER:=ram}"
: "${FILEDIR:=nvme}"
: "${BENCH_ARGS:=6 512 64 512 64 512 64}"
: "${VARIANTS:=baseline,clio_vfd,clio_vol}"
: "${RUN_TIMEOUT:=20m}"

JOB=${SLURM_JOB_ID:-local}
RESULTS="$WORK/results/${TAG}_${JOB}"
DRIVER="$WORK/drivers/${TAG}_${JOB}"
JW="$WORK/jobs/${TAG}_${JOB}"
NVME_ROOT=/mnt/nvme/hyoklee/nc4_clio
mkdir -p "$RESULTS" "$DRIVER" "$JW/netcdf-build/nc_perf"
ln -sfn "$WORK/hdf5-install"   "$JW/hdf5-install"
ln -sfn "$WORK/netcdf-install" "$JW/netcdf-install"
ln -sfn "$WORK/clio-build"     "$JW/clio-build"
ln -f   "$WORK/netcdf-build/nc_perf/tst_chunks3" \
        "$JW/netcdf-build/nc_perf/tst_chunks3" 2>/dev/null

export PATH="$WORK/toolbin:$PATH"
export LD_LIBRARY_PATH="$WORK/hdf5-install/lib:$MC3/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

echo "=== nc4 clio run: host=$(hostname) job=$JOB $(date -Is) ==="
echo "TAG=$TAG TIER=$TIER FILEDIR=$FILEDIR VARIANTS=$VARIANTS"
echo "BENCH_ARGS=$BENCH_ARGS RUN_TIMEOUT=$RUN_TIMEOUT"

# --- driver copy with the requested runtime config ---------------------------
cp "$HPF/.github/scripts/nc4_clio_bench.sh" "$DRIVER/"
cp "$ARES_BIN/nc4_clio_runtime_${TIER}.yaml" "$DRIVER/clio_runtime.yaml"
cp "$DRIVER/clio_runtime.yaml" "$RESULTS/clio_runtime.yaml"

# --- where the netCDF file is written ----------------------------------------
rm -rf "$JW/run"
if [ "$FILEDIR" = nvme ]; then
  rm -rf "$NVME_ROOT/run"
  mkdir -p "$NVME_ROOT/run"
  ln -s "$NVME_ROOT/run" "$JW/run"
else
  mkdir -p "$JW/run"
fi
echo "tst_chunks3 cwd: $(readlink -f "$JW/run") ($(df -h "$JW/run" | awk 'NR==2{print $2" "$6}'))"

# The NVMe tier's parent must exist before clio_run opens the bdev file.
if [ "$TIER" = nvme ]; then
  rm -rf "$NVME_ROOT/cte_tier1"
  mkdir -p "$NVME_ROOT"
  df -h /mnt/nvme | tail -1
fi

# clio shm segments outlive a killed runtime; start from a clean slate.
find /dev/shm -maxdepth 1 \( -name 'chimaera*' -o -name 'clio*' \) -delete 2>/dev/null

T0=$(date +%s)
bash "$DRIVER/nc4_clio_bench.sh" \
  --work-dir     "$JW" \
  --results-dir  "$RESULTS" \
  --hdf5-src     /home/hyoklee/src/HDFGroup/hdf5 \
  --netcdf-src   /home/hyoklee/src/unidata/netcdf-c \
  --clio-src     /home/hyoklee/src/iowarp/clio-core/dev/conda \
  --stages       run \
  --variants     "$VARIANTS" \
  --bench-args   "$BENCH_ARGS" \
  --run-timeout  "$RUN_TIMEOUT"
RC=$?
T1=$(date +%s)
echo "=== driver exit=$RC walltime=$((T1 - T0))s ==="

# --- what the run left behind ------------------------------------------------
echo "=== storage after the run ==="
du -sh "$(readlink -f "$JW/run")"/* 2>/dev/null
if [ "$TIER" = nvme ]; then
  ls -l "$NVME_ROOT" 2>/dev/null
  # Apparent vs allocated size: the bdev file is created at its full
  # capacity_limit, so `du` (blocks actually written) is the honest measure of
  # how much of the tier the benchmark really touched.
  du -sh --apparent-size "$NVME_ROOT/cte_tier1" 2>/dev/null
  du -sh "$NVME_ROOT/cte_tier1" 2>/dev/null
fi
df -h /mnt/nvme | tail -1
cp "$JW/clio_run.log" "$RESULTS/clio_run.log" 2>/dev/null

# --- parse into the dashboard's JSON -----------------------------------------
SHA() { python3 -c "import json,sys;print(json.load(open('$JW/sources.json'))['$1'][:8])"; }
INFO="hdf5 $(SHA hdf5_sha) / netcdf-c $(SHA netcdf_sha) / clio-core $(SHA clio_sha) / ares $TIER tier"
for v in baseline clio_vfd clio_vol; do
  python3 "$HPF/.github/scripts/parse_nc4_clio_results.py" \
    "$RESULTS/tst_chunks3_${v}.txt" "$RESULTS/nc4_${v}.json" "$v" "$INFO"
done
python3 "$HPF/.github/scripts/combine_nc4_clio_results.py" \
  "$RESULTS/nc4_baseline.json" "$RESULTS/nc4_clio_vfd.json" \
  "$RESULTS/nc4_clio_vol.json" "$RESULTS/benchmark_data.json" || true

echo "=== variant status ==="
cat "$RESULTS/variant_status.tsv" 2>/dev/null
echo "results: $RESULTS"

# Leave the node's NVMe clean for the next job (and for the next cold tier).
if [ "$FILEDIR" = nvme ] || [ "$TIER" = nvme ]; then
  rm -rf "$NVME_ROOT"
fi
echo "NC4_CLIO_RUN_DONE rc=$RC"
exit $RC
