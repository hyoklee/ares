# NetCDF-4 through the clio-core VFD and VOL on ares

Run on **ares**, 2026-08-13, answering
[`20260813_claude_netcdf_test.md`](20260813_claude_netcdf_test.md): build
netCDF-C `main` once, run its `tst_chunks3` benchmark three ways on one HDF5
`develop` build, and compare. Plot page:
[`20260813_claude_netcdf_plots.html`](20260813_claude_netcdf_plots.html)
(same renderer as
[hpf's published page](https://hyoklee.github.io/hpf/benchmarks_nc4_clio/plots.html):
18 charts, three series each, one point per run).

## Headline

* **The CLIO VOL is a flat ~2.5–2.9x CPU tax**, remarkably uniform: every one of
  the 18 benchmarks lands between 1.8x and 6.8x the baseline. Nothing pathological.
* **The CLIO VFD is cheaper than the VOL on 14 of 18 benchmarks (median
  1.4–1.6x) and catastrophic on one.** `contiguous write 256x256x1` — the
  unchunked variable written one xy-slab at a time — costs **1200–1600 s against
  a 6.1 s baseline (165–271x)**, and that single operation is **96–97% of the
  VFD's entire total**. Its read counterpart is the next worst at 11x; the
  remaining 16 benchmarks are all ≤ 8.5x.
* **The CTE tier medium is nearly irrelevant to what this benchmark reports.**
  Node-local NVMe vs DRAM: median ratio **0.97–0.99x** over all 18 benchmarks,
  for all three variants. Moving the netCDF file itself from node-local NVMe to
  shared NFS changes almost as little.
* **That is a property of the benchmark, not a claim that storage is free.**
  `tst_chunks3` reports `getrusage` **CPU time**, not elapsed time, so I/O wait
  is invisible to it while adapter overhead is fully counted. Job wall-clock
  *does* separate the tiers: 829/875 s on DRAM vs 1049/1074 s on NVMe (~+23%).
* **The CLIO VOL never exits cleanly.** All five runs measured all 18 timings and
  then hung in teardown and had to be killed — the known
  `H5_term_library`/atexit ordering bug, reproduced here on every single run.
* **Doubling dimensions and chunks costs ~8x per step for all three variants,
  and the series ends at 256³** — where it ends because plain HDF5 needs more
  than 90 minutes at 512³, not because clio-core broke.

## What was built

| component | checkout | branch | commit |
| --- | --- | --- | --- |
| HDF5 | `~/src/HDFGroup/hdf5` | `develop` | `e4b6a964723` (reports 2.3.0) |
| netCDF-C | `~/src/unidata/netcdf-c` | `main` | `db5a7f931` |
| clio-core | `~/src/iowarp/clio-core/dev/conda` | `dev` | `edd8ab45` |

All three were clean checkouts at that day's HEAD. The build is driven by hpf's
`.github/scripts/nc4_clio_bench.sh` — the same script its CI uses — so these
numbers are comparable in kind with the published dashboard.

The three variants share **one** netCDF-C binary and **one** HDF5 build; only the
HDF5 plugin environment differs:

| variant | selection |
| --- | --- |
| `baseline` | nothing set — sec2 VFD, native VOL |
| `clio_vfd` | `HDF5_DRIVER=clio_vfd`, `HDF5_DRIVER_CONFIG=cache=1` |
| `clio_vol` | `HDF5_VOL_CONNECTOR=clio` (under-VOL native) |

Both plugins were verified by `ldd` to resolve
`nc4-clio-work/hdf5-install/lib/libhdf5.so.1000` — the HDF5 just built, not the
one in the conda base at `~/mc3`. Without that gate a plugin can silently bind
the wrong libhdf5 and fall back to native, which would make a CLIO series a
duplicate of the baseline.

### Two ares-specific things

**`ares-comp-08` has no `libelf-dev`.** clio-core builds with
`CLIO_CORE_ENABLE_ELF=ON` on Linux, which does
`pkg_check_modules(libelf REQUIRED)`; that fails on comp-08 and only comp-08
(03–07 all have it), while a bare `pkg-config --exists libelf` on the same node
succeeds — because the *runtime* `libelf.so.1` is installed there and the headers
are not. Two builds were lost to this before the node was identified;
`nc4_clio_build.sbatch` now carries `--exclude=ares-comp-08`. Runs are
unaffected.

**HDF5 `develop` needs CMake ≥ 3.26 and the system CMake is 3.22.** The build
puts the conda CMake (4.2.3) on `PATH` through a one-entry symlink directory
rather than prepending all of `~/mc3/bin`, which would also hand the build
conda's compilers, zlib, and libhdf5.

## How it was run

One ares compute node per job, `--exclusive` (Xeon Silver 4114, 2x10 cores /
40 threads, 46 GB RAM, 24 GB `/dev/shm`, node-local Samsung 960 EVO NVMe at
`/mnt/nvme`). Scripts are in [`../bin`](../bin):

| script | role |
| --- | --- |
| `nc4_clio_build.sbatch` | builds all three components (one job) |
| `nc4_clio_run.sbatch` | one measurement job: three variants at one size |
| `nc4_clio_sweep.sbatch` | the dimension/chunk doubling sweep |
| `nc4_clio_runtime_{ram,nvme}.yaml` | `clio_run` compose configs, DRAM vs NVMe CTE tier |
| `nc4_clio_sample_page.py` | local results → the hpf plot page |
| `nc4_clio_table.py`, `nc4_clio_sweep_table.py` | results → the tables below |

Two things the wrapper adds over the CI driver, both necessary here:

1. **The run directory is node-local.** The driver puts `tst_chunks3`'s cwd under
   its work directory, which on ares is the shared `/mnt/common` — i.e. NFS.
   Measuring an HDF5 baseline against NFS while CLIO buffers in node-local DRAM
   would not be a comparison of adapters. It is redirected to `/mnt/nvme` by
   default (`FILEDIR=nvme`); `FILEDIR=shared` is used once, deliberately, below.
2. **Per-job work directories**, so jobs can measure on several nodes at once —
   symlinks to the shared build tree, plus a *hard* link for `tst_chunks3`
   (the driver finds it with `find ... -type f`, which neither descends a
   symlinked directory nor matches a symlink).

Workload: `tst_chunks3 6 256 64 256 64 256 64` — a 256³ float variable stored
three ways (contiguous, chunked 64³, chunked+deflate 6) in one netCDF-4 file,
each written and read along three access shapes. 192 MiB of variable data;
18 timings per variant.

### What the numbers are

`tst_chunks3`'s timing macros are built on `getrusage(RUSAGE_SELF)`:

```c
emic = (1000000*(ru.ru_utime.tv_sec + ru.ru_stime.tv_sec)
         + ru.ru_utime.tv_usec + ru.ru_stime.tv_usec) - emic;
seconds = emic / (1000000.0 * TMreps);
```

So every number below is **process CPU time, summed over all threads**, not
elapsed time. Two consequences that matter for reading this report:

* Time spent *waiting* on a device is not counted, which is why swapping the CTE
  tier between DRAM and NVMe — or the file between NVMe and NFS — barely moves
  these numbers.
* CLIO's cost *is* counted, in full, including its client-side polling threads.
  A CLIO timing can exceed the wall-clock time of the operation that produced it.

Both effects are real and neither is a defect in the measurement — but a reader
who assumes "seconds" means elapsed time will draw the wrong conclusion from
this benchmark, on this dashboard as much as here.

## The comparison at 256³

Job 23559 (`ram1`), CTE tier in DRAM, file on node-local NVMe. Seconds of CPU
time; "x base" is the ratio to the baseline column.

| benchmark | baseline (s) | CLIO VFD (s) | x base | CLIO VOL (s) | x base |
| --- | ---: | ---: | ---: | ---: | ---: |
| contiguous write 1x256x256 | 0.026 | 0.22 | 8.5x | 0.14 | 5.4x |
| chunked write 1x256x256 / chunks 64x64x64 | 0.028 | 0.12 | 4.3x | 0.18 | 6.4x |
| compressed write 1x256x256 / chunks 64x64x64 | 0.028 | 0.1 | 3.6x | 0.19 | 6.8x |
| contiguous write 256x1x256 | 1.30 | 3.00 | 2.3x | 2.60 | 2.0x |
| chunked write 256x1x256 / chunks 64x64x64 | 0.046 | 0.11 | 2.4x | 0.18 | 3.9x |
| compressed write 256x1x256 / chunks 64x64x64 | 0.045 | 0.11 | 2.4x | 0.18 | 4.0x |
| **contiguous write 256x256x1** | **6.10** | **1200** | **196.7x** | **11.00** | **1.8x** |
| chunked write 256x256x1 / chunks 64x64x64 | 0.38 | 0.61 | 1.6x | 0.85 | 2.2x |
| compressed write 256x256x1 / chunks 64x64x64 | 0.38 | 0.62 | 1.6x | 0.83 | 2.2x |
| contiguous read 1x256x256 | 0.018 | 0.028 | 1.6x | 0.057 | 3.2x |
| chunked read 1x256x256 / chunks 64x64x64 | 0.027 | 0.038 | 1.4x | 0.078 | 2.9x |
| compressed read 1x256x256 / chunks 64x64x64 | 0.028 | 0.034 | 1.2x | 0.08 | 2.9x |
| contiguous read 256x1x256 | 0.63 | 0.18 | **0.3x** | 1.30 | 2.1x |
| chunked read 256x1x256 / chunks 64x64x64 | 0.033 | 0.047 | 1.4x | 0.1 | 3.0x |
| compressed read 256x1x256 / chunks 64x64x64 | 0.033 | 0.047 | 1.4x | 0.092 | 2.8x |
| **contiguous read 256x256x1** | **3.50** | **39.00** | **11.1x** | **6.60** | **1.9x** |
| chunked read 256x256x1 / chunks 64x64x64 | 0.38 | 0.5 | 1.3x | 0.88 | 2.3x |
| compressed read 256x256x1 / chunks 64x64x64 | 0.38 | 0.52 | 1.4x | 0.85 | 2.2x |

Per run, over all 18 benchmarks:

| run | tier | file | VFD median | VFD worst | VOL median | VOL worst | Σ base | Σ VFD | Σ VOL |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| ram1 (23559) | DRAM | NVMe | 1.62x | 197x | 2.82x | 6.8x | 13.4 | 1245 | 26.2 |
| ram2 (23564) | DRAM | NVMe | 1.41x | 213x | 2.76x | 6.4x | 13.3 | 1343 | 24.6 |
| nvme1 (23565) | NVMe | NVMe | 1.45x | 250x | 2.59x | 6.4x | 13.0 | 1543 | 24.2 |
| nvme2 (23566) | NVMe | NVMe | 1.43x | 271x | 2.54x | 6.4x | 12.8 | 1643 | 24.1 |
| nfs1 (23567) | DRAM | NFS | 1.64x | 164x | 2.85x | 6.8x | 14.8 | 1246 | 28.3 |

Three things worth pulling out:

* **One operation is the whole VFD story.** `contiguous write 256x256x1` is
  96–97% of the VFD's 1245 s total. Drop it and the VFD is a ~1.5x tax, cheaper
  than the VOL on 14 of the 18 benchmarks.
* **The access pattern that hurts is the strided one on an unchunked variable.**
  The xy-slab loop touches `dim[0]*dim[1]` non-contiguous regions per slab; HDF5
  turns that into a very large number of small, scattered I/O requests, and
  every one of them becomes a CLIO task. The runtime log shows the scheduler
  routing ~50M tasks and repeatedly reporting "heavy class saturated". Chunking
  the same variable (the `chunked`/`compressed` rows, same shape) drops the VFD
  to 1.6x.
* **The VFD beats the baseline once**: `contiguous read 256x1x256`, 0.18 s vs
  0.63 s (0.3x), reproducibly in all five runs — the CTE cache tier serving
  reads that the baseline takes from the file.

Run-to-run reproducibility is good: the baseline agrees to two significant
figures between `ram1` and `ram2`, the VOL within ~5%, the VFD within ~8% (its
big operation, 1200 vs 1300 s). This is much steadier than the wall-clock IOR
numbers in the earlier ares reports — again because these are CPU times.

## NVMe on the compute node

Two questions, answered separately.

### The CTE tier: DRAM vs node-local NVMe

`nc4_clio_runtime_nvme.yaml` is identical to the DRAM config except for one CTE
storage entry — a file-backed bdev on `/mnt/nvme` instead of a RAM tier. The
tier really was used: `clio_run` created
`/mnt/nvme/hyoklee/nc4_clio/cte_tier1_node0` (1 GiB file, ~128 MB actually
allocated after the run) and its own probe measured that device at
**477 MB/s read / 580 MB/s write**.

Ratio of NVMe-tier to DRAM-tier timings, median over all 18 benchmarks
(two runs each, summed):

| variant | median | min | max |
| --- | ---: | ---: | ---: |
| baseline | 0.99x | 0.94 | 1.04 |
| CLIO VFD | 0.97x | 0.88 | 1.24 |
| CLIO VOL | 0.97x | 0.91 | 1.25 |

**In CPU terms the tier medium is indistinguishable.** The `max` column is where
it shows: the tail is the pathological VFD write (1200/1300 s on DRAM vs
1500/1600 s on NVMe, +23%).

Wall-clock tells the same story more honestly, because it includes the I/O wait
that `getrusage` omits — total job time for the identical three-variant workload:

| tier | jobs | wall clock |
| --- | --- | --- |
| DRAM | 23559, 23564 | 829 s, 875 s |
| NVMe | 23565, 23566 | 1049 s, 1074 s |

So the node-local NVMe tier costs **~23% wall clock** against DRAM here, and buys
nothing at this working-set size (192 MiB, which fits the 8 GB DRAM tier with
room to spare). Its value would be capacity rather than speed — and the scaling
sweep below never reached a size where that capacity mattered, so this run does
not test it.

### The file: node-local NVMe vs shared NFS

`nfs1` (23567) repeats `ram1` with `tst_chunks3`'s output file on `/mnt/common`
(NFS) instead of `/mnt/nvme`. The baseline's totals move from 13.4 s to 14.8 s
(+10%, concentrated in the two contiguous strided writes: 6.1 → 7.3 s and
1.3 → 1.5 s); the CLIO variants are unchanged within noise. Again: this
benchmark counts CPU, and NFS costs wait, not CPU.

## Effect of doubling dimensions and chunk sizes

`nc4_clio_sweep.sbatch` starts at 64³ with 16³ chunks and doubles **both** the
dimension and the chunk edge each step, so each step multiplies the data by 8.
Two sweeps ran in parallel, one per CTE tier (jobs 23561 DRAM, 23562 NVMe).
Σ is the sum of all 18 timings; "growth" is against the previous size.

| dim | chunk | data MiB | variant | Σ 18 timings (s) | growth | worst op (s) |
| ---: | ---: | ---: | --- | ---: | ---: | ---: |
| | | | **DRAM CTE tier** | | | |
| 64 | 16 | 3 | baseline | 0.158 | — | 0.029 |
| 64 | 16 | 3 | CLIO VFD | 20.0 | — | 19 |
| 64 | 16 | 3 | CLIO VOL | 0.414 | — | 0.065 |
| 128 | 32 | 24 | baseline | 1.32 | 8.4x | 0.37 |
| 128 | 32 | 24 | CLIO VFD | 186 | 9.3x | 180 |
| 128 | 32 | 24 | CLIO VOL | 2.99 | 7.2x | 0.79 |
| 256 | 64 | 192 | baseline | 13.3 | 10.1x | 6.1 |
| 256 | 64 | 192 | CLIO VFD | 1240 | 6.7x | 1200 |
| 256 | 64 | 192 | CLIO VOL | 24.2 | 8.1x | 9.6 |
| | | | **NVMe CTE tier** | | | |
| 64 | 16 | 3 | baseline | 0.160 | — | 0.029 |
| 64 | 16 | 3 | CLIO VFD | 27.1 | — | 26 |
| 64 | 16 | 3 | CLIO VOL | 0.421 | — | 0.065 |
| 128 | 32 | 24 | baseline | 1.32 | 8.3x | 0.37 |
| 128 | 32 | 24 | CLIO VFD | 186 | 6.9x | 180 |
| 128 | 32 | 24 | CLIO VOL | 2.91 | 6.9x | 0.77 |
| 256 | 64 | 192 | baseline | 13.9 | 10.5x | 6.3 |
| 256 | 64 | 192 | CLIO VFD | 1640 | 8.8x | 1600 |
| 256 | 64 | 192 | CLIO VOL | 25.0 | 8.6x | 10 |

**Through 256³, cost tracks data volume for all three variants.** Each doubling
multiplies the data by 8 and the total by 6.7–10.5x — including the CLIO VFD.
Its penalty is an enormous *constant factor* on one access pattern, not an
exponent that degrades with size, and the two tiers scale identically.

### Where it stops

At **512³ / chunk 128³** (1.5 GiB of variable data) the run does not complete —
and the first thing to fail is **not** CLIO:

| job | tier | variants | outcome |
| --- | --- | --- | --- |
| 23561 / 23562 (sweeps) | DRAM / NVMe | all three | baseline killed at the 20 min cap |
| 23569 | DRAM | baseline, VOL | **both** killed at a 90 min cap, < 18 timings |
| 23570 | NVMe | baseline, VOL | **both** killed at a 90 min cap, < 18 timings |

Plain netCDF-4 on stock HDF5 needs more than **90 minutes** of wall clock for
this workload at 512³, against 13.3 s of CPU (and a small multiple of that in
wall clock) at 256³ — far worse than the 8x the data grew by. The
mechanism is visible in the shape of the benchmark: `contiguous write NxNx1`
walks an unchunked variable with a stride of `N*4` bytes, so as N doubles both
the element count and the stride double, and past 256³ the working set
(512 MiB per variable) leaves the HDF5 chunk cache (67 MB) and the access
degenerates into scattered per-element I/O. That is a property of `tst_chunks3`
at these dimensions, not of any adapter.

So the doubling experiment ends at **256³ for every variant**, and the honest
statement of "where clio-core fails" is about *practicality*, not correctness:

* **The CLIO VFD is the first to become unusable, at 256³.** It still completes,
  but `contiguous write 256x256x1` costs 1200–1600 s of CPU against 6.1 s, and
  the VFD accounts for essentially all of a sweep step's wall clock at that size
  (905 s for the whole 256³ step, while the baseline and VOL together sum to
  under 40 s of CPU). Applying its own measured 6.7–8.8x per doubling to that
  operation puts it near **3 hours at 512³** — an extrapolation, not a
  measurement: a 3-hour VFD job at 512³ (23571) was started and then cancelled
  once the baseline's own 90-minute failure made the size unreachable for every
  variant.
* **The CLIO VOL tracks the baseline all the way up** and fails at exactly the
  same size the baseline does, for the same reason.
* **No capacity failure was reached.** The DRAM tier (8 GB) and the NVMe tier
  never had to hold more than the 192 MiB working set of the largest completed
  size, so nothing here tests the capacity advantage a node-local NVMe tier is
  supposed to buy. That would need a workload that grows the working set without
  the unchunked strided writes that cap this one — `tst_chunks3` cannot separate
  the two.

## Reproducing

```bash
sbatch bin/nc4_clio_build.sbatch                     # ~35 min, one node

# Set the knobs in the environment, not in --export=ALL,K=V: VARIANTS and
# BENCH_ARGS contain commas/spaces and --export would split them into more
# variables ("Batch script is empty!" is what that looks like).
TAG=ram1 TIER=ram FILEDIR=nvme RUN_TIMEOUT=30m \
  BENCH_ARGS="6 256 64 256 64 256 64" \
  sbatch --export=ALL bin/nc4_clio_run.sbatch

TIER=ram D0=64 C0=16 STEPS=6 RUN_TIMEOUT=20m \
  sbatch --export=ALL bin/nc4_clio_sweep.sbatch

python3 bin/nc4_clio_sample_page.py doc/20260813_claude_netcdf_plots.html \
        ram1=<results-dir> ...
```

`RUN_TIMEOUT` is per variant and applies to the *baseline* too — at 512³ that is
what stops the sweep, so a sweep meant to reach 512³ needs hours per variant,
not the 20 minutes that is ample through 256³.

Results, logs, and the `clio_run` log for every job are under
`/mnt/common/hyoklee/nc4-clio-work/results/<tag>_<jobid>/`.
