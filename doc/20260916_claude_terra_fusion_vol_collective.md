# Collective I/O through the clio VOL works — and is at parity; the 1.3x "win" was phase ordering

Run on **ares**, 2026-09-16, jobs 24132/24133, node `ares-comp-08`,
`hyoklee/core` `34ce0ab9` + HDF5 2.3.0 (parallel) + netcdf-c 4.10.2 +
netcdf-fortran 4.6.5, all from the forks.

Fourth in the series after
[`20260905`](20260905_claude_terra_fusion_io_study.md) (no clio),
[`20260914`](20260914_claude_terra_fusion_cliofs.md) (clio-fs over FUSE) and
[`20260915`](20260915_claude_terra_fusion_vfd_vol.md) (VFD/VOL, serial). That
last one closed with one question: the VOL now *links* a parallel HDF5, but a
VOL replaces the file API wholesale while `H5Pset_fapl_mpio` configures a
**VFD**, which lives below the native VOL. Whether an MPI-configured FAPL
reaches the under-VOL was undocumented, so nothing so far said whether the
connector could ever sit under E3SM.

## Headline

* **Collective netCDF-4 I/O works through the clio VOL.** `nf90_open_par`
  succeeds, `nf90_var_par_access(NF90_COLLECTIVE)` is accepted, reads scale
  1→8 ranks, **zero errors across 48 cells in two jobs**. The connector
  forwards the MPI FAPL to its under-VOL.
* **Multi-rank clio clients work.** N MPI ranks each running `CLIO_INIT`
  against one runtime over SHM. Every previous clio test in this series drove a
  single process (the FUSE daemon, or a serial reader), so this was untested.
* **Performance is at parity** — 540.9 (native) vs 537.1 (VOL) MiB/s on
  16-chunk MODIS at 8 ranks, a 0.7% gap; ~113 vs ~112 on MISR's 755 MB chunk.
* **An apparent 1.3x VOL speedup was an artifact of phase ordering**, caught by
  a control run and never published. Whichever phase runs second is faster,
  whichever one it is.

**The architectural objection from 09-15 is removed.** The VOL is no longer
disqualified from E3SM's parallel I/O path. It is simply neutral on this
workload — the same conclusion clio-fs and the VFD reached, for the same
reason: zlib inflate caps throughput far below where the data path matters.

## Method

The driver is [`bin/tf_sweep.f90`](../bin/tf_sweep.f90) **unchanged** — it
already does `nf90_open_par` + `nf90_var_par_access(NF90_COLLECTIVE)` — so the
only difference between the two phases is `HDF5_VOL_CONNECTOR` in the
environment. Same binary, same decomposition, same files, same allocation.

| phase | environment |
| --- | --- |
| native | `HDF5_VOL_CONNECTOR`, `HDF5_PLUGIN_PATH`, `HDF5_DRIVER*` all unset |
| clio_vol | `HDF5_VOL_CONNECTOR=clio`, `HDF5_PLUGIN_PATH=$CLIO/lib`, `CLIO_SERVER_CONF` |

Files are the flattened variables from the 09-05 study on node-local NVMe, page
cache evicted before every read, medians reported.

Three outcomes were treated as equally informative going in: `open_par` fails
(no parallel open path), `par_access` fails (opens but no collective mode), or
reads succeed (compare throughput). It was the third.

## The phase-order control, and why it mattered

Job 24132 ran native first, 3 reps, and produced what looked like a clean win:

| `flat_modis` | ranks | native | clio_vol | apparent ratio |
| --- | --- | --- | --- | --- |
| | 1 | 95.1 | 104.1 | 1.09 |
| | 2 | 132.7 | 193.9 | **1.46** |
| | 4 | 240.7 | 339.5 | **1.41** |
| | 8 | 414.5 | 537.1 | **1.30** |

But the native spreads were wide and bimodal with maxima reaching the VOL's
medians (`@2`: 125.8-193.6 against the VOL's tight 193.8-194.6; `@4`:
182.5-295.2 against 334.3-346.4). That is the same signature that produced the
retracted "+29% VFD win" in the 09-15 doc — a noisy baseline, not a fast
adapter — so the number was withheld and job 24133 re-ran with the **phase
order reversed** and 5 reps.

It inverts. Lined up by *phase position* rather than by label:

| `flat_modis` @8 ranks | phase 1 | phase 2 |
| --- | --- | --- |
| job 24132 (native first) | native **414.5** | clio_vol **537.1** |
| job 24133 (VOL first) | clio_vol **478.9** | native **540.9** |

Whichever phase runs second is faster. The second-phase values agree across the
two jobs to 0.7% (537.1 vs 540.9) while both first-phase values sit well below.
There is a first-phase penalty — most plausibly writeback from the `cp` that
stages the files, which `posix_fadvise` eviction does not address — and it
lands on whichever phase is unlucky enough to go first.

## Results

Settled (second-phase) values, MiB/s of logical bytes, collective access.

| variable | ranks | native | clio_vol | ratio |
| --- | --- | --- | --- | --- |
| `flat_modis` (16 × 11 MB) | 1 | 103.7 | 103.1 | 0.99 |
| | 2 | 193.5 | 193.8 | 1.00 |
| | 4 | 343.0 | 340.4 | 0.99 |
| | 8 | **540.9** | **537.1** | **0.99** |
| `flat_misr` (1 × 755 MB) | 1 | 133.8 | 133.8 | 1.00 |
| | 2 | 133.2 | 141.0 | 1.06 |
| | 4 | 132.1 | 132.7 | 1.00 |
| | 8 | 113.5 | 112.1 | 0.99 |

Parity everywhere. The scaling shape is the familiar one from 09-05: MODIS
scales with rank count because it has 16 chunks, MISR is flat then declines
because it has one.

## Method note: phase ordering deserves a control

Two of the four studies in this series produced an apparent clio win that did
not survive scrutiny, and both had the same shape — a noisy first-measured
baseline against a tight later measurement:

* **09-15, VFD, +29% on ASTER** — published, then retracted after a re-run on
  the current forks. Cost: one wrong headline in the repo for a day.
* **09-16, VOL, +30-46% on MODIS** — caught before publication by the phase-order
  control. Cost: one extra 10-minute job.

A phase-order control is cheap and would have caught the first one too. For
within-allocation A/B work of this kind it should be standard: run the
comparison both ways, and believe the effect only if it survives the swap.
`PHASE_ORDER=vol_first` exists in the job script for exactly this.

## Caveats

* Single node, one allocation per job, 3 reps (24132) and 5 reps (24133).
  The parity conclusion rests on the two independent second-phase measurements
  agreeing to 0.7%, not on any single cell.
* The first-phase penalty is characterised but not diagnosed. Writeback from
  the staging `cp` is the plausible cause; it was not confirmed, and
  `posix_fadvise(DONTNEED)` does not address dirty pages.
* Collective **writes** through the VOL are untested — everything here is
  read-only (`NC_NOWRITE`). Given the VOL issues a `PutBlobTask` at close even
  for read-only opens (see 09-15), the write path is worth its own look.
* No multi-node test. Every rank shares one node and one runtime.

## Reproducing

[`bin/tf_vol_parallel.sbatch`](../bin/tf_vol_parallel.sbatch) — both phases in
one allocation, builds the driver on the node, starts the runtime, runs, tears
down.

```sh
sbatch bin/tf_vol_parallel.sbatch                                   # native first
sbatch --export=ALL,PHASE_ORDER=vol_first,REPS=5 bin/tf_vol_parallel.sbatch
```

Knobs: `PHASE_ORDER` (`native_first` | `vol_first`), `REPS`, `RANKS`.

Results: `/mnt/common/hyoklee/tf-clio/runs/volpar_24132/` and `volpar_24133/`.
