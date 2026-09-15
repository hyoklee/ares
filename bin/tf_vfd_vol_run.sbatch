#!/bin/bash
# =============================================================================
# Terra Fusion serial netCDF-4 reads: baseline vs clio VFD vs clio VOL.
#
#   sbatch /home/hyoklee/src/hyoklee/ares/bin/tf_vfd_vol_run.sbatch
#
# WHY SERIAL: clio's VFD and VOL are built against a non-parallel HDF5
# (nc4-clio-work/hdf5-install reports "Parallel HDF5: OFF") and link no MPI, so
# they cannot be used with nf90_open_par. Every read here is one process. That
# is not a limitation of the test -- it is the adapters' actual operating
# envelope, and it is also the cleanest possible probe of the VFD's
# vector/coalescing path, since a single-chunk variable becomes exactly one
# enormous read request.
#
# The whole stack is nc4-clio-work's (HDF5 2.3.0 serial + netcdf-c 4.10.2),
# i.e. the combination the adapters were built and CI-tested against, rather
# than the parallel stack in /mnt/common/hyoklee/opt. Mixing a parallel libhdf5
# with serial-built plugins would put the plugin ABI in question for no gain.
#
# Variant selection is entirely by environment, so the binary is byte-identical
# across all three phases; the only thing that changes is the data path HDF5
# loads underneath it.
# =============================================================================
#SBATCH --job-name=tf_vfdvol
#SBATCH --nodes=1
#SBATCH --exclusive
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=40
#SBATCH --partition=debug
#SBATCH --time=01:00:00
#SBATCH --output=/home/hyoklee/logs/tf_vfdvol_%j.log

set -uo pipefail

# Stack is selectable: default is the nc4-clio-work tree the adapters were
# originally CI-tested against (serial HDF5); STACK=ours points at the forks
# built in this series (HDF5 2.3.0 PARALLEL + netcdf-c 4.10.2 + clio-core dev),
# which is the only combination where the VOL links a parallel HDF5.
W=/mnt/common/hyoklee/nc4-clio-work
STACK=${STACK:-cicompat}
if [ "$STACK" = ours ]; then
  CLIO_BIN=${CLIO_BIN:-/mnt/common/hyoklee/opt/clio-core/lib}
  CLIO_RUN_BIN=${CLIO_RUN_BIN:-/mnt/common/hyoklee/opt/clio-core/bin}
  NC_INST=${NC_INST:-/mnt/common/hyoklee/opt/netcdf-c}
  H5_INST=${H5_INST:-/mnt/common/hyoklee/opt/hdf5-develop}
else
  CLIO_BIN=$W/clio-build/bin
  CLIO_RUN_BIN=$W/clio-build/bin
  NC_INST=$W/netcdf-install
  H5_INST=$W/hdf5-install
fi
BIN=/home/hyoklee/src/hyoklee/ares/bin

JOB=${SLURM_JOB_ID}
RUNDIR=/mnt/common/hyoklee/tf-clio/runs/vfdvol_${JOB}
LOCAL=/mnt/nvme/hyoklee/tfvfdvol
CLIO_CONF=$RUNDIR/clio_runtime.yaml
CLIO_LOG=$RUNDIR/clio_run.log
REPS=${REPS:-3}
# Per-read cap. clio_vol hangs at PROCESS EXIT (clio_write_stamp issues a
# PutBlobTask during H5VL_file_close and never gets a reply), so the read itself
# finishes and the result line is already on stdout when the timeout fires --
# command substitution still harvests it. A short cap keeps that phase bounded.
READ_TIMEOUT=${READ_TIMEOUT:-90}
VARIANTS=${VARIANTS:-baseline,clio_vfd,clio_vol}

mkdir -p "$RUNDIR" "$LOCAL" /home/hyoklee/logs
echo "=== $(date) job=$JOB node=$(hostname)"
echo "    hdf5   : $(grep -aoE 'HDF5 Version: [0-9.]+' $H5_INST/lib/libhdf5.so | head -1)  parallel=$(grep -aoE 'Parallel HDF5: [A-Z]+' $H5_INST/lib/libhdf5.so | head -1)"
echo "    netcdf : $($NC_INST/bin/nc-config --version 2>/dev/null || echo 4.10.2-development)"
echo "    stack  : $STACK  clio=$CLIO_BIN"
echo "    plugins: $(ls $CLIO_BIN/libclio_vfd.so $CLIO_BIN/libclio_hdf5_vol.so 2>/dev/null | wc -l)/2 present"
echo "    vol links: $(ldd $CLIO_BIN/libclio_hdf5_vol.so 2>/dev/null | grep -icE 'libmpi') mpi"

unset LD_LIBRARY_PATH CONDA_PREFIX PYTHONPATH CMAKE_PREFIX_PATH LIBRARY_PATH
export PATH=/usr/local/bin:/usr/bin:/bin
NCLIB=$NC_INST/lib:$H5_INST/lib

cd "$RUNDIR" || exit 1
gcc -O2 -o tf_serial_read $BIN/tf_serial_read.c \
  -I$NC_INST/include -L$NC_INST/lib -lnetcdf \
  -Wl,-rpath,$NC_INST/lib -Wl,-rpath,$H5_INST/lib || { echo "FATAL: build"; exit 1; }
echo "    reader built"

# Node-local copies so no variant is measuring shared storage.
cp /mnt/common/hyoklee/bench/tf_flat.nc "$LOCAL/tf_flat.nc"
cp /mnt/common/hyoklee/bench/tf_misr.nc "$LOCAL/tf_misr.nc"
sync

clio_stop() {
  pkill -9 clio_run 2>/dev/null
  sleep 1
  rm -rf /dev/shm/chimaera_hyoklee* 2>/dev/null
}
clio_start() {
  clio_stop
  cp $W/clio_runtime.yaml "$CLIO_CONF"
  CLIO_SERVER_CONF="$CLIO_CONF" LD_LIBRARY_PATH=$CLIO_BIN \
    "$CLIO_RUN_BIN/clio_run" start > "$CLIO_LOG" 2>&1 &
  for _ in $(seq 1 60); do
    grep -q "pools created successfully" "$CLIO_LOG" 2>/dev/null && { sleep 1; echo "    clio_run ready"; return 0; }
    grep -q "Could not start TCP server" "$CLIO_LOG" 2>/dev/null && { echo "    FATAL: clio bind failed"; return 1; }
    sleep 1
  done
  echo "    FATAL: clio_run not ready"; tail -15 "$CLIO_LOG"; return 1
}

median() { printf '%s\n' "$@" | sort -g | awk 'NR==2{m=$1} NR==1{lo=$1} END{print m","lo","$1}'; }

# run_variant <label> -- caller exports the adapter env first
run_variant() {
  local lab=$1 f v vals out x
  for spec in "tf_flat.nc:modis_ev" "tf_flat.nc:aster_swir" "tf_misr.nc:misr_red"; do
    f=${spec%%:*}; v=${spec#*:}
    vals=()
    for r in $(seq $REPS); do
      python3 "$BIN/tf_evict.py" "$LOCAL/$f" 2>/dev/null
      out=$(timeout $READ_TIMEOUT env LD_LIBRARY_PATH=$NCLIB:$CLIO_BIN ./tf_serial_read "$LOCAL/$f" "$v" "$lab" 2>>"$RUNDIR/err_$lab.log")
      x=$(echo "$out" | awk -F, '{print $5}')
      [ -n "$x" ] && vals+=("$x")
    done
    if [ ${#vals[@]} -gt 0 ]; then echo "$v,$lab,$(median "${vals[@]}")"
    else echo "$v,$lab,FAILED,,"; fi
  done
}

echo
echo "var,variant,median_MiB_s,min,max"

# ---------------------------------------------------------------- baseline --
case ",$VARIANTS," in *,baseline,*)
( unset HDF5_DRIVER HDF5_DRIVER_CONFIG HDF5_VOL_CONNECTOR HDF5_PLUGIN_PATH
  run_variant baseline ) ;; esac

# ---------------------------------------------------------------- clio_vfd --
case ",$VARIANTS," in *,clio_vfd,*)
if clio_start; then
  ( unset HDF5_VOL_CONNECTOR
    export HDF5_PLUGIN_PATH="$CLIO_BIN"
    export HDF5_DRIVER="clio_vfd"          # H5FD_CLIO_NAME from H5FDclio.h
    export HDF5_DRIVER_CONFIG="cache=1"    # CTE cache tier; key=value grammar is mandatory
    export CLIO_SERVER_CONF="$CLIO_CONF"
    run_variant clio_vfd )
else
  echo "modis_ev,clio_vfd,NO_RUNTIME,,"; echo "aster_swir,clio_vfd,NO_RUNTIME,,"; echo "misr_red,clio_vfd,NO_RUNTIME,,"
fi
clio_stop ;; esac

# ---------------------------------------------------------------- clio_vol --
case ",$VARIANTS," in *,clio_vol,*)
if clio_start; then
  ( unset HDF5_DRIVER HDF5_DRIVER_CONFIG
    export HDF5_PLUGIN_PATH="$CLIO_BIN"
    export HDF5_VOL_CONNECTOR="clio"       # under-VOL defaults to native
    export CLIO_SERVER_CONF="$CLIO_CONF"
    run_variant clio_vol )
else
  echo "modis_ev,clio_vol,NO_RUNTIME,,"; echo "aster_swir,clio_vol,NO_RUNTIME,,"; echo "misr_red,clio_vol,NO_RUNTIME,,"
fi
clio_stop ;; esac

echo
echo "--- adapter stderr (first lines, if any)"
for l in baseline clio_vfd clio_vol; do
  [ -s "$RUNDIR/err_$l.log" ] && { echo "== $l"; head -6 "$RUNDIR/err_$l.log"; }
done
rm -rf "$LOCAL"
echo "=== results in $RUNDIR"
echo "TF-VFDVOL-DONE"
