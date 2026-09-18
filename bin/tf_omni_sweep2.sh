#!/bin/bash
# Real OMNI sweep against the rebuilt (HDF5-enabled) wrp.
# Config form that the code actually reads: TOP-LEVEL src:, URI hdf5://<file.h5>/<dataset>
cd "$(dirname "$0")" || exit 1
W=/home/hyoklee/cae/omni/build-hdf5/wrp          # Release = quiet
G=/mnt/common/datasets-staging/TERRA_BF_L1B_O10204_20011118010522_F000_V001.h5
DS=MISR/AN/Data_Fields/Red_Radiance
E="env -u LD_LIBRARY_PATH -u CONDA_PREFIX"
echo "nblocks,MiB,max_scale,seconds,MiB_s"
for NB in 1 15 180; do
  MIB=$(python3 -c "print(f'{$NB*512*2048*4/1048576:.1f}')")
  for MS in 1 2 4 8 16; do
    cat > omni_r.yaml <<EOF
name: sweep_${NB}_${MS}
max_scale: $MS
tags: [terra fusion, sweep]
src: "hdf5://$G/$DS"
start: [0, 0, 0]
count: [$NB, 512, 2048]
stride: [1, 1, 1]
EOF
    python3 tf_evict.py $G 2>/dev/null
    S=$(date +%s.%N)
    $E timeout 900 $W -q put omni_r.yaml >/dev/null 2>&1; RC=$?
    T=$(python3 -c "print(f'{$(date +%s.%N)-$S:.2f}')")
    [ $RC -eq 0 ] && echo "$NB,$MIB,$MS,$T,$(python3 -c "print(f'{$MIB/max($T,0.001):.1f}')")" \
                  || echo "$NB,$MIB,$MS,$T,FAILED"
  done
done
echo "OMNI-SWEEP2-DONE"
