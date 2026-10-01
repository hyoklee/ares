# Terra Fusion 5-sensor discrepancy, part 17: all granules — the highest-discrepancy block in the collection

Run on **ares**, 2026-09-30. Extends parts 1-16, which studied one orbit, to
every Terra Fusion granule on this machine: 284 GB, 10 files, 2000-03-04 to
2002-03-26.

## Answer

**O11602 block 46 — 25.84°S to 25.17°S, 122.91°E to 123.75°E** (inland Western
Australia, 2002-02-22), **C₅ = 0.355**, the lowest of 263 blocks.

| | |
| --- | --- |
| granule | `TERRA_BF_L1B_O11602_20020222010314` / `granule_02222002015809` |
| congruence C₅ | **0.355** (orbit median 0.692, collection median 0.703) |
| Kendall's W | 0.328 |
| cells with all five valid | 1089 |
| scene | BT₃₁ 303.6 K, spatial sd 3.29 K — real contrast, not a flat scene |
| loadings | MODI=0.63 ASTE=0.54 CERE=0.43 MOPI=0.30 **MISR=0.18** |
| weakest | **MISR**, `load_gap` 0.45 |

The signature is single-sensor: four sensors load 0.30-0.63 on a shared mode and
MISR contributes almost nothing. Over a bright desert at 30 °C, MISR's 0.67 µm
red reflectance is dominated by surface albedo while the other four are thermal
or broadband — a decoupling that is physically expected, so this is **not**
evidence of a processing fault. It is the largest genuine cross-sensor
disagreement in the collection.

## What was actually processed

| orbit | date | GB | sensors | ASTER blocks | result |
| --- | --- | --- | --- | --- | --- |
| O1117 | 2000-03-04 | 15.7 | CERES,MISR,MODIS,MOPITT | — | **no ASTER** |
| O10204 | 2001-11-18 | 30.6 | all five | 32 | 32 blocks |
| O10437 | 2001-12-04 | 16.2 | all five | 2 | **failed** (see below) |
| O10670 | 2001-12-20 | 42.3 | — | — | **file will not open** |
| O10903 | 2002-01-05 | 47.5 | all five | 75 | 75 blocks |
| O11136 | 2002-01-21 | 26.4 | all five | 27 | 27 blocks |
| O11369 | 2002-02-06 | 42.2 | all five | 66 | 66 blocks |
| O11602 | 2002-02-22 | 36.9 | all five | 49 | 49 blocks |
| O11835 | 2002-03-10 | 22.1 | all five | 14 | 14 blocks |
| O12068 | 2002-03-26 | 3.9 | MISR,MOPITT | — | **two sensors only** |

**263 blocks from 6 granules.** Three granules carry no usable ASTER-defined
blocks, and one cannot be read at all.

### O10670 does not open

42.3 GB, valid HDF5 signature, tail reads back fine — but `netCDF4` reports
`[Errno -101] NetCDF: HDF error` and **`h5ls` is OOM-killed (exit 137)** on a
94 GB host. Not a truncation; something in its structure makes the library
allocate without bound. Worth a separate look, and worth knowing before anyone
schedules a job over the full collection.

### O10437 fails on sparse-sensor overlap

`ValueError: zero-size array to reduction operation minimum`. It has only 2
ASTER granules, so its strip is tiny and CERES/MOPITT contribute no points
inside it. A real data condition rather than a bug, but `tf_sources.py` crashes
rather than reporting it; worth a clearer error.

## The ranking, and why it needed filtering

Pooling all 263 blocks and sorting by C₅ gives a top ten dominated by **O11369
blocks 10-15**, all around 7-9°N / 132°E. They are an artifact.

Part 13 established that C₅ is partly a **scene-contrast** measure: a featureless
scene gives every sensor nothing to agree on, so congruence falls without any
disagreement being present. That effect is far stronger at this sample size than
it was at n=32:

> **Spearman(BT₃₁ spatial sd, C₅) = +0.518, p = 1.8 × 10⁻¹⁹** across 263 blocks.

Those equatorial blocks have BT₃₁ standard deviations of **0.42 to 0.90 K**
against a collection median of **6.36 K** — uniform warm tropical ocean, with
essentially no structure. Seven of the raw top ten drop out on a 2.0 K contrast
floor:

| | raw rank | C₅ | BT₃₁ sd | verdict |
| --- | --- | --- | --- | --- |
| O11602 blk 46 | 0 | 0.355 | 3.29 | **kept** |
| O11369 blk 14 | 1 | 0.374 | **0.42** | dropped, featureless |
| O11369 blk 10 | 2 | 0.444 | **0.48** | dropped |
| O11369 blk 26 | 3 | 0.449 | 4.04 | kept |
| O11369 blk 13 | 4 | 0.450 | **0.52** | dropped |
| O11369 blk 11 | 5 | 0.456 | **0.80** | dropped |
| O11369 blk 0 | 6 | 0.457 | **1.40** | dropped |
| O11369 blk 15 | 7 | 0.458 | **0.90** | dropped |
| O11369 blk 12 | 8 | 0.473 | **0.53** | dropped |
| O10903 blk 65 | 9 | 0.481 | 8.68 | kept |

**The winner survives the filter unchanged** — O11602 blk 46 is both the lowest
C₅ overall and has genuine contrast — so the answer does not depend on where the
floor is set. The rest of the list changes substantially.

## Top 12 genuine discrepancy blocks (236 blocks with BT₃₁ sd ≥ 2 K)

| rk | orbit | blk | lat | lon | C₅ | sd K | BT K | weakest | gap | loadings |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 0 | O11602 | 46 | −25.84, −25.17 | 122.91 | **0.355** | 3.29 | 303.6 | MISR | 0.45 | MODI=0.63 ASTE=0.54 CERE=0.43 MOPI=0.30 MISR=0.18 |
| 1 | O11369 | 26 | 0.60, 1.26 | 130.90 | 0.449 | 4.04 | 292.8 | MISR | 0.57 | MODI=0.61 ASTE=0.60 MOPI=0.41 CERE=0.31 MISR=0.05 |
| 2 | O10903 | 65 | −14.39, −13.73 | 127.72 | 0.481 | 8.68 | 286.7 | MISR | 0.38 | MODI=0.59 ASTE=0.58 MOPI=0.39 CERE=0.35 MISR=0.21 |
| 3 | O10903 | 71 | −17.60, −16.94 | 127.01 | 0.485 | 3.52 | 300.9 | MISR | 0.54 | MODI=0.59 ASTE=0.56 MOPI=0.45 CERE=0.36 MISR=0.05 |
| 4 | O10903 | 72 | −18.13, −17.47 | 126.90 | 0.493 | 3.28 | 302.2 | CERES | 0.34 | MODI=0.59 ASTE=0.55 MOPI=0.42 MISR=0.34 CERE=0.25 |
| 5 | **O10204** | **13** | 42.62, 43.32 | 141.52 | 0.508 | 3.36 | 257.4 | MOPITT | 0.18 | MODI=0.55 ASTE=0.51 MISR=0.39 CERE=0.39 MOPI=0.37 |
| 6 | O10903 | 11 | 29.93, 30.64 | 137.65 | 0.517 | 4.72 | 287.7 | MOPITT | 0.36 | MODI=0.57 ASTE=0.55 MISR=0.49 CERE=0.30 MOPI=0.21 |
| 7 | O11602 | 9 | 42.99, 43.69 | 138.93 | 0.519 | 2.53 | 262.2 | CERES | 0.18 | ASTE=0.53 MODI=0.52 MISR=0.41 MOPI=0.40 CERE=0.35 |
| 8 | O11602 | 36 | −20.52, −19.84 | 124.24 | 0.519 | 6.97 | 238.0 | CERES | 0.27 | ASTE=0.55 MODI=0.55 MOPI=0.43 MISR=0.37 CERE=0.28 |
| 9 | O11602 | 25 | 34.52, 35.20 | 136.54 | 0.525 | 6.62 | 258.3 | MISR | 0.44 | MODI=0.56 ASTE=0.55 CERE=0.45 MOPI=0.42 MISR=0.12 |
| 10 | O10903 | 63 | −13.32, −12.66 | 127.95 | 0.531 | 5.36 | 291.7 | CERES | 0.28 | MODI=0.57 ASTE=0.56 MOPI=0.42 MISR=0.31 CERE=0.29 |
| 11 | O10204 | 26 | 35.76, 36.46 | 139.29 | 0.535 | 3.75 | 285.8 | MISR | 0.27 | MODI=0.54 ASTE=0.49 CERE=0.46 MOPI=0.43 MISR=0.27 |

**Block 13 of O10204 — the winner of parts 10-15 — is rank 5 of the collection.**
It remains a genuine outlier, but seven blocks across three other granules are
more discrepant, and the single-orbit study could not have known that.

MISR is the weakest sensor in half the top twelve, and the pattern is
geographic: six of the top twelve are in the Australian interior or the seas
north-west of it (120-128°E, 12-26°S), hot bright scenes where a reflective band
and four thermal ones have the least reason to agree.

## Collection statistics

| | |
| --- | --- |
| blocks | 263 from 6 granules |
| C₅ | min **0.355**, median 0.703, max **0.920** |
| most congruent | O10903 blk 48, 5.29°S-4.63°S, C₅ = 0.920 |
| C₅ vs Kendall's W | **r = 0.9901** across all 263 |
| weakest-sensor tally | MISR 105, MOPITT 102, CERES 55, ASTER 1, **MODIS 0** |

Two things to note. The W cross-check from part 4 holds at **r = 0.990** on 8×
the data, which is the strongest evidence so far that the statistic is measuring
something real. And **MODIS is never the weakest sensor in 263 blocks** under
the matched configuration — which is what part 11 predicted after the band-20
artifact was removed, now confirmed collection-wide rather than on one orbit.

## Per granule

| orbit | blocks | C₅ min | median | max |
| --- | --- | --- | --- | --- |
| O10204 | 32 | 0.508 | 0.720 | 0.867 |
| O10903 | 75 | 0.481 | 0.703 | 0.920 |
| O11136 | 27 | 0.509 | 0.704 | 0.827 |
| O11369 | 66 | 0.374 | 0.701 | 0.887 |
| O11602 | 49 | **0.355** | 0.692 | 0.891 |
| O11835 | 14 | 0.585 | 0.738 | 0.882 |

Medians sit within 0.046 of each other across six orbits spanning five months
and both hemispheres, which says the metric is stable and that the extremes are
properties of individual scenes rather than of a granule or a season.

## Caveats

* **Six granules, not ten.** Three lack usable sensors and one will not open.
* The 2.0 K contrast floor is a judgement, not a derived threshold. It was chosen
  because the dropped blocks sit at 0.4-1.4 K against a 6.36 K median, an
  order-of-magnitude gap; the winner is unaffected by where it is placed, the
  rest of the list is not.
* **No reanalysis or cloud-product check was run on the new granules.** Parts
  13-14 did that for O10204 only. O11602 blk 46's interpretation — bright desert,
  MISR decoupling on albedo — follows from BT₃₁ = 303.6 K and the loading
  profile, and is **not** independently confirmed.
* Everything is nearest-neighbour resampling on a 0.02° grid with the per-sensor
  radii from part 4, and the matched band configuration from parts 11-12.
* Congruence is computed only where all five sensors are valid, so blocks are
  compared on differing cell counts (982-2457).

## Reproducing

```sh
bash bin/tf_all_granules.sh                       # ~35 min, 3 granules at a time
cd /mnt/common/hyoklee/tfwork/allgran
TOP=20 python3 bin/tf_rank_all.py                 # -> all_granule_ranking.json
```

`tf_aster_blocks.py`, `tf_sources.py` and `tf_congruence.py` now all take
`TF_GRANULE`; `tf_sources.py` also discovers the MOPITT granule group by
structure rather than by the hardcoded `granule_20011118`, which had silently
restricted the whole pipeline to one orbit.
