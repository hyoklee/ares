#!/bin/bash
# Minimal reproducer: clio-fs silently returns wrong data.
#
# Writes N copies of the same file through a clio-fs mount and checksums each
# read-back. Some come back with the CORRECT SIZE and WRONG CONTENT. cp exits 0,
# nothing is logged by the runtime or the FUSE daemon, and the file system
# reports no error at any layer.
#
# Found while investigating why the clio-fs arm of the NVMe tier study returned
# 0.00 s: the staged HDF5 granule opened but contained zero MODIS granules,
# because its bytes were not the bytes that were written.
#
# Observed (login node, ares, clio-core dev @ 6cec5008):
#   fresh 8 GB RAM + 200 GB disk tier   1 of 12 corrupt   (~8%)
#   tier with prior traffic              3 of 14 corrupt   (~21%)
#   same, CLIO_FUSE_SIEVE=0              9 of 12 corrupt   (~75%)
#
# Corruption shape, measured on a 1 GiB file:
#   * exactly one 1 MiB region differs -- 1 MiB is kFsPageSize, the CTE page
#   * that page's first 128 KiB is correct; the remaining 896 KiB is not
#   * the bytes at page+128K are the bytes from page+0, i.e. a 128 KiB
#     sub-block appears twice. 128 KiB is cp's write size and equals
#     DeferRegistry::kBatchChunk.
#   * both PERSISTENT (still wrong minutes later) and TRANSIENT (correct on a
#     later read) instances occur, so at least the write path is affected and
#     possibly the read-your-writes path as well.
#
# Not exhaustion: it reproduces on a 200 GB tier holding 12 GB.
#
# Usage:
#   bash bin/tf_cliofs_corruption_repro.sh            # 12 x 1 GiB
#   SIZE_MB=512 N=20 bash bin/tf_cliofs_corruption_repro.sh
#   CLIO_FUSE_SIEVE=0 bash bin/tf_cliofs_corruption_repro.sh
set -uo pipefail

P=${PREFIX:-/mnt/common/hyoklee/opt/clio-core}
FUSE_BIN=${FUSE_BIN:-$HOME/src/hyoklee/core/build-vol/bin/clio_cte_fuse}
H5=/mnt/common/hyoklee/opt/hdf5-develop
MPI=/mnt/repo/software/modules-install/mpich/4.1.1
DISTRO_FUSE=${DISTRO_FUSE:-/usr/lib/x86_64-linux-gnu/libfuse3.so.3}
WORK=${WORK:-/mnt/common/hyoklee/tfwork/cliofs_repro_$$}
SIZE_MB=${SIZE_MB:-1024}
N=${N:-12}
RAM_TIER=${RAM_TIER:-8GB}
DISK_TIER=${DISK_TIER:-200GB}
PORT=${PORT:-9895}

MNT=$WORK/mnt
export CLIO_MEMFD_DIR=$WORK/memfd
mkdir -p "$MNT" "$WORK/tier" "$CLIO_MEMFD_DIR" || exit 1

cleanup() {
  fusermount3 -u "$MNT" 2>/dev/null; sleep 1
  for p in $(pgrep -x clio_cte_fuse -u "$(id -u)" 2>/dev/null); do kill -9 "$p"; done
  for p in $(pgrep -x clio_run     -u "$(id -u)" 2>/dev/null); do kill -9 "$p"; done
  sleep 1
  [ "${KEEP:-0}" = "1" ] || rm -rf "$WORK"
}
trap cleanup EXIT

# Template config: an install prefix keeps it under data/, a build tree under
# context-runtime/config/. CONF_TEMPLATE overrides both.
CONF_TEMPLATE=${CONF_TEMPLATE:-}
if [ -z "$CONF_TEMPLATE" ]; then
  for c in "$P/data/clio_default.yaml" \
           "$P/../context-runtime/config/clio_default.yaml" \
           "$HOME/src/hyoklee/core/context-runtime/config/clio_default.yaml"; do
    [ -f "$c" ] && { CONF_TEMPLATE=$c; break; }
  done
fi
[ -f "$CONF_TEMPLATE" ] || { echo "!!! no clio_default.yaml found; set CONF_TEMPLATE"; exit 1; }
echo "# config template: $CONF_TEMPLATE"

python3 - "$CONF_TEMPLATE" "$WORK/rt.yaml" "$WORK/tier/cte_disk.dat" \
         "$PORT" "$RAM_TIER" "$DISK_TIER" <<'PY'
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

# An install prefix puts libraries in lib/, a build tree in bin/. Include both,
# and point the chimod loader at the same place.
export LD_LIBRARY_PATH=$P/lib:$P/bin:$H5/lib:$MPI/lib
export CLIO_REPO_PATH=${CLIO_REPO_PATH:-$([ -d "$P/lib" ] && echo "$P/lib" || echo "$P/bin")}
export CLIO_SERVER_CONF=$WORK/rt.yaml
export PATH=/usr/bin:/bin

for p in $(pgrep -x clio_run -u "$(id -u)" 2>/dev/null); do kill -9 "$p"; done
sleep 2
setsid nohup "${CLIO_RUN:-$P/bin/clio_run}" start > "$WORK/rt.log" 2>&1 &
for i in $(seq 1 120); do
  grep -q "pools created successfully" "$WORK/rt.log" 2>/dev/null && break
  sleep 1
done

# The DISTRO libfuse3 must be preloaded: this build links spack's 3.16.2 while
# the setuid /usr/bin/fusermount3 is 3.10.5, and the mismatch surfaces as a
# misleading "Operation not permitted".
[ -e "$DISTRO_FUSE" ] && export LD_PRELOAD=$DISTRO_FUSE
setsid nohup "$FUSE_BIN" "$MNT" -f > "$WORK/fuse.log" 2>&1 &
for i in $(seq 1 60); do mountpoint -q "$MNT" && break; sleep 1; done
unset LD_PRELOAD
mountpoint -q "$MNT" || { echo "!!! mount failed"; tail -5 "$WORK/fuse.log"; exit 1; }

SRC=$WORK/src.bin
dd if=/dev/urandom of="$SRC" bs=1M count="$SIZE_MB" status=none
WANT=$(sha256sum "$SRC" | cut -d' ' -f1)
echo "# src $SIZE_MB MiB  sha $(echo "$WANT" | cut -c1-16)"
echo "# tier $RAM_TIER RAM + $DISK_TIER disk   sieve=${CLIO_FUSE_SIEVE:-default(on)}"
echo

bad=0
for i in $(seq 1 "$N"); do
  f=$MNT/r$i.bin
  cp "$SRC" "$f" 2>/dev/null
  rc=$?
  got=$(sha256sum "$f" 2>/dev/null | cut -d' ' -f1)
  sz=$(stat -c %s "$f" 2>/dev/null)
  if [ "$got" = "$WANT" ]; then
    echo "  $i: ok   (cp rc=$rc, size=$sz)"
  else
    bad=$((bad+1))
    echo "  $i: *** WRONG CONTENT ***  cp rc=$rc  size=$sz (correct)  sha=$(echo "$got" | cut -c1-16)"
  fi
done

echo
echo "RESULT: $bad of $N read back with the wrong content"
echo "# runtime errors logged: $(grep -aciE 'PutBlob failed|out of space|shortfall' "$WORK/rt.log" 2>/dev/null)"
echo "# tier usage: $(du -sh "$WORK/tier" 2>/dev/null | cut -f1) of $DISK_TIER"
