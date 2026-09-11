#!/bin/bash
# Terra Fusion parallel netCDF-4 read sweep — clean re-run.
# Changes vs first pass: 3 reps + median per config, min/max spread reported,
# indep dropped for compressed vars (proven NC_EINVAL), load recorded.

cd "$(dirname "$0")" || exit 1
MPI=/mnt/repo/software/modules-install/mpich/4.1.1
GRAN=/mnt/common/datasets-staging/TERRA_BF_L1B_O10204_20011118010522_F000_V001.h5
RUN="env -u LD_LIBRARY_PATH -u CONDA_PREFIX $MPI/bin/mpiexec"
REPS=3

evict() { python3 "$(dirname "$0")/tf_evict.py" "$GRAN" 2>/dev/null; }

median3() {  # median, min, max of the numeric args
  printf '%s\n' "$@" | sort -g | awk 'NR==2{m=$1} NR==1{lo=$1} END{print m","lo","$1}'
}

echo "# ===== clean re-run ====="
echo "# load at start : $(uptime | sed 's/.*load average: //')"
echo "# raw sequential ceiling, O_DIRECT 8MB blocks, 3 samples:"
for i in 1 2 3; do
  dd if="$GRAN" of=/dev/null bs=8M count=384 iflag=direct 2>&1 | tail -1 | sed 's/^/#   /'
done
echo "#"
echo "key,mode,cache,nprocs,MiB,median_MiB_s,min_MiB_s,max_MiB_s"

run_one() {  # key mode nprocs cache -> MiB/s or empty
  local key=$1 mode=$2 n=$3 cache=$4
  [ "$cache" = cold ] && evict
  timeout 900 $RUN -n "$n" ./tf_sweep "$key" "$mode" 2>/dev/null \
    | grep -E "^$key," | tail -1 | awk -F, '{gsub(/ /,"",$6); print $6}'
}

sweep_cell() {  # key mode nprocs cache
  local key=$1 mode=$2 n=$3 cache=$4
  local vals=() v mib
  for r in $(seq $REPS); do
    v=$(run_one "$key" "$mode" "$n" "$cache")
    [ -n "$v" ] && vals+=("$v")
  done
  if [ ${#vals[@]} -eq 0 ]; then
    echo "$key,$mode,$cache,$n,,FAILED,,"
    return
  fi
  mib=$(timeout 900 $RUN -n "$n" ./tf_sweep "$key" "$mode" 2>/dev/null \
        | grep -E "^$key," | tail -1 | awk -F, '{gsub(/ /,"",$4); print $4}')
  echo "$key,$mode,$cache,$n,$mib,$(median3 "${vals[@]}")"
}

# --- cold, collective: the main scaling sweep ---
for key in mopitt modis aster misr; do
  case $key in
    misr) RANKS="1 2 4 8" ;;
    *)    RANKS="1 2 4 8 16" ;;
  esac
  for n in $RANKS; do sweep_cell "$key" coll "$n" cold; done
done

# --- independent access: only meaningful on the uncompressed variable ---
echo "#"
echo "# independent access — compressed vars return NC_EINVAL, so only the"
echo "# uncompressed control (mopitt) is swept here"
for n in 1 2 4 8 16; do sweep_cell mopitt indep "$n" cold; done

# --- warm cache on the well-chunked variable: isolates inflate from disk ---
echo "#"
echo "# warm cache (no eviction)"
for n in 1 2 4 8 16; do
  $RUN -n 1 ./tf_sweep modis coll >/dev/null 2>&1   # prime
  sweep_cell modis coll "$n" warm
done

echo "#"
echo "# load at end : $(uptime | sed 's/.*load average: //')"
echo "SWEEP-DONE"
