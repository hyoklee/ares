# Terra Fusion 5-sensor discrepancy, part 2: regridding with pytaf and the ranked blocks

Run on **ares**, 2026-09-18. Stages 2-3 of the CLAUDE.md task: regrid the five
instruments into the 32 ASTER blocks found in
[part 1](20260918_claude_terra_fusion_discrepancy_01_intersection.md), and rank
the blocks by cross-sensor pattern discrepancy.

## Headline

* **End-to-end cost is ~80 s for a whole orbit**, all 32 blocks, all 5 sensors:
  0.0 s blocks + 7.4 s co-location + 22.4 s science reads + 57.6 s regrid
  (1.80 s/block).
* **MISR alone is 69% of the read time** (15.5 s of 22.4 s) because its
  `Red_Radiance` is a single 755 MB chunk. Only 15 of 180 SOM blocks are needed
  and none of that saving is realisable — the chunk is atomic. This is the
  09-05 chunk-layout finding landing directly on a science workload.
* **E3SM's regridding stack is not applicable** and not installed: no `ncremap`,
  ESMF, TempestRemap or NCO anywhere on ares. It is weight-file grid-to-grid
  machinery for model grids, not per-pixel swath geolocation.
* **pytaf does the job in 1.80 s/block**, built with OpenMP against its own
  `reproject.c`. `advancedFusion` was cloned but not needed for this stage —
  see "which is faster" below.
* **The ranking is dominated by a physically real signal**, not by processing
  error: ASTER TIR and MISR red reflectance are **anti-correlated**, the classic
  cloud signature (bright in red, cold in thermal).

## Regridding: which tool

| candidate | status | why |
| --- | --- | --- |
| **E3SM / `ncremap`** | **unavailable and mismatched** | no `ncremap`, ESMF, TempestRemap or NCO installed; E3SM regridding needs SCRIP grid descriptions and pre-generated weight files, which is grid-to-grid remapping for model grids. Swath L1B has per-pixel geolocation, irregular and self-overlapping — writing SCRIP files per instrument per granule to then generate weights would cost far more than the resampling itself. |
| **pytaf** | **used** | purpose-built for Terra instrument resampling. `nearestNeighborBlockIndex` + `nnInterpolate` / `summaryInterpolate` over a lat/lon block index. Builds in seconds with `setup.py.omp` (OpenMP). |
| **advancedFusion** | cloned, not required | the C++ sibling; ships `inputParameters_ASTER2MODIS.txt` etc. Its value is whole-instrument resampling into a fused product, which is a superset of what this ranking needs. |

pytaf's `summaryInterpolate` additionally returns per-target-cell **mean, SD and
source-pixel count** in one pass, which is a ready-made sub-pixel variability
metric if the discrepancy definition is later refined.

## Pipeline timings

| stage | time | note |
| --- | --- | --- |
| ASTER block footprints | **0.0 s** | 32 × 11 × 11 coarse geolocation |
| co-location, 4 instruments | 7.4 s | geolocation only, no radiances |
| read MODIS `EV_1KM_Emissive` band 0 | 6.8 s | 2 of 19 granules, chunk {1,2030,1354} |
| read MISR `AN/Red_Radiance` | **15.5 s** | **single 755 MB chunk, unavoidable** |
| read CERES `LW_Radiance` | 0.1 s | 6,777 footprints |
| read MOPITT `MOPITTRadiances` | 0.0 s | 1,652 pixels |
| regrid, 32 blocks × 5 sensors | 57.6 s | 1.80 s/block, OpenMP |

Target grid is a regular 0.02° (~2.2 km) lat/lon mesh per block, ~1,850 cells,
nearest-neighbour within `maxR = 3000 m`.

## Ranked blocks — dense sensors (ASTER / MODIS / MISR)

Discrepancy is the RMS difference of per-block **z-scores**, so instruments with
different units and wavelengths are comparable. **For two independent
standardised fields the expected RMS is √2 ≈ 1.414**: above that is
anti-correlation, below is correlation. That null value is the reference for
every number here.

| rank | blk | lat0 | lat1 | lon0 | lon1 | worst pair | worst | mean |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 0 | 27 | 35.23 | 35.94 | 139.14 | 140.10 | ASTER-MISR | **2.026** | 1.578 |
| 1 | 31 | 33.11 | 33.82 | 138.52 | 139.46 | ASTER-MISR | 2.022 | 1.584 |
| 2 | 2 | 48.35 | 49.11 | 143.69 | 144.94 | ASTER-MISR | 2.008 | 1.568 |
| 3 | 3 | 47.83 | 48.59 | 143.48 | 144.71 | ASTER-MISR | 1.954 | 1.577 |
| 4 | 0 | 49.40 | 50.15 | 144.14 | 145.41 | ASTER-MISR | 1.951 | 1.596 |
| 5 | 30 | 33.64 | 34.35 | 138.67 | 139.62 | ASTER-MISR | 1.932 | 1.599 |
| 6 | 1 | 48.88 | 49.63 | 143.92 | 145.18 | ASTER-MODIS | 1.908 | 1.526 |
| 7 | 5 | 46.81 | 47.52 | 143.08 | 144.25 | ASTER-MISR | 1.893 | 1.554 |
| 8 | 9 | 44.71 | 45.42 | 142.28 | 143.39 | ASTER-MISR | 1.881 | 1.560 |
| 9 | 8 | 45.24 | 45.95 | 142.47 | 143.60 | ASTER-MISR | 1.862 | 1.547 |

Block 27 (35.23-35.94°N, 139.14-140.10°E) is the Tokyo Bay / Mt Fuji area.
Blocks 30-31 are just south of it; blocks 0-3 are the Sakhalin end of the track.

## Pair statistics, and what they mean

Across all 32 blocks:

| pair | mean RMS | min | max | reading |
| --- | --- | --- | --- | --- |
| ASTER-MISR | 1.791 | 1.069 | 2.026 | **anti-correlated** (dense) |
| MISR-MOPITT | 1.693 | 0.919 | 2.120 | anti-corr — sparse |
| MISR-CERES | 1.675 | 1.484 | 1.970 | anti-corr — sparse |
| ASTER-MODIS | 1.610 | 0.656 | 1.908 | **anti-correlated** (dense) |
| MODIS-CERES | 1.486 | 1.161 | 1.747 | uncorrelated — sparse |
| MODIS-MOPITT | 1.467 | 0.777 | 1.943 | uncorrelated — sparse |
| **MODIS-MISR** | **1.076** | 0.747 | 1.535 | **correlated** (dense) |
| ASTER-CERES | 1.036 | 0.620 | 1.321 | correlated — sparse |
| CERES-MOPITT | 0.859 | 0.278 | 1.762 | correlated — sparse |
| ASTER-MOPITT | 0.806 | 0.501 | 1.227 | correlated — sparse |

**This is physics, not a processing error.** ASTER `ImageData10` is thermal
(~10.6 µm); MISR `Red_Radiance` is reflected red. Cloud is *bright* in red
reflectance and *cold* in thermal emission, so the two anti-correlate wherever
cloud dominates the block — which is exactly the "interesting weather pattern"
branch of the question rather than the "error during processing" branch. MODIS
band 0 of `EV_1KM_Emissive` is 3.75 µm, which carries a solar reflective
component by day, and duly **correlates** with MISR red (1.076). That
correlation is the pipeline's main sanity check: it is the one pair that should
track, and it does.

## Sparse sensors are not comparable at block scale

CERES contributes **58-85 footprints** and MOPITT **6-19 pixels** per block,
against ~1,850 target cells. Nearest-neighbour expansion of a dozen points into
1,850 cells produces a field of large constant patches whose "pattern" is an
artifact of the Voronoi tessellation, not of the measurement. Their pair scores
are reported for completeness but **should not drive the ranking** — hence the
dense-only table above. The all-sensor ranking (top entry: block 20,
MISR-MOPITT 2.120) is in `discrepancy.json` and is dominated by this artifact.

Any serious use of CERES/MOPITT here needs a coarser block (their native
footprints are ~20 km) or a metric that compares block *aggregates* rather than
patterns.

## Three traps that cost real time

**1. pytaf mutates its inputs in place.** `nearestNeighborBlockIndex` converts
both source and target lat/lon from degrees to radians *in the caller's arrays*
(`reproject.c:200-207`). `np.ascontiguousarray` is a no-op on an
already-contiguous float64 array, so passing one straight in destroys it for the
next call. Symptom: only the **first** instrument per block matched, so no pair
ever formed and all 32 blocks silently produced zero rows. Every array handed to
pytaf must be a fresh `.copy()`.

**2. pytaf writes −999, not NaN, for "no neighbour"** (`reproject.c:350`). Those
are finite and poison any downstream mean/σ. Mask on `tarNNSouID < 0`.

**3. Fill values need `valid_min`/`valid_max`, not a `_FillValue` test.**
MOPITT carries a **second** sentinel (−8888) alongside its `_FillValue` of
−9999, and only channels `[4,*]` and `[6,*]` hold data at all. A
`_FillValue`-only mask lets −8888 through. Every variable here publishes
`valid_min`/`valid_max`; use them.

## Caveats

* One orbit (O10204), one variable per instrument. Band choice materially
  affects the correlation signs — a reflective MODIS band would not
  anti-correlate with MISR the way the 3.75 µm band does.
* z-score RMS measures pattern *disagreement*, not calibration error. It cannot
  by itself separate "interesting weather" from "processing fault"; the
  ASTER-MISR cloud signature above is an interpretation, not an output.
* Nearest-neighbour, not area-weighted. `summaryInterpolate` would be the
  correct choice for fine→coarse and is available.
* Target resolution 0.02° is a compromise: finer than MODIS 1 km would
  oversample, coarser would erase ASTER's contribution entirely.

## Reproducing

| file | what it does |
| --- | --- |
| [`bin/tf_colocate.py`](../bin/tf_colocate.py) | co-locate 4 instruments into the ASTER strip, per-block counts |
| [`bin/tf_discrepancy.py`](../bin/tf_discrepancy.py) | regrid all 5 with pytaf, z-score, rank blocks |

```sh
cd ~/src/TerraFusion/pytaf && python3 setup.py.omp build_ext --inplace   # OpenMP build
RES=0.02 MAXR=3000 python3 bin/tf_discrepancy.py
```

Outputs `discrepancy.json` (all pairs, all blocks) and `discrepancy_dense.json`
(ASTER/MODIS/MISR only).

## Next

Stage 4: the I/O driver comparison for *this* pipeline — netCDF parallel,
SCORPIO, clio-fs, clio VOL, clio VFD — and OMNI/cluster-size tuning. The four
I/O studies already predict the answer (all paths within a few percent on a
decompression-bound workload), but the MISR 755 MB chunk read is 69% of this
pipeline's read time and is the one place a different data path could matter.
