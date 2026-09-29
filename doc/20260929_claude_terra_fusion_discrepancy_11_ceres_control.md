# Terra Fusion 5-sensor discrepancy, part 11: the CERES control — spectral, confirmed; and MOPITT is not the same story

Run on **ares**, 2026-09-29. Runs the control that
[part 10](20260929_claude_terra_fusion_discrepancy_10_modis_band_control.md)
flagged as untested, applying the rule part 10 ended on: an anomaly isolated to
one sensor is a hypothesis about that sensor's *input*, so vary the input.

## Headline

* **CERES's weakness is spectral, and it is now fixed.** Swapping
  `LW_Radiance` (broadband, ~5-100 µm) for `WN_Radiance` (the **8-12 µm window
  channel**) takes CERES from weakest sensor in **20 of 32** blocks to weakest
  in **1 of 32**.
* **The footprint hypothesis is refuted.** All three CERES channels share the
  same 6777 points, the same geolocation and the same 25 km search radius — the
  footprint is *identical* — so a change that large cannot be geometric.
* **MOPITT is a different story, and the tidy generalisation fails.** Swapping
  MOPITT's channel does **not** rescue it: it stays weakest in 21, 31, 25 and 30
  of 32 blocks across channels 4-7, and the originally-chosen channel 4 is the
  *best* of the four.
* Two further MOPITT hypotheses were tested and **both eliminated**: target-grid
  resolution (loading flat across a 25× change in cell count) and per-block
  support (r = +0.18, n = 32).
* **The block ranking is robust** to all of this: Spearman 0.9655 between the LW
  and WN orderings, same top four blocks.

## The control

CERES carries five usable radiance channels. Three were run with MODIS held at
band 31 and everything else identical:

| channel | spectral content | radiance range | CERES weakest in | median CERES loading |
| --- | --- | --- | --- | --- |
| `LW_Radiance` (parts 2-10) | broadband longwave ~5-100 µm | 44.58 – 93.49 | **20 / 32** | 0.370 |
| `WN_Radiance` | **window, 8-12 µm** | 10.76 – 28.48 | **1 / 32** | **0.438** |
| `SW_Radiance` | shortwave 0.3-5 µm | 9.24 – 231.2 | 15 / 32 | 0.408 |

The window channel is the right comparison because it overlaps the two sensors
that define the common mode — ASTER TIR-10 at 8.29 µm and MODIS band 31 at
11.03 µm. The broadband LW channel integrates 5-100 µm, so it measures a
genuinely different quantity: a flux, not a channel radiance.

Overall congruence improves accordingly — median C₅ **0.682 → 0.720**, max
0.835 → 0.867.

### Why this rules out the footprint

Part 10 offered two candidate causes and could not separate them. This
separates them cleanly, because the control holds geometry fixed:

| held constant across LW / WN / SW | varied |
| --- | --- |
| 6777 footprints, identical lat/lon | spectral band |
| ~20 km footprint | |
| 25 km search radius, 0.02° target grid | |
| nearest-neighbour resampling | |

CERES's loading moves 0.370 → 0.438 and its weakest-count collapses 20 → 1 with
**no geometric change whatsoever**. A ~20 km footprint against a 2 km grid
cannot be the explanation for a deficit that disappears when only the wavelength
changes.

## MOPITT: the generalisation does not hold

Part 10 ended with MODIS resolved, and this part resolves CERES the same way. It
was tempting to conclude that "weakest sensor" simply tracks spectral distance
from the common mode. **That is wrong, and testing it is what showed it.**

With CERES on the matched window channel, MOPITT inherits the weakest slot
(21/32). Running all four populated MOPITT channel indices:

| MOPITT channel | valid points | MOPITT weakest in | median C₅ |
| --- | --- | --- | --- |
| 4 (used by parts 2-10) | 1652 | **21 / 32** | 0.720 |
| 5 | 1606 | 31 / 32 | 0.686 |
| 6 | 1651 | 25 / 32 | 0.689 |
| 7 | 1619 | 30 / 32 | 0.685 |

Every alternative is **worse**, and the channel chosen back in part 2 turns out
to be the best available. MOPITT's weakness is not a band-selection artifact.

`MOPITTRadiances` records no wavelength per channel index, so these are reported
by index; no band identity is claimed for them.

### Two more MOPITT hypotheses, both eliminated

**Target-grid resolution.** If a ~22 km footprint against a 2 km grid were
flattening MOPITT's structure, coarsening the grid should help:

| target RES | ≈ cell size | cells/block (median) | MOPITT loading | MOPITT weakest in |
| --- | --- | --- | --- | --- |
| 0.02° | 2 km | 1311 | 0.405 | 21 / 32 |
| 0.05° | 5 km | 210 | 0.409 | 18 / 32 |
| 0.10° | 11 km | 54 | 0.411 | 18 / 32 |

**Flat** — 0.405 → 0.411 across a 25× reduction in cell count. (At 0.10° five
blocks fall below the 50-cell floor and drop out, so that row covers 27 blocks.)

**Per-block support.** MOPITT has 6-19 footprints per block. If that were the
limit, blocks with more should score higher. They barely do: **r = +0.18**
across 32 blocks, which at n = 32 is not distinguishable from zero. (CERES, on
the window channel, gives r = +0.10 over 51-85 points.)

Note the resolution sweep tests whether *oversampling the target* hurts. It does
not test MOPITT's information content, which is 6-19 independent samples per
block whatever the grid — coarsening the target adds no MOPITT information.

### What is left for MOPITT

> **ANSWERED in
> [part 12](20260929_claude_terra_fusion_discrepancy_12_mopitt_coherence.md):
> the hypothesis below is supported.** MOPITT's four channels agree with each
> other at median |rho| = 0.799 — above the MODIS-vs-CERES control of 0.711 —
> so its regridded field carries coherent structure and is not noise-dominated.
> Under the matched configuration no sensor pair falls below |rho| = 0.44.

The remaining candidate is that **MOPITT is measuring a different geophysical
quantity**. It retrieves CO, a chemical tracer whose spatial structure need not
follow the cloud-and-surface-temperature field that ASTER, MODIS and CERES all
resolve. If so, a low MOPITT loading is *correct physics* rather than a defect,
and no amount of channel or grid tuning should fix it — which is consistent with
everything measured above.

**This is a hypothesis and is not tested here.** Stating it as a result would
repeat exactly the error part 10 corrected, so it is recorded as the open item
rather than as a finding.

## Ranking stability — the deliverable is robust

The diagnosis of *which sensor is weak* turned out to be highly sensitive to
band choice. The block ranking that CLAUDE.md actually asks for is not:

* Spearman correlation between the LW and WN block orderings: **0.9655**
* top-5 under LW: **13, 26, 10, 20**, 12
* top-5 under WN: **13, 26, 10, 20**, 17
* C₅ vs Kendall's W under WN: **r = 0.9938**

**Block 13 (42.62-43.32°N) is the top discrepancy under every configuration
tried** — bands 20/29/31, CERES LW/WN/SW, and all three resolutions.

Top of the corrected ranking (MODIS band 31, CERES `WN_Radiance`, 0.02°):

| rk | blk | lat0 | lat1 | C₅ | C_dense | W | weakest | gap | loadings |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 0 | **13** | 42.62 | 43.32 | **0.508** | 0.696 | 0.490 | MOPITT | 0.18 | MODI=0.55 ASTE=0.51 MISR=0.39 CERE=0.39 MOPI=0.37 |
| 1 | 26 | 35.76 | 36.46 | 0.535 | 0.638 | 0.508 | MISR | 0.27 | MODI=0.54 ASTE=0.49 CERE=0.46 MOPI=0.43 MISR=0.27 |
| 2 | 10 | 44.19 | 44.89 | 0.558 | 0.652 | 0.513 | MISR | 0.39 | MODI=0.53 ASTE=0.50 MOPI=0.48 CERE=0.47 MISR=0.14 |
| 3 | 20 | 38.94 | 39.63 | 0.594 | 0.767 | 0.585 | MISR | 0.15 | MODI=0.53 ASTE=0.50 CERE=0.43 MOPI=0.38 MISR=0.37 |
| 4 | 17 | 40.52 | 41.21 | 0.598 | 0.872 | 0.570 | MOPITT | 0.26 | MODI=0.55 ASTE=0.52 MISR=0.49 CERE=0.33 MOPI=0.28 |

Block 13's profile is now *balanced* (gap 0.18, three sensors within 0.02 of
each other) rather than single-sensor — under part 4's own reading, a
**structure/weather candidate**, not a processing-error one. Block 10 is the
clearest remaining single-sensor case, with MISR at 0.14 against MODIS 0.53.

## Where the series now stands on CLAUDE.md's question

CLAUDE.md asks whether a large discrepancy means a processing error or an
interesting weather pattern. After parts 10 and 11, the honest answer for this
orbit is: **so far, neither — every large discrepancy examined has been an
artifact of which band was read.**

| flagged as suspect | verdict |
| --- | --- |
| MODIS weakest in 19/32 (part 4) | band 20's reflected-solar contamination; gone at 8.55/11.03 µm |
| CERES weakest in 20/32 (part 10) | broadband-vs-window mismatch; gone on `WN_Radiance` |
| MOPITT weakest in 21/32 (here) | **open** — not spectral, not resolution, not support |

Two of three "suspect sensor" findings dissolved under their own control. That
is the practical lesson for anyone running this kind of cross-sensor comparison:
**before reporting a sensor as anomalous, vary its input.** The cost here was
about a minute of compute per control, against a finding that stood in this
series for eleven days.

## Caveats

* One orbit, `TERRA_BF_L1B_O10204_20011118010522`.
* **The MOPITT explanation is untested**, as set out above.
* `TOT_Filtered_Radiance` and the two `*_Filtered_*` CERES channels were not
  run; only LW, WN and SW.
* MOPITT states (`[...,chan,1]`) were not swept — only state 0 of each channel.
* The 0.10° resolution row covers 27 blocks, not 32, because five fall below the
  50-cell floor. Comparisons across that row are on a different block set.
* MISR is reflective-only and has no thermal analogue in this product, so it
  cannot be spectrally matched to the thermal common mode the way MODIS and
  CERES now are. It is weakest in 10/32 under the matched configuration and was
  not controlled.
* Everything remains nearest-neighbour resampling with per-sensor radii
  (ASTER/MODIS/MISR 3 km, CERES/MOPITT 25 km).

## Reproducing

```sh
PY=~/src/hyoklee/ares/.venv-tf/bin/python3

# CERES spectral control (MODIS band 31 fixed)
for cf in LW_Radiance WN_Radiance SW_Radiance; do
  MODIS_BAND_IDX=10 CERES_FIELD=$cf $PY bin/tf_sources.py
done

# MOPITT channel control (CERES on the matched window channel)
for ch in 5 6 7; do
  MODIS_BAND_IDX=10 CERES_FIELD=WN_Radiance MOPITT_CHAN=$ch $PY bin/tf_sources.py
done

# resolution control
for r in 0.02 0.05 0.10; do
  TF_RES=$r TF_NPZ=regrid_inputs_b31_WN.npz TF_TAG=WNres$r $PY bin/tf_congruence.py
done
```

`bin/tf_sources.py` gained `CERES_FIELD`, `MOPITT_CHAN` and `MOPITT_STATE`;
`bin/tf_congruence.py` gained `TF_RES`. `tf_sources.py` now also honours
`valid_range`, which CERES uses where MODIS and MOPITT use
`valid_min`/`valid_max` — this changes no counts for `LW_Radiance` (6777 points
before and after, so part 10 is unaffected) but matters for `SW_Radiance`, whose
valid range is [−10, 510].
