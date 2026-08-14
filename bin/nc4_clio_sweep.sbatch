#!/bin/bash
# Dimension/chunk doubling sweep for the NetCDF-4/CLIO comparison.
#
# Runs the same three variants as nc4_clio_run.sbatch, but repeatedly: starting
# from <D0>/<C0> it doubles BOTH the dimension and the chunk edge each step
# (64/16 -> 128/32 -> 256/64 -> ...), which grows the file 8x per step, and
# stops when the CLIO variants stop producing results -- the point the exercise
# is looking for. The baseline keeps running one step past that so the last
# CLIO step still has a reference to be measured against.
#
# Everything is one allocation and one runtime configuration, so the only thing
# that changes between steps is the problem size.
#
# Usage:
#   sbatch --export=ALL,TIER=ram,D0=64,C0=16,STEPS=6 \
#          /home/hyoklee/src/hyoklee/ares/bin/nc4_clio_sweep.sbatch
#
# Env knobs:
#   TIER         ram | nvme (default ram) -- CTE storage medium
#   D0, C0       first dimension / chunk edge (default 64 / 16)
#   STEPS        how many doublings to attempt (default 6)
#   DEFLATE      deflate level passed to tst_chunks3 (default 6)
#   RUN_TIMEOUT  per-variant timeout (default 20m)
#   TAG          results label (default sweep)
#SBATCH --job-name=nc4sweep
#SBATCH --partition=debug
#SBATCH --nodes=1
#SBATCH --exclusive
#SBATCH --time=12:00:00
#SBATCH --output=/home/hyoklee/logs/nc4_clio_sweep_%j.log
set -uo pipefail

WORK=${WORK:-/mnt/common/hyoklee/nc4-clio-work}
HPF=/home/hyoklee/src/hyoklee/hpf
ARES_BIN=/home/hyoklee/src/hyoklee/ares/bin
MC3=/home/hyoklee/mc3
: "${TIER:=ram}"
: "${D0:=64}"
: "${C0:=16}"
: "${STEPS:=6}"
: "${DEFLATE:=6}"
: "${RUN_TIMEOUT:=20m}"
: "${TAG:=sweep}"

JOB=${SLURM_JOB_ID:-local}
ROOT="$WORK/results/${TAG}_${TIER}_${JOB}"
DRIVER="$WORK/drivers/${TAG}_${JOB}"
# Private work dir so a sweep and a single run (or a second sweep on another
# tier) can measure at the same time on different nodes -- see the comment in
# nc4_clio_run.sbatch for why tst_chunks3 is a hard link and the rest symlinks.
JW="$WORK/jobs/${TAG}_${JOB}"
NVME_ROOT=/mnt/nvme/hyoklee/nc4_clio
mkdir -p "$ROOT" "$DRIVER" "$JW/netcdf-build/nc_perf"
ln -sfn "$WORK/hdf5-install"   "$JW/hdf5-install"
ln -sfn "$WORK/netcdf-install" "$JW/netcdf-install"
ln -sfn "$WORK/clio-build"     "$JW/clio-build"
ln -f   "$WORK/netcdf-build/nc_perf/tst_chunks3" \
        "$JW/netcdf-build/nc_perf/tst_chunks3" 2>/dev/null

export PATH="$WORK/toolbin:$PATH"
export LD_LIBRARY_PATH="$WORK/hdf5-install/lib:$MC3/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

cp "$HPF/.github/scripts/nc4_clio_bench.sh" "$DRIVER/"
cp "$ARES_BIN/nc4_clio_runtime_${TIER}.yaml" "$DRIVER/clio_runtime.yaml"

echo "=== nc4 clio sweep: host=$(hostname) job=$JOB tier=$TIER $(date -Is) ==="
echo "start ${D0}/${C0}, $STEPS doublings, deflate=$DEFLATE, timeout=$RUN_TIMEOUT"

SUMMARY="$ROOT/sweep_summary.tsv"
printf 'dim\tchunk\tfile_MiB\tvariant\tstatus\twall_s\tnote\n' >"$SUMMARY"

D=$D0
C=$C0
VARIANTS=baseline,clio_vfd,clio_vol
for step in $(seq 1 "$STEPS"); do
  # 3 float variables of D^3 elements each.
  MIB=$(( 3 * D * D * D * 4 / 1048576 ))
  echo ""
  echo "############ step $step: dim=$D chunk=$C (~${MIB} MiB of variable data) ############"

  RES="$ROOT/d${D}_c${C}"
  mkdir -p "$RES"

  rm -rf "$JW/run" "$NVME_ROOT/run"
  mkdir -p "$NVME_ROOT/run"
  ln -s "$NVME_ROOT/run" "$JW/run"
  [ "$TIER" = nvme ] && { rm -rf "$NVME_ROOT/cte_tier1"; mkdir -p "$NVME_ROOT"; }
  find /dev/shm -maxdepth 1 \( -name 'chimaera*' -o -name 'clio*' \) -delete 2>/dev/null

  T0=$(date +%s)
  bash "$DRIVER/nc4_clio_bench.sh" \
    --work-dir    "$JW" \
    --results-dir "$RES" \
    --hdf5-src    /home/hyoklee/src/HDFGroup/hdf5 \
    --netcdf-src  /home/hyoklee/src/unidata/netcdf-c \
    --clio-src    /home/hyoklee/src/iowarp/clio-core/dev/conda \
    --stages      run \
    --variants    "$VARIANTS" \
    --bench-args  "$DEFLATE $D $C $D $C $D $C" \
    --run-timeout "$RUN_TIMEOUT"
  T1=$(date +%s)
  echo "step $step wall=$((T1 - T0))s"
  df -h /mnt/nvme | tail -1

  for v in baseline clio_vfd clio_vol; do
    st=$(awk -F'\t' -v v="$v" '$1 == v {s = $2; n = $3} END {print (s ? s : "not_run") "\t" n}' \
           "$RES/variant_status.tsv" 2>/dev/null)
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$D" "$C" "$MIB" "$v" "${st%%$'\t'*}" "$((T1 - T0))" \
      >>"$SUMMARY"
    python3 "$HPF/.github/scripts/parse_nc4_clio_results.py" \
      "$RES/tst_chunks3_${v}.txt" "$RES/nc4_${v}.json" "$v" "ares $TIER d$D c$C" >/dev/null
  done
  python3 "$HPF/.github/scripts/combine_nc4_clio_results.py" \
    "$RES/nc4_baseline.json" "$RES/nc4_clio_vfd.json" "$RES/nc4_clio_vol.json" \
    "$RES/benchmark_data.json" >/dev/null 2>&1

  echo "--- status after step $step ---"
  cat "$RES/variant_status.tsv"

  # A CLIO variant that produced nothing is dropped from the following steps:
  # re-running a size that already failed only burns the timeout again, and the
  # question here is where it stops working, not how many times it can fail.
  NEXT=baseline
  for v in clio_vfd clio_vol; do
    case ",$VARIANTS," in *",$v,"*) ;; *) continue ;; esac
    if [ -s "$RES/tst_chunks3_${v}.txt" ]; then
      NEXT="$NEXT,$v"
    else
      echo "dropping $v from subsequent steps: no result at dim=$D chunk=$C"
    fi
  done
  VARIANTS="$NEXT"

  if [ "$VARIANTS" = baseline ]; then
    # One more baseline-only step would measure nothing about CLIO. Stop.
    echo "both CLIO variants have failed; sweep stops at dim=$D chunk=$C"
    break
  fi
  if [ ! -s "$RES/tst_chunks3_baseline.txt" ]; then
    echo "baseline itself produced no result at dim=$D chunk=$C; sweep stops"
    break
  fi

  D=$((D * 2))
  C=$((C * 2))
done

rm -rf "$NVME_ROOT"
echo ""
echo "=== sweep summary ==="
cat "$SUMMARY"
echo "results: $ROOT"
echo "NC4_CLIO_SWEEP_DONE"
