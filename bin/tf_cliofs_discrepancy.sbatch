#!/bin/bash
# =============================================================================
# The discrepancy read path over clio-fs, on a compute node.
#
# Companion to part 16's VOL and VFD tests, which ran on the login node. clio-fs
# cannot: a FUSE mount there fails with "fusermount3: mount failed: Operation
# not permitted" even with the setuid /usr/bin/fusermount3 and /dev/fuse
# readable, so the mount has to happen inside an allocation.
#
# Runs bin/tf_vol_discrepancy_read.c -- the SAME binary the VOL and VFD were
# measured with -- against three paths, interleaved within one job so only
# within-job ratios are reported:
#
#   base    node-local copy of the granule          (the honest baseline)
#   cliofs  the same bytes staged into clio-fs      (what is being tested)
#   shared  /mnt/common original                    (context only)
#
# The baseline reads a NODE-LOCAL copy, not /mnt/common: comparing a clio
# RAM/NVMe tier against shared storage would measure the network, not the tier.
# That is the same discipline as tf_clio_run.sbatch.
#
# Submit:
#   sbatch bin/tf_cliofs_discrepancy.sbatch
#   sbatch --export=ALL,REPS=5,STAGE=0 bin/tf_cliofs_discrepancy.sbatch
# =============================================================================
#SBATCH --job-name=tf_cliofs
#SBATCH --nodes=1
#SBATCH --exclusive
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=40
#SBATCH --partition=compute
#SBATCH --time=02:00:00
#SBATCH --output=/home/hyoklee/logs/tf_cliofs_%j.log

set -uo pipefail

P=${PREFIX:-/mnt/common/hyoklee/opt/clio-core}
H5=/mnt/common/hyoklee/opt/hdf5-develop
MPI=/mnt/repo/software/modules-install/mpich/4.1.1
SPACK_FUSE=/mnt/repo/software/spack/spack/opt/spack/linux-ubuntu22.04-skylake_avx512/gcc-11.4.0/libfuse-3.16.2-qt4vscda64u35pbekhasgf74uafzwvpe
FUSE_BIN=${FUSE_BIN:-$HOME/src/hyoklee/core/build-vol/bin/clio_cte_fuse}
BENCH=${BENCH:-/mnt/common/hyoklee/tfwork/tf_vol_read}
GRAN=/mnt/common/datasets-staging/TERRA_BF_L1B_O10204_20011118010522_F000_V001.h5
REPS=${REPS:-3}
STAGE=${STAGE:-1}
PORT=${PORT:-9841}

# Node-local scratch. /mnt/nvme is what tf_clio_run.sbatch used; fall back to
# /tmp so the job still runs on a node without it rather than silently
# benchmarking shared storage as if it were local.
for cand in /mnt/nvme /mnt/local /tmp; do
  [ -d "$cand" ] && [ -w "$cand" ] && { LOCAL_ROOT=$cand; break; }
done
WORK=$LOCAL_ROOT/hyoklee/tf_cliofs_$SLURM_JOB_ID
MNT=$WORK/mnt; BASE=$WORK/base; TIER=$WORK/tier
export CLIO_MEMFD_DIR=$WORK/memfd

echo "# node        : $(hostname)"
echo "# local root  : $LOCAL_ROOT"
echo "# clio prefix : $P"
echo "# reps        : $REPS   stage granule: $STAGE"
df -hT "$LOCAL_ROOT" | tail -1
free -g | head -2

cleanup() {
  echo "# --- teardown"
  fusermount3 -u "$MNT" 2>/dev/null
  sleep 2
  for p in $(pgrep -x clio_cte_fuse -u "$(id -u)" 2>/dev/null); do kill -9 "$p"; done
  for p in $(pgrep -x clio_run     -u "$(id -u)" 2>/dev/null); do kill -9 "$p"; done
  sleep 1
  # The 33 GB copies are node-local and this node is exclusive to the job.
  [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
}
trap cleanup EXIT

mkdir -p "$MNT" "$BASE" "$TIER" "$CLIO_MEMFD_DIR" || exit 1

# ---- runtime config: 8 GB RAM tier + 60 GB node-local disk tier -------------
python3 - "$P/data/clio_default.yaml" "$WORK/rt.yaml" "$TIER/cte_disk.dat" "$PORT" <<'PY'
import re, sys
src, dst, tierpath, port = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
s = open(src).read()
s = s.replace('capacity: "0g"', 'capacity: "8GB"', 1)
s = s.replace('capacity_limit: "0g"', 'capacity_limit: "8GB"', 1)
s = s.replace('${HOME}/.clio/cte_disk_tier.dat', tierpath)
s = s.replace('capacity_limit: "10GB"', 'capacity_limit: "60GB"', 1)
s = re.sub(r'^(\s*port:)\s*9413', r'\g<1> ' + port, s, count=1, flags=re.M)
open(dst, 'w').write(s)
PY

export LD_LIBRARY_PATH=$P/lib:$H5/lib:$MPI/lib:$SPACK_FUSE/lib
export CLIO_SERVER_CONF=$WORK/rt.yaml
# The DISTRO fusermount3 is setuid; spack's is not, and spack's alone fails
# with EPERM. Keep /usr/bin ahead of the spack bin dir.
export PATH=/usr/bin:/bin:$SPACK_FUSE/bin:$H5/bin
ulimit -n "$(ulimit -Hn)" 2>/dev/null

echo "# --- start runtime"
RTLOG=$WORK/rt.log
setsid nohup "$P/bin/clio_run" start > "$RTLOG" 2>&1 &
for i in $(seq 1 120); do
  grep -q "pools created successfully" "$RTLOG" 2>/dev/null \
    && [ -e "$CLIO_MEMFD_DIR/chi_main_segment_$(id -un)_${PORT}" ] \
    && { echo "# runtime ready after ${i}s"; break; }
  sleep 1
done
grep -q "pools created successfully" "$RTLOG" || { echo "!!! runtime failed"; tail -20 "$RTLOG"; exit 1; }

echo "# --- mount clio-fs"
FLOG=$WORK/fuse.log
setsid nohup "$FUSE_BIN" "$MNT" > "$FLOG" 2>&1 &
for i in $(seq 1 60); do
  mount | grep -q "$MNT" && { echo "# mounted after ${i}s"; break; }
  sleep 1
done
mount | grep -q "$MNT" || { echo "!!! mount failed"; tail -20 "$FLOG"; exit 1; }

if [ "$STAGE" = "1" ]; then
  echo "# --- stage granule (32.9 GB) to node-local baseline"
  t0=$SECONDS; cp "$GRAN" "$BASE/" || exit 1
  echo "# base copy: $((SECONDS-t0))s"
  echo "# --- stage granule into clio-fs"
  t0=$SECONDS; cp "$BASE/$(basename $GRAN)" "$MNT/" || { echo "!!! stage to clio-fs failed"; tail -20 "$FLOG"; exit 1; }
  echo "# clio-fs stage: $((SECONDS-t0))s"
fi
ls -la "$MNT" | head -3

echo
echo "# ==== interleaved A/B/C, $REPS reps ===="
echo "rep,path,modis_band,misr_full,modis_geo,total"
for r in $(seq 1 "$REPS"); do
  for path in base cliofs shared; do
    case $path in
      base)   f=$BASE/$(basename $GRAN) ;;
      cliofs) f=$MNT/$(basename $GRAN) ;;
      shared) f=$GRAN ;;
    esac
    out=$(timeout 3600 "$BENCH" "$f" 2>/dev/null)
    row=$(echo "$out" | awk -F, '/^modis_band|^misr_full|^modis_geo|^TOTAL/{printf "%s,",$2}')
    echo "$r,$path,${row%,}"
  done
done
echo "TF-CLIOFS-DONE"
