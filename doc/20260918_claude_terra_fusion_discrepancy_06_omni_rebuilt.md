# Terra Fusion 5-sensor discrepancy, part 6: CAE rebuilt with HDF5 — OMNI now reads, and `max_scale` is inert

Run on **ares**, 2026-09-18. Resolves the blocker from
[part 5](20260918_claude_terra_fusion_discrepancy_05_omni.md), which found that
`wrp put` performed no I/O at all. CAE's OMNI module is now rebuilt with HDF5
support and **does real parallel HDF5 reads**. With working measurements, the
OMNI tuning question can finally be answered — and the answer is that the two
knobs CLAUDE.md asks about do not currently do anything.

> **SUPERSEDED — WRONG TOOL.** This benchmarks `wrp` from `~/cae/omni`, a
> **deprecated tree**: clio-core's own CAE has `# add_subdirectory(omni)`
> commented out, and the live OMNI tool is **`clio_cae`**. See
> [part 7](20260918_claude_terra_fusion_discrepancy_07_omni_clio_cae.md).
> The findings below are accurate for `wrp` but do not transfer: the two tools
> share no schema, URI format or code path, and `clio_cae` has no `max_scale`.


## Headline

* **CAE rebuilt with HDF5.** `wrp` now links HDF5 2.3.0 (parallel), initialises
  MPI, opens with `H5Pset_fapl_mpio`, and reports *"Using collective I/O mode /
  Successfully read dataset with parallel HDF5"*.
* **`max_scale` is inert.** Wall time is identical from `max_scale: 1` to `16`
  (4.54-4.85 s). It is parsed into the config and never used; `wrp` runs as a
  single process ("MPI initialized with 1 processes") whatever it is set to.
* **The hyperslab is pointless because the full dataset is read first.**
  Requesting **4 MiB costs the same as 720 MiB** (~4.6 s floor). The client reads
  the entire 188,743,680-element dataset and *then* the requested hyperslab.
* **Therefore there is still nothing to tune** — but now for measured reasons
  rather than because nothing ran.

## Getting it built

Three obstacles, none of them `USE_HDF5` itself.

**1. The original dependency tree is gone.** The existing build at
`/mnt/common/hyoklee/cae/build` was configured against `~/spack` packages —
Hermes, HermesShm, OpenMPI 5.0.3 — that no longer exist on ares. The top-level
`CMakeLists.txt` does `find_package(Hermes REQUIRED)`, a name that predates the
Hermes → clio/CTE rename, so the current clio-core install (which provides
`clio_cte_*` and `iowarp-core` configs) does not satisfy it.

**Resolution:** `omni/CMakeLists.txt` carries its own `project()` and makes
`HERMES_LIBS` conditional on `USE_HERMES` (default OFF), so the `wrp` tool builds
standalone without any of that.

**2. The reader is MPI-parallel.** `omni/format/hdf5_dataset_client.cc` calls
`H5Pset_fapl_mpio` and `H5Pset_dxpl_mpio`, so it needs a *parallel* HDF5 and a
matching MPI. Built against `/mnt/common/hyoklee/opt/hdf5-develop` (2.3.0,
parallel, MPICH 4.1.1) — the stack from the earlier I/O series. All APIs it uses
(`H5Dopen2`, `H5Sselect_hyperslab`, …) survive into HDF5 2.x.

**3. Release builds hide the diagnostics.** The config echo and most tracing sit
inside `#ifndef NDEBUG`. A `CMAKE_BUILD_TYPE=Release` build is silent and looks
like it is doing nothing; the original build had an empty `CMAKE_BUILD_TYPE`,
which is why it echoed. Build `Debug` to diagnose, `Release` to time.

```sh
cmake -S ~/cae/omni -B build-hdf5 -DUSE_HDF5=ON -DUSE_MPI=ON \
  -DUSE_HERMES=OFF -DUSE_POCO=OFF -DUSE_DATAHUB=OFF -DUSE_AWS=OFF \
  -DHDF5_ROOT=/mnt/common/hyoklee/opt/hdf5-develop
```

Verification that it took: `ldd wrp | grep -c hdf5` → 1, and
`nm -C wrp | grep -cE 'H5Dread|H5Dopen'` → 2. Both were **0** before.

## The config schema, corrected

Part 5 reported a URI-format mismatch. With the code now reachable, the actual
requirements are narrower and stricter than either existing config generation:

| requirement | value |
| --- | --- |
| dataset key | **top-level `src:`** — not `uri:`, not nested under `data:` |
| URI form | `hdf5://<file>/<dataset path>` — all slashes |
| file extension | **must end in `.h5`** |

The extension rule comes from `dataset_config.cc:76`:

```c
std::regex uri_regex(R"(hdf5://(.+\.h5)/?(.*))");
```

A `.nc` file — including the rechunked MISR product from
[part 3](20260918_claude_terra_fusion_discrepancy_03_optimization.md) — fails to
parse regardless of content.

**Every config in `~/cae/omni/config/` uses the wrong key.** `tf.yaml` and
`tf3d.yaml` use top-level `uri:`; `tf10.yaml`, `tf_all.yaml` and
`terra_hdf5_load.yaml` use `data:` with `path:`. Neither populates the `path`
variable that gates the HDF5 branch at `OMNI.cc:2783`, so none of them would read
data even against this rebuilt binary.

There is also **dead code**: `ProcessHdf5DataEntry` (`h5.cc:28`, declared in
`omni_processing.h:12`) is a complete second HDF5 implementation that **nothing
calls**. The live path is `OMNI.cc:2783` → `ParseDatasetConfig` →
`Hdf5DatasetClient::ReadDataset`. Part 5 inspected the dead one, which is why it
concluded the URI needed a colon — that is `h5.cc`'s `ParseHdf5Uri`, not the
parser actually used.

## Measurements

`MISR/AN/Data_Fields/Red_Radiance` from the granule, cold cache, Release build.

| blocks | MiB requested | max_scale | seconds | MiB/s |
| --- | --- | --- | --- | --- |
| 1 | 4.0 | 1 | 4.75 | 0.8 |
| 1 | 4.0 | 8 | 4.54 | 0.9 |
| 1 | 4.0 | 16 | 4.54 | 0.9 |
| 15 | 60.0 | 1 | 4.69 | 12.8 |
| 15 | 60.0 | 16 | 4.55 | 13.2 |
| 180 | 720.0 | 1 | 5.21 | 138.2 |
| 180 | 720.0 | 8 | 5.19 | 138.7 |
| 180 | 720.0 | 16 | 5.45 | 132.1 |

**`max_scale` does nothing.** Across its full range the spread is 4.54-4.85 s at
one block and 5.11-5.45 s at 180 — within run-to-run noise, with no trend. The
debug build confirms the mechanism: `MPI initialized with 1 processes`, whatever
`max_scale` says. It is parsed in `par.cc:27` into `OmniJobConfig::max_scale` and
never consulted again.

**The hyperslab does not reduce work.** 4 MiB and 720 MiB both cost ~4.6-5.2 s
because the client reads the *whole* dataset before extracting the requested
selection — visible in the debug trace as a full 188,743,680-element read
followed by "Successfully read dataset hyperslab" over 1,048,576 elements. The
~4.6 s floor is that full read of MISR's single 755 MB chunk, consistent with the
3.40-9.24 s measured directly in part 3.

At 180 blocks the effective 138 MiB/s is in the same band as the direct netCDF-4
reads measured throughout this series, so the HDF5 layer itself is behaving
normally. The waste is entirely in reading everything before selecting.

## What this means for the CLAUDE.md question

"Adjust parameters for OMNI to maximize hardware utilization such as NVMe and
clusters" cannot presently be satisfied:

* **Clusters** — `max_scale` is the only parallelism knob and it is not wired to
  anything. Independent of that, both the I/O series and part 3's regrid scaling
  put the optimum at **8** on this node, so its default of **100**
  (`omni_job_config.h:39`) would be far into the regressing regime once wired.
* **NVMe** — utilisation is capped by the full-dataset pre-read, not by any
  tunable. Fixing the hyperslab path to read only the selection would give the
  same **8.1×** that rechunking gave in part 3, for the same reason: stop moving
  bytes nobody asked for.

Two fixes, in priority order:

1. **Read only the hyperslab.** Select before reading rather than after. This is
   the large win and is independent of parallelism.
2. **Wire `max_scale`**, then default it to 8 rather than 100.

## Caveats

* `wrp get`, DataHub, Globus and AWS paths were all built OFF and are untested.
* The rebuild is the OMNI module only, not all of CAE. The `wrp` produced is at
  `~/cae/omni/build-hdf5/wrp`; the original at
  `/mnt/common/hyoklee/cae/build/bin/wrp` is untouched.
* `USE_HERMES=OFF` means `PutData` writes to the local `.blackhole` directory
  rather than a CTE buffer. Read timings are unaffected; ingest-side behaviour
  with Hermes enabled is not covered here.
* "checking IOWarp runtime…yes" is cosmetic — `SetBlackhole()` only tests for a
  local `.blackhole` directory and `mkdir`s it. "launching a new IOWarp
  runtime…done" is a directory creation, not a runtime.

## Reproducing

| file | what it does |
| --- | --- |
| [`bin/tf_build_cae_omni.sh`](../bin/tf_build_cae_omni.sh) | standalone OMNI build with HDF5 + MPI |
| [`bin/tf_omni_sweep2.sh`](../bin/tf_omni_sweep2.sh) | max_scale × hyperslab sweep, working config form |

```sh
bash bin/tf_build_cae_omni.sh      # Debug for diagnostics, Release for timing
bash bin/tf_omni_sweep2.sh
```
