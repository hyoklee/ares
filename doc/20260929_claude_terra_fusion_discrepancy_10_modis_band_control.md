# Terra Fusion 5-sensor discrepancy, part 10: the MODIS band control — part 4's headline finding is RETRACTED

Run on **ares**, 2026-09-29. Executes the control that
[part 4](20260918_claude_terra_fusion_discrepancy_04_congruence.md) named as
required and did not perform:

> *"The systematic MODIS weakness is the headline candidate and **cannot be
> attributed to a processing fault without testing another band**."*

It has now been tested. **The MODIS weakness was that band's physics, not a
processing fault.** Part 4's central claim does not survive its own control.

## Headline

* **MODIS goes from weakest sensor in 19 of 32 blocks to weakest in 0 of 32**
  when the band is changed from 20 (3.75 µm) to 29 (8.55 µm) or 31 (11.03 µm).
* Its median loading on the common mode rises **0.342 → 0.514**, and its minimum
  **0.012 → 0.473**. Under a thermal band MODIS is the *strongest* loader in
  every one of the ten least-congruent blocks.
* **Block 7 — part 4's "cleanest signature in the dataset" — is now rank 30 of
  32, the second-*most* congruent block in the orbit.** MODIS loading 0.038 →
  0.473; `load_gap` 0.49 → 0.06.
* Bands 29 and 31 agree at **r = 0.9998** (max |ΔC₅| = 0.008), so this is a
  property of thermal-versus-3.75 µm, not of one band choice.
* Overall congruence rises: median **0.556 → 0.682**, min 0.342 → 0.466.
* **New open question:** under a thermal band, **CERES** becomes weakest in 20
  of 32 blocks — and that is *not* explained by its sparsity.

## What was actually changed

One index. `EV_1KM_Emissive` carries 16 bands:

```
band_names = 20,21,22,23,24,25,27,28,29,30,31,32,33,34,35,36
```

Parts 2-4 always read index 0. The control re-runs the identical pipeline at
three indices, with the four non-MODIS sensors byte-identical across all three
runs:

| index | band | wavelength | character | MODIS radiance range |
| --- | --- | --- | --- | --- |
| 0 | 20 | 3.75 µm | reflected solar **+** thermal | 0.055 – 1.124 |
| 8 | 29 | 8.55 µm | thermal, nearest ASTER TIR-10 (8.29 µm) | 2.65 – 7.76 |
| 10 | 31 | 11.03 µm | clean thermal window | 3.59 – 8.49 |

The a priori reason to suspect band 20 is the overpass geometry: mean longitude
141.7°E at 01:05:22 UTC gives a **local solar time of 10:32**. In broad daylight
the 3.75 µm channel carries a large reflected-solar component, so it is
measuring partly a different physical quantity from ASTER TIR (emission) and
partly the same one as MISR red (reflection) — which is exactly the way to
decouple from both at once.

## Result

### MODIS loading on the common mode

| band | min | median | max | blocks with loading < 0.20 | weakest in |
| --- | --- | --- | --- | --- | --- |
| 20 (3.75 µm) | **0.012** | 0.342 | 0.506 | 3 / 32 | **19 / 32** |
| 29 (8.55 µm) | 0.473 | 0.514 | 0.597 | 0 / 32 | **0 / 32** |
| 31 (11.03 µm) | 0.470 | 0.514 | 0.596 | 0 / 32 | **0 / 32** |

### Part 4's five "processing-error candidates", re-measured

| blk | MODIS @ b20 | MODIS @ b31 | C₅ b20 → b31 | gap b20 → b31 | weakest @ b31 |
| --- | --- | --- | --- | --- | --- |
| 7 | **0.038** | 0.473 | 0.653 → **0.834** | 0.49 → **0.06** | CERES |
| 15 | **0.012** | 0.519 | 0.483 → 0.645 | 0.53 → 0.19 | CERES |
| 8 | 0.137 | 0.514 | 0.511 → 0.674 | 0.41 → 0.16 | CERES |
| 10 | 0.242 | 0.550 | 0.407 → 0.537 | 0.49 → 0.39 | MISR |
| 17 | 0.360 | 0.564 | 0.430 → 0.569 | 0.38 → 0.34 | CERES |

Every MODIS-weakest entry dissolves. Block 7 does more than dissolve — it
inverts, from the strongest apparent fault signature in the orbit to its
second-most congruent block.

### Robustness

Two independently chosen thermal bands give the same answer:

* C₅ correlation b29 vs b31: **r = 0.9998**, max |ΔC₅| = 0.0083
* identical weakest-sensor tallies (CERES 20, MOPITT 7, MISR 5)
* MODIS loadings agree to ≤ 0.01 in every block

By contrast C₅(b20) vs C₅(b31) correlates at r = 0.9333 — the band choice moves
the result materially, and in a structured way rather than as noise.

C₅ and Kendall's W still agree at **r = 0.9930** across the 32 blocks, so the
cross-check from part 4 continues to hold under the new band.

## The corrected ranking — CLAUDE.md's deliverable

Sorted largest discrepancy (least congruent) first, MODIS band 31, all 32
blocks, 5 sensors each.

| rk | blk | lat0 | lat1 | cells | C₅ | C_dense | W | weakest | gap | loadings (sign-aligned) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 0 | 13 | 42.62 | 43.32 | 1337 | **0.466** | 0.696 | 0.422 | CERES | 0.40 | MODI=0.60 ASTE=0.55 MISR=0.42 MOPI=0.35 CERE=0.20 |
| 1 | 26 | 35.76 | 36.46 | 1215 | 0.507 | 0.638 | 0.479 | MISR | 0.26 | MODI=0.55 ASTE=0.50 MOPI=0.44 CERE=0.40 MISR=0.29 |
| 2 | 10 | 44.19 | 44.89 | 1375 | 0.537 | 0.652 | 0.492 | MISR | 0.39 | MODI=0.55 ASTE=0.52 MOPI=0.46 CERE=0.43 MISR=0.16 |
| 3 | 20 | 38.94 | 39.63 | 1266 | 0.549 | 0.767 | 0.534 | CERES | 0.22 | MODI=0.55 ASTE=0.53 MISR=0.41 MOPI=0.37 CERE=0.33 |
| 4 | 12 | 43.14 | 43.84 | 1350 | 0.566 | 0.759 | 0.544 | CERES | 0.25 | MODI=0.55 ASTE=0.53 MOPI=0.41 MISR=0.39 CERE=0.30 |
| 5 | 17 | 40.52 | 41.21 | 1297 | 0.569 | 0.872 | 0.525 | CERES | 0.34 | MODI=0.56 ASTE=0.54 MISR=0.52 MOPI=0.27 CERE=0.22 |
| 6 | 21 | 38.41 | 39.10 | 1254 | 0.576 | 0.845 | 0.552 | CERES | 0.33 | MODI=0.55 ASTE=0.52 MISR=0.49 MOPI=0.36 CERE=0.22 |
| 7 | 18 | 39.99 | 40.68 | 1286 | 0.585 | 0.821 | 0.568 | CERES | 0.22 | MODI=0.54 ASTE=0.50 MISR=0.46 MOPI=0.39 CERE=0.31 |
| 8 | 22 | 37.88 | 38.57 | 1247 | 0.596 | 0.867 | 0.576 | CERES | 0.27 | MODI=0.55 ASTE=0.53 MISR=0.49 MOPI=0.32 CERE=0.28 |
| 9 | 5 | 46.81 | 47.52 | 1442 | 0.615 | 0.884 | 0.593 | CERES | 0.27 | MODI=0.54 ASTE=0.53 MISR=0.47 MOPI=0.38 CERE=0.27 |
| 10 | 16 | 41.04 | 41.74 | 1307 | 0.618 | 0.876 | 0.591 | MOPITT | 0.26 | MODI=0.53 ASTE=0.52 MISR=0.49 CERE=0.36 MOPI=0.28 |
| 11 | 11 | 43.67 | 44.37 | 1359 | 0.629 | 0.783 | 0.616 | MISR | 0.18 | MODI=0.53 ASTE=0.51 MOPI=0.43 CERE=0.40 MISR=0.35 |
| 12 | 28 | 34.70 | 35.41 | 1195 | 0.634 | 0.885 | 0.619 | MOPITT | 0.19 | MODI=0.53 ASTE=0.49 MISR=0.49 CERE=0.36 MOPI=0.34 |
| 13 | 15 | 41.57 | 42.26 | 1316 | 0.645 | 0.848 | 0.633 | CERES | 0.19 | MODI=0.52 ASTE=0.50 MISR=0.45 MOPI=0.42 CERE=0.33 |
| 14 | 8 | 45.24 | 45.95 | 1398 | 0.674 | 0.891 | 0.663 | CERES | 0.16 | MODI=0.51 ASTE=0.50 MISR=0.46 MOPI=0.39 CERE=0.35 |
| 15 | 24 | 36.82 | 37.52 | 1230 | 0.682 | 0.675 | 0.647 | MISR | 0.30 | MODI=0.51 ASTE=0.49 CERE=0.48 MOPI=0.47 MISR=0.22 |
| 16 | 4 | 47.33 | 48.04 | 1457 | 0.683 | 0.940 | 0.664 | CERES | 0.20 | MODI=0.52 ASTE=0.51 MISR=0.50 MOPI=0.35 CERE=0.31 |
| 17 | 29 | 34.17 | 34.88 | 1189 | 0.703 | 0.834 | 0.690 | MOPITT | 0.10 | MODI=0.50 ASTE=0.49 CERE=0.42 MISR=0.42 MOPI=0.40 |
| 18 | 9 | 44.71 | 45.42 | 1387 | 0.713 | 0.857 | 0.700 | CERES | 0.16 | MODI=0.50 ASTE=0.48 MOPI=0.47 MISR=0.44 CERE=0.33 |
| 19 | 14 | 42.09 | 42.79 | 1326 | 0.714 | 0.910 | 0.693 | CERES | 0.16 | MODI=0.51 ASTE=0.48 MISR=0.47 MOPI=0.42 CERE=0.34 |
| 20 | 19 | 39.46 | 40.16 | 1277 | 0.720 | 0.869 | 0.718 | MOPITT | 0.09 | MODI=0.49 ASTE=0.47 MISR=0.44 CERE=0.43 MOPI=0.40 |
| 21 | 1 | 48.88 | 49.63 | 1503 | 0.725 | 0.937 | 0.694 | MOPITT | 0.17 | MODI=0.51 ASTE=0.49 MISR=0.48 CERE=0.41 MOPI=0.33 |
| 22 | 23 | 37.35 | 38.05 | 1238 | 0.730 | 0.875 | 0.725 | MOPITT | 0.07 | MODI=0.49 ASTE=0.47 MISR=0.43 CERE=0.42 MOPI=0.42 |
| 23 | 27 | 35.23 | 35.94 | 1205 | 0.731 | 0.865 | 0.731 | CERES | 0.11 | MODI=0.49 ASTE=0.48 MOPI=0.44 MISR=0.43 CERE=0.38 |
| 24 | 31 | 33.11 | 33.82 | 868 | 0.738 | 0.933 | 0.681 | CERES | 0.16 | MODI=0.50 MISR=0.49 ASTE=0.47 MOPI=0.42 CERE=0.34 |
| 25 | 25 | 36.29 | 36.99 | 1222 | 0.744 | 0.838 | 0.744 | MISR | 0.10 | MODI=0.49 ASTE=0.46 CERE=0.45 MOPI=0.42 MISR=0.40 |
| 26 | 30 | 33.64 | 34.35 | 1178 | 0.762 | 0.897 | 0.752 | MOPITT | 0.10 | MODI=0.49 ASTE=0.48 CERE=0.43 MISR=0.43 MOPI=0.39 |
| 27 | 0 | 49.40 | 50.15 | 1517 | 0.809 | 0.912 | 0.796 | CERES | 0.07 | MODI=0.48 ASTE=0.46 MISR=0.44 MOPI=0.44 CERE=0.41 |
| 28 | 6 | 46.28 | 46.99 | 1428 | 0.811 | 0.916 | 0.804 | CERES | 0.05 | MODI=0.47 ASTE=0.46 MISR=0.45 MOPI=0.43 CERE=0.42 |
| 29 | 2 | 48.35 | 49.11 | 1485 | 0.813 | 0.954 | 0.790 | CERES | 0.08 | MODI=0.48 ASTE=0.47 MISR=0.46 MOPI=0.42 CERE=0.40 |
| 30 | **7** | 45.76 | 46.47 | 1401 | 0.834 | 0.949 | 0.838 | CERES | 0.06 | MODI=0.47 ASTE=0.47 MISR=0.46 MOPI=0.42 CERE=0.41 |
| 31 | 3 | 47.83 | 48.59 | 1471 | 0.835 | 0.919 | 0.814 | CERES | 0.06 | MODI=0.48 ASTE=0.46 MOPI=0.44 MISR=0.44 CERE=0.42 |

**Block 13 (42.62-43.32°N) is the top discrepancy.** Its signature is a
single-sensor one: CERES loads 0.20 against MODIS 0.60 and ASTER 0.55, the
largest gap in the orbit (0.40). Blocks 26 and 10 follow, both with MISR as the
odd sensor out.

The congruent end (blocks 3, 7, 2, 6, 0) has all five loadings within 0.06 of
each other at C₅ > 0.80 — five instruments seeing one shared pattern, nothing to
investigate.

## The new open question: CERES

> **RESOLVED in
> [part 11](20260929_claude_terra_fusion_discrepancy_11_ceres_control.md):
> spectral, and the footprint hypothesis below is refuted.** Swapping
> `LW_Radiance` (broadband 5-100 µm) for `WN_Radiance` (the 8-12 µm window
> channel) takes CERES from weakest in 20/32 to weakest in **1/32**, with the
> footprint held identical. The section below reads the sparsity evidence
> correctly but was wrong to keep the footprint in play as the leading
> alternative.

Under a thermal MODIS band, CERES is weakest in **20 of 32** blocks. The obvious
explanation is sparsity — but it does not hold:

| sensor | points/block (min / med / max) | median loading | r(log₁₀ support, loading) |
| --- | --- | --- | --- |
| MODIS | 8022 / 8185 / 9071 | 0.514 | −0.50 |
| MISR | 6897 / 7044 / 7818 | 0.445 | +0.11 |
| CERES | 51 / 60 / 85 | **0.370** | **−0.06** |
| MOPITT | 6 / 17 / 19 | 0.416 | +0.07 |

Two things rule sparsity out as the explanation. Within CERES, block-to-block
loading is **uncorrelated** with block-to-block support (r = −0.06). And
**MOPITT, with roughly a third of CERES's points per block, loads higher**
(0.416 vs 0.370). Point count is not what is driving this.

Plausible remaining causes, none tested here: CERES `LW_Radiance` is a
*broadband* longwave flux, not a narrow channel, so it measures a different
integral of the same scene; and its ~20 km footprint against a 0.02° (≈2 km)
target grid means one footprint covers many target cells, which flattens
within-block structure regardless of how many footprints exist. **Distinguishing
those requires a control on the CERES side — a narrowband channel, or a target
grid matched to the footprint — which has not been done.** That is the same
sentence part 4 wrote about MODIS, and it should be read with the same caution:
it is a hypothesis, not a result.

## What this changes in the series

| part 4 said | part 10 finds |
| --- | --- |
| MODIS weakest in 19/32 is "systematic, not block-specific, and the single most investigable finding" | an artifact of reading the 3.75 µm band in daylight |
| block 7 is "the cleanest signature in the dataset ... what a processing fault looks like" | rank 30/32, the second-most congruent block |
| "four instruments agreeing while one contributes nothing" | at 8.55 or 11.03 µm all five agree, gap 0.06 |

Part 4's *method* is unaffected and is what made the retraction possible: the
per-sensor loadings are precisely what localised the anomaly to one instrument,
which is what made "change that instrument's band" the obvious control. A
max-over-pairs statistic would not have pointed anywhere. The defect was in the
input choice, not the statistic.

**The methodological point is the one worth keeping**: an anomaly isolated to a
single sensor is a hypothesis about that sensor's *input*, and the first control
is to vary that input. Part 4 named the control and then reported the finding as
though it had been run. The finding survived one week of being cited in this
series before the control refuted it in an hour of compute.

## A reproducibility gap, fixed

`tf_congruence.py` documented *"Needs `regrid_inputs.npz` from
`bin/tf_discrepancy.py`"*. **No committed script writes that file** — it was an
ad-hoc snippet in the original session, so the congruence stage could not be
rerun from the repo at all. That is why this control needed new code before it
could run.

[`bin/tf_sources.py`](../bin/tf_sources.py) now builds it, with `MODIS_BAND_IDX`
as the control knob, and `tf_congruence.py` takes `TF_NPZ`/`TF_TAG` so bands can
be compared side by side.

Also note the environment had drifted: `netCDF4` and `scipy` were gone from the
conda base that ran parts 1-4, so the analysis stack was rebuilt in an isolated
venv (`ares/.venv-tf`) rather than by modifying the conda env the clio and HDF5
builds depend on.

## Caveats

* **One orbit.** Everything here is `TERRA_BF_L1B_O10204_20011118010522`.
* **The CERES finding is untested**, as set out above. It is now the headline
  candidate, and it should not be cited as a result until its own control has
  been run — precisely the error this part corrects.
* Bands 29 and 31 were chosen as thermal analogues of ASTER TIR-10; the other 13
  emissive bands, and the reflective (`EV_250/500_Aggr1km_RefSB`, `EV_1KM_RefSB`)
  products, were not swept. A full band sweep would establish where the
  transition from "decoupled" to "congruent" occurs.
* MODIS' negative support-loading correlation (−0.50) is unexplained and was not
  pursued; with support varying only 8022-9071 it is a narrow range and may not
  mean much.
* Congruence is still computed only where **all five** sensors are valid, so
  blocks are compared on differing cell counts (868-1517).
* Nearest-neighbour resampling, 0.02° target grid, per-sensor radii unchanged
  from part 4 (ASTER/MODIS/MISR 3 km, CERES/MOPITT 25 km).

## Reproducing

```sh
PY=~/src/hyoklee/ares/.venv-tf/bin/python3      # netCDF4 + numpy + scipy
$PY bin/tf_aster_blocks.py                      # -> aster_blocks.json

for idx in 0 8 10; do                           # bands 20, 29, 31
  MODIS_BAND_IDX=$idx $PY bin/tf_sources.py     # -> regrid_inputs_b<band>.npz
done

for b in b20 b29 b31; do
  TF_NPZ=regrid_inputs_$b.npz TF_TAG=$b $PY bin/tf_congruence.py
done                                            # -> congruence_b<band>.json
```

Roughly 30 s per source build (dominated by MISR's 755 MB single chunk, re-read
each time) and 60 s per congruence run.
