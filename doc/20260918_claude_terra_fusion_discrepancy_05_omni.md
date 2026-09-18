# Terra Fusion 5-sensor discrepancy, part 5: OMNI tuning is blocked — `wrp` does no HDF5 I/O

Run on **ares**, 2026-09-18. Stage 5 of the CLAUDE.md task: "adjust parameters
for OMNI file to maximize hardware utilization such as NVMe and clusters."

**Result: there is nothing to tune in this build.** `wrp put` parses the OMNI
YAML and performs no I/O. Two independent defects, either of which alone is
fatal.

## Evidence

A `max_scale` × hyperslab sweep on the rechunked MISR file produced impossible
numbers:

| blocks | MiB | max_scale | seconds | MiB/s |
| --- | --- | --- | --- | --- |
| 1 | 4.0 | 1 | 0.01 | 400 |
| 15 | 60.0 | 2 | 0.01 | 6,000 |
| 180 | **720.0** | 1-16 | **0.01** | **72,000** |

720 MiB in 0.01 s is 72 GB/s — roughly 150× the measured device ceiling of
~466 MB/s from the [09-05 study](20260905_claude_terra_fusion_io_study.md). That
is the signature of a no-op, not of fast I/O. Note `max_scale` changes nothing
across its whole range, which is the second tell.

### Defect 1: `wrp` is not linked against HDF5

```
nm -C wrp | grep -c 'H5Dread|H5Dopen'   -> 0
ldd wrp | grep -c hdf5                   -> 0
```

`cae/omni/h5.cc` guards its entire read path:

```c
void ProcessHdf5DataEntry(const OmniJobConfig::DataEntry &entry) {
  ...
#ifdef USE_HDF5
  // parse URI, open dataset, read hyperslab
```

`USE_HDF5` was not defined for this build, so the function body compiles away and
every `hdf5://` entry is silently a no-op.

### Defect 2: the URI parser disagrees with every config

`ParseHdf5Uri` expects a **colon** between file and dataset:

```c
const std::string prefix = "hdf5://";
size_t path_end = uri.find(':', prefix.length());
if (path_end == std::string::npos) return false;      // <- all configs land here
```

Every config in `~/cae/omni/config/` uses an all-slash form:

```yaml
uri: "hdf5:///mnt/common/datasets-staging/TERRA_BF_L1B_O10204_....h5/ASTER/granule_.../SWIR/Geolocation/Latitude"
```

There is no colon after the prefix, so `find` returns `npos` and the parse fails
before any read is attempted — independently of defect 1.

## The OMNI configs were never doing I/O either

This retroactively explains the state of `~/cae/omni/config/`, noted at the start
of this work:

* `terra_hdf5_load.yaml` and `tf10.yaml` are headed *"OMNI job to load entire
  TERRA HDF5 file"* and set `offset: 0, size: 10000` — 10 KB per file, 100 KB
  across all ten granules, out of 284 GB.
* `tf_all.yaml` carries the comment `# size omitted to read entire file`
  directly above a `size: 10000`.
* `tf.yaml` / `tf3d.yaml` request `count: [1,3]` and `[1,3,2]` — 3 and 6 elements.

Those are also **two different schema generations**: the `data:`/`path:`/`size:`
form is the old one, while current `wrp` requires a top-level `tags:` field and
rejects the old configs outright with

```
Error: 'tags' field is required in OMNI YAML file
```

So the existing OMNI corpus is a mix of a superseded schema and a working schema
pointed at a code path that is compiled out.

## What tuning would look like once unblocked

The schema does expose the right knobs — `cae/omni/par.cc` parses:

| level | field | tuning role |
| --- | --- | --- |
| job | `max_scale` | degree of parallelism (default **100** in `omni_job_config.h`) |
| entry | `offset`, `size` | byte-range for raw reads |
| entry | `start`, `count`, `stride` | HDF5 hyperslab |
| entry | `src`, `range`, `run` | source, extent, post-process hook |

Given the rest of this series, the tuning is largely predictable:

* **`max_scale` should be 8, not 100.** Both the I/O studies (read ranks) and the
  regrid scaling in [part 3](20260918_claude_terra_fusion_discrepancy_03_optimization.md)
  peak at 8 on this node and degrade past it. The default of 100 is far into the
  regressing regime.
* **`count` must cover real data.** The current 3-element and 10 KB requests
  cannot utilise anything.
* **Chunk alignment matters more than `max_scale`.** Part 3 got **8.1×** from
  rechunking MISR and the I/O series found every data path within a few percent
  of every other. Aligning `start`/`count` to chunk boundaries is where the
  remaining gain is, not in the parallelism knob.

## Unblocking

1. Rebuild CAE with HDF5: `-DUSE_HDF5=ON` (or the project's equivalent) and an
   HDF5 the linker can see — `/mnt/common/hyoklee/opt/hdf5-develop` (2.3.0,
   parallel) is available and is what the rest of this series uses.
2. Reconcile the URI format. Either change `ParseHdf5Uri` to split on the last
   `/` that precedes a dataset path, or change the configs to
   `hdf5://<file>:<dataset>`. The parser is the smaller change and the configs
   are the documented form, so the parser is probably wrong.
3. Re-run [`bin/tf_omni_sweep.sh`](../bin/tf_omni_sweep.sh), which is written and
   will produce real numbers as soon as `put` moves bytes.

## Caveats

* Only `wrp put` was exercised. `wrp get` and the DataHub/Globus paths were not
  tested and may be unaffected.
* This is one build of CAE, dated Oct 2025. A current build may already define
  `USE_HDF5`; no attempt was made to rebuild it here.
* `wrp ls` fails with `Could not open the file ".blackhole/ls"`, but
  `.blackhole` is a test fixture from `test_omni.cc` rather than evidence of a
  storage misconfiguration.

## Reproducing

[`bin/tf_omni_sweep.sh`](../bin/tf_omni_sweep.sh) — `max_scale` × hyperslab
sweep, writes CSV. Ready to produce meaningful output once `wrp` reads HDF5.

```sh
bash bin/tf_omni_sweep.sh
```
