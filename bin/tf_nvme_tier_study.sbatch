#!/bin/bash
# Do the clio adapters pay off when the tier is node-local NVMe and the source
# is shared storage? Part 16 said no, but measured the wrong regime.
#
# Part 16 ran VOL and VFD on the LOGIN node, where /mnt/common is local XFS with
# 33 GB of page cache in front of it. That is the most hostile case a burst tier
# can face: the thing it replaces was already DRAM-fast. Its own admission gate
# measured that and declined to stage, which is correct behaviour and tells us
# nothing about the case the adapter exists for.
#
# On a COMPUTE node the picture inverts:
#   /mnt/common  is NFS (172.25.1.1)   <- slow, shared, what a tier would front
#   /mnt/nvme    is local NVMe          <- fast, private, where a tier belongs
#   /mnt/ssd     is local SATA SSD      <- local-disk reference point
#
# Phases, all reading the SAME 1318 MiB through the same binary
# (bin/tf_vol_discrepancy_read.c), cold unless marked warm. Cold means the
# source file's page cache is dropped with posix_fadvise(DONTNEED) first, which
# needs no privileges.
#
#   nfs_cold    read the granule over NFS, cache dropped   <- THE BASELINE
#   nfs_warm    read it again, cache hot                   <- upper bound of doing nothing
#   ssd_cold    read a node-local SSD copy, cache dropped  <- local-disk reference
#   vol         clio VOL, NVMe-backed tier, source on NFS
#   vfd         clio VFD, NVMe-backed tier, source on NFS
#   cliofs      clio-fs, NVMe-backed tier, granule staged in
#
# Then a tuning pass on whichever adapter shows promise.
#
# Submit:
#   sbatch bin/tf_nvme_tier_study.sbatch
#   sbatch --export=ALL,GRAN=...,REPS=5 bin/tf_nvme_tier_study.sbatch
#SBATCH --job-name=tf_nvme
#SBATCH --nodes=1
#SBATCH --exclusive
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=40
#SBATCH --partition=compute
#SBATCH --time=04:00:00
#SBATCH --output=/home/hyoklee/logs/tf_nvme_%j.log

set -uo pipefail

P=${PREFIX:-/mnt/common/hyoklee/opt/clio-core}
BUILD=${BUILD:-$HOME/src/hyoklee/core/build-cae-ci/bin}
H5=/mnt/common/hyoklee/opt/hdf5-develop
MPI=/mnt/repo/software/modules-install/mpich/4.1.1
SPACK_FUSE=/mnt/repo/software/spack/spack/opt/spack/linux-ubuntu22.04-skylake_avx512/gcc-11.4.0/libfuse-3.16.2-qt4vscda64u35pbekhasgf74uafzwvpe
BENCH=${BENCH:-/mnt/common/hyoklee/tfwork/tf_vol_read}
EVICT=${EVICT:-$HOME/src/hyoklee/ares/bin/tf_evict.py}
FUSE_BIN=${FUSE_BIN:-$HOME/src/hyoklee/core/build-vol/bin/clio_cte_fuse}
GRAN=${GRAN:-/mnt/common/datasets-staging/TERRA_BF_L1B_O10204_20011118010522_F000_V001.h5}
REPS=${REPS:-3}
PORT=${PORT:-9881}
PY=${PY:-$HOME/src/hyoklee/ares/.venv-tf/bin/python3}

NVME=/mnt/nvme/$(id -un)/tf_nvme_$SLURM_JOB_ID      # the DEVICE UNDER TEST: tiers
SSDD=/mnt/ssd/$(id -un)/tf_nvme_$SLURM_JOB_ID       # bulk: local baseline copy
export CLIO_MEMFD_DIR=$NVME/memfd
MNT=$NVME/mnt

echo "# node $(hostname)   $(free -g | awk 'NR==2{print $2}') GiB RAM"
echo "# granule $(basename "$GRAN")  $(stat -c %s "$GRAN") bytes"
df -PT "$GRAN" | tail -1 | awk '{print "# source  : "$2" on "$1}'
df -PT /mnt/nvme | tail -1 | awk '{print "# tier dev: "$2" "$5" free on "$1}'
for d in "$NVME" "$SSDD" "$MNT" "$CLIO_MEMFD_DIR" "$NVME/tier"; do mkdir -p "$d" || exit 1; done

cleanup() {
  fusermount3 -u "$MNT" 2>/dev/null; sleep 1
  for p in $(pgrep -x clio_cte_fuse -u "$(id -u)" 2>/dev/null); do kill -9 "$p"; done
  for p in $(pgrep -x clio_run     -u "$(id -u)" 2>/dev/null); do kill -9 "$p"; done
  sleep 1
  rm -rf "$NVME" "$SSDD"
}
trap cleanup EXIT

export LD_LIBRARY_PATH=$BUILD:$P/lib:$H5/lib:$MPI/lib:$SPACK_FUSE/lib
export PATH=/usr/bin:/bin:$SPACK_FUSE/bin:$H5/bin
ulimit -n "$(ulimit -Hn)" 2>/dev/null

mkconf() {  # $1 = tier path, $2 = ram cap, $3 = disk cap
  "$PY" - "$P/data/clio_default.yaml" "$NVME/rt.yaml" "$1" "$PORT" "$2" "$3" <<'PY'
import re, sys
src, dst, tier, port, ram, disk = sys.argv[1:7]
s = open(src).read()
s = s.replace('capacity: "0g"', 'capacity: "%s"' % ram, 1)
s = s.replace('capacity_limit: "0g"', 'capacity_limit: "%s"' % ram, 1)
s = s.replace('${HOME}/.clio/cte_disk_tier.dat', tier)
s = s.replace('capacity_limit: "10GB"', 'capacity_limit: "%s"' % disk, 1)
s = re.sub(r'^(\s*port:)\s*9413', r'\g<1> ' + port, s, count=1, flags=re.M)
open(dst, 'w').write(s)
PY
}

start_rt() {
  for p in $(pgrep -x clio_run -u "$(id -u)" 2>/dev/null); do kill -9 "$p"; done
  sleep 2; rm -rf "$CLIO_MEMFD_DIR"; mkdir -p "$CLIO_MEMFD_DIR"
  RTLOG=$NVME/rt_$(date +%s%N).log
  CLIO_SERVER_CONF=$NVME/rt.yaml setsid nohup "$P/bin/clio_run" start > "$RTLOG" 2>&1 &
  for i in $(seq 1 120); do
    grep -q "pools created successfully" "$RTLOG" 2>/dev/null \
      && [ -e "$CLIO_MEMFD_DIR/chi_main_segment_$(id -un)_${PORT}" ] && return 0
    sleep 1
  done
  echo "    !!! runtime failed"; tail -5 "$RTLOG"; return 1
}

run() {  # $1 label, $2 file, $3 cold(1/0); rest = env assignments
  local label=$1 file=$2 cold=$3; shift 3
  local t
  [ "$cold" = "1" ] && "$PY" "$EVICT" "$file" 2>/dev/null
  t=$(env "$@" timeout 3600 "$BENCH" "$file" 2>/dev/null \
        | awk -F, '/^TOTAL/{printf "%.2f", $2}')
  echo "${t:-FAIL}"
}

echo
echo "phase,rep,seconds"

# ---- A: the baseline -- read it over NFS -----------------------------------
for r in $(seq 1 "$REPS"); do echo "nfs_cold,$r,$(run nfs_cold "$GRAN" 1 CLIO_X=0)"; done
for r in $(seq 1 "$REPS"); do echo "nfs_warm,$r,$(run nfs_warm "$GRAN" 0 CLIO_X=0)"; done

# ---- B: local-disk reference ------------------------------------------------
cp "$GRAN" "$SSDD/g.h5" || exit 1
for r in $(seq 1 "$REPS"); do echo "ssd_cold,$r,$(run ssd_cold "$SSDD/g.h5" 1 CLIO_X=0)"; done

# ---- C: clio VOL, NVMe tier, NFS source ------------------------------------
mkconf "$NVME/tier/cte_disk.dat" 8GB 40GB
start_rt || exit 1
for mode in "default:" "readmiss:CLIO_VOL_ADMIT=read-miss" "forced:CLIO_VOL_ADMIT=read-miss CLIO_VOL_ADMIT_COST=0"; do
  lbl=${mode%%:*}; envs=${mode#*:}
  for r in $(seq 1 "$REPS"); do
    echo "vol_${lbl},$r,$(run vol "$GRAN" 1 HDF5_VOL_CONNECTOR=clio HDF5_PLUGIN_PATH=$P/lib \
        CLIO_SERVER_CONF=$NVME/rt.yaml CLIO_MEMFD_DIR=$CLIO_MEMFD_DIR $envs)"
  done
done

# ---- D: clio VFD, NVMe tier -------------------------------------------------
for cfg in "default:" "readtier:CLIO_VFD_READ_TIER=1"; do
  lbl=${cfg%%:*}; envs=${cfg#*:}
  for r in $(seq 1 "$REPS"); do
    echo "vfd_${lbl},$r,$(run vfd "$GRAN" 1 HDF5_DRIVER=clio_vfd HDF5_PLUGIN_PATH=$P/lib \
        CLIO_SERVER_CONF=$NVME/rt.yaml CLIO_MEMFD_DIR=$CLIO_MEMFD_DIR $envs)"
  done
done

# ---- E: clio-fs, NVMe tier --------------------------------------------------
DISTRO_FUSE=/usr/lib/x86_64-linux-gnu/libfuse3.so.3
[ -e "$DISTRO_FUSE" ] && export LD_PRELOAD=$DISTRO_FUSE
setsid nohup env CLIO_SERVER_CONF=$NVME/rt.yaml CLIO_MEMFD_DIR=$CLIO_MEMFD_DIR \
  "$FUSE_BIN" "$MNT" -f > "$NVME/fuse.log" 2>&1 &
for i in $(seq 1 60); do mountpoint -q "$MNT" && break; sleep 1; done
unset LD_PRELOAD
if mountpoint -q "$MNT"; then
  t0=$SECONDS
  if cp "$GRAN" "$MNT/g.h5"; then
    echo "# clio-fs stage: $((SECONDS-t0))s"
    for r in $(seq 1 "$REPS"); do
      echo "cliofs,$r,$(run cliofs "$MNT/g.h5" 0 CLIO_SERVER_CONF=$NVME/rt.yaml \
          CLIO_MEMFD_DIR=$CLIO_MEMFD_DIR)"
    done
  else
    echo "# clio-fs stage FAILED"; tail -3 "$NVME/fuse.log"
  fi
else
  echo "# clio-fs mount FAILED"; tail -5 "$NVME/fuse.log"
fi

echo "TF-NVME-DONE"
