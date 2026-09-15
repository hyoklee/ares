#!/bin/bash
# =============================================================================
# Terra Fusion parallel netCDF-4 reads: node-local NVMe vs clio-fs, one node,
# both phases inside ONE allocation so only within-job ratios are reported.
#
# Submit:
#   sbatch --export=ALL,PREFIX=/mnt/common/hyoklee/cliodev3nv/install \
#          /home/hyoklee/src/hyoklee/ares/bin/tf_clio_run.sbatch
#
# Env knobs: PREFIX (which clio build) CHAIN=chain|nochain NUM_REPLICAS
#            RAM_TIER_CAP DISK_TIER_CAP BDEV_CAP STAGE_GRANULE=1|0
#
# Layout: clio_run daemon -> clio_cte_fuse mount -> MPICH tf_sweep/pio_read
# reading through the local mount. Single node, so no ssh fan-out: the daemon
# and FUSE run in the background of this script's own session.
#
# The baseline phase reads the SAME files from /mnt/nvme (node-local ext4/xfs),
# not from /mnt/common -- comparing a clio RAM/NVMe tier against NFS-ish shared
# storage would measure the wrong thing.
# =============================================================================
#SBATCH --job-name=tf_clio
#SBATCH --nodes=1
#SBATCH --exclusive
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=40
#SBATCH --partition=debug
#SBATCH --time=02:00:00
#SBATCH --output=/home/hyoklee/logs/tf_clio_%j.log

set -uo pipefail

PREFIX=${PREFIX:-/mnt/common/hyoklee/cliodev3nv/install}
BUILD_TAG=$(basename "$(dirname "$PREFIX")")
CHAIN=${CHAIN:-chain}
NUM_REPLICAS=${NUM_REPLICAS:-1}
PORT=${PORT:-9413}
BDEV_CAP=${BDEV_CAP:-8g}
RAM_TIER_CAP=${RAM_TIER_CAP:-16GB}
DISK_TIER_CAP=${DISK_TIER_CAP:-64GB}
STAGE_GRANULE=${STAGE_GRANULE:-1}

RUNROOT=/mnt/common/hyoklee/tf-clio/runs
TMPLDIR=/mnt/common/hyoklee/clio886/runs
JOB=${SLURM_JOB_ID}
RUNDIR=$RUNROOT/run_${BUILD_TAG}_${JOB}
LOCAL_DIR=/mnt/nvme/hyoklee/tfclio
MEMFD_DIR=/dev/shm/chimaera_hyoklee
MNT=$LOCAL_DIR/mnt
BASE=$LOCAL_DIR/base          # node-local baseline copies

BIN=/home/hyoklee/src/hyoklee/ares/bin
MPI=/mnt/repo/software/modules-install/mpich/4.1.1
H5=/mnt/common/hyoklee/opt/hdf5-develop
NC=/mnt/common/hyoklee/opt/netcdf-c
NF=/mnt/common/hyoklee/opt/netcdf-fortran
SP=/mnt/common/hyoklee/opt/scorpio

GRAN_SRC=/mnt/common/datasets-staging/TERRA_BF_L1B_O10204_20011118010522_F000_V001.h5
FLAT_SRC=/mnt/common/hyoklee/bench/tf_flat.nc
MISR_SRC=/mnt/common/hyoklee/bench/tf_misr.nc

mkdir -p "$RUNDIR" /home/hyoklee/logs
echo "=== $(date) job=$JOB node=$(hostname) build=$BUILD_TAG prefix=$PREFIX chain=$CHAIN"

# --------------------------------------------------------------- build tools -
# Our drivers are MPICH-linked; keep conda and the spack iowarp tree out.
unset LD_LIBRARY_PATH CONDA_PREFIX PYTHONPATH CMAKE_PREFIX_PATH LIBRARY_PATH
export PATH=$MPI/bin:/usr/local/bin:/usr/bin:/bin
RUNENV="env -u CONDA_PREFIX LD_LIBRARY_PATH=$NF/lib:$NC/lib:$H5/lib:$MPI/lib"

cd "$RUNDIR" || exit 1
echo "--- compiling drivers on the node"
$MPI/bin/mpif90 -O2 -o tf_sweep $BIN/tf_sweep.f90 \
  -I$NF/include -L$NF/lib -lnetcdff -L$NC/lib -lnetcdf -L$H5/lib \
  -Wl,-rpath,$NF/lib -Wl,-rpath,$NC/lib -Wl,-rpath,$H5/lib || { echo "FATAL: tf_sweep build"; exit 1; }
$MPI/bin/mpif90 -O2 -o pio_read $BIN/tf_pio_read.f90 -I$SP/include -I$NF/include \
  $SP/lib/libpiof.a $SP/lib/libpioc.a $SP/lib/libgptl.a \
  -L$NF/lib -lnetcdff -L$NC/lib -lnetcdf -L$H5/lib -lhdf5 -lhdf5_hl -lz -lstdc++ \
  -Wl,-rpath,$NF/lib -Wl,-rpath,$NC/lib -Wl,-rpath,$H5/lib || { echo "FATAL: pio_read build"; exit 1; }
echo "    ok"

# ------------------------------------------------------------- node cleanup --
fusermount3 -u  $MNT 2>/dev/null
fusermount3 -uz $MNT 2>/dev/null
umount -l $MNT 2>/dev/null
pkill -9 clio_cte_fuse 2>/dev/null; pkill -9 clio_run 2>/dev/null
ls $MNT >/dev/null 2>&1 || mv $MNT $MNT.broken.$$ 2>/dev/null
rm -rf $MEMFD_DIR $LOCAL_DIR
mkdir -p $MEMFD_DIR $LOCAL_DIR $MNT $BASE

# =========================================================== PHASE 1: BASELINE
echo
echo "############ PHASE 1: node-local NVMe baseline ############"
cp "$FLAT_SRC" "$BASE/tf_flat.nc"
cp "$MISR_SRC" "$BASE/tf_misr.nc"
[ "$STAGE_GRANULE" = 1 ] && { echo "--- copying granule to $BASE (33 GB)"; time cp "$GRAN_SRC" "$BASE/granule.h5"; }
sync
df -h /mnt/nvme | tail -1

run_suite() {   # $1 = label, $2 = directory holding the files
  local lab=$1 dir=$2
  echo "# suite=$lab dir=$dir"
  echo "var,path,nprocs,MiB,MiB_s   # $lab"
  for n in 1 2 4 8; do
    for spec in "flat_modis:$dir/tf_flat.nc" "flat_aster:$dir/tf_flat.nc" "flat_misr:$dir/tf_misr.nc"; do
      local key=${spec%%:*} f=${spec#*:}
      local out
      out=$(timeout 900 $RUNENV $MPI/bin/mpiexec -n "$n" ./tf_sweep "$key" coll "$f" 2>/dev/null | grep "^$key,")
      [ -n "$out" ] && echo "$(echo "$out" | awk -F, -v l="$lab" -v OFS=, '{gsub(/ /,"");print $1,"raw-"l,$3,$4,$6}')" \
                    || echo "$key,raw-$lab,$n,,FAILED"
    done
    for io in netcdf4p netcdf4c; do
      for spec in "modis_ev:$dir/tf_flat.nc" "misr_red:$dir/tf_misr.nc"; do
        local v=${spec%%:*} f=${spec#*:}
        local out
        out=$(timeout 900 $RUNENV $MPI/bin/mpiexec -n "$n" ./pio_read "$io" "$v" "$f" 2>/dev/null | grep "^$v,")
        [ -n "$out" ] && echo "$(echo "$out" | awk -F, -v l="$lab" -v i="$io" -v OFS=, '{gsub(/ /,"");print $1,"scorpio-"i"-"l,$3,$4,$6}')" \
                      || echo "$v,scorpio-$io-$lab,$n,,FAILED"
      done
    done
  done
}

run_suite nvme "$BASE" 2>&1 | tee "$RUNDIR/phase1_nvme.csv"

# =========================================================== PHASE 2: CLIO-FS
echo
echo "############ PHASE 2: clio-fs ############"
echo "$(hostname)" > "$RUNDIR/hosts"
echo "$(hostname)-40g" > "$RUNDIR/clio_hostfile"

TMPL=$TMPLDIR/clio_$([ "$CHAIN" = chain ] && echo chain || echo nochain).yaml.tmpl
CONF=$RUNDIR/clio.yaml
sed -e "s|@PORT@|$PORT|g" -e "s|@HOSTFILE@|$RUNDIR/clio_hostfile|g" \
    -e "s|@LOCAL_DIR@|$LOCAL_DIR|g" -e "s|@BDEV_CAP@|$BDEV_CAP|g" \
    -e "s|@RAM_TIER_CAP@|$RAM_TIER_CAP|g" -e "s|@DISK_TIER_CAP@|$DISK_TIER_CAP|g" \
    -e "s|@NEIGHBORHOOD@|1|g" -e "s|@NUM_REPLICAS@|$NUM_REPLICAS|g" \
    -e "s|@CFS_NEXT@|563.0|g" "$TMPL" > "$CONF"

CLIENT_ENV="CLIO_SERVER_CONF=$CONF CLIO_MEMFD_DIR=$MEMFD_DIR CLIO_REPO_PATH=$PREFIX/lib LD_LIBRARY_PATH=$PREFIX/lib"
NPOOLS=$(grep -c "^  - mod_name" "$CONF")

ulimit -n "$(ulimit -Hn)"
echo "--- starting clio_run daemon"
env $CLIENT_ENV CTP_LOG_LEVEL=info CTP_LOG_OUT=$RUNDIR/daemon.log \
    "$PREFIX/bin/clio_run" runtime start > "$RUNDIR/daemon.out" 2>&1 &
DAEMON_PID=$!

for i in $(seq 1 90); do
  grep -qs "Compose: All $NPOOLS pools created successfully" "$RUNDIR/daemon.log" "$RUNDIR/daemon.out" && break
  kill -0 $DAEMON_PID 2>/dev/null || { echo "FATAL: daemon died"; tail -20 "$RUNDIR/daemon.log" "$RUNDIR/daemon.out"; exit 1; }
  sleep 1
done
grep -qs "Compose: All $NPOOLS pools created successfully" "$RUNDIR/daemon.log" "$RUNDIR/daemon.out" \
  || { echo "FATAL: daemon never composed $NPOOLS pools"; tail -25 "$RUNDIR/daemon.log" "$RUNDIR/daemon.out"; exit 1; }
echo "    composed $NPOOLS pools"

echo "--- mounting clio-fs at $MNT"
env $CLIENT_ENV CLIO_WITH_RUNTIME=0 \
    LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libfuse3.so.3 \
    CTP_LOG_LEVEL=info CTP_LOG_OUT=$RUNDIR/fuse.log \
    "$PREFIX/bin/clio_cte_fuse" "$MNT" -f > "$RUNDIR/fuse.out" 2>&1 &
FUSE_PID=$!
sleep 8
mountpoint -q "$MNT" || { echo "FATAL: mount failed"; tail -20 "$RUNDIR/fuse.out" "$RUNDIR/fuse.log"; exit 1; }
echo "    mounted"

echo "--- staging files into clio-fs"
time cp "$BASE/tf_flat.nc" "$MNT/tf_flat.nc"
time cp "$BASE/tf_misr.nc" "$MNT/tf_misr.nc"
[ "$STAGE_GRANULE" = 1 ] && { echo "--- staging granule (33 GB) through FUSE"; time cp "$BASE/granule.h5" "$MNT/granule.h5"; }
ls -l "$MNT"

run_suite cliofs "$MNT" 2>&1 | tee "$RUNDIR/phase2_cliofs.csv"

# ------------------------------------------------------------------ teardown -
echo
echo "--- tier occupancy after the run"
du -sh --block-size=1M $LOCAL_DIR/cte_disk_tier.dat_node* 2>/dev/null | awk '{s+=$1} END{print "  disk tier: "s" MiB"}'
tail -5 "$RUNDIR/fuse.log" 2>/dev/null

fusermount3 -u "$MNT" 2>/dev/null; sleep 2
kill $FUSE_PID 2>/dev/null; kill $DAEMON_PID 2>/dev/null
sleep 2
pkill -9 clio_cte_fuse 2>/dev/null; pkill -9 clio_run 2>/dev/null

echo
echo "=== results in $RUNDIR"
echo "TF-CLIO-DONE"
