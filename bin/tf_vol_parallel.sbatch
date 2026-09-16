#!/bin/bash
# =============================================================================
# Does collective (MPI) netCDF-4 I/O work through the clio VOL connector?
#
#   sbatch /home/hyoklee/src/hyoklee/ares/bin/tf_vol_parallel.sbatch
#
# This is the question left open by 20260915: the VOL now links a PARALLEL
# HDF5 (2.3.0 + libmpi), which is a precondition for E3SM relevance, but a VOL
# replaces the file API wholesale and H5Pset_fapl_mpio sets a *VFD* -- which
# lives below the native VOL. Whether the clio VOL passes an MPI FAPL through
# to its under-VOL (native) is not documented anywhere, so it gets measured.
#
# The driver is tf_sweep.f90 unchanged -- it already does nf90_open_par +
# nf90_var_par_access(NF90_COLLECTIVE) -- so the ONLY difference between the
# two phases is HDF5_VOL_CONNECTOR in the environment.
#
# Three outcomes are interesting and all are recorded rather than treated as
# failure:
#   open_par fails        -> the VOL has no parallel file-open path
#   par_access fails      -> it opens but cannot do collective mode
#   reads succeed         -> collective I/O works; compare throughput
#
# Multi-rank clio clients are themselves new here: every previous clio test in
# this series drove ONE process (the FUSE daemon, or a serial reader), so N
# ranks each running CLIO_INIT against one runtime is untested ground.
# =============================================================================
#SBATCH --job-name=tf_volpar
#SBATCH --nodes=1
#SBATCH --exclusive
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=40
#SBATCH --partition=debug
#SBATCH --time=01:00:00
#SBATCH --output=/home/hyoklee/logs/tf_volpar_%j.log

set -uo pipefail

CLIO=/mnt/common/hyoklee/opt/clio-core
H5=/mnt/common/hyoklee/opt/hdf5-develop
NC=/mnt/common/hyoklee/opt/netcdf-c
NF=/mnt/common/hyoklee/opt/netcdf-fortran
MPI=/mnt/repo/software/modules-install/mpich/4.1.1
BIN=/home/hyoklee/src/hyoklee/ares/bin
W=/mnt/common/hyoklee/nc4-clio-work

JOB=${SLURM_JOB_ID}
RUNDIR=/mnt/common/hyoklee/tf-clio/runs/volpar_${JOB}
LOCAL=/mnt/nvme/hyoklee/tfvolpar
CLIO_CONF=$RUNDIR/clio_runtime.yaml
CLIO_LOG=$RUNDIR/clio_run.log
REPS=${REPS:-3}
RANKS=${RANKS:-"1 2 4 8"}
# Phase order is a knob because the first phase runs right after the file copy
# and can carry writeback noise. A real effect survives reordering; a
# first-phase artifact inverts. PHASE_ORDER=vol_first runs the VOL first.
PHASE_ORDER=${PHASE_ORDER:-native_first}

mkdir -p "$RUNDIR" "$LOCAL" /home/hyoklee/logs
echo "=== $(date) job=$JOB node=$(hostname)"
echo "    clio   : $(cd $HOME/src/hyoklee/core && git log --oneline -1)"
echo "    hdf5   : $(grep -aoE 'HDF5 Version: [0-9.]+' $H5/lib/libhdf5.so | head -1)  $(grep -aoE 'Parallel HDF5: [A-Z]+' $H5/lib/libhdf5.so | head -1)"
echo "    vol mpi: $(ldd $CLIO/lib/libclio_hdf5_vol.so 2>/dev/null | grep -c libmpi)"

unset LD_LIBRARY_PATH CONDA_PREFIX PYTHONPATH CMAKE_PREFIX_PATH LIBRARY_PATH
export PATH=$MPI/bin:/usr/local/bin:/usr/bin:/bin
NCLIB=$NF/lib:$NC/lib:$H5/lib:$MPI/lib

cd "$RUNDIR" || exit 1
$MPI/bin/mpif90 -O2 -o tf_sweep $BIN/tf_sweep.f90 \
  -I$NF/include -L$NF/lib -lnetcdff -L$NC/lib -lnetcdf -L$H5/lib \
  -Wl,-rpath,$NF/lib -Wl,-rpath,$NC/lib -Wl,-rpath,$H5/lib || { echo "FATAL: build"; exit 1; }
echo "    driver built"

cp /mnt/common/hyoklee/bench/tf_flat.nc "$LOCAL/tf_flat.nc"
cp /mnt/common/hyoklee/bench/tf_misr.nc "$LOCAL/tf_misr.nc"
sync

clio_stop() { pkill -9 clio_run 2>/dev/null; sleep 1; rm -rf /dev/shm/chimaera_hyoklee* 2>/dev/null; }
clio_start() {
  clio_stop
  cp $W/clio_runtime.yaml "$CLIO_CONF"
  CLIO_SERVER_CONF="$CLIO_CONF" LD_LIBRARY_PATH=$CLIO/lib \
    "$CLIO/bin/clio_run" start > "$CLIO_LOG" 2>&1 &
  for _ in $(seq 1 60); do
    grep -q "pools created successfully" "$CLIO_LOG" 2>/dev/null && { sleep 1; echo "    clio_run ready"; return 0; }
    sleep 1
  done
  echo "    FATAL: clio_run not ready"; tail -15 "$CLIO_LOG"; return 1
}

median() { printf '%s\n' "$@" | sort -g | awk 'NR==2{m=$1} NR==1{lo=$1} END{print m","lo","$1}'; }

# run_phase <label>  -- caller exports HDF5_VOL_CONNECTOR etc first
run_phase() {
  local lab=$1 key f n r out x vals
  for spec in "flat_modis:$LOCAL/tf_flat.nc" "flat_misr:$LOCAL/tf_misr.nc"; do
    key=${spec%%:*}; f=${spec#*:}
    for n in $RANKS; do
      vals=()
      for r in $(seq $REPS); do
        python3 "$BIN/tf_evict.py" "$f" 2>/dev/null
        out=$(timeout 300 env LD_LIBRARY_PATH=$NCLIB:$CLIO/lib $MPI/bin/mpiexec -n "$n" \
              ./tf_sweep "$key" coll "$f" 2>>"$RUNDIR/err_$lab.log" | grep "^$key,")
        x=$(echo "$out" | awk -F, '{gsub(/ /,"");print $6}')
        [ -n "$x" ] && vals+=("$x")
      done
      if [ ${#vals[@]} -gt 0 ]; then echo "$key,$lab,$n,$(median "${vals[@]}")"
      else echo "$key,$lab,$n,FAILED,,"; fi
    done
  done
}

echo
echo "var,phase,nprocs,median_MiB_s,min,max"

phase_native() {
  ( unset HDF5_VOL_CONNECTOR HDF5_PLUGIN_PATH HDF5_DRIVER HDF5_DRIVER_CONFIG
    run_phase native )
}
phase_vol() {
  if clio_start; then
    ( unset HDF5_DRIVER HDF5_DRIVER_CONFIG
      export HDF5_PLUGIN_PATH="$CLIO/lib"
      export HDF5_VOL_CONNECTOR="clio"
      export CLIO_SERVER_CONF="$CLIO_CONF"
      run_phase clio_vol )
  else
    for k in flat_modis flat_misr; do for n in $RANKS; do echo "$k,clio_vol,$n,NO_RUNTIME,,"; done; done
  fi
  clio_stop
}

if [ "$PHASE_ORDER" = vol_first ]; then
  echo "# phase order: clio_vol then native"
  phase_vol; phase_native
else
  echo "# phase order: native then clio_vol"
  phase_native; phase_vol
fi

echo
echo "--- first distinct errors from the VOL phase"
sed 's/\x1b\[[0-9;]*m//g' "$RUNDIR/err_clio_vol.log" 2>/dev/null \
  | grep -aiE "FAIL \[|symbol lookup|error|abort|denied|not supported|unsupported" \
  | sort | uniq -c | sort -rn | head -6
rm -rf "$LOCAL"
echo "=== results in $RUNDIR"
echo "TF-VOLPAR-DONE"
