#!/bin/bash
# OMNI dataset_filter sweep, ISOLATED and with a FRESH RUNTIME PER CELL.
#
# Supersedes tf_cae_sweep.sh. Two controls that its results lacked, each of
# which independently invalidated the earlier numbers:
#
#   1. PRIVATE PORT. clio_default.yaml binds 9413, and on a shared machine
#      another user's runtime may already hold it -- a client will then talk to
#      THEIR runtime and THEIR tier. Uses a private networking.port and a
#      private CLIO_MEMFD_DIR.
#   2. FRESH RUNTIME PER CELL. The CTE tier accumulates across ingests, so a
#      later cell can fail on a tier that earlier cells filled. This restarts
#      clio_run before every measurement.
#
# Telemetry is set on the RUNTIME, not the client: the assimilator runs
# server-side, so CLIO_CAE_TELEMETRY on clio_cae silently produces nothing.
set -u

P=${CLIO:-/mnt/common/hyoklee/opt/clio-core}
G=${GRANULE:-/mnt/common/datasets-staging/TERRA_BF_L1B_O10204_20011118010522_F000_V001.h5}
PORT_BASE=${PORT_BASE:-9713}
PORT=$PORT_BASE          # advanced per cell; see below
WORK=${WORK:-$PWD/cae_clean}
REPS=${REPS:-3}
RAM_TIER=${RAM_TIER:-4GB}
CTE_TIER=${CTE_TIER:-24GB}

mkdir -p "$WORK"; cd "$WORK" || exit 1
export CLIO_MEMFD_DIR=$WORK/memfd
sed -e "s/capacity: \"0g\"/capacity: \"$RAM_TIER\"/" \
    -e "s/capacity_limit: \"0g\"/capacity_limit: \"$CTE_TIER\"/" \
    -e "s/^\( *port:\) *9413/\1 $PORT/" \
    "$P/data/clio_default.yaml" > rt.yaml

kill_mine() { for p in $(pgrep -x clio_run -u "$(id -u)" 2>/dev/null); do kill -9 "$p" 2>/dev/null; done; }

# Shared-memory segment names embed the port (chi_main_segment_<user>_<port>),
# so reusing one port across cells lets a stale segment from the previous
# runtime collide with the next -- the client then dies with
# "shm_attach(chi_main_segment_..._<port>) failed". Each cell gets its own port
# and its own segment namespace.
next_port() { PORT=$((PORT + 1)); sed -i "s/^\( *port:\) *[0-9]*/\1 $PORT/" "$WORK/rt.yaml"; }

purge_shm() {
  for f in /dev/shm/chi_*_"$(id -un)"_* /dev/shm/clio-*; do
    [ -e "$f" ] && rm -rf "$f" 2>/dev/null
  done
  return 0
}

start_runtime() {                      # $1 = telemetry path
  kill_mine
  purge_shm
  # Wait for the port to actually be released. After a heavy ingest the socket
  # lingers past SIGKILL, and the next runtime then dies with
  # "local server port is already bound" -- which is how the geo cell was lost
  # on the first clean run.
  for _ in $(seq 1 60); do
    ss -ltn 2>/dev/null | grep -q ":$PORT\b" || break
    sleep 1
  done
  sleep 2
  rm -rf "$CLIO_MEMFD_DIR"; mkdir -p "$CLIO_MEMFD_DIR"
  # A UNIQUE log per start. Reusing one rt.log lets the readiness grep match the
  # PREVIOUS start's "pools created successfully" before the shell truncates the
  # file -- a false ready, after which the client attaches to a segment that does
  # not exist yet and dies with
  #   shm_open failed: No such file or directory
  #   shm_attach(main='chi_main_segment_<user>_<port>') failed
  RTLOG=$WORK/rt_${PORT}_$(date +%s%N).log
  ln -sf "$RTLOG" "$WORK/rt.log"
  CLIO_SERVER_CONF=$WORK/rt.yaml CLIO_MEMFD_DIR=$CLIO_MEMFD_DIR \
    CLIO_CAE_TELEMETRY="$1" LD_LIBRARY_PATH=$P/lib \
    setsid nohup "$P/bin/clio_run" start > "$RTLOG" 2>&1 &
  # The segments are NOT POSIX shm objects in /dev/shm. On Linux they are
  # memfds, published in CLIO_MEMFD_DIR as symlinks into /proc/<pid>/fd:
  #     chi_main_segment_<user>_<port> -> /proc/<runtime pid>/fd/5
  # `-e` FOLLOWS the symlink, so it is false both when the link is absent and
  # when the owning runtime has died leaving it dangling -- which are precisely
  # the two states that make a client fail with
  #     shm_open failed: No such file or directory
  local seg="$CLIO_MEMFD_DIR/chi_main_segment_$(id -un)_${PORT}"
  for _ in $(seq 1 120); do
    # Belt and braces: the log line AND the segment actually existing. The log
    # alone is not proof the client can attach.
    if grep -q "pools created successfully" "$RTLOG" 2>/dev/null && [ -e "$seg" ]; then
      sleep 1; return 0
    fi
    sleep 1
  done
  echo "    start_runtime: timeout (log_ready=$(grep -qc 'pools created successfully' "$RTLOG" 2>/dev/null || echo 0) seg_exists=$([ -e "$seg" ] && echo 1 || echo 0))" >&2
  return 1
}

cfg() {                                # $1 = tag, $2 = pattern
  cat > "job_$1.yaml" <<EOF
version: "1.0"
transfers:
  - name: "t_$1"
    src: "hdf5::$G"
    dst: "iowarp::c_$1"
    format: "hdf5"
    depends_on: ""
    range_off: 0
    range_size: 0
    dataset_filter:
      include_patterns:
        - "$2"
EOF
}

med() { printf '%s\n' "$@" | sort -g | awk 'NR==int((NF+1)/2)+0{}{a[NR]=$1} END{print a[int((NR+1)/2)]}'; }

echo "# isolated port $PORT, fresh runtime per cell, tiers $RAM_TIER/$CTE_TIER, reps=$REPS"
echo "tag,pattern,median_s,exit,tasks,discovered,filtered,errors"
for spec in \
  "one:/ASTER/granule_11182001013943/TIR/ImageData10" \
  "tir:/ASTER/*/TIR/ImageData10" \
  "swirexp:/ASTER/*/SWIR/ImageData4" \
  "tirall:/ASTER/*/TIR/*" \
  "swir:/ASTER/*/SWIR/*" \
  "geo:*/Geolocation/*" ; do
  tag=${spec%%:*}; pat=${spec#*:}
  # TAGS="swir geo" restricts the sweep to named cells
  if [ -n "${TAGS:-}" ]; then case " $TAGS " in *" $tag "*) ;; *) continue ;; esac; fi
  next_port
  cfg "$tag" "$pat"
  times=(); last_exit=0; last_tasks="?"
  for r in $(seq "$REPS"); do
    rm -f "tele_$tag.jsonl"
    start_runtime "$WORK/tele_$tag.jsonl" || { echo "$tag,\"$pat\",,RUNTIME_FAIL,,,,"; continue 2; }
    s=$(date +%s.%N)
    env -u CONDA_PREFIX LD_LIBRARY_PATH=$P/lib CLIO_SERVER_CONF=$WORK/rt.yaml \
      CLIO_MEMFD_DIR=$CLIO_MEMFD_DIR timeout 900 "$P/bin/clio_cae" "job_$tag.yaml" \
      > "out_$tag.log" 2>&1
    last_exit=$?
    times+=("$(python3 -c "print(f'{$(date +%s.%N)-$s:.2f}')")")
    last_tasks=$(grep -aoE "Tasks scheduled: [0-9]+" "out_$tag.log" | tail -1 | grep -oE "[0-9]+")
  done
  sleep 10   # assimilation is async; let the telemetry record land
  read -r disc filt errs <<<"$(python3 - "tele_$tag.jsonl" <<'PY'
import json,sys
try:
    r=[json.loads(l) for l in open(sys.argv[1])][-1]
    print(r['datasets_discovered'], r['datasets_filtered'], r['dataset_errors'])
except Exception:
    print('?','?','?')
PY
)"
  echo "$tag,\"$pat\",$(med "${times[@]}"),${last_exit},${last_tasks:-?},$disc,$filt,$errs"
done
kill_mine
echo "CAE-CLEAN-SWEEP-DONE"
