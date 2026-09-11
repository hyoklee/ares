#!/bin/bash
cd "$(dirname "$0")" || exit 1
MPI=/mnt/repo/software/modules-install/mpich/4.1.1
FLAT=/mnt/common/hyoklee/bench/tf_flat.nc
RUN="env -u LD_LIBRARY_PATH -u CONDA_PREFIX $MPI/bin/mpiexec"
evict() { python3 "$(dirname "$0")/tf_evict.py" "$FLAT" 2>/dev/null; }
echo "var,path,nprocs,MiB,median_MiB_s,min,max"
med3(){ printf '%s\n' "$@" | sort -g | awk 'NR==2{m=$1} NR==1{lo=$1} END{print m","lo","$1}'; }
for var in modis_ev aster_swir; do
  for io in netcdf4p netcdf4c; do
    for n in 1 2 4 8; do
      v=(); mib=
      for r in 1 2 3; do
        evict
        line=$(timeout 600 $RUN -n "$n" ./pio_read "$io" "$var" 2>/dev/null | grep -E "^$var,")
        [ -n "$line" ] && { v+=("$(echo "$line"|awk -F, '{gsub(/ /,"",$6);print $6}')"); mib=$(echo "$line"|awk -F, '{gsub(/ /,"",$4);print $4}'); }
      done
      if [ ${#v[@]} -gt 0 ]; then echo "$var,scorpio-$io,$n,$mib,$(med3 "${v[@]}")"
      else echo "$var,scorpio-$io,$n,,FAILED,,"; fi
    done
  done
done
echo "PIO-CMP-DONE"
