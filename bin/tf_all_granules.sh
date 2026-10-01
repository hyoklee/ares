#!/bin/bash
# Run the congruence pipeline over EVERY Terra Fusion granule.
#
# Parts 1-15 used one granule (O10204). This extends the same analysis to all
# ten, so the "highest discrepancy block" question is answered across 284 GB
# rather than within one orbit.
#
# Uses the MATCHED configuration established in parts 11-12, and nothing else is
# defensible: MODIS band 31 (11.03 um) and CERES WN_Radiance (8-12 um). Running
# this at the old defaults -- MODIS band 20, CERES LW -- would reproduce the
# band-selection artifacts that parts 10 and 11 retracted, ten times over.
#
# Per granule, in its own work directory:
#   tf_aster_blocks.py   -> aster_blocks.json   (blocks differ per orbit)
#   tf_sources.py        -> regrid_inputs_b31_WN.npz
#   tf_congruence.py     -> congruence_b31_WN.json
#
# Usage:
#   bash bin/tf_all_granules.sh              # all granules, 3 at a time
#   JOBS=1 GRANULES="O10204 O10670" bash bin/tf_all_granules.sh
set -uo pipefail

PY=${PY:-$HOME/src/hyoklee/ares/.venv-tf/bin/python3}
BIN=${BIN:-$HOME/src/hyoklee/ares/bin}
DATA=${DATA:-/mnt/common/datasets-staging}
ROOT=${ROOT:-/mnt/common/hyoklee/tfwork/allgran}
JOBS=${JOBS:-3}
MODIS_BAND_IDX=${MODIS_BAND_IDX:-10}      # band 31
CERES_FIELD=${CERES_FIELD:-WN_Radiance}

mkdir -p "$ROOT" || exit 1
echo "# matched config: MODIS band idx $MODIS_BAND_IDX, CERES $CERES_FIELD"
echo "# $JOBS granule(s) at a time, work root $ROOT"

run_one() {
  local f=$1
  local orbit
  orbit=$(basename "$f" | sed -E 's/TERRA_BF_L1B_(O[0-9]+)_.*/\1/')
  local w=$ROOT/$orbit
  mkdir -p "$w" || return 1
  local log=$w/run.log
  {
    echo "=== $orbit  $(basename "$f")"
    cd "$w" || exit 1
    t0=$SECONDS
    TF_GRANULE=$f timeout 3600 "$PY" "$BIN/tf_aster_blocks.py" > blocks.log 2>&1 \
      || { echo "!!! blocks failed"; tail -3 blocks.log; exit 1; }
    nblk=$(python3 -c "import json;print(len(json.load(open('aster_blocks.json'))))" 2>/dev/null)
    echo "    blocks: ${nblk:-?}  ($((SECONDS-t0))s)"
    TF_GRANULE=$f MODIS_BAND_IDX=$MODIS_BAND_IDX CERES_FIELD=$CERES_FIELD \
      timeout 7200 "$PY" "$BIN/tf_sources.py" > sources.log 2>&1 \
      || { echo "!!! sources failed"; tail -5 sources.log; exit 1; }
    npz=$(ls regrid_inputs_*.npz 2>/dev/null | head -1)
    echo "    sources: ${npz:-none}  ($((SECONDS-t0))s)"
    TF_GRANULE=$f TF_NPZ=$npz TF_TAG=b31_WN \
      timeout 7200 "$PY" "$BIN/tf_congruence.py" > congruence.log 2>&1 \
      || { echo "!!! congruence failed"; tail -5 congruence.log; exit 1; }
    n=$(python3 -c "import json;print(len(json.load(open('congruence_b31_WN.json'))))" 2>/dev/null)
    echo "    congruence: ${n:-?} blocks  ($((SECONDS-t0))s total)  OK"
  } >> "$log" 2>&1
  tail -5 "$log"
}
export -f run_one
export PY BIN ROOT MODIS_BAND_IDX CERES_FIELD

sel=${GRANULES:-}
files=()
for f in "$DATA"/TERRA_BF_L1B_*.h5; do
  orbit=$(basename "$f" | sed -E 's/TERRA_BF_L1B_(O[0-9]+)_.*/\1/')
  if [ -n "$sel" ]; then case " $sel " in *" $orbit "*) ;; *) continue ;; esac; fi
  files+=("$f")
done
echo "# ${#files[@]} granule(s) to process"

printf '%s\n' "${files[@]}" | xargs -P "$JOBS" -I{} bash -c 'run_one "$@"' _ {}

echo
echo "# ==== per-granule status ===="
for d in "$ROOT"/O*; do
  o=$(basename "$d")
  if [ -f "$d/congruence_b31_WN.json" ]; then
    n=$(python3 -c "import json;print(len(json.load(open('$d/congruence_b31_WN.json'))))" 2>/dev/null)
    echo "  $o: $n blocks"
  else
    echo "  $o: INCOMPLETE -- $(grep -c '!!!' "$d/run.log" 2>/dev/null) error(s), see $d/run.log"
  fi
done
echo "ALL-GRANULES-DONE"
