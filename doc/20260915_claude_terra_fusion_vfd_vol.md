# clio VFD and VOL on Terra Fusion — both adapters are neutral; the 29% "win" was a noisy baseline

> **UPDATE, later on 2026-09-15 (jobs 24126/24127) — both original headline
> findings are RETRACTED.** Re-run against the current forks
> (`hyoklee/hdf5` `f720275127` + `hyoklee/netcdf-c` `9039e1987` +
> **`hyoklee/core` `34ce0ab9`**) at 5 reps:
>
> | variable | baseline | clio_vfd | clio_vol |
> | --- | --- | --- | --- |
> | `modis_ev` (16 × 11 MB) | 115.4 | 116.3 | 114.2 |
> | `aster_swir` (1 × 32 MB) | 221.4 | 220.2 | 218.7 |
> | `misr_red` (1 × 755 MB) | 174.5 | 171.9 | 163.9 |
>
> 1. **The 29% VFD win does not reproduce — it was a bimodal baseline.** The
>    original baseline for `aster_swir` ranged **160.9-216.2** (median 169.9)
>    while the VFD's was tight at 207.5-218.5. On the current stack the baseline
>    is stable at 221.4 (220.4-222.5) and the VFD matches it at 220.2. The
>    original VFD figure (218.5) is essentially the *current baseline*: the VFD
>    was never fast, the baseline sample was slow. The doc flagged this number as
>    "the single most load-bearing" one; it did not survive.
> 2. **The VOL reads all three variables successfully.** `nc_inq_varndims:
>    NetCDF: HDF error` is gone, and so is the teardown hang — **15/15 clean
>    `nc_close`** for both adapters, zero errors. `core` `34ce0ab9` carries the
>    fix (`clio_vol_exiting_g`, `clio_vol.cc:370`) for precisely the atexit
>    ordering bug diagnosed below.
> 3. **Corrected conclusion: no clio adapter wins on this workload.** All three
>    paths sit within ~1% on the chunked variables; the VOL costs ~6% on MISR's
>    755 MB chunk, where adapter overhead has nowhere to hide. That is consistent
>    with the clio-fs result and has the same cause — zlib inflate caps
>    throughput far below the point where the data path matters.
>
> Everything below this box records the original 09-15 run and is kept for the
> diagnosis, which remains accurate for the plugin build it describes.
>
> **Collective I/O through the VOL was then tested** in
> [`20260916_claude_terra_fusion_vol_collective.md`](20260916_claude_terra_fusion_vol_collective.md):
> it **works** — `nf90_open_par` and `NF90_COLLECTIVE` both succeed, reads scale
> to 8 ranks, zero errors — and performs at parity with native. The
> architectural objection raised below is therefore removed.

Run on **ares**, 2026-09-15, jobs 23941/23942/23943, node `ares-comp-08`.
Third in the series after
[`20260905_claude_terra_fusion_io_study.md`](20260905_claude_terra_fusion_io_study.md)
(no clio) and
[`20260914_claude_terra_fusion_cliofs.md`](20260914_claude_terra_fusion_cliofs.md)
(clio-fs over FUSE). Those two left one thread open: the clio **VFD** and **VOL**
adapters were never exercised, so nothing so far said anything about the
vector-coalescing fix from
[`20260813_claude_netcdf_test.md`](20260813_claude_netcdf_test.md).

## Headline (as originally measured — see the retraction above)

* **`clio_vfd` is 29% faster than baseline on ASTER** — 218.5 vs 169.9 MiB/s on a
  single 32 MB zlib-1 chunk. This is the **first and only configuration in the
  whole series where clio beats the baseline**.
* **It does not generalise by chunk size, and not in the direction expected.**
  The gain is absent on 16 × 11 MB chunks (1.00) and *negative* on a single
  755 MB chunk (0.95). Bigger single chunk does **not** mean bigger win.
* **`clio_vol` cannot read these files at all.** `nc_inq_varndims` fails with
  `NetCDF: HDF error` on every variable, immediately after a successful
  `nc_open` and `nc_inq_varid`. No read is ever issued. 9/9 reps.
* **Separately, the VOL hangs at process teardown** in `clio_write_stamp` →
  `PutBlobTask`, a WRITE issued during file close on a file opened `NC_NOWRITE`,
  which never receives a reply.
* **Both adapters are serial-only**, so none of this composes with the parallel
  reads the earlier two studies measured.

## The adapters are serial-only (as built by the CI tree — see the update above)

`libclio_vfd.so` and `libclio_hdf5_vol.so` link **no MPI**, and the HDF5 they are
built against (`nc4-clio-work/hdf5-install`) reports **`Parallel HDF5: OFF`**.
They therefore cannot be used with `nf90_open_par` / `H5FD_MPIO`.

This is a hard architectural boundary, not a test artifact: the 8-rank collective
reads that produced every number in the previous two studies are unavailable to
the VFD and VOL. Everything below is one process issuing one read.

That does make it the cleanest available probe of the coalescing path — a
single-chunk variable read whole becomes exactly one enormous request, with no
MPI aggregation in the way.

## Method

Stack is `nc4-clio-work`'s own — HDF5 **2.3.0 serial** + netcdf-c
**4.10.2-development** — i.e. what the adapters were built and CI-tested
against, not the parallel stack in `/mnt/common/hyoklee/opt`. Same HDF5 version,
but mixing a parallel libhdf5 with serial-built plugins would put the plugin ABI
in question for no benefit.

Variant selection is **entirely by environment**, so the binary is byte-identical
across all three phases and the only thing that changes is the data path HDF5
loads underneath it:

| variant | environment |
| --- | --- |
| baseline | `HDF5_DRIVER`, `HDF5_DRIVER_CONFIG`, `HDF5_VOL_CONNECTOR`, `HDF5_PLUGIN_PATH` all unset |
| clio_vfd | `HDF5_DRIVER=clio_vfd`, `HDF5_DRIVER_CONFIG=cache=1`, `HDF5_PLUGIN_PATH=$CLIO_BIN` |
| clio_vol | `HDF5_VOL_CONNECTOR=clio`, `HDF5_PLUGIN_PATH=$CLIO_BIN` |

`cache=1` is what makes the VFD variant a CLIO measurement rather than a second
baseline; the `key=value` grammar is mandatory, and a driver-config the VFD
cannot parse surfaces through netCDF-C as the very misleading "Permission
denied".

Files are the flattened Terra Fusion variables from the 09-05 study
(`tf_flat.nc`, `tf_misr.nc`), copied to node-local NVMe, page cache evicted
before each read, 3 reps, median reported. The runtime config has an 8 GB RAM
tier so the 33 GB granule is out of scope here; the flat files carry all three
chunk regimes regardless.

## Results

MiB/s of logical (uncompressed) bytes, single process, median of 3.

| variable | chunk layout | baseline | clio_vfd | ratio |
| --- | --- | --- | --- | --- |
| `modis_ev` | 16 × 11 MB, zlib-1 | 115.0 | 114.8 | 1.00 |
| `aster_swir` | **1 × 32 MB**, zlib-1 | 169.9 | **218.5** | **1.29** |
| `misr_red` | **1 × 755 MB**, zlib-1 | 172.5 | 164.3 | 0.95 |

| variable | clio_vol |
| --- | --- |
| `modis_ev` | `nc_inq_varndims`: NetCDF: HDF error |
| `aster_swir` | `nc_inq_varndims`: NetCDF: HDF error |
| `misr_red` | `nc_inq_varndims`: NetCDF: HDF error |

The serial baseline agrees with the parallel stack's 1-rank figures from the
earlier studies (`modis_ev` 115.0 here vs 114.7 there), so the change of stack
and of node did not move the reference point.

### The VFD result is real but narrow

`aster_swir` at +29% is the only clio win in three studies, and it is worth
taking seriously: a single 32 MB chunk read whole is precisely the shape the
vector/coalescing path exists to serve.

But the shape across chunk sizes is **non-monotonic**, and the expectation going
in — that the 755 MB chunk would show the largest gain because it produces the
single biggest read request — is **wrong**. It shows a 5% loss. Whatever the VFD
is doing well at 32 MB either stops applying or is outweighed by the time the
request reaches 755 MB. Two plausible readings, neither tested here:

* the 32 MB chunk fits the CTE cache tier behaviour (`cache=1`) in a way the
  755 MB one does not — the runtime config's RAM tier is 8 GB, so both fit, but
  page/blob granularity may not;
* at 755 MB the read is already large enough to saturate whatever the native
  driver does, leaving no coalescing headroom and only adapter overhead.

Distinguishing those would need a chunk-size sweep between 32 MB and 755 MB,
which is a cheap follow-up now that the harness exists.

### The VOL is broken on these files, two ways

**1. Metadata queries fail.** Every read fails at `nc_inq_varndims` with
`NetCDF: HDF error`, 9/9 reps across all three variables. `nc_open` succeeds and
`nc_inq_varid` succeeds — the connector finds the variable by name and then
cannot report its rank. No data read is ever attempted, so there is no VOL
throughput number to report.

**2. Teardown hangs.** Independently, the process blocks at exit. Stack from
job 23941:

```
exit() -> H5_term_library -> H5F_term_package -> H5I_clear_type
       -> H5F__close_cb -> H5VL_file_close
       -> clio_file_close -> clio_write_stamp
       -> Future<PutBlobTask> -> IpcCpu2Cpu::RecvOut<PutBlobTask>   [ep_poll, forever]
```

`clio_write_stamp` issues a **`PutBlobTask` — a write — during file close on a
file opened `NC_NOWRITE`**, and the future never completes. Nothing here is
Terra-specific: any program that opens a netCDF-4 file through this VOL and exits
normally should hang the same way. With the original 600 s per-read cap this
turned a fast failure into a 30-minute job that hit its wall, which is how the
first attempt (23941) was lost.

## Where this leaves the coalescing question

Partly answered. The VFD's fast path does produce a **measurable 29% gain on a
32 MB single-chunk read**, which is the first evidence in this series that clio's
data path can beat the native one on a real scientific file. It does not extend
to the 755 MB chunk, so "bigger single read is better for clio" is not supported.

Still unanswered: whether any of this survives contact with parallel I/O. It
cannot be tested with these adapters as built — they are serial. A parallel-HDF5
build of the VFD would be needed before the result means anything for E3SM or for
the 8-rank numbers in the previous two studies.

## What the current forks changed

Re-running against `hyoklee/core` `34ce0ab9` built directly on the HDF5 2.3.0 and
netcdf-c 4.10.2 forks (rather than the `nc4-clio-work` CI tree) changed three
things.

**The VOL works.** Every read succeeds. Whatever produced `nc_inq_varndims:
NetCDF: HDF error` in the older plugin build is not present in `core` `dev`.

**The teardown hang is fixed at source.** `clio_vol.cc:370` documents the atexit
LIFO ordering problem — the CLIO client is first constructed on the first
`H5Fopen`, long after `H5open()`, so its static destructors run *before*
HDF5's `H5_term_library`, and `clio_write_stamp`'s `Wait()` then blocks on a
future no surviving receive thread can complete. The `clio_vol_exiting_g` guard
skips the tier once teardown has begun, which is fail-closed: an unwritten
coherence stamp just makes the next open see `kAbsent` and re-read from the
authoritative native file.

**The VOL now links a parallel HDF5** (`libhdf5.so.1000` 2.3.0 parallel +
`libmpi.so.12`), which the CI-tree plugins could not. That removes the hard
serial-only barrier described above as a *build* property — though it does not by
itself demonstrate collective I/O support, since a VOL replaces the file API
wholesale and `H5Pset_fapl_mpio` does not obviously apply beneath it. **That was
tested on 09-16 and it does work**, at parity with native — see
[`20260916`](20260916_claude_terra_fusion_vol_collective.md).

Two build hazards worth recording, both of which cost time here:

* **Parallel HDF5 drags MPI into clio-core's build.** `hdf5-config.cmake` does
  `find_dependency(MPI)`, so a clio-core configure that never needed MPI before
  fails at `CMakeLists.txt:814` unless MPICH is discoverable.
* **Conda's HDF5 headers will silently win.** clio's deps (zmq, yaml-cpp,
  cereal) live in `~/mc3`, so conda's include directory must be on the path —
  and `~/mc3/include/H5VLnative.h` is **HDF5 1.14**, where
  `#define H5VL_NATIVE (H5VL_native_register())`. HDF5 2.3.0 defines the same
  macro as `(H5OPEN H5VL_NATIVE_g)`, a variable. Compiling the VOL against 1.14
  headers while linking 2.3.0 produces a library that loads and then dies with
  `undefined symbol: H5VL_native_register`. Pinning `HDF5_ROOT` is not enough;
  the include order needs forcing with `-I<hdf5>/include`.

## Caveats

* Single node, single process, 3 reps. `aster_swir` is only 30.5 MiB logical, so
  open/metadata cost is a visible fraction of it — the variable showing the win
  is also the smallest one measured.
* `aster_swir` baseline spread was wide (160.9-216.2, median 169.9) while the
  `clio_vfd` spread was tight (207.5-218.5). The medians differ by more than the
  overlap, but a larger rep count would firm this up, and it is the single most
  load-bearing number in the report.
* The clio runtime here is the `nc4-clio-work` config (8 GB RAM tier, no NVMe
  tier), not the chain used in the clio-fs study, so these numbers are not
  directly comparable to `20260914`'s.

## Reproducing

| file | what it does |
| --- | --- |
| [`bin/tf_serial_read.c`](../bin/tf_serial_read.c) | serial netCDF-4 whole-variable reader; reports **before** `nc_close` so a close-path hang cannot swallow the measurement |
| [`bin/tf_vfd_vol_run.sbatch`](../bin/tf_vfd_vol_run.sbatch) | all three variants in one allocation; `VARIANTS`, `READ_TIMEOUT`, `REPS` knobs, and `STACK=ours\|cicompat` to select the fork stack or the CI tree |
| [`bin/tf_build_clio_core.sh`](../bin/tf_build_clio_core.sh) | builds `hyoklee/core` with VOL + VFD against the HDF5 2.3.0 fork, with both hazards above handled |

```sh
sbatch --export=ALL,STACK=ours,REPS=5 bin/tf_vfd_vol_run.sbatch    # current forks
sbatch bin/tf_vfd_vol_run.sbatch                                   # CI tree, all three
sbatch --export=ALL,VARIANTS=clio_vol,READ_TIMEOUT=90 bin/tf_vfd_vol_run.sbatch
```

`READ_TIMEOUT` exists because of the VOL teardown hang: without a short cap a
variant that fails in milliseconds still burns the full per-read timeout on every
rep. Print-before-close exists for the same reason.

Results: `/mnt/common/hyoklee/tf-clio/runs/vfdvol_23941/` (baseline + clio_vfd,
`driver.log`), `vfdvol_23943/` (clio_vol, `err_clio_vol.log` has the HDF error
lines).
