#!/bin/bash
# OMNI dataset_filter sweep via clio_cae (the LIVE tool; wrp in ~/cae/omni is
# deprecated and commented out of clio-core's build).
#
# PREREQUISITE: the runtime must compose a clio_cae_core pool, or clio_cae busy-
# polls forever with no error -- last log line "Calling ParseOmni...".
P=${CLIO:-/mnt/common/hyoklee/opt/clio-core}
G=${GRANULE:-/mnt/common/datasets-staging/TERRA_BF_L1B_O10204_20011118010522_F000_V001.h5}
RT=${CLIO_SERVER_CONF:?set CLIO_SERVER_CONF to a config composing clio_cae_core}
run() { # $1 tag  $2 pattern
  cat > /tmp/cae_$1.yaml <<EOF
version: "1.0"
transfers:
  - name: "t_$1"
    src: "hdf5::$G"
    dst: "iowarp::sw_$1"
    format: "hdf5"
    depends_on: ""
    range_off: 0
    range_size: 0
    dataset_filter:
      include_patterns:
        - "$2"
EOF
  S=$(date +%s.%N)
  env -u CONDA_PREFIX LD_LIBRARY_PATH=$P/lib CLIO_SERVER_CONF=$RT \
    timeout 900 $P/bin/clio_cae /tmp/cae_$1.yaml > /tmp/cae_$1.log 2>&1
  T=$(python3 -c "print(f'{$(date +%s.%N)-$S:.2f}')")
  N=$(grep -aoE "Tasks scheduled: [0-9]+" /tmp/cae_$1.log | tail -1 | grep -oE "[0-9]+")
  echo "$1,\"$2\",$T,${N:-?}"
}
echo "tag,pattern,seconds,tasks_scheduled"
run one     "/ASTER/granule_11182001013943/TIR/ImageData10"
run tir     "/ASTER/*/TIR/ImageData10"
run swirexp "/ASTER/*/SWIR/ImageData4"
run swir    "/ASTER/*/SWIR/*"
run geo     "*/Geolocation/*"
