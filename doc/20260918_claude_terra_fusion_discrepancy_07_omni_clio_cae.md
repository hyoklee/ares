# Terra Fusion 5-sensor discrepancy, part 7: OMNI via `clio_cae` — trailing-wildcard filters match nothing

Run on **ares**, 2026-09-18. **Supersedes
[part 5](20260918_claude_terra_fusion_discrepancy_05_omni.md) and
[part 6](20260918_claude_terra_fusion_discrepancy_06_omni_rebuilt.md)**, which
benchmarked the wrong tool.

## The wrong tool

Parts 5-6 used `wrp` from `~/cae/omni`. That is a **deprecated tree**: clio-core
carries its own context-assimilation-engine, whose `CMakeLists.txt` line 61
reads

```cmake
# add_subdirectory(omni)
```

The live OMNI tool is **`clio_cae`** (installed alongside a legacy
`clio_cae_omni` symlink), built when `CLIO_CORE_ENABLE_CAE=ON` — which is the
**default**. My earlier clio-core build passed `CLIO_CORE_ENABLE_CAE=OFF`, which
is why only `clio_run` and `cte_search` appeared and why I went looking in
`~/cae` at all.

Everything parts 5-6 concluded — `max_scale` inert, full-dataset-then-hyperslab,
`.h5`-only regex, dead `ProcessHdf5DataEntry` — is **accurate for `wrp` and
irrelevant to `clio_cae`**. The two tools do not share a schema, a URI format, or
a code path.

| | `wrp` (deprecated) | `clio_cae` (live) |
| --- | --- | --- |
| schema | `name`, `tags`, top-level `src:` | `version` + **`transfers:`** list |
| URI | `hdf5://file.h5/dataset` | **`hdf5::/path`** → `dst: iowarp::<tag>` |
| subsetting | `start`/`count`/`stride` hyperslab | **`dataset_filter`** glob include/exclude |
| ordering | none | **`depends_on`** task graph |
| parallelism knob | `max_scale` (inert) | none exposed |

Note `clio_cae` has **no `max_scale`** at all, so the CLAUDE.md question about
tuning cluster count has no knob in the live tool.

## Build

`clio-core` rebuilt with CAE and HDF5:

```sh
-DCLIO_CORE_ENABLE_CAE=ON -DCLIO_CORE_ENABLE_HDF5=ON \
-DCLIO_CTE_ENABLE_HDF5_VOL=ON -DCLIO_CTE_ENABLE_VFD=ON \
-DHDF5_ROOT=/mnt/common/hyoklee/opt/hdf5-develop
```

Installs `clio_cae`, `clio_cae_omni`, `clio_run`, `cte_search`.

## Trap: a missing runtime pool hangs `clio_cae` silently

**`clio_cae` hangs indefinitely if the runtime does not compose a
`clio_cae_core` pool.** I reused `nc4-clio-work/clio_runtime.yaml`, which
composes only:

```
clio_bdev, clio_cte_core, clio_cte_filesystem
```

clio-core's own `data/clio_default.yaml` composes seven, including
**`clio_cae_core`**. Without it, the client submits its assimilation task, no
handler exists, and it busy-polls forever:

* 13 threads in `ep_poll`, **40 s of CPU in 105 s elapsed** — spinning, not idle
* no error at any log level; the last line is `Calling ParseOmni...`
* a single 3.4 MB dataset hung just as thoroughly as a 6 GB pattern, so data
  volume is not the tell

Composing the 7-pool default turned a 30-minute non-completion into **`rc=0` in
10.65 s**. Anyone driving `clio_cae` should verify
`All 7 pools created successfully` in the runtime log first.

Note the default config sets tier capacity `"0g"`, meaning **80% of system
DRAM** — ~75 GB on this login node. Cap it before running anywhere shared.

## The finding: trailing wildcards match nothing

`dataset_filter` glob patterns whose **final component is a wildcard** match zero
datasets. Same file, same prefix, only the terminal component differs:

| pattern | terminal | tasks scheduled | seconds |
| --- | --- | --- | --- |
| `/ASTER/granule_11182001013943/TIR/ImageData10` | literal | **1** | 0.13 |
| `/ASTER/*/TIR/ImageData10` | literal | **1** | 1.54 |
| `/ASTER/*/SWIR/ImageData4` | literal | **1** | 3.48 |
| `/ASTER/*/SWIR/*` | **wildcard** | **0** | 62.85 |
| `*/Geolocation/*` | **wildcard** | **0** | 207.59 |

`/ASTER/*/SWIR/ImageData4` and `/ASTER/*/SWIR/*` differ only in the last path
component. The first schedules a transfer in 3.5 s; the second schedules nothing
after 63 s. A `*` in an *interior* component works fine — `/ASTER/*/TIR/...`
matches across all 32 granules.

**The tool's own documented examples use the broken form.**
`context-assimilation-engine/test/unit/hdf5_assim/hdf5_assim_omni.yaml` ships:

```yaml
include_patterns:
  - "*/Geolocation/*"           # All geolocation datasets
  - "/ASTER/*/SWIR/*"           # Wildcard matching
```

Both match nothing.

**The failure is silent and expensive.** `rc=0`, `ParseOmni completed
successfully!`, and only `Tasks scheduled: 0` distinguishes it from a working
run — a field easy to miss. Meanwhile the non-match still pays full dataset
discovery: 62.9 s for the ASTER-rooted pattern and **207.6 s** for the
`*`-rooted one, which walks the entire 33 GB granule before matching nothing.
Discovery cost scales with how much of the file the pattern's *prefix* covers.

## Selectivity, where it works

Among patterns that match, cost tracks breadth as expected:

| scope | datasets | seconds |
| --- | --- | --- |
| one explicit dataset | 1 | 0.13 |
| one dataset × 32 granules (`/ASTER/*/TIR/ImageData10`) | 32 | 1.54 |
| one SWIR band × 32 granules | 32 | 3.48 |

So `dataset_filter` *is* the right mechanism for the subsetting this pipeline
needs — matching part 1's finding that subsetting before reading is the whole
optimisation — provided every pattern terminates in a literal name.

## What this means for the CLAUDE.md tuning question

* **Cluster count: no knob.** `clio_cae` exposes no `max_scale` equivalent.
  Concurrency is expressed only through `depends_on` between transfers, which was
  not swept here.
* **NVMe utilisation: governed by `dataset_filter`**, and therefore currently
  capped by the trailing-wildcard defect — the natural way to express "all SWIR
  data" silently selects nothing.
* **Workaround:** enumerate terminal dataset names explicitly. For ASTER SWIR
  that is six patterns (`ImageData4` … `ImageData9`) rather than one `*`.

## Caveats

* `depends_on` concurrency and `range_off`/`range_size` were not swept.
* Timings are single-run, on a shared login node, with a warm runtime. The
  0.13 s figure for a repeated single dataset may reflect idempotent skipping of
  an already-ingested tag rather than a genuine re-read.
* Whether `Tasks scheduled: 1` implies the data actually landed in CTE was not
  verified — `cte_search` was not used to confirm tag contents.
* Only `include_patterns` was exercised; `exclude_patterns` untested.

## Reproducing

[`bin/tf_cae_sweep.sh`](../bin/tf_cae_sweep.sh) — builds the OMNI configs, runs
`clio_cae`, reports seconds and tasks scheduled.

```sh
# runtime MUST compose clio_cae_core
sed -e 's/capacity: "0g"/capacity: "4GB"/' -e 's/capacity_limit: "0g"/capacity_limit: "8GB"/' \
    /mnt/common/hyoklee/opt/clio-core/data/clio_default.yaml > rt.yaml
CLIO_SERVER_CONF=$PWD/rt.yaml clio_run start &
bash bin/tf_cae_sweep.sh
```
