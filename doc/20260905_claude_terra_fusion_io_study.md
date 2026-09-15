# Terra Fusion parallel netCDF-4 reads — chunk layout decides everything

Run on **ares**, 2026-09-05. Whole stack built from source: HDF5 `develop`,
netcdf-c `main`, netcdf-fortran, SCORPIO. **No clio in the stack** — plain XFS,
HDF5's `sec2` driver, MPICH ROMIO. Followed up on clio-fs in
[`20260914_claude_terra_fusion_cliofs.md`](20260914_claude_terra_fusion_cliofs.md).

The question was whether E3SM's I/O layer (SCORPIO) can read the Terra Fusion
Basic Fusion granules in `/mnt/common/datasets-staging`, and what read
throughput looks like across chunk layouts, rank counts, access modes and cache
state.

## Corpus

Ten Basic Fusion granules, **284 GB**. The nine 2001-2002 orbits are spaced
exactly 233 orbits apart — Terra's 16-day ground-repeat cycle — all at ~01:03-01:05
UTC equator crossing, so this is a deliberate repeat-track sample rather than a
random grab.

| orbit | date | size | instruments |
| --- | --- | --- | --- |
| O1117 | 2000-03-04 | 16.8 GB | CERES MISR MODIS MOPITT (no ASTER) |
| O10204 | 2001-11-18 | 32.9 GB | all 5 |
| O10437 | 2001-12-04 | 17.4 GB | all 5 |
| O10670 | 2001-12-20 | 45.4 GB | all 5 |
| O10903 | 2002-01-05 | 51.0 GB | all 5 |
| O11136 | 2002-01-21 | 28.3 GB | all 5 |
| O11369 | 2002-02-06 | 45.3 GB | all 5 |
| O11602 | 2002-02-22 | 39.6 GB | all 5 |
| O11835 | 2002-03-10 | 23.7 GB | all 5 |
| O12068 | 2002-03-26 | 4.2 GB | MISR MOPITT only (truncated) |

**These files are genuine netCDF-4**, not merely HDF5 that resembles it. The
from-source netcdf-c reports `ncdump -k → netCDF-4`; `nc_open` succeeds with 281
named root dimensions, the full group hierarchy, and named dimensions on every
variable. The dimension scales carry
`NAME = "This is a netCDF dimension but not a netCDF variable."`, a string the
netCDF-4 library itself emits — so they were written *through* the netCDF-4 API.

All measurements below use `O10204`.

## Stack

| component | version | revision | prefix |
| --- | --- | --- | --- |
| HDF5 | 2.3.0 (`develop`) | `f720275127` | `/mnt/common/hyoklee/opt/hdf5-develop` |
| netcdf-c | 4.10.2-development | `9039e1987` | `/mnt/common/hyoklee/opt/netcdf-c` |
| netcdf-fortran | 4.6.5-development | `db3d1a2` | `/mnt/common/hyoklee/opt/netcdf-fortran` |
| SCORPIO | v2.0.3 | `8d79456` | `/mnt/common/hyoklee/opt/scorpio` |

MPICH 4.1.1, gcc 11.4.0, cmake 3.30.5. Parallel HDF5 on, zlib on, szip off,
DAP/byterange/NCZARR off, PnetCDF off (not installed, and it cannot read
netCDF-4 anyway). `netcdf-c 4.10.2 builds clean against HDF5 2.3.0`, and
SCORPIO's `WITH_HDF5=ON` holds against HDF5 2.x — neither pairing needed a
workaround.

Host: 40 cores, 94 GB RAM, XFS on local RAID (`sunit=128`/`swidth=768` → 64 KB
stripe unit, 6-wide). Not a parallel filesystem; single-node numbers only.

## Two environment bugs found while building

**1. HDF5 `develop` does not build on glibc < 2.38.** `src/H5private.h:156`
supplies portable `strlcpy`/`strlcat` but guards them with
`#ifdef H5_HAVE_WIN32_API`, assuming every non-Windows platform has them. glibc
only gained them in 2.38 (Aug 2023). On ares (glibc 2.35) the symbols are absent
and the build dies:

```
/usr/bin/ld: bin/libhdf5.so.1000.0.0: undefined reference to `strlcpy'
h5repack_copy.c:(.text+0x2ef): undefined reference to `strlcat'
```

The uses are in the core library (`H5FDonion.c:855`, `H5Pfapl.c:4184`), so
`libhdf5.so` itself carries the undefined symbols and every consumer fails.
There is no `HAVE_STRLCPY` configure check anywhere in the tree to catch it.
This breaks Ubuntu 22.04, RHEL 8/9 and Debian 11/12. Proper fix is a configure
check plus a widened guard, e.g. `#if defined(H5_HAVE_WIN32_API) || !defined(H5_HAVE_STRLCPY)`.
Worked around here with an external force-included shim
(`-DCMAKE_C_FLAGS="-include strlcpy_shim.h"`), leaving the HDF5 tree unmodified.
Note the shim compiles *into* `libhdf5.so`, so downstream builds need nothing —
only a rebuild of HDF5 itself does.

**2. Any CMake `QUERY FQDN` hangs on ares.** SCORPIO's `CMakeLists.txt:84` calls
`cmake_host_system_information(RESULT FQDN_SITENAME QUERY FQDN)` purely to
pattern-match HPC sites (`cori`, `theta`, `summit`, `frontier`). The hostname is
`ares.ares.local`, and `.local` is the mDNS domain, so forward resolution falls
through to systemd-resolved's mDNS path and never returns. Configure sat blocked
in `do_poll` on a UDP socket to `127.0.0.53:53` for 14+ minutes:

```
getent hosts ares.ares.local   → timeout (rc=124)
getent hosts 127.0.1.1         → instant
```

This will hang *any* CMake project doing an FQDN query on this host. Real fix is
an `/etc/hosts` entry (needs root). Worked around by running the build in a user
namespace with `hosts: files` bind-mounted over `/etc/nsswitch.conf`.

## SCORPIO cannot read Terra Fusion granules

**SCORPIO has no netCDF-4 group API.** No `inq_grp`, `inq_ncid`, `def_grp` or
`nc_inq_grps` anywhere in `src/`. Variable lookup goes straight to the root
ncid — `src/clib/core/pio_nc.cpp:1781`:

```c
ierr = nc_inq_varid(file->fh, name, varidp);
```

Terra Fusion keeps every science variable inside nested groups. The granule's
root namespace holds only four band-index vectors (16, 15, 2, 5 elements), so
SCORPIO can open a granule and see nothing worth reading.

For the SCORPIO measurements the variables were therefore copied to the root of
flat files with **chunking and zlib level preserved bit-for-bit**; only the group
nesting is gone. The raw netcdf-fortran path was then re-measured against those
same flat files so every SCORPIO-vs-raw comparison is same-file, same-decomposition.

## Chunk layout of the four representative variables

| variable | shape | chunk | filter | ratio |
| --- | --- | --- | --- | --- |
| `MOPITT/.../Geolocation/Latitude` | 436×29×4 | contiguous | **none** | 1:1 |
| `MODIS/.../EV_1KM_Emissive` | 16×2030×1354 | {1,2030,1354} = 11 MB × **16** | zlib-1 | 1.64:1 |
| `ASTER/.../SWIR/ImageData4` | 2695×2968 | **whole dataset**, 32 MB × 1 | zlib-1 | 7.25:1 |
| `MISR/AN/.../Red_Radiance` | 180×512×2048 | **whole dataset**, 755 MB × 1 | zlib-1 | 3.35:1 |

This spread is the independent variable of the whole study. HDF5's filter
pipeline is chunk-granular, so a 3-element hyperslab of `Red_Radiance` inflates
755 MB. One chunk means one reader, unavoidably.

## Headline

* **Independent access is impossible on compressed variables.**
  `nf90_var_par_access(..., NF90_INDEPENDENT)` returns `NC_EINVAL` for MODIS,
  ASTER and MISR — every zlib-1 variable — and **succeeds** on MOPITT, the one
  uncompressed variable. Clean control: the refusal tracks compression, not the
  variable. HDF5 requires collective I/O on filtered chunks and netcdf-c enforces
  it at the API boundary. Any PIO decomposition over Terra Fusion science data
  must be collective.
* **Collective is mandatory, not better.** On uncompressed MOPITT, *independent*
  beats collective 332 vs 140 MiB/s at 8 ranks. Collective coordination is real
  cost; on 0.19 MiB it is pure overhead.
* **Chunking decides scaling, and nothing else does.** MODIS (16 chunks) scales
  5.3x to 8 ranks. ASTER and MISR (single chunk) are flat at every rank count.
  Everything regresses at 16 ranks.
* **The workload is decompression-bound, not I/O-bound.** Warm cache raises MODIS
  from 515.8 to 731.4 MiB/s at 8 ranks yet never nears memory speed. Best cold
  number corresponds to ~313 MB/s off disk against a ~466 MB/s raw ceiling.
* **On a 755 MB single chunk, parallelism buys literally nothing.** The best
  result anywhere — SCORPIO at 8 ranks, 145.6 MiB/s — is indistinguishable from
  **one rank of raw netCDF-4 (143.6)**.
* **Never use `netcdf4c` for reads.** It plateaus on well-chunked data (~100
  MiB/s vs 370) and on MISR it *inverts*: 68.4 → 25.6 MiB/s, a 2.7x slowdown as
  ranks increase.

## Scaling by chunk regime

Raw netcdf-fortran, `nf90_open_par`, collective, cold cache (page cache evicted
with `posix_fadvise(DONTNEED)` before every run), median of 3 reps, MiB/s of
**logical** (uncompressed) bytes.

| ranks | mopitt (uncompressed) | modis (16 chunks) | aster (32 MB × 1) | misr (755 MB × 1) |
| --- | --- | --- | --- | --- |
| 1 | 8.6 | 97.6 | 151.0 | 121.1 |
| 2 | 148.8 | 167.2 | 174.2 | 121.2 |
| 4 | 161.8 | 310.8 | 180.0 | 124.8 |
| 8 | 140.0 | **515.8** | 162.5 | 104.6 |
| 16 | 99.8 | 491.3 | 63.9 | — |

Reps were tight (modis at 8 ranks: 502-538 across three). MISR capped at 8 ranks
because every rank must inflate the full 755 MB chunk regardless of how little it
asks for.

### Cold vs warm — isolating inflate from disk

| ranks | cold | warm | delta |
| --- | --- | --- | --- |
| 1 | 97.6 | 118.7 | +22% |
| 4 | 310.8 | 410.5 | +32% |
| 8 | 515.8 | **731.4** | +42% |

Removing disk entirely gains only 42%. Inflate is the wall.

## SCORPIO vs raw netCDF-4, same file, same decomposition

SCORPIO path is `PIO_init` (subset rearranger) → `PIO_openfile` →
`PIO_initdecomp` → `PIO_read_darray`, decomposed over the slowest-varying
dimension exactly as the raw path is.

**`modis_ev`** — 16 chunks:

| ranks | raw netcdf4p | scorpio netcdf4p | scorpio netcdf4c |
| --- | --- | --- | --- |
| 1 | 114.7 | 56.1 | 55.0 |
| 2 | 213.7 | 117.2 | 72.5 |
| 4 | 381.4 | 202.6 | 89.7 |
| 8 | **687.7** | 369.9 | 99.7 |

**`aster_swir`** — single 32 MB chunk:

| ranks | raw netcdf4p | scorpio netcdf4p | scorpio netcdf4c |
| --- | --- | --- | --- |
| 1 | 186.6 | 75.5 | 77.9 |
| 2 | 191.6 | 136.7 | 134.4 |
| 4 | 187.9 | **206.3** | 165.1 |
| 8 | 156.6 | **216.9** | 190.7 |

**`misr_red`** — single 755 MB chunk:

| ranks | raw netcdf4p | scorpio netcdf4p | scorpio netcdf4c |
| --- | --- | --- | --- |
| 1 | **143.6** | 64.0 | 68.4 |
| 2 | 143.7 | 96.7 | 65.0 |
| 4 | 137.6 | 127.9 | 45.1 |
| 8 | 119.0 | **145.6** | 25.6 |

The crossover is real and reproduces on both single-chunk variables: raw goes
flat then declines while SCORPIO climbs past it. Mechanism is that each rank in
the raw path independently inflates the same chunk — at 8 ranks on MISR that is
~6 GB of redundant decompression for 720 MiB of data — whereas the rearranger
reads once and redistributes.

It was expected to be *larger* on MISR than ASTER. It is **smaller**: +22% vs
+38%, and the crossover arrives later (between 4-8 ranks rather than at 4).
Rearranger overhead scales with chunk size, so SCORPIO starts 2.2x behind at 1
rank and spends the sweep climbing out.

## Practical upshot

Three regimes, three different right answers:

| chunk layout | best path | why |
| --- | --- | --- |
| many chunks (MODIS) | **raw netCDF-4**, 8 ranks → 688 MiB/s | rearranger is pure ~1.9x overhead |
| one medium chunk (ASTER 32 MB) | **SCORPIO netcdf4p**, ≥4 ranks → 217 | avoids redundant inflate, +38% |
| one huge chunk (MISR 755 MB) | **anything, 1 rank** → ~144 | nothing scales; do not spend ranks |

A reader for this corpus should select its path per-variable by chunk layout,
not globally. And the real fix for MISR is not an I/O library — it is
rechunking. The 755 MB single chunk forecloses every option; at 143.6 MiB/s
logical against 3.35:1 compression that is ~43 MiB/s off disk, ~10x away from
the hardware, with no number of ranks closing it.

## Method and caveats

* All throughput figures are **logical** (uncompressed) MiB/s. MODIS compresses
  1.64:1, so 515.8 MiB/s logical is ~313 MB/s physical. This matters when
  comparing against the raw ceiling.
* Cold runs evict the granule with `posix_fadvise(POSIX_FADV_DONTNEED)`, verified
  effective as non-root (`Cached` drops by the amount read). Individual granules
  are 4-51 GB against 94 GB RAM, so uncontrolled repeat runs go cache-hot and
  report fantasy numbers.
* **The raw sequential ceiling is not a constant on this box.** Measured 1.0 GB/s,
  then 614 MB/s, then 440/548/466 MB/s on three consecutive samples. ares carries
  ~57 logged-in users; absolute values should be read as ±20%, ratios and shapes
  are solid.
* Load rose during runs (1.76 → 7.19 on the main sweep, 2.43 → 7.92 on MISR),
  partly from the benchmark's own ranks. The three-rep medians were tight
  throughout.
* The first sweep pass overlapped the hung SCORPIO configure and its numbers were
  discarded; everything reported here is from clean re-runs.
* ASTER's flat file is small (30.5 MiB logical) so open/metadata cost is a visible
  fraction there. MODIS and MISR numbers are on firmer ground.

## Reproducing

Drivers and sweep scripts, all MPI + cold-cache controlled:

| file | what it does |
| --- | --- |
| [`bin/tf_sweep.f90`](../bin/tf_sweep.f90) | raw netcdf-fortran reader; keys `mopitt`/`modis`/`aster`/`misr` (in-granule, group-walking) and `flat_*` (root-level), `coll`/`indep`, optional file override |
| [`bin/tf_pio_read.f90`](../bin/tf_pio_read.f90) | SCORPIO reader via `PIO_initdecomp` + `PIO_read_darray`; `netcdf4p`/`netcdf4c`, optional file override |
| [`bin/tf_sweep.sh`](../bin/tf_sweep.sh) | chunk regime × mode × ranks × cache, 3 reps + median |
| [`bin/tf_pio_cmp.sh`](../bin/tf_pio_cmp.sh), [`bin/tf_misr_cmp.sh`](../bin/tf_misr_cmp.sh) | SCORPIO vs raw on identical flat files |
| [`bin/tf_flatten.py`](../bin/tf_flatten.py), [`bin/tf_flatten_misr.py`](../bin/tf_flatten_misr.py) | copy grouped variables to root preserving chunking and filters |
| [`bin/tf_evict.py`](../bin/tf_evict.py) | `posix_fadvise(DONTNEED)` page-cache eviction |
| [`bin/tf_strlcpy_shim.h`](../bin/tf_strlcpy_shim.h) | glibc < 2.38 workaround for HDF5 develop |
| [`bin/tf_build_hdf5_netcdf.sh`](../bin/tf_build_hdf5_netcdf.sh), [`bin/tf_build_netcdf_fortran.sh`](../bin/tf_build_netcdf_fortran.sh), [`bin/tf_build_scorpio.sh`](../bin/tf_build_scorpio.sh) | the from-source stack builds, in a conda-free environment |

`tf_build_scorpio.sh` must be run inside the DNS workaround namespace described
above, otherwise its configure hangs:

```sh
printf 'hosts: files\n' > nsswitch.files
unshare -r -m bash -c 'mount --bind $PWD/nsswitch.files /etc/nsswitch.conf && exec bin/tf_build_scorpio.sh'
```

One trap worth recording: SCORPIO's Fortran `PIO_inq_vardimid` **already returns
dimids in Fortran (column-major) order**. Reversing them before `PIO_initdecomp`
— the natural instinct when crossing the C/Fortran boundary — hands it the
C-order shape and aborts with `NetCDF: Start+count exceeds dimension bound`.
