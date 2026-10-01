# Terra Fusion, part 18: NVMe tiers on compute nodes — the workload is decompression-bound, so no tier can help

Run on **ares**, 2026-10-01. Re-runs the VOL / VFD / clio-fs comparison in the
regime [part 16](20260929_claude_terra_fusion_discrepancy_16_clio_vol.md) never
tested: **NFS source, node-local NVMe tier, compute node**. Part 16 measured on
the login node where `/mnt/common` is local XFS behind 33 GB of page cache —
the most hostile case a burst tier can face.

The regime changed. The answer did not, and the reason is now definite.

## Headline

* **Storage does not matter for this workload.** NFS cold **10.37 s**, NFS warm
  **10.30 s**, local SSD cold **10.60 s** — a spread of 2.2%.
* **It is decompression-bound.** A warm read runs at **96% CPU** (7.74 s user +
  2.29 s sys of 10.38 s wall). Both datasets are **zlib level 1**.
* **The floor is ~10.4 s and no storage device can go below it.** NVMe can only
  recover the cold-start I/O — about 5.6 s, measured as 15.98 s cold vs 10.38 s
  warm — which a local copy or a warm page cache already does for free.
* **VFD is the only adapter at or below parity**: 10.15 s, −2.1% vs NFS.
* **VOL costs +16% to +27%** — except when its cache hits, where it reaches
  **6.60 s, 1.57× faster than the floor**, because it caches *decompressed*
  images and skips inflate entirely. It hit once in three.
* **clio-fs produced a corrupt read and must not be scored** (below).

## Results

Same binary, same 1318 MiB, 3 reps each, one compute node, exclusive.

| phase | median | min | vs NFS cold |
| --- | --- | --- | --- |
| `nfs_cold` | **10.37 s** | 10.36 | — |
| `nfs_warm` | 10.30 s | 10.25 | −0.7% |
| `ssd_cold` | 10.60 s | 10.57 | +2.2% |
| `vol_default` | 13.14 s | 12.05 | **+26.7%** |
| `vol_readmiss` | 12.13 s | 12.06 | +17.0% |
| `vol_forced` | 12.02 s | **6.60** | +15.9% |
| `vfd_default` | **10.15 s** | 10.10 | **−2.1%** |
| `vfd_readtier` | 10.87 s | 10.76 | +4.8% |
| `cliofs` | *invalid* | — | see below |

## Why no tier can win here

The first three rows are the whole argument. Reading the granule over **NFS**,
reading it over NFS with the cache **warm**, and reading a **node-local SSD
copy** all cost the same within 2.2%. If the workload were I/O-bound those three
would differ by a lot; the device under them changed completely and the clock
did not move.

The direct measurement confirms it:

```
cold: wall 15.98s  user 8.36s  sys 2.72s  cpu 69%
warm: wall 10.38s  user 7.74s  sys 2.29s  cpu 96%
```

**96% CPU on the warm path.** The 10.4 s is almost entirely `zlib` inflate —
both datasets carry `complevel: 1`, MISR in a single 755 MB chunk
(`[180, 512, 2048]`) and MODIS one band per chunk (`[1, 2030, 1354]`).

Put in terms of the device: the benchmark moves **672 MB of file bytes in
~10.3 s, about 65 MB/s**. The NVMe on these nodes does multiple GB/s. The
storage is roughly **30× faster than this workload can consume**, so making it
faster still changes nothing.

**What NVMe can actually buy is the cold-start penalty — 15.98 s → 10.38 s, about
5.6 s or 35%.** That is real, and it is exactly what a node-local copy or a warm
page cache already delivers without any tier software in the path.

## The one thing that beat the floor, and why

`vol_forced` rep 2 came in at **6.60 s** — *below* the 10.4 s decompression
floor. That is not an I/O result and cannot be: no amount of faster reading can
beat a CPU-bound floor.

The VOL caches at the **HDF5 object layer**, so what it stores is the
*materialised, already-decompressed* dataset image. A cache hit does not read
the compressed bytes faster — it **skips inflate altogether**. That is why it is
the only mechanism measured here that goes below the floor, and it is a
decompression win wearing a storage-tier costume.

It is also unreliable: one hit in three runs, and `CLIO_VOL_ADMIT_COST=0` (a
test-suite override, not a supported setting) was needed to get it. The other
two runs paid +16%. Part 16 saw the same shape on the login node — 1 hit in 7,
6.17 s when it landed.

## clio-fs: not a performance result, a correctness one

`cliofs` reported **0.00 s** for all three reps. That is not a speedup. The
benchmark opened the staged file successfully and then found **zero MODIS
granules**, so every phase read nothing and the timer recorded nothing.

The 30.6 GB stage itself reported success (194 s). So clio-fs served a file that
**HDF5 could open but whose group structure it could not traverse** — the file
came back readable at the superblock level and empty underneath.

That is a data-integrity symptom, not a slow one, and it is more serious than
any timing in this table.

> **PURSUED AND REPRODUCED**, see
> [clio-fs silently returns wrong data](20261001_claude_cliofs_silent_corruption.md).
> Files written through a clio-fs mount come back with the **correct size and
> wrong content** — 5 of 10 in the packaged reproducer, with `cp` exiting 0 and
> zero errors logged anywhere. Exactly one 1 MiB CTE page is damaged per
> occurrence, with a 128 KiB sub-block duplicated inside it. Not tier
> exhaustion: it reproduces on a 200 GB tier holding 9.7 GB.

**No clio-fs performance number should be quoted from this study.** Part 16's
figures (+15% steady state) were also never content-verified, so they carry the
same caveat now.

## So what IS the optimal way to use NVMe here?

Not as a storage tier. In order of measured value:

1. **Avoid the cold start** — worth ~5.6 s (35%). A node-local copy on NVMe
   does this, and so does simply reading the file twice. No clio component
   needed; `ssd_cold` at 10.60 s shows even SATA SSD is sufficient, because the
   bottleneck is not the device.
2. **Avoid inflate** — worth ~3.8 s below the floor (1.57×), and the only thing
   that can break 10.4 s. The VOL's decompressed-image cache does this when it
   hits. Making that reliable is where the engineering value is, and it is a
   caching-policy problem, not a storage problem.
3. **Parallelise inflate** — untested here, but it is the obvious remaining
   lever since the work is CPU. [Part 3](20260918_claude_terra_fusion_discrepancy_03_optimization.md)
   measured the optimum at **8 processes** on this hardware for the regrid
   stage, and the chunk layout permits it: MODIS has one chunk per band, so 16
   bands can inflate independently. MISR cannot — its single 755 MB chunk is one
   indivisible inflate, which is the same single-chunk pathology part 3 fixed by
   rechunking for an 8.1× win.

**The highest-value change is still rechunking MISR**, not adding a tier. Part 3
already measured that at 8.1×, and this study explains why: it converts one
serial 755 MB inflate into work that can be divided.

## Caveats

* **The `nfs_cold` numbers are not reliably cold.** `nfs_cold` and `nfs_warm`
  came out within 0.7%, which means `posix_fadvise(DONTNEED)` did not evict the
  NFS page cache. The standalone measurement on an untouched node *did* show a
  genuine 15.98 s cold figure, so a true cold NFS read is slower than this table
  suggests. The storage-independence conclusion does not depend on it — it rests
  on the warm-vs-SSD comparison and the 96% CPU figure.
* 3 reps per cell, one node, one granule (O10204, 30.6 GB).
* `CLIO_VOL_ADMIT_COST=0` is a test override. The 6.60 s is what the hardware
  can do, not a configuration recommendation.
* Parallel decompression was not measured, only inferred from the chunk layout
  and part 3's scaling result.
* The clio-fs failure was observed once and not diagnosed.

## Reproducing

```sh
sbatch bin/tf_nvme_tier_study.sbatch
# phases: nfs_cold nfs_warm ssd_cold vol_{default,readmiss,forced}
#         vfd_{default,readtier} cliofs
```

Tier on `/mnt/nvme` (the device under test), bulk copies on `/mnt/ssd`, cold
control via `bin/tf_evict.py` (`posix_fadvise(DONTNEED)`, no privileges needed).
