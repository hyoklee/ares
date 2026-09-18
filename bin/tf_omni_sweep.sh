#!/bin/bash
# OMNI parameter sweep: max_scale x hyperslab size, on the rechunked MISR file.
# Throughput is logical (uncompressed) MiB / wall second.
cd "$(dirname "$0")" || exit 1
WRP=/mnt/common/hyoklee/cae/build/bin/wrp
F=/mnt/common/hyoklee/bench/tf_misr_rechunk.nc
E="env -u LD_LIBRARY_PATH -u CONDA_PREFIX"
# warm the runtime once so its startup is not charged to the first cell
$E timeout 120 $WRP put omni_probe2.yaml >/dev/null 2>&1
echo "nblocks,MiB,max_scale,seconds,MiB_s"
for NB in 1 15 180; do
  MIB=$(python3 -c "print(f'{$NB*512*2048*4/1048576:.1f}')")
  for MS in 1 2 4 8 16 32; do
    cat > omni_s.yaml <<EOF
name: sweep_${NB}_${MS}
max_scale: $MS
tags:
  - terra fusion
  - sweep
uri: "hdf5://$F/misr_red"
start: [0, 0, 0]
count: [$NB, 512, 2048]
stride: [1, 1, 1]
EOF
    python3 tf_evict.py $F 2>/dev/null
    S=$(date +%s.%N)
    $E timeout 900 $WRP -q put omni_s.yaml >/dev/null 2>&1
    RC=$?
    T=$(python3 -c "print(f'{$(date +%s.%N)-$S:.2f}')")
    if [ $RC -eq 0 ]; then
      echo "$NB,$MIB,$MS,$T,$(python3 -c "print(f'{$MIB/max($T,0.001):.1f}')")"
    else
      echo "$NB,$MIB,$MS,$T,FAILED"
    fi
  done
done
echo "OMNI-SWEEP-DONE"
