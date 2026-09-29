# Terra Fusion 5-sensor discrepancy, part 12: MOPITT carries coherent structure — and nothing in this orbit is anomalous

Run on **ares**, 2026-09-29. Closes the last open item from
[part 11](20260929_claude_terra_fusion_discrepancy_11_ceres_control.md), which
eliminated three explanations for MOPITT's low loading and left one hypothesis
explicitly untested: that MOPITT measures a genuinely different quantity, so a
low loading is correct physics rather than a defect.

## Headline

* **MOPITT's field is coherent, not noise.** Its four channel indices agree with
  each other at median |ρ| = **0.799** — *higher* than the agreement between two
  independent thermal instruments, MODIS vs CERES at **0.711**.
* Within-MOPITT agreement exceeds MOPITT-vs-thermal agreement in **30 of 32**
  blocks (0.799 vs 0.590, a factor of 1.36).
* **So the hypothesis is supported**: MOPITT resolves real, reproducible spatial
  structure that is simply not the thermal common mode.
* **And the framing the series has been using is wrong.** Under the matched
  configuration every one of the ten sensor pairs correlates at **0.443 to
  0.925**. No pair is near zero. "Weakest sensor" means *least aligned among
  five well-correlated sensors*, not *anomalous*.

## The test

Part 11 left two readings open and no way to choose between them from the
congruence numbers alone. MOPITT's four populated channel indices share
footprints, geolocation, search radius and resampling, and differ only in what
they measure — which makes them a built-in control:

| if | then |
| --- | --- |
| MOPITT channels agree with **each other** but not with the thermal sensors | MOPITT carries coherent structure that is not the common mode → "different quantity" |
| MOPITT channels do not agree with each other either | the regridded field is noise-dominated at this scale, and the low loading says nothing about CO |

Both quantities are measured the same way — Spearman |ρ| on the same target
cells, same rank transform — so they are directly comparable.

## Result

| quantity | min | median | max |
| --- | --- | --- | --- |
| \|ρ\| MOPITT channel vs channel | 0.333 | **0.799** | 0.937 |
| \|ρ\| MOPITT vs MODIS / CERES | 0.279 | **0.590** | 0.790 |
| \|ρ\| MODIS vs CERES *(control)* | 0.455 | **0.711** | 0.879 |

* within-MOPITT > MOPITT-vs-thermal in **30 / 32** blocks
* ratio of medians **1.36×**

The control row is what makes this readable. MODIS band 31 and CERES `WN` are
two separate instruments observing overlapping thermal bands; their mutual
agreement of 0.711 is roughly the ceiling one should expect between genuinely
independent measurements of the same field at this resolution. **MOPITT's
internal agreement is above that.** A noise-dominated field cannot do that.

## The bigger correction: nothing here is orthogonal

With the band-selection confounds of parts 10 and 11 removed — MODIS on band 31,
CERES on `WN_Radiance` — the full pairwise picture across 32 blocks is:

| pair | median \|ρ\| | |
| --- | --- | --- |
| ASTER – MODIS | **0.925** | both thermal, 8.29 vs 11.03 µm |
| MODIS – MISR | 0.791 | |
| **CERES – MOPITT** | **0.736** | the two coarse-footprint sensors, agreeing strongly |
| ASTER – MISR | 0.718 | |
| MODIS – CERES | 0.704 | |
| ASTER – CERES | 0.630 | |
| MODIS – MOPITT | 0.568 | |
| ASTER – MOPITT | 0.533 | |
| MISR – CERES | 0.499 | |
| MISR – MOPITT | 0.443 | reflective vs CO — the least-aligned pair |

The ordering is exactly what physics predicts. The two thermal sensors at
adjacent wavelengths agree most (0.925). The reflective sensor and the CO
sensor agree least (0.443). And the two coarse, sparse sensors — CERES at 51-85
footprints per block and MOPITT at 6-19 — agree with *each other* at 0.736,
which is further evidence that their low loadings reflect what they measure and
how they sample, not degradation.

**Nothing in this orbit is orthogonal to anything.** Part 4 described MODIS as
"essentially orthogonal to a mode the rest share" at loading 0.01; that was the
band-20 artifact. At no point under a matched configuration does any sensor pair
fall below |ρ| = 0.44.

### What the congruence loading actually measures

This reframes the metric itself. `C = λ₁/n` and the per-sensor loadings rank
sensors by alignment with the leading common mode. When one sensor's input is
mis-specified — band 20's solar contamination, CERES's broadband integral — that
ranking does expose it, which is what made parts 10 and 11 possible. But once
the inputs are matched, **the loading ordering is a spectral-similarity
ordering, not an anomaly detector.** A sensor at the bottom of it is not
suspect; it is merely the least like the others.

Reading a low loading as evidence of a processing fault — which is what part 4
did — requires first establishing that the sensor's input is comparable. That
step was missing, and it is the whole lesson of parts 10-12.

## Where CLAUDE.md's question now stands

CLAUDE.md asks whether a large discrepancy indicates a processing error or an
interesting weather pattern. For this orbit the sequence resolved as:

| flagged | verdict |
| --- | --- |
| MODIS weakest in 19/32 (part 4) | band 20 reflected-solar contamination — **artifact** |
| CERES weakest in 20/32 (part 10) | broadband-vs-window mismatch — **artifact** |
| MOPITT weakest in 21/32 (part 11) | coherent structure, different quantity — **not a defect** |

**No processing error has been demonstrated in
`TERRA_BF_L1B_O10204_20011118010522`.** All three sensor-level anomalies were
properties of which band was read, and the residual differences between sensors
are physically ordered.

That leaves the *weather* branch of CLAUDE.md's question as the live one. The
block ranking is stable across every configuration tried (Spearman 0.9655
between the LW and WN orderings), and **block 13 (42.62-43.32°N) is the top
discrepancy under all of them**, with a balanced loading profile (gap 0.18,
three sensors within 0.02) — which under part 4's own reading is the signature
of real structure that all five sensors partly resolve, not of one bad sensor.
Confirming that it corresponds to an actual meteorological feature would need
ancillary data — a reanalysis field or a cloud product.

> **Done in
> [part 13](20260929_claude_terra_fusion_discrepancy_13_reanalysis.md), with a
> result that cuts against the weather reading.** Congruence *rises* with
> synoptic activity (cell-averaged rho(|grad T|, C5) = +0.867, p = 0.001), so
> C5 largely measures scene contrast rather than disturbance. Block 13 does
> survive as a genuine outlier — residual z = -2.81 after controlling for the
> thermal gradient — but its dip is sub-grid-scale and its cause is
> unresolved.

## Caveats

* **Shared geolocation.** MOPITT's channels are sampled at identical points, so
  high inter-channel agreement rules out *noise*; it does **not** rule out a
  geolocation error, which would move all four channels together. Testing that
  needs an external reference, not this dataset.
* MOPITT's channels may also be physically correlated by construction if several
  are CO-sensitive. `MOPITTRadiances` records no wavelength per index, so this
  cannot be checked from the file, and the channels are reported by index only.
* Only state 0 of each MOPITT channel was used, and channels 4-7 are the only
  populated ones.
* One orbit. Everything in parts 10-12 rests on a single granule, and none of it
  establishes what would happen at a different season, latitude or overpass time
  — the band-20 result in particular is a *daytime* finding.
* ASTER enters this comparison through the per-block granule read, not the
  strip-wide npz, so the pairwise table mixes two code paths (the same two
  tf_congruence.py already used).
* The "weather" conclusion is an absence of evidence for the processing-error
  branch, not positive evidence for the weather branch.

## Reproducing

```sh
PY=~/src/hyoklee/ares/.venv-tf/bin/python3
$PY bin/tf_mopitt_coherence.py      # -> mopitt_coherence.json
```

Needs `regrid_inputs_b31_WN.npz` plus the `_m50/_m60/_m70` channel variants from
[part 11](20260929_claude_terra_fusion_discrepancy_11_ceres_control.md), and
`aster_blocks.json`. Runs in ~23 s.
