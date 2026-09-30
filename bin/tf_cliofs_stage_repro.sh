#!/bin/bash
# Minimal reproducer for the clio_run abort seen staging into clio-fs.
#
# Job 24279 on ares-comp-10 died with glibc's "corrupted size vs. prev_size"
# after ~27 GiB of a 32.9 GB stage, leaving the FUSE mount wedged and cp blocked
# for 59 minutes. The same 32.9 GB staged fine on the login node, so the trigger
# is not simply the size.
#
# This strips the case to its bones: no granule, no HDF5, no benchmark -- mount
# clio-fs and write synthetic data into it in chunks until either the target is
# reached or the runtime dies, reporting the exact byte count at death. Every
# variable that differed between the working and failing runs is a knob, so the
# trigger can be bisected:
#
#   RAM_TIER   RAM tier capacity          (login 8GB,  comp 8GB)
#   DISK_TIER  file tier capacity         (login 60GB, comp 304GB)
#   TIER_DIR   where the file tier lives  (login /mnt/common, comp /mnt/ssd)
#   TOTAL_GB   how much to write          (crash seen at ~27 GiB)
#   CHUNK_MB   write granularity
#
# Usage:
#   TOTAL_GB=35 DISK_TIER=304GB bash bin/tf_cliofs_stage_repro.sh
set -uo pipefail

P=${PREFIX:-/mnt/common/hyoklee/opt/clio-core}
H5=/mnt/common/hyoklee/opt/hdf5-develop
MPI=/mnt/repo/software/modules-install/mpich/4.1.1
SPACK_FUSE=/mnt/repo/software/spack/spack/opt/spack/linux-ubuntu22.04-skylake_avx512/gcc-11.4.0/libfuse-3.16.2-qt4vscda64u35pbekhasgf74uafzwvpe
FUSE_BIN=${FUSE_BIN:-$HOME/src/hyoklee/core/build-vol/bin/clio_cte_fuse}
DISTRO_FUSE=${DISTRO_FUSE:-/usr/lib/x86_64-linux-gnu/libfuse3.so.3}

WORK=${WORK:-/mnt/common/hyoklee/tfwork/repro_$$}
TIER_DIR=${TIER_DIR:-$WORK/tier}
RAM_TIER=${RAM_TIER:-8GB}
DISK_TIER=${DISK_TIER:-304GB}
TOTAL_GB=${TOTAL_GB:-35}
CHUNK_MB=${CHUNK_MB:-512}
PORT=${PORT:-9851}

MNT=$WORK/mnt
export CLIO_MEMFD_DIR=$WORK/memfd
mkdir -p "$MNT" "$TIER_DIR" "$CLIO_MEMFD_DIR" || exit 1

echo "# host      : $(hostname)   RAM $(free -g | awk 'NR==2{print $2}') GiB"
echo "# ram tier  : $RAM_TIER     disk tier: $DISK_TIER at $TIER_DIR"
echo "# target    : ${TOTAL_GB} GiB in ${CHUNK_MB} MiB chunks"
df -PT "$TIER_DIR" | tail -1

cleanup() {
  fusermount3 -u "$MNT" 2>/dev/null
  sleep 1
  for p in $(pgrep -x clio_cte_fuse -u "$(id -u)" 2>/dev/null); do kill -9 "$p"; done
  for p in $(pgrep -x clio_run     -u "$(id -u)" 2>/dev/null); do kill -9 "$p"; done
  sleep 1
  [ "${KEEP:-0}" = "1" ] || rm -rf "$WORK"
}
trap cleanup EXIT

python3 - "$P/data/clio_default.yaml" "$WORK/rt.yaml" "$TIER_DIR/cte_disk.dat" \
          "$PORT" "$RAM_TIER" "$DISK_TIER" <<'PY'
import re, sys
src, dst, tierpath, port, ram, disk = sys.argv[1:7]
s = open(src).read()
s = s.replace('capacity: "0g"', 'capacity: "%s"' % ram, 1)
s = s.replace('capacity_limit: "0g"', 'capacity_limit: "%s"' % ram, 1)
s = s.replace('${HOME}/.clio/cte_disk_tier.dat', tierpath)
s = s.replace('capacity_limit: "10GB"', 'capacity_limit: "%s"' % disk, 1)
s = re.sub(r'^(\s*port:)\s*9413', r'\g<1> ' + port, s, count=1, flags=re.M)
open(dst, 'w').write(s)
PY

export LD_LIBRARY_PATH=$P/lib:$H5/lib:$MPI/lib:$SPACK_FUSE/lib
export CLIO_SERVER_CONF=$WORK/rt.yaml
export PATH=/usr/bin:/bin:$SPACK_FUSE/bin
ulimit -n "$(ulimit -Hn)" 2>/dev/null

for p in $(pgrep -x clio_run -u "$(id -u)" 2>/dev/null); do kill -9 "$p"; done
sleep 1
RTLOG=$WORK/rt.log
setsid nohup "$P/bin/clio_run" start > "$RTLOG" 2>&1 &
for i in $(seq 1 120); do
  grep -q "pools created successfully" "$RTLOG" 2>/dev/null \
    && [ -e "$CLIO_MEMFD_DIR/chi_main_segment_$(id -un)_${PORT}" ] && break
  sleep 1
done
grep -q "pools created successfully" "$RTLOG" || { echo "!!! runtime failed to start"; tail -10 "$RTLOG"; exit 1; }
RT_PID=$(pgrep -x clio_run -u "$(id -u)" | head -1)
echo "# runtime pid $RT_PID"

[ -e "$DISTRO_FUSE" ] && export LD_PRELOAD=$DISTRO_FUSE
setsid nohup "$FUSE_BIN" "$MNT" -f > "$WORK/fuse.log" 2>&1 &
for i in $(seq 1 60); do mountpoint -q "$MNT" && break; sleep 1; done
mountpoint -q "$MNT" || { echo "!!! mount failed"; tail -10 "$WORK/fuse.log"; exit 1; }
unset LD_PRELOAD
echo "# mounted"

# Write in chunks with a per-chunk timeout, so a wedged mount reports rather
# than hanging the way job 24279 did for 59 minutes.
CHUNKS=$(( TOTAL_GB * 1024 / CHUNK_MB ))
OUT=$MNT/stage.bin
written=0
t0=$SECONDS
for c in $(seq 1 "$CHUNKS"); do
  if ! timeout 120 dd if=/dev/zero of="$OUT" bs=1M count="$CHUNK_MB" \
        seek=$(( (c-1) * CHUNK_MB )) conv=notrunc 2>/dev/null; then
    echo "!!! dd FAILED or timed out at chunk $c (${written} MiB written, $((SECONDS-t0))s)"
    break
  fi
  written=$(( c * CHUNK_MB ))
  if ! kill -0 "$RT_PID" 2>/dev/null; then
    echo "!!! RUNTIME DIED after ${written} MiB ($(echo "scale=2; $written/1024" | bc) GiB), $((SECONDS-t0))s"
    break
  fi
  [ $(( c % 8 )) -eq 0 ] && echo "#   ${written} MiB ok ($((SECONDS-t0))s)"
done

echo
if kill -0 "$RT_PID" 2>/dev/null; then
  echo "RESULT: runtime SURVIVED ${written} MiB in $((SECONDS-t0))s"
else
  echo "RESULT: runtime DIED at ${written} MiB"
fi
echo "--- runtime abort signature (if any):"
grep -aiE "corrupted|Aborted|malloc|free\(\)|stack smashing|double free" "$RTLOG" | tail -5
echo "--- tier file:"
ls -la "$TIER_DIR" 2>/dev/null | tail -2
echo "REPRO-DONE"
