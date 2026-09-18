# Terra Fusion 5-sensor discrepancy, part 1: the intersection is ASTER, and it is free to find

Run on **ares**, 2026-09-18. First stage of the CLAUDE.md task: find the region
of largest pattern discrepancy among ASTER, CERES, MISR, MODIS and MOPITT in the
Terra Fusion collection. Stage 1 is the common overlapping intersection along
track.

Builds on the I/O series
([`20260905`](20260905_claude_terra_fusion_io_study.md),
[`20260914`](20260914_claude_terra_fusion_cliofs.md),
[`20260915`](20260915_claude_terra_fusion_vfd_vol.md),
[`20260916`](20260916_claude_terra_fusion_vol_collective.md)), which established
the chunk layouts and read throughput this work has to live within.

Granule: `TERRA_BF_L1B_O10204_20011118010522_F000_V001.h5` (orbit 10204,
2001-11-18, 32.9 GB).

## Headline

* **ASTER determines the 5-way intersection, alone.** The other four instruments
  are near-global on this orbit; ASTER covers **17° of latitude** in a narrow
  strip. The intersection *is* the ASTER footprint.
* **The block structure costs ~0 s to compute.** ASTER carries a coarse
  **11 × 11** per-granule `Geolocation`, so all 32 granule footprints are read in
  **0.0 s** — no science data touched, no decompression, nothing read from the
  755 MB or 32 MB chunks that dominate this file.
* **That is the whole optimisation.** The expensive framing — regrid five
  instruments globally, then intersect — is unnecessary. Subset first against 32
  cheap boxes, then regrid only inside them.

## Instrument footprints on orbit 10204

Subsampled stride 10 where arrays are large; 6.3 s total for all five.

| instrument | points | lat min | lat max | lon min | lon max | structure |
| --- | --- | --- | --- | --- | --- | --- |
| **ASTER** | 3,872 | **33.11** | **50.15** | **138.52** | **145.41** | 32 granules |
| CERES | 34,810 | −89.83 | 89.83 | −179.94 | 179.98 | 2 granules, FM1+FM2 footprints |
| MISR | 60,840 | −84.35 | 84.25 | −179.87 | 179.92 | SOM grid (180, 128, 512) |
| MODIS | 524,824 | −89.88 | 89.93 | −180.00 | 180.00 | 19 granules |
| MOPITT | 50,576 | −85.04 | 84.85 | −179.99 | 179.98 | (436, 29, 4) |

**Along-track latitude intersection of all five: [33.11, 50.15], span 17.03°.**

Geographically that strip runs from the Sea of Okhotsk / Sakhalin down through
Hokkaido and Honshu to just south of Tokyo — roughly 138.5-145.4°E.

A naming trap worth recording: MISR stores geolocation as
`MISR/Geolocation/GeoLatitude` / `GeoLongitude`, not `Latitude` / `Longitude`
like the other four. A search keyed on the common names finds **zero** MISR
geolocation and silently drops the instrument from the intersection.

## The 32 ASTER granules are the natural blocks

They tile the track contiguously, each ~0.70° of latitude and ~1° of longitude,
with slight overlap between neighbours. All 32 carry VNIR, SWIR and TIR.

| # | granule | lat0 | lat1 | lon0 | lon1 | Δlat |
| --- | --- | --- | --- | --- | --- | --- |
| 0 | `granule_11182001013943` | 49.40 | 50.15 | 144.14 | 145.41 | 0.75 |
| 1 | `granule_11182001013952` | 48.88 | 49.63 | 143.92 | 145.18 | 0.75 |
| … | (28 more, monotonically south) | | | | | ~0.70 |
| 30 | `granule_11182001014409` | 33.64 | 34.35 | 138.67 | 139.62 | 0.71 |
| 31 | `granule_11182001014417` | 33.11 | 33.82 | 138.52 | 139.46 | 0.71 |

Consecutive granules overlap by ~0.2° in latitude, so the strip is gap-free.
Full table in `bin/tf_aster_blocks.py` output / `aster_blocks.json`.

Using ASTER granules as blocks rather than imposing a regular lat/lon grid keeps
the block boundaries aligned with the instrument that constrains the problem,
and means no ASTER pixel is split across two blocks.

## Why this makes the search cheap

The I/O series established that this file is decompression-bound: every science
variable is zlib-1, and whole-variable reads run at 100-700 MiB/s of *logical*
bytes regardless of storage path. Reading all five instruments' science data
globally to then discard 95% of it would be the dominant cost of the whole task.

Instead:

1. Read ASTER's 32 coarse 11 × 11 geolocation arrays — **0.0 s**, a few KB.
2. Intersect the other four instruments' geolocation against those 32 boxes —
   geolocation only, still no radiance data.
3. Read science data **only** for the co-located subsets.

Step 3's cost is set by how much of each instrument actually falls in a 0.7° × 1°
box, which is a small fraction of a global swath. Quantifying that, and the
regridding itself, is stage 2.

## Method note

Footprints are computed from geolocation alone, with a validity mask
(`|lat| ≤ 90`, `|lon| ≤ 180`, finite, not exactly (0,0)) — the fill pattern in
these files puts unflagged zeros in unfilled geolocation, and without the
`(lat,lon) != (0,0)` test every instrument's bounding box silently extends to the
Gulf of Guinea.

## Reproducing

| file | what it does |
| --- | --- |
| [`bin/tf_footprints.py`](../bin/tf_footprints.py) | per-instrument footprint + 5-way latitude intersection |
| [`bin/tf_aster_blocks.py`](../bin/tf_aster_blocks.py) | the 32 ASTER granule boxes, sorted north→south |

```sh
python3 bin/tf_footprints.py  [granule.h5]
python3 bin/tf_aster_blocks.py
```

Both need a netCDF4 python with HDF5 ≥ 1.14; the pip `netCDF4` wheel is
sufficient and needs no build.

## Next

Stage 2: co-locate the other four instruments into the 32 ASTER blocks, measure
what fraction of each is actually needed, and compare regridding paths — E3SM
first, then `advancedFusion` and `pytaf`.
