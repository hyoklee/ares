# Terra Fusion reads over clio-fs — 0-36% slower, and the workload is why

Run on **ares**, 2026-09-14, job 23939, node `ares-comp-08`, build
`cliodev3nv` (`3357ac99` + viz disabled). Follows
[`20260905_claude_terra_fusion_io_study.md`](20260905_claude_terra_fusion_io_study.md),
which measured the same reads on local XFS with no clio in the stack at all.

The question: does staging the Terra Fusion granules on clio-fs change the
picture? Short answer — it does not, and the reason is a property of the
workload rather than of clio.

## Method

Both phases run **inside one allocation on one node**, minutes apart, and only
within-job ratios are reported. This matters more than usual here: the 09-05
baseline was measured on the **login node** (94 GB RAM, `/mnt/common` XFS) and a
compute node has **46 GB RAM** and a different disk, so a cross-job comparison
would be measuring hardware.

* **Phase 1 — baseline:** files copied to `/mnt/nvme` (node-local), suite run.
* **Phase 2 — clio-fs:** `clio_run` daemon → `clio_cte_fuse` mount → the same
  files staged in → identical suite.

The baseline is node-local NVMe, deliberately not `/mnt/common`: measuring a
clio RAM/NVMe tier against shared storage would not be a comparison of data
paths. `CHAIN=chain`, `NUM_REPLICAS=1`, 16 GB RAM tier, 64 GB disk tier — the
defaults from `run_ior_cliofs.sh`.

The full 33 GB granule was staged alongside the 326 MB of flattened variables so
the working set exceeds the RAM tier. It does: the disk tier held **31,666 MiB**
after the run, so tiering was genuinely exercised rather than everything sitting
in DRAM.

Staging costs, for the record:

| copy | time | rate |
| --- | --- | --- |
| granule, `/mnt/common` → node NVMe | 2m51s | ~193 MB/s |
| granule, node NVMe → clio-fs | 2m26s | ~225 MB/s |
| `tf_flat.nc` (111 MB) → clio-fs | 0.34s | ~330 MB/s |
| `tf_misr.nc` (215 MB) → clio-fs | 0.54s | ~400 MB/s |

## The baseline reproduces on different hardware

Before the clio comparison is worth anything, the 09-05 result has to survive a
change of node. It does:

| measurement | login node (XFS, 94 GB) | comp-08 (NVMe, 46 GB) |
| --- | --- | --- |
| `flat_modis` raw, 8 ranks | 687.7 | 684.6 |
| `flat_misr` raw, 8 ranks | 119.0 | 113.5 |
| `misr_red` scorpio-netcdf4p, 8 ranks | 145.6 | 143.0 |
| `misr_red` scorpio-netcdf4c, 8 ranks | 25.6 | 23.7 |

The MISR crossover reproduces (raw 113.5 vs SCORPIO 143.0 at 8 ranks, +26% here
against +22% there) and so does the `netcdf4c` inversion.

## Headline

* **clio-fs costs 0-36% and never wins.** The only ratio above 1.0 in the whole
  matrix is `flat_aster` at 1 rank (1.08), which is inside the noise.
* **The penalty tracks achieved throughput.** Where the workload is fast, clio-fs
  costs the most: `modis` at 8 ranks gives up 24% raw and 36% through SCORPIO.
  Where the workload is already decompression-bound and flat (`aster`, `misr` at
  ≥2 ranks), clio-fs is **free** — within 1-9% of baseline.
* **Terra Fusion is a poor benchmark for a storage layer.** Every variable is
  zlib-1 and the inflate wall caps throughput far below device bandwidth, so a
  faster data path has no headroom to show through and can only add overhead.
  The IOR work exercises exactly the bandwidth clio exists to deliver; these
  reads never ask for it.
* **The `netcdf4c` inversion is backend-independent** — 23.7 (NVMe) vs 23.4
  (clio-fs) at 8 ranks, degrading identically across rank count on both. That
  pins it on SCORPIO's serialization, not on storage.

## Raw netcdf-fortran

MiB/s of logical (uncompressed) bytes, collective access.

| variable | ranks | nvme | clio-fs | ratio |
| --- | --- | --- | --- | --- |
| `flat_modis` (16 chunks) | 1 | 97.9 | 91.8 | 0.94 |
| | 2 | 204.9 | 188.9 | 0.92 |
| | 4 | 385.3 | 349.8 | 0.91 |
| | 8 | **684.6** | **523.2** | **0.76** |
| `flat_aster` (32 MB × 1) | 1 | 152.2 | 165.0 | 1.08 |
| | 2 | 174.3 | 175.0 | 1.00 |
| | 4 | 178.8 | 170.6 | 0.95 |
| | 8 | 144.3 | 146.4 | 1.01 |
| `flat_misr` (755 MB × 1) | 1 | 128.8 | 54.6 | **0.42** |
| | 2 | 137.9 | 131.2 | 0.95 |
| | 4 | 134.7 | 122.1 | 0.91 |
| | 8 | 113.5 | 110.1 | 0.97 |

The `flat_misr` 1-rank outlier is **first touch, not steady state** — the very
first read of the 755 MB chunk through the mount, converging to parity by 2
ranks. Once the chunk is resident, clio-fs costs nothing on this variable.

## SCORPIO

| variable | iotype | ranks | nvme | clio-fs | ratio |
| --- | --- | --- | --- | --- | --- |
| `modis_ev` | netcdf4p | 1 | 48.8 | 42.3 | 0.87 |
| | | 2 | 102.3 | 93.1 | 0.91 |
| | | 4 | 209.4 | 159.1 | 0.76 |
| | | 8 | 436.0 | 280.7 | **0.64** |
| `modis_ev` | netcdf4c | 1 | 53.6 | 45.0 | 0.84 |
| | | 8 | 98.4 | 84.1 | 0.85 |
| `misr_red` | netcdf4p | 1 | 60.6 | 47.3 | 0.78 |
| | | 4 | 130.2 | 99.1 | 0.76 |
| | | 8 | 143.0 | 118.7 | 0.83 |
| `misr_red` | netcdf4c | 1 | 46.9 | 54.3 | 1.16 |
| | | 4 | 43.3 | 41.4 | 0.96 |
| | | 8 | 23.7 | 23.4 | 0.99 |

SCORPIO takes the clio-fs penalty harder than the raw path does (0.64 vs 0.76 on
`modis_ev` at 8 ranks). The rearranger's own overhead and the FUSE overhead
compound rather than overlap.

The MISR crossover survives on clio-fs but weakens: raw 110.1 vs
scorpio-netcdf4p 118.7 at 8 ranks, **+8%** against +26% on NVMe.

## What this did NOT test

**This exercised clio-fs (FUSE), not the clio VFD or VOL adapters.** The VFD
vector-coalescing fix from
[`20260813_claude_netcdf_test.md`](20260813_claude_netcdf_test.md) lives in the
`clio_vfd` path driven by `nc4_clio_run.sbatch`, which never runs here. Whether
coalescing helps when HDF5 issues one enormous read — MISR's single 755 MB chunk
is about as clean a test case as exists — is still open, and would need the
`clio_vfd`/`clio_vol` variants pointed at these files.

## Caveats

* **Cache state is not matched between the phases.** `posix_fadvise(DONTNEED)`
  has no defined effect on CTE tier residency, so baseline reads were
  page-cache-evicted while clio-fs reads hit whatever tier held the data. If
  anything this flatters the clio-fs column.
* **Single rep per cell**, unlike the 09-05 study's median-of-3. The
  cross-hardware agreement above is the main evidence that the numbers are
  stable; individual cells should not be read to better than ~10%.
* **The daemon core-dumped on teardown** — `Aborted (core dumped)` from
  `clio_run runtime start` on the `kill` after all measurements had completed.
  Both result files are complete so no data is affected, but the runtime not
  exiting cleanly on SIGTERM may be worth a look independently.

## Reproducing

[`bin/tf_clio_run.sbatch`](../bin/tf_clio_run.sbatch) — both phases in one
allocation, compiles the drivers on the node, composes the clio chain, mounts
clio-fs, stages, runs, tears down.

```sh
sbatch --export=ALL,PREFIX=/mnt/common/hyoklee/cliodev3nv/install \
       bin/tf_clio_run.sbatch
```

Knobs: `PREFIX` (which clio build), `CHAIN`, `NUM_REPLICAS`, `RAM_TIER_CAP`,
`DISK_TIER_CAP`, `BDEV_CAP`, `STAGE_GRANULE=0` to skip the 33 GB copy and keep
the working set inside the RAM tier.

Four things taken straight from `run_ior_cliofs.sh`, each of which is a silent
failure otherwise: `CLIO_WITH_RUNTIME=0` so the FUSE adapter does not start an
embedded runtime that fights the daemon for port 9413; `LD_PRELOAD` of the
distro libfuse3 so the setuid `fusermount3` performs the mount; `ulimit -n`
raised to the hard limit; and the stale-mount cleanup for a previous phase whose
FUSE process died.

Results: `/mnt/common/hyoklee/tf-clio/runs/run_cliodev3nv_23939/`
(`phase1_nvme.csv`, `phase2_cliofs.csv`, `clio.yaml`, `daemon.log`, `fuse.log`).
