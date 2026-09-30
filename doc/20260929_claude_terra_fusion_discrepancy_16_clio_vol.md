# Terra Fusion 5-sensor discrepancy, part 16: the discrepancy read path through the clio VOL and VFD — VOL slower, VFD at parity

Run on **ares**, 2026-09-29, against `hyoklee/core` dev at `75706f67` (22
commits ahead of the tree parts 1-15 used, including the merge of PR #5 and four
`perf(vol)` commits).

**Answer: performance is not better. The VOL is ~25% slower on this workload
and its own admission logic independently reaches the same conclusion; the VFD
is at exact parity and cannot be tuned into a win.**

## Headline

* **Default configuration: 24% slower.** Median TOTAL **11.01 s** vs native
  **8.88 s** over an interleaved A/B, and the trace shows **0 of 58 reads served
  from the tier**. The overhead is pure pass-through.
* **That is correct behaviour, not a bug.** The default admission mode is
  `kOnWrite`; this pipeline never writes, so nothing is ever staged.
* **With read admission enabled it still declines**, because the cost gate from
  `85c00bf0` measures the authoritative path and finds the local XFS page cache
  faster than the tier. Still 0/58.
* **Forced past the gate, the tier genuinely wins when it serves** — 6.17 s vs
  8.88 s (**1.44×**), MISR alone 2.10 s vs 3.79 s (**1.8×**) — **but it served on
  only 1 of 7 passes**, with the blobs demonstrably still resident in the tier on
  the passes that missed.
* **The VFD costs nothing and gains nothing**: median **9.24 s** against native
  **9.24 s**. Its default 64 KiB sieve is already optimal — 1 MiB, 16 MiB and
  sieve-off are all *worse* — and `CLIO_VFD_READ_TIER=1` costs 15-37%.
* **The VFD's own trace says why no cache can help**: `repeated_ranges: 0,
  distinct_ranges: 685`. Nothing is read twice in a pass.

## Why the Python pipeline could not be used directly

`bin/tf_sources.py` gets netCDF4 from a pip wheel that bundles its own HDF5
1.14; the clio VOL is built against the HDF5 2.3.0 fork. A connector cannot load
into a different libhdf5, so that path is native-only by construction.

[`bin/tf_vol_discrepancy_read.c`](../bin/tf_vol_discrepancy_read.c) reproduces
what the pipeline actually asks the file for, linked against the HDF5 the VOL
targets:

| phase | what | why it is here |
| --- | --- | --- |
| `modis_band` | `EV_1KM_Emissive[band,:,:]` × 19 granules | a **partial** read, 1 of 16 bands — the case `1fc47b3d` changed |
| `misr_full` | `AN/Data_Fields/Red_Radiance` entire | one 755 MB chunk; part 3 measured this at 69% of pipeline read time |
| `modis_geo` | `_1KM/Geolocation` Lat+Lon × 19 granules | many medium reads; the case `ab28d5e2` addresses |

1318 MiB moved per pass.

## Result: default configuration

Interleaved within one session, native and VOL alternating, as the `perf(vol)`
commits' own methodology requires:

| rep | mode | modis_band | misr_full | modis_geo | **TOTAL** |
| --- | --- | --- | --- | --- | --- |
| 1 | native | 1.43 | 3.83 | 3.66 | **8.91** |
| 1 | clio | 1.48 | 5.99 | 4.67 | **12.14** |
| 2 | native | 1.44 | 3.79 | 3.65 | **8.88** |
| 2 | clio | 1.45 | 5.18 | 4.39 | **11.01** |
| 3 | native | 1.39 | 3.73 | 3.62 | **8.74** |
| 3 | clio | 1.46 | 4.92 | 4.35 | **10.73** |

Medians: native **8.88 s**, clio **11.01 s** — the VOL is **24% slower**.

Per phase the cost is not uniform. `modis_band` is at **parity** (1.43 vs 1.46,
+2%); the loss is in `misr_full` (+37%) and `modis_geo` (+20%).

The trace explains all of it:

```
datasets touched      : 58
reads served from tier: 0
reads served native   : 58
bytes from tier       : 0.0 MiB
bytes from native     : 1318.0 MiB
writes staged         : 0
```

**Nothing was ever cached**, so nothing could be served, and the 24% is the cost
of routing every call through a connector that then hands it to the native
driver. `CLIO_VOL_ADMIT` defaults to `kOnWrite` and this workload is read-only.

## The cost gate declines on purpose

Setting `CLIO_VOL_ADMIT=read-miss` — stage on a read that misses — changes
nothing:

| pass | TOTAL | tier-served |
| --- | --- | --- |
| 1 | 10.87 s | 0/58 |
| 2 | 11.24 s | 0/58 |
| 3 | 11.77 s | 0/58 |

`clio_worth_staging` predicts a tier cost and admits only if the measured native
path was slower. Reading a local XFS file with 33 GB of page cache on a 94 GB
host, native wins, so the gate says no. `85c00bf0`'s message states this
intention directly: *"on a local filesystem it paid to cache data the page cache
already served an order of magnitude faster."* **The connector is making the
right call for this workload.**

## Forced past the gate: the tier can win, but does not hold

With `CLIO_VOL_ADMIT_COST=0` disabling the gate:

| pass | tier-served | misr_full | modis_geo | TOTAL |
| --- | --- | --- | --- | --- |
| 1 | 0/58 | 5.53 | 4.55 | 11.55 |
| **2** | **20/58, 919 MiB** | **2.10** | **2.59** | **6.17** |
| 3 | 0/58 | 5.98 | 4.61 | 12.08 |
| 4 | 0/58 | — | — | 11.72 |
| 5 | 0/58 | — | — | 11.22 |
| 6 | 0/58 | — | — | 12.10 |
| 7 | 0/58 | — | — | 11.95 |

**Pass 2 is the whole case for the VOL on this workload**: 919 MiB served from
DRAM, MISR's 755 MB chunk read in 2.10 s against native's 3.79 s (**1.8×**), and
a total of 6.17 s against native's 8.88 s (**1.44×**). That is a real and
substantial win, and it is what a burst tier is for.

It happened once in seven. The other six passes served nothing — **while the
data was still in the tier**. `cte_search` after the run lists the blobs:

```
hdf5:/mnt/.../TERRA_BF_L1B_O10204_....h5//MISR/AN/Data_Fields/Red_Radiance/chunk_574
hdf5:/mnt/.../TERRA_BF_L1B_O10204_....h5//MISR/AN/Data_Fields/Red_Radiance/chunk_351
hdf5:/mnt/.../TERRA_BF_L1B_O10204_....h5//MODIS/granule_2001322_0140/_1KM/Geolocation/Longitude/chunk_9
...
```

So this is a **lookup/binding failure, not an eviction**: the tier holds the
data and the reader does not find it. `ab28d5e2` describes a mechanism that
would produce exactly this shape — `clio_file_bind_tag` deletes and recreates
the tag whenever its coherence verdict is not `kMatched`, and the new
`tier_known_empty` flag then short-circuits the per-dataset hit test for the
rest of the file. **Whether that is what fires here was not traced**, and it
should not be cited as the cause without that work.

## The VFD: parity, and not tunable upward

`HDF5_DRIVER=clio_vfd` sits below the VOL, at byte altitude. Same benchmark, same
interleaving, its own session (native drifted to 9.24 s here — absolute times are
not comparable across sessions, only within):

| rep | native | clio_vfd |
| --- | --- | --- |
| 1 | 9.26 | 9.52 |
| 2 | 9.24 | 9.24 |
| 3 | 9.24 | 9.23 |

Medians **9.24 s vs 9.24 s — exact parity.** Only the first VFD pass is slower
(9.52), consistent with a one-off first-touch cost. Where the VOL costs 24% to
route every call, the VFD's pass-through is free.

### Tuning does not help

The trace shows a scattered small-read pattern, which is what a coalescing
window exists for, so the `sieve` knob is the obvious lever:

| `HDF5_DRIVER_CONFIG` | modis_band | misr_full | modis_geo | TOTAL |
| --- | --- | --- | --- | --- |
| *(default, 64 KiB)* | 1.49 | 3.98 | 3.82 | **9.29** |
| `sieve=1048576` | 1.49 | 4.43 | 3.85 | 9.76 |
| `sieve=16777216` | 1.47 | 4.29 | 3.83 | 9.59 |
| `sieve=0` (off) | 1.49 | 4.22 | 3.79 | 9.50 |

**The 64 KiB default is already the best of these**, and every change is worse.
Turning coalescing off costs 2%; widening it costs 3-5%, since the window bounds
a per-call scratch allocation that then goes mostly unused.

`CLIO_VFD_READ_TIER=1`, which lets reads be served from the tier, is worse
still — 12.71 s, 10.59 s, 10.96 s across three passes, all above native's 9.24 s.

### Why no cache can help this workload

The VFD trace is the clearest statement of the structural problem, because it
sees byte ranges the VOL cannot:

```
totals:        reads 685, writes 0, read_bytes 672,395,980
request_size:  lt_1k 566 | 1k_4k 59 | 4k_64k 2 | ge_1m 58
locality:      sequential 42, scattered 643
repeat:        repeated_ranges 0, distinct_ranges 685
```

**`repeated_ranges: 0`.** Across a full pass over the granule, not one byte range
is read twice. A burst tier is a reuse device; this pipeline has no reuse within
a run to exploit, and between runs the OS page cache already holds the file. The
566 sub-kilobyte reads are HDF5 metadata, and the 58 reads ≥1 MiB are the
chunks — 672 MB of file bytes inflating to the 1318 MiB the application asked
for, which is the zlib-1 compression measured back in part 1.

## What this means for the pipeline

**Keep the discrepancy pipeline on the native path.** Concretely:

* As shipped and configured by default, the VOL costs 24% and returns nothing on
  this workload, because a read-only pipeline never triggers write admission.
* The VFD is free but also does nothing here. It is the right choice if a clio
  data path is wanted for other reasons — telemetry, or a future tier-backed
  deployment — since it costs nothing to leave in place.
* The gate's refusal is correct for a local XFS file. Parts 10-15 re-read this
  granule dozens of times, which *sounds* like the reuse case a tier exists for
  — but the reuse is being served by the OS page cache already, which is what
  the gate measures and respects.
* The regime where this would change is the one the commits name: a parallel
  filesystem with latency-bound small reads, or a working set too large for page
  cache. **Neither was tested here**, and on ares' local XFS neither applies.

`modis_band` reaching parity (+2%) is worth noting given `1fc47b3d` targets
exactly that partial-read path — but with no measurement of the pre-`1fc47b3d`
build in this session, **no improvement is claimed**; parity is simply what was
observed.

## Caveats

* **Warm page cache throughout.** The file is 32.9 GB on local XFS with 33 GB in
  `buff/cache` on a 94 GB host. This is the most favourable possible case for
  native and the least favourable for a tier.
* Single-node, single-process, serial reads. No MPI, no collective I/O; the
  parallel cases from the 09-14/09-15/09-16 studies were not repeated.
* The 1-in-7 tier-hit rate is reported as observed. Its cause was not traced,
  and seven passes is a small sample for a rate.
* Absolute times drift with load on this shared node — the commits' own note.
  All comparisons here are within one session, interleaved.
* clio-fs was not re-tested against this updated tree; only the VOL and VFD.
* The VFD sieve sweep is single-run per setting, not replicated. The spread
  (9.29-9.76) is small enough that only the direction — default is best — should
  be read from it, not the exact ordering of the three losers.
* `CLIO_VOL_ADMIT_COST=0` is a test-suite override, not a supported production
  setting. The 1.44× figure is what the hardware can do, not a configuration
  recommendation.

## Reproducing

```sh
H5=/mnt/common/hyoklee/opt/hdf5-develop
P=/mnt/common/hyoklee/opt/clio-core
$H5/bin/h5cc -O2 -o tf_vol_read bin/tf_vol_discrepancy_read.c

# private runtime, capped tier
sed -e 's/capacity: "0g"/capacity: "8GB"/' -e 's/capacity_limit: "0g"/capacity_limit: "24GB"/' \
    -e 's/^\( *port:\) *9413/\1 9823/' $P/data/clio_default.yaml > rt.yaml
CLIO_SERVER_CONF=$PWD/rt.yaml clio_run start &

export LD_LIBRARY_PATH=$P/lib:$H5/lib HDF5_PLUGIN_PATH=$P/lib
./tf_vol_read                                   # native
HDF5_VOL_CONNECTOR=clio ./tf_vol_read           # through the connector
HDF5_VOL_CONNECTOR=clio CLIO_VOL_TRACE=$PWD/tr ./tf_vol_read   # + per-access trace
```

`CLIO_VOL_TRACE` takes a **directory**, not a boolean; it writes
`<file>.access.jsonl` per access and `<file>.access.json` aggregated at close,
and the `read_served.cache` / `read_served.native` counters are what settle
whether the tier did anything.
