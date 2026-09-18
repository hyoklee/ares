# Terra Fusion 5-sensor discrepancy, part 3: rechunk MISR, use 8 processes, ignore OpenMP

Run on **ares**, 2026-09-18. Stage 4 of the CLAUDE.md task: find the fastest
algorithm, I/O driver, and degree of parallelism. Follows
[part 1](20260918_claude_terra_fusion_discrepancy_01_intersection.md) (the
intersection) and
[part 2](20260918_claude_terra_fusion_discrepancy_02_ranking.md) (regridding and
the ranking).

## Headline

* **Rechunking MISR gives 8.1× on the read that dominated the pipeline** —
  3.40 s → 0.42 s for the 15 SOM blocks actually needed. One-time cost 16.8 s,
  +28% storage.
* **advancedFusion and pytaf are the same algorithm.** They share all five
  resampling entry points; pytaf's `reproject.c` is a trimmed extraction of
  advancedFusion's `reproject.cpp`. There is no resampling-speed comparison to
  make.
* **pytaf's OpenMP is worthless and at scale harmful** — 40 threads is **1.7×
  slower** than serial. Parallelise across blocks with processes, not inside
  pytaf with threads.
* **8 processes is the optimum**, 5.06× over serial; 16 and 32 are worse. The
  same figure the I/O studies found for read ranks.
* **After rechunking the pipeline is compute-bound**, so the I/O driver choice —
  netCDF parallel, SCORPIO, clio-fs, clio VOL, clio VFD — is close to irrelevant
  for this workload, as the four earlier studies predicted.

## The MISR rechunk

`MISR/AN/Data_Fields/Red_Radiance` is (180, 512, 2048) in **one 755 MB chunk**,
zlib-1. The pipeline needs SOM blocks **49-63, 15 of 180**.

| operation | time |
| --- | --- |
| ORIGINAL, full read | 9.24 s |
| ORIGINAL, subset read (15 blocks) | **3.40 s** — chunk is atomic, subsetting saves nothing |
| rechunk write, one-time | 16.8 s → 275 MiB |
| RECHUNKED, subset read (15 blocks) | **0.42 s** |
| RECHUNKED, full read | 7.96 s |

**8.1× on the subset read.** The rechunk pays for itself after ~6 pipeline runs
and is unambiguously right for repeated analysis across orbits. The cost is
**+28% storage** (275 MiB against 215 MiB): per-block compression is less
efficient than one large chunk, which is the trade the original chunking was
presumably making.

Chunk shape used: `{1, 512, 2048}` — one SOM block per chunk, matching the
access granularity the geolocation implies.

### A trap worth recording

The first rechunk attempt copied block-by-block:

```python
for b in range(180): nv[b,:,:] = rr[b,:,:]      # 0.5 MiB written in minutes
```

Each `rr[b,:,:]` re-inflates **all 755 MB**, because the source is a single
chunk — 180× the necessary work. It is the exact pathology the rechunk exists to
remove, reproduced by accident. Read the source once:

```python
whole = np.asarray(rr[:])
for b in range(180): nv[b,:,:] = whole[b]       # 16.8 s total
```

This generalises: **any loop over the SOM-block axis of an unrechunked MISR
variable pays the full 755 MB per iteration.** A natural-looking `for block in
range(...)` is a 180× penalty here.

## advancedFusion vs pytaf

CLAUDE.md asks which is faster. They are the same code.

| function | advancedFusion `reproject.cpp` | pytaf `reproject.c` |
| --- | --- | --- |
| `nearestNeighborBlockIndex` | ✓ | ✓ |
| `nnInterpolate` | ✓ | ✓ |
| `summaryInterpolate` | ✓ | ✓ |
| `pointIndexOnLatLon` | ✓ | ✓ |
| `clipping` | ✓ | ✓ |
| `nearestNeighbor` (brute force) | ✓ | — |

744 lines against 448; the only function pytaf lacks is a brute-force fallback
to the block-indexed search both implement. Any timing difference between the
two tools is wrapper and I/O overhead around identical numerics.

The practical asymmetry runs against advancedFusion on this machine:

| | pytaf | advancedFusion |
| --- | --- | --- |
| dependencies | Cython + numpy | **gdal** (not installed), OpenMP, HDF5 |
| HDF5 vintage | version-agnostic C core | written for **1.8.16 / 1.10.2**; ares has **2.3.0** |
| build | seconds (`setup.py.omp`) | needs a gdal stack first |

Building gdal to run the same arithmetic is not justified. **pytaf, on grounds of
dependency surface rather than speed.** advancedFusion remains the better choice
where a whole fused output product is wanted rather than a block ranking.

## Parallelism: 8 processes, no OpenMP

Regrid of the two dense instruments (MODIS + MISR) over all 32 blocks. The
`matched` count is identical (129,120) in every configuration, so correctness is
held constant.

| processes | `OMP_NUM_THREADS` | total threads | seconds | speedup |
| --- | --- | --- | --- | --- |
| 1 | 1 | 1 | 8.55 | 1.00 |
| 1 | 8 | 8 | 8.85 | 0.97 |
| 1 | 40 | 40 | **14.68** | **0.58** |
| 2 | 1 | 2 | 4.79 | 1.79 |
| 4 | 1 | 4 | 2.85 | 3.00 |
| **8** | **1** | **8** | **1.69** | **5.06** |
| 16 | 1 | 16 | 2.32 | 3.69 |
| 32 | 1 | 32 | 4.80 | 1.78 |
| 8 | 4 | 32 | 2.34 | 3.65 |
| 16 | 2 | 32 | 2.92 | 2.93 |
| 32 | 2 | 64 | 5.42 | 1.58 |

**Three results:**

1. **pytaf's OpenMP does nothing** (8.85 s against 8.55 s serial) and **hurts
   badly at 40 threads** (14.68 s, 1.7× slower). Its `#pragma omp parallel for`
   regions run over arrays of ~2k target cells and ~9k source points per block —
   far too little work to amortise thread startup, and at 40 threads the
   contention dominates outright. Build it with OpenMP if you like, but set
   `OMP_NUM_THREADS=1`.
2. **Block-level process parallelism is the right axis**, peaking at 8.
3. **Past 8 it degrades** — 32 processes for 32 blocks is one block each, where
   fork and input-sharing overhead exceeds the work. Mixed configurations
   totalling 32 threads are all worse than 8 processes alone.

8 processes is also the optimum the I/O series found for read ranks
([09-05](20260905_claude_terra_fusion_io_study.md)), where MODIS peaked at 8 and
regressed at 16. Two independent measurements of different things landing on the
same number suggests a node-level property — memory bandwidth or effective
parallelism on this hardware — rather than a coincidence of either workload.

## I/O driver: it stops mattering

The four earlier studies measured every available data path on exactly these
files and found them within a few percent of each other, because the workload is
decompression-bound:

| path | result | reference |
| --- | --- | --- |
| netCDF parallel (native) | reference | [09-05](20260905_claude_terra_fusion_io_study.md) |
| SCORPIO `netcdf4p` | ~1.9× slower on chunked data; **wins on single-chunk** | 09-05 |
| SCORPIO `netcdf4c` | **never** — plateaus, and inverts under rank count | 09-05, 09-14 |
| clio-fs (FUSE) | 0-36% slower, never wins | [09-14](20260914_claude_terra_fusion_cliofs.md) |
| clio VFD | parity | [09-15](20260915_claude_terra_fusion_vfd_vol.md) |
| clio VOL (serial) | parity | 09-15 |
| clio VOL (collective) | parity | [09-16](20260916_claude_terra_fusion_vol_collective.md) |

After the MISR rechunk the pipeline spends **0.42 s** on the read that used to
cost 3.40-15.5 s, and ~11 s on regridding at 8 processes. **I/O is no longer the
bottleneck at all**, so choosing between these paths cannot materially change
the result. The one case where a path mattered — SCORPIO's rearranger beating
native on a single 755 MB chunk — is precisely the case the rechunk eliminates.

## The optimal recipe

1. **Blocks from ASTER's coarse 11 × 11 geolocation** — 0.0 s, no science data.
2. **Co-locate on geolocation only** — 7.4 s, before touching any radiance.
3. **Rechunk MISR once** to `{1, 512, 2048}` — 16.8 s, then 0.42 s per subset
   read forever after.
4. **Regrid with pytaf**, `OMP_NUM_THREADS=1`, **8 processes** over blocks.
5. **Native netCDF-4 parallel** for I/O; no adapter earns its overhead here.

Projected end-to-end for a full orbit: ~0 s blocks + 7.4 s co-location + ~5 s
reads (MODIS 4.7 s + rechunked MISR 0.42 s + CERES/MOPITT ~0.1 s) + ~11 s regrid
at 8 processes ≈ **24 s**, against ~80 s for the unoptimised pipeline in part 2.

## Caveats

* The scaling table regrids **two** instruments (MODIS + MISR, the dense ones
  that dominate), not five, so 8.55 s serial there is not the 57.6 s five-sensor
  figure from part 2. The *shape* of the scaling is the result; the 5.06×
  applied to the full pipeline is a projection, not a measurement.
* The ~24 s end-to-end figure is likewise a projection from measured components,
  not a single timed run.
* Rechunking changes the file. The 275 MiB rechunked copy is a derived artifact
  at `/mnt/common/hyoklee/bench/tf_misr_rechunk.nc`; the source granule is
  untouched.
* Single node throughout. Multi-node was not tested, and nothing here
  establishes how the 8-process optimum composes across nodes.

## Reproducing

| file | what it does |
| --- | --- |
| [`bin/tf_misr_rechunk.py`](../bin/tf_misr_rechunk.py) | rechunk MISR and time original vs rechunked subset reads |
| [`bin/tf_regrid_scale.py`](../bin/tf_regrid_scale.py) | process × OpenMP scaling sweep |

```sh
python3 bin/tf_misr_rechunk.py
for cfg in "1 1" "8 1" "16 1" "32 1"; do python3 bin/tf_regrid_scale.py $cfg; done
```
