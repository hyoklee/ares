# Terra Fusion 5-sensor discrepancy, part 8: the wildcard bug was not real, data does land in CTE, and CAE now has telemetry

Run on **ares**, 2026-09-18. Three tasks: fix the `dataset_filter` wildcard
issue, verify data actually reaches CTE, and add telemetry to CAE. The first
turned out to have no bug to fix.

## Retraction: there is no trailing-wildcard bug

[Part 7](20260918_claude_terra_fusion_discrepancy_07_omni_clio_cae.md) claimed
that `dataset_filter` patterns ending in a wildcard match nothing. **That is
wrong.** Two independent disproofs:

**1. The matcher permits it by construction.** `MatchGlobPattern`
(`hdf5_file_assimilator.cc:735`) calls

```c
int result = fnmatch(pattern.c_str(), str.c_str(), 0);
```

with **flags = 0** — no `FNM_PATHNAME` — so `*` crosses `/` deliberately. A
direct check agrees:

```
fnmatch("/ASTER/*/SWIR/*", "/ASTER/granule_X/SWIR/ImageData4") -> True
```

**2. A trailing wildcard works when the match is small.**
`/ASTER/granule_11182001013943/TIR/*` → **`Tasks scheduled: 1` in 0.29 s.**

### What was actually happening

The runtime log carried hundreds of

```
ERROR FlushData: PutBlob failed for blob chunk_3 (error 1...)
```

The CTE tier was exhausted, `PutBlob` failed, and the transfer was not
scheduled. **The tier accumulates across runs**, and part 7's sweep drove one
long-lived runtime, so later patterns failed on a tier that earlier patterns had
filled — regardless of their own size or shape.

The confound is visible in the ordering: `one` (ok) → `tir` (ok) → `geo` (fail)
→ `swir` (fail). I varied pattern breadth and accumulated tier state together,
then attributed the result to the pattern.

On a clean runtime with a 24 GB tier, the identical pattern that part 7 reported
as broken:

| pattern | part 7 (dirty tier) | clean runtime |
| --- | --- | --- |
| `/ASTER/*/TIR/*` | 0 tasks | **1 task, 6.20 s, 0 PutBlob failures** |

**Method note.** This is the second retraction in this series, after the
[09-15 VFD "+29%"](20260915_claude_terra_fusion_vfd_vol.md). Both had the same
shape: a sweep in which the independent variable moved together with some
accumulated state, and a conclusion drawn from the confounded comparison. The
[09-16 phase-order control](20260916_claude_terra_fusion_vol_collective.md)
caught that class of error once; it should have been applied here too. **For CAE
work specifically: restart the runtime between measurements, or the tier carries
state from the previous one.**

## Data does land in CTE

Verified with `cte_search`, which part 7 listed as untested:

```
x_tirall/ASTER/granule_11182001014417/TIR/Geolocation/Longitude/chunk_3
x_tirall/ASTER/granule_11182001014121/TIR/ImageData11/chunk_1
x_tirall/ASTER/granule_11182001014316/TIR/ImageData12/description
```

Each dataset becomes `<dst>/<dataset_path>` carrying a `description` blob plus
`chunk_N` data blobs, exactly as `hdf5_assim_omni.yaml` documents.

**But assimilation is asynchronous.** `clio_cae` returns once tasks are
*scheduled*; an immediate `cte_search` returns `(no results)`. Nothing in the
client tells you when — or whether — the work finished. Allow settling time, or
poll `cte_search`, before concluding an ingest failed.

## Telemetry added to CAE

Committed to `hyoklee/core` on branch **`hyoklee/cae-telemetry`** (`af293f25`),
in `Hdf5FileAssimilator::Schedule`.

Three gaps motivated it, all encountered above:

1. Everything interesting happens **server-side** in the `clio_cae_core` pool,
   so it lands in the runtime log rather than the client's output.
   `CTP_LOG_LEVEL=debug` on the *client* surfaces none of it.
2. A filter matching nothing still reports success.
3. No phase timings, so "which part is slow" needed a profiler.

### `CLIO_CAE_TELEMETRY=<path>`

Appends one JSON object per assimilation. Inert when unset (one `getenv` per
transfer).

```json
{"wall_ms":11896400000.0,
 "src":"/mnt/common/datasets-staging/TERRA_BF_L1B_O10204_....h5",
 "dst":"iowarp::sw_small",
 "include_patterns":["/ASTER/granule_11182001013943/TIR/*"],
 "exclude_patterns":[],
 "datasets_discovered":1691,"datasets_filtered":7,"dataset_errors":0,
 "mode":"single","num_nodes":1,
 "open_ms":4.42738,"discover_ms":55.4239,"filter_ms":0.269592,
 "assimilate_ms":229.978,"total_ms":290.099,"error_code":0}
```

* **Bottleneck** — the phase split is the point. Here assimilation is **79%** of
  wall time, discovery 19%, filtering negligible.
* **Replay** — `src`, `dst` and both pattern lists are the whole request, so a
  record reconstructs the transfer that produced it.
* **Failure attribution** — `datasets_filtered: 0` separates "pattern matched
  nothing" from `dataset_errors > 0`, "matched but failed to store".

### Promoted logging

`Discovered N dataset(s)` and `Filtered to N (from M)` moved from `kDebug` to
`kInfo`, so a default run shows them. A `kWarning` now fires when the filter
matches nothing:

```
NO datasets matched the include patterns -- nothing will be assimilated.
Check pattern syntax against the discovered dataset paths
(run with CTP_LOG_LEVEL=debug to list them).
```

The success path logs the phase breakdown at `kInfo`.

## What the telemetry immediately showed

**Discovery walks all 1,691 datasets on every transfer**, however narrow the
filter. At 55 ms on this granule that is tolerable, but it is a fixed cost per
transfer that no filter reduces — the same "do the work then discard it" shape
as MISR's single 755 MB chunk in
[part 3](20260918_claude_terra_fusion_discrepancy_03_optimization.md). A
multi-transfer OMNI job over one file pays it once per transfer.

That observation is only available because the phase timings exist, which is the
argument for the instrumentation.

## Caveats

* Telemetry covers the HDF5 assimilator only, not S3/GCS/binary paths.
* `wall_ms` is `steady_clock` since epoch — good for ordering and deltas, not a
  wall date.
* Per-dataset timings are not recorded, only per-transfer aggregates. A slow
  single dataset inside a large filter is still invisible.
* The `kWarning` fires on an empty *filtered* set; it cannot distinguish a
  malformed pattern from a correct pattern that genuinely matches nothing.
* Not tested in distributed mode (`num_nodes > 1`); the field is recorded but
  only the single-node path was exercised.
* Tier capacity is still not surfaced to the client. `PutBlob` failures appear
  as `dataset_errors` in telemetry and in the runtime log, but a user without
  either still sees "success".

## Reproducing

```sh
# runtime must compose clio_cae_core; restart it between measurements
CLIO_SERVER_CONF=rt.yaml CLIO_CAE_TELEMETRY=$PWD/cae_tele.jsonl clio_run start &
CLIO_SERVER_CONF=rt.yaml clio_cae job.yaml
sleep 20 && cte_search '.*' | head        # assimilation is async
jq . cae_tele.jsonl
```

Source: `context-assimilation-engine/core/src/factory/hdf5_file_assimilator.cc`
on branch `hyoklee/cae-telemetry`.
