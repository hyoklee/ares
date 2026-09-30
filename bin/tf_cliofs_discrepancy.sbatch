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
#   shared  /mnt/common original                    (what clio-fs would replace)
#
# On a COMPUTE node /mnt/common is NFS (172.25.1.1:/mnt/common), not the local
# xfs it is on the login node. That makes the third arm the realistic case for
# a burst buffer -- shared storage is what a tier exists to sit in front of --
# rather than the afterthought it was on the login node.
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

# ---- node-local scratch selection -------------------------------------------
# A candidate must be writable, NODE-LOCAL, and big enough. The original version
# of this block checked only the first two of those -- in fact only existence
# and writability -- and on a node without /mnt/nvme it fell through to /tmp,
# which on ares-comp-31 is a 13 GB ext4 root. Against a 32.9 GB granule that
# either dies mid-copy or, worse, leaves a truncated file that still opens far
# enough to produce timings. Two further faults in the same three lines: a
# shared filesystem would have been accepted silently, making the "node-local
# baseline" a measurement of the network instead; and LOCAL_ROOT was never
# initialised, so under `set -u` a total miss crashed with an unbound-variable
# error rather than saying what was wrong.
#
# Space needed: STAGE=1 writes the granule TWICE under $WORK -- once as the
# node-local baseline copy, once into the clio tier -- so budget 2x plus 10%.
GRAN_BYTES=$(stat -c %s "$GRAN" 2>/dev/null) || { echo "!!! cannot stat $GRAN"; exit 1; }
if [ "$STAGE" = "1" ]; then
  NEED_KB=$(( GRAN_BYTES / 1024 * 22 / 10 ))
else
  NEED_KB=$(( GRAN_BYTES / 1024 * 11 / 10 ))
fi
echo "# granule      : $((GRAN_BYTES/1024/1024/1024)) GiB"
echo "# space needed : $((NEED_KB/1024/1024)) GiB on node-local scratch (STAGE=$STAGE)"

LOCAL_ROOT=""
# Ordered fastest-first. /mnt/ssd and /mnt/hdd were missing from this list and
# are the only node-local filesystems on ares compute nodes big enough for the
# 2x granule this job writes: ares-comp-19 has nvme 81 GiB, ssd 474 GiB, hdd
# 819 GiB. nvme alone is marginal and was below the bar on the node job 24274
# landed on (47 GiB free).
for cand in ${LOCAL_CANDIDATES:-/mnt/nvme /mnt/ssd /mnt/hdd /mnt/local /mnt/scratch /scratch /tmp}; do
  [ -d "$cand" ] || { echo "#   $cand: absent"; continue; }
  # Probe the path we would ACTUALLY use, not the mount root. /mnt/nvme is
  # root-owned drwxr-xr-x while /mnt/nvme/hyoklee is the user's and writable,
  # so testing `-w` on the root alone rejects the one suitable filesystem on
  # this cluster -- which is exactly what job 24272 did.
  probe=$cand/$(id -un)
  if ! mkdir -p "$probe" 2>/dev/null || [ ! -w "$probe" ]; then
    echo "#   $cand: cannot create or write $probe"; continue
  fi
  fstype=$(df -PT "$probe" 2>/dev/null | awk 'NR==2{print $2}')
  case "$fstype" in
    nfs|nfs4|lustre|gpfs|cifs|smb*|fuse.*|beegfs|panfs)
      echo "#   $cand: $fstype is NOT node-local -- skipped"; continue ;;
  esac
  availkb=$(df -Pk "$probe" 2>/dev/null | awk 'NR==2{print $4}')
  if [ -z "$availkb" ] || [ "$availkb" -lt "$NEED_KB" ]; then
    echo "#   $cand: $fstype, $((availkb/1024/1024)) GiB free < $((NEED_KB/1024/1024)) GiB needed -- skipped"
    continue
  fi
  echo "#   $cand: $fstype, $((availkb/1024/1024)) GiB free -- SELECTED"
  LOCAL_ROOT=$cand; LOCAL_AVAIL_KB=$availkb; break
done

if [ -z "$LOCAL_ROOT" ]; then
  echo "!!! no node-local filesystem with $((NEED_KB/1024/1024)) GiB free."
  echo "!!! Refusing to run: a smaller or shared filesystem would silently"
  echo "!!! benchmark the wrong thing. Options:"
  echo "!!!   STAGE=0            reuse an already-staged tier (halves the need)"
  echo "!!!   LOCAL_CANDIDATES=  point at a suitable path explicitly"
  echo "!!!   -w <node>          pick a node that has one"
  exit 1
fi

WORK=$LOCAL_ROOT/$(id -un)/tf_cliofs_$SLURM_JOB_ID
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
# Disk tier sized from what the selected filesystem actually has, less the
# baseline copy, rather than a fixed 60 GB that may not exist there.
DISK_TIER_GB=${DISK_TIER_GB:-$(( (LOCAL_AVAIL_KB/1024/1024 - GRAN_BYTES/1024/1024/1024) * 9 / 10 ))}
[ "$DISK_TIER_GB" -lt 1 ] && DISK_TIER_GB=1
echo "# disk tier    : ${DISK_TIER_GB} GB at $TIER"
python3 - "$P/data/clio_default.yaml" "$WORK/rt.yaml" "$TIER/cte_disk.dat" "$PORT" "$DISK_TIER_GB" <<'PY'
import re, sys
src, dst, tierpath, port, tiergb = sys.argv[1:6]
s = open(src).read()
s = s.replace('capacity: "0g"', 'capacity: "8GB"', 1)
s = s.replace('capacity_limit: "0g"', 'capacity_limit: "8GB"', 1)
s = s.replace('${HOME}/.clio/cte_disk_tier.dat', tierpath)
s = s.replace('capacity_limit: "10GB"', 'capacity_limit: "%sGB"' % tiergb, 1)
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
# LD_PRELOAD the DISTRO libfuse3. This build links spack's libfuse 3.16.2 while
# the setuid helper at /usr/bin/fusermount3 is 3.10.5, and the version mismatch
# makes the mount fail with "fusermount3: mount failed: Operation not
# permitted" -- which reads like a privilege problem and is not one. This is
# the same LD_PRELOAD tf_clio_run.sbatch has carried since September.
DISTRO_FUSE=${DISTRO_FUSE:-/usr/lib/x86_64-linux-gnu/libfuse3.so.3}
if [ -e "$DISTRO_FUSE" ]; then
  echo "# preloading $DISTRO_FUSE (spack libfuse would fail with EPERM)"
  export LD_PRELOAD=$DISTRO_FUSE
else
  echo "# WARNING: $DISTRO_FUSE absent; mount may fail with a misleading EPERM"
fi
setsid nohup "$FUSE_BIN" "$MNT" -f > "$FLOG" 2>&1 &
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

# The preload was only needed to mount; drop it so the benchmark runs in the
# same library environment as the login-node VOL/VFD measurements.
unset LD_PRELOAD

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
