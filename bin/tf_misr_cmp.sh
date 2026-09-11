#!/bin/bash
cd "$(dirname "$0")" || exit 1
MPI=/mnt/repo/software/modules-install/mpich/4.1.1
F=/mnt/common/hyoklee/bench/tf_misr.nc
RUN="env -u LD_LIBRARY_PATH -u CONDA_PREFIX $MPI/bin/mpiexec"
med(){ printf '%s\n' "$@" | sort -g | awk 'NR==2{m=$1} NR==1{lo=$1} END{print m","lo","$1}'; }
echo "# MISR Red_Radiance: single 755 MB chunk, zlib-1, 215 MiB on disk"
echo "# load: $(uptime | sed 's/.*load average: //')"
echo "path,nprocs,MiB,median_MiB_s,min,max"
for n in 1 2 4 8; do
  v=()
  for r in 1 2 3; do
    python3 "$(dirname "$0")/tf_evict.py" "$F" 2>/dev/null
    x=$(timeout 900 $RUN -n $n ./tf_sweep flat_misr coll "$F" 2>/dev/null | grep "^flat_misr," | awk -F, '{gsub(/ /,"",$6);print $6}')
    [ -n "$x" ] && v+=("$x")
  done
  [ ${#v[@]} -gt 0 ] && echo "raw-netcdf4p,$n,720.00,$(med "${v[@]}")" || echo "raw-netcdf4p,$n,,FAILED,,"
done
for io in netcdf4p netcdf4c; do
  for n in 1 2 4 8; do
    v=()
    for r in 1 2 3; do
      python3 "$(dirname "$0")/tf_evict.py" "$F" 2>/dev/null
      x=$(timeout 900 $RUN -n $n ./pio_read "$io" misr_red "$F" 2>/dev/null | grep "^misr_red," | awk -F, '{gsub(/ /,"",$6);print $6}')
      [ -n "$x" ] && v+=("$x")
    done
    [ ${#v[@]} -gt 0 ] && echo "scorpio-$io,$n,720.00,$(med "${v[@]}")" || echo "scorpio-$io,$n,,FAILED,,"
  done
done
echo "# load end: $(uptime | sed 's/.*load average: //')"
echo "MISR-CMP-DONE"
