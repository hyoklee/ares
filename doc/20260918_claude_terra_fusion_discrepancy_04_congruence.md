# Terra Fusion 5-sensor discrepancy, part 4: how to measure congruence, and which blocks are suspect

Run on **ares**, 2026-09-18. Replaces the pairwise metric of
[part 2](20260918_claude_terra_fusion_discrepancy_02_ranking.md) with a
multi-sensor congruence statistic that can distinguish CLAUDE.md's two
hypotheses — *processing error* versus *interesting weather* — rather than only
ranking disagreement.

## Why the part-2 metric was not enough

Part 2 ranked blocks by the RMS difference of per-block z-scores. That quantity
is algebraically `sqrt(2(1-r))` — a monotone reparameterisation of **Pearson
r**. Three defects follow:

1. **Only pairwise.** Five sensors give ten pairs and no single answer to "is
   this block congruent?", only a maximum over pairs.
2. **Pearson is the wrong correlation.** Different wavelengths relate
   *monotonically*, not linearly — Planck curve, reflection versus emission. A
   rank correlation is the correct instrument.
3. **It scores anti-correlation as disagreement.** ASTER TIR versus MISR red was
   the top-ranked "discrepancy" in part 2 at 2.026, but that is *the same
   spatial pattern with opposite sign* — congruent structure, not conflict. The
   measurement confirms it: **3.28 of 5 sensors per block** need a sign flip to
   align with the common mode.

## The recommended method

Per block, on target cells where all sensors are valid:

1. **Rank-transform** each sensor's regridded field (Spearman basis).
2. **Sign-align**: take the leading eigenvector of the 5×5 correlation matrix and
   flip any sensor loading negatively, so anti-correlated sensors count as
   congruent.
3. **Congruence** `C = λ₁/n` — the variance fraction in the leading common mode.
   Ranges from `1/n = 0.2` (fully incongruent) to `1.0` (one shared pattern).
4. **Per-sensor loadings** on that mode, and `load_gap` = (highest − lowest).
5. **Kendall's W** on the sign-aligned ranks as an independent cross-check.

`load_gap` is what makes the result actionable:

| signature | reading |
| --- | --- |
| one sensor's loading near zero, the other four high | **that sensor is suspect** — processing error candidate |
| all loadings moderate, small gap, low `C` | **real structure** all sensors partly resolve — weather candidate |
| all loadings high, `C` near 1 | congruent, nothing to investigate |

A max-over-pairs statistic cannot make that distinction; an eigen-decomposition
can, because it separates "how much common signal is there" from "who is not
participating in it".

### Validation

**`C` and Kendall's W agree at Pearson r = 0.986** across the 32 blocks. These
are independently derived — one an eigenvalue of a correlation matrix, the other
a rank-sum concordance — so their agreement is evidence the congruence signal is
real rather than an artifact of the eigen-decomposition.

`C` (all five) against `C` (dense three) correlates at only **r = 0.718**, so the
sparse sensors genuinely change the picture and are not merely adding noise.

## Results

Congruence across the 32 blocks: **min 0.342, median 0.556, max 0.729.**

### A. Single-sensor outliers — processing-error candidates

Ranked by `load_gap`.

| rk | blk | lat0 | lat1 | weakest | its load | gap | C₅ | the other four |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 0 | 15 | 41.57 | 42.26 | **MODIS** | **0.01** | 0.53 | 0.483 | ASTE=0.54 MOPI=0.52 MISR=0.51 CERE=0.42 |
| 1 | 10 | 44.19 | 44.89 | **MISR** | 0.11 | 0.49 | 0.407 | MOPI=0.60 CERE=0.56 ASTE=0.51 MODI=0.24 |
| 2 | 7 | 45.76 | 46.47 | **MODIS** | **0.04** | 0.49 | **0.653** | ASTE=0.53 MISR=0.51 MOPI=0.48 CERE=0.48 |
| 3 | 8 | 45.24 | 45.95 | MODIS | 0.14 | 0.41 | 0.511 | ASTE=0.55 MISR=0.53 MOPI=0.47 CERE=0.43 |
| 4 | 17 | 40.52 | 41.21 | CERES | 0.24 | 0.38 | 0.430 | MISR=0.61 ASTE=0.59 MODI=0.36 MOPI=0.30 |

**Block 7 is the cleanest signature in the dataset**: overall congruence is
*high* (C₅ = 0.653), the other four sensors load 0.48-0.53 — and MODIS loads
**0.04**, essentially orthogonal to a mode the rest share. Four instruments
agreeing while one contributes nothing is what a processing fault looks like;
weather does not single out one instrument while leaving four coherent.

Block 15 is the largest gap (0.53) with MODIS at **0.01**.

**MODIS is the weakest sensor in 19 of 32 blocks** and holds four of the top
eight outlier slots. That is systematic, not block-specific, and is the single
most investigable finding here. It could equally be physical — band 0 of
`EV_1KM_Emissive` is 3.75 µm, which mixes reflected solar and thermal emission
and so may genuinely decouple from both the pure-thermal (ASTER TIR) and
pure-reflective (MISR red) sensors. **Distinguishing those two explanations
requires re-running with a different MODIS band, which has not been done.**

### B. Low congruence with a balanced profile — structure candidates

`load_gap < 0.25`, ranked by C₅.

| rk | blk | lat0 | lat1 | C₅ | C_dense | W | gap |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 0 | 12 | 43.14 | 43.84 | 0.437 | 0.539 | 0.425 | 0.20 |
| 1 | 26 | 35.76 | 36.46 | 0.455 | 0.630 | 0.441 | 0.11 |
| 2 | 20 | 38.94 | 39.63 | 0.479 | 0.706 | 0.470 | 0.21 |
| 3 | 5 | 46.81 | 47.52 | 0.483 | 0.653 | 0.472 | 0.23 |
| 4 | 16 | 41.04 | 41.74 | 0.494 | 0.677 | 0.478 | 0.20 |

These are blocks where no sensor is an outlier but the common mode is weak — all
five partly resolve different aspects of the scene. Block 26 (gap 0.11) is the
most balanced disagreement in the orbit.

Note these are a **different set of blocks** from part 2's ranking. Part 2's top
entry, block 27, does not appear in either list here: its ASTER-MISR
anti-correlation was structure, and the new metric correctly stops counting it as
discrepancy.

## Implementation notes

**Per-sensor search radius is required.** A uniform `maxR = 3000 m` leaves MOPITT
(22 km footprint, 6-19 pixels per block) covering almost no target cells, so
requiring all five sensors at the same cell yields **zero** usable cells and the
whole analysis silently returns nothing. Radii matched to native footprint —
ASTER/MODIS/MISR 3 km, CERES/MOPITT 25 km — fix it. Extrapolating a 1 km sensor
25 km would be wrong; covering 25 km with a 22 km footprint is not.

**Kendall's W needs actual ranks.** Fed standardised z-scores, its numerator
vanishes against the `m²(n³−n)` denominator and W collapses to exactly 0.000 for
every block. Rank 1..n per rater first.

## Caveats

* One MODIS band. The systematic MODIS weakness is the headline candidate and
  **cannot be attributed to a processing fault without testing another band**.
* One orbit, nearest-neighbour resampling, 0.02° target grid.
* CERES and MOPITT are resampled from 58-85 and 6-19 points per block
  respectively. Their loadings are computed on genuinely sparse input and the
  25 km radius means a single footprint can dominate many target cells.
* Congruence is computed only where **all** sensors are valid, so blocks are
  compared on differing cell counts.

## Reproducing

[`bin/tf_congruence.py`](../bin/tf_congruence.py) — Spearman, sign alignment,
λ₁/n congruence, per-sensor loadings, Kendall's W.

```sh
python3 bin/tf_congruence.py     # writes congruence.json
```

Needs `regrid_inputs.npz` from `bin/tf_discrepancy.py`.
