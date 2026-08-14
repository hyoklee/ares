# Can a 4-node clio-core cluster pass the 512³ large-chunk test in 90 minutes?

Run on **ares**, 2026-08-14. Answers
[`20260814_claude_netcdf_test.md`](20260814_claude_netcdf_test.md), which asks
whether forming a 4-node clio-core cluster gets `tst_chunks3` at
**512³ / chunk 128³** through in 90 minutes — the case that
["Where it stops"](20260813_claude_netcdf_test_results.md) reports as
unfinished on a single node.

## Short answer

**No — and the premise needs correcting first.** The 512³ case is not something
clio-core failed and more clio-core nodes could fix:

* **The thing that fails first is plain HDF5.** On 2026-08-13 the `baseline`
  variant — no CLIO in the path at all — was killed at the same 90-minute cap as
  the VOL, on two independent jobs. Adding clio-core nodes cannot speed up a run
  that has no clio-core in it.
* **The workload is a single serial process.** `tst_chunks3` is one process, one
  thread of I/O, no MPI. A clio-core cluster distributes the *runtime's* storage
  and task processing; it adds no client-side parallelism, so there is nothing
  for the extra three nodes to do except answer remote requests.
* **Measured, the cluster is slower, not faster** (numbers below): 2.7x slower
  at 64³, a wash to slightly slower at 256³ for the VOL, and **1.5x slower** on
  the operation that dominates the VFD.

Run head to head for 90 minutes at 512³ / chunk 128³:

| | timings completed in 90 min | Σ of those timings |
| --- | ---: | ---: |
| 1 node, plain HDF5 (no CLIO) | **5 of 18** | 3981 s |
| 4-node clio-core cluster, CLIO VOL | **5 of 18** | 5317 s (**1.34x slower**) |

Both were killed at the cap having finished the same five operations, and the
cluster took a third longer to do it. A **single one** of the 18 timings —
`compressed write 1x512x512` — costs **65 minutes** of the 90-minute budget on
plain HDF5 and **87 minutes** through the cluster.

Profiling that operation (below) identifies it exactly: 5 of 5 samples inside
zlib `deflate`, reached through
`H5D__chunk_lock -> H5D__chunk_cache_evict -> H5D__chunk_flush_entry`, with
**651 syscalls in 60 seconds** — pure user-space CPU, no I/O to distribute.
Giving HDF5 a chunk cache that fits the working set (`argv[8]`, 2 GiB) takes
that operation from **3900 s to 0.61 s** and the whole 18-timing test to
**202 s on one node** — and the CLIO VOL passes it too, at its usual 1.26x.

## Method

Same builds, same node type, same `tst_chunks3` as yesterday (HDF5 `develop`
`e4b6a96` / netCDF-C `main` `db5a7f9` / clio-core `dev` `edd8ab4`).

New pieces in [`../bin`](../bin):

| file | role |
| --- | --- |
| `nc4_clio_run4.sbatch` | runs the variants against an N-node clio-core cluster |
| `nc4_clio_runtime_cluster.yaml` | cluster compose config (hostfile + `neighborhood`) |

hpf's `nc4_clio_bench.sh` could not be reused as-is: it starts the runtime with
a bare local `clio_run start`, which is a single daemon by construction. The
cluster needs one daemon per node (`srun --ntasks-per-node=1`), a shared
hostfile, readiness *counted* across all daemons rather than matched once, and a
distributed stop and `/dev/shm` sweep. The per-variant timeout, the exit-hang
watchdog (the VOL still never exits), the result-file format and
`variant_status.tsv` are reproduced deliberately so the existing parsers and
table scripts work unchanged.

The cluster is real, not a fallback to single-node: `networking.hostfile` is
injected with the job's node list, `targets.neighborhood` is set to the node
count ("number of targets (nodes CTE can buffer to)" — `core_config.h`; leaving
it at 1 would pin every buffer to the local node), and each run logs four
daemons on four distinct hosts reporting `neighborhood=4`, with readiness
confirmed as `4/4 nodes reported pools`.

**One addition that changes what can be said: `stdbuf -oL`.** `tst_chunks3`'s
stdout is a pipe here, so glibc block-buffers it and nothing appears until the
process exits. That is why yesterday's 90-minute runs left *empty* result files
and could not say how far they had got — and why yesterday's report should have
said "was killed at 90 minutes" rather than "< 18 timings", which was an
artifact of the buffering, not a measurement. Line buffering turns the same runs
into a progress trace.

## Does a cluster help at a size that does complete?

The decisive experiment is not at 512³ (where nothing finishes) but at sizes
where the single-node numbers are known. Seconds of CPU time, as before.

| size | variant | 1 node | 4-node cluster | cluster / 1 node |
| --- | --- | ---: | ---: | ---: |
| 64³ / chunk 16³ | CLIO VOL, Σ 18 timings | 0.414 | 1.113 | **2.7x slower** |
| 256³ / chunk 64³ | CLIO VOL, `contiguous write xy` | 11.0 | 10.0 | 0.9x |
| 256³ / chunk 64³ | CLIO VOL, `contiguous read xy` | 6.6 | 6.4 | 1.0x |
| 256³ / chunk 64³ | CLIO VOL, `contiguous write yz` | 0.14 | 0.46 | 3.3x slower |
| 256³ / chunk 64³ | CLIO VOL, `contiguous read yz` | 0.057 | 0.31 | 5.4x slower |
| 256³ / chunk 64³ | **CLIO VFD, `contiguous write xy`** | **1200** | **1800** | **1.5x slower** |
| 256³ / chunk 64³ | CLIO VFD, `contiguous read xy` | 39 | 37 | 0.9x |

The pattern is consistent and it is what a serial client against a distributed
runtime should do:

* **Small operations get much worse** (3–5x), because their cost is per-operation
  latency and the cluster adds a network hop whenever CTE places a buffer on
  another node.
* **Large operations are unchanged** (±10%), because they are limited by what the
  single client process can push, not by the tier behind it.
* **The one operation that dominates the VFD gets 50% worse.** That is the whole
  budget: at 256³ the VFD's `contiguous write 256x256x1` is 96% of its total, and
  the cluster takes it from 1200 s to 1800 s.

Nothing here is a criticism of the cluster; it is the wrong tool for this
workload. `tst_chunks3` issues millions of tiny, strictly ordered I/O requests
from one thread. Four nodes of CTE capacity and four sets of runtime workers do
not make that thread issue them faster.

## What actually breaks at 512³ / chunk 128³

The progress traces (now that output is line-buffered) show the size does not
degrade gracefully — one operation class explodes:

| operation | 256³ / chunk 64³ | 512³ / chunk 128³ | factor |
| --- | ---: | ---: | ---: |
| `contiguous write 1xNxN` (baseline) | 0.026 s | 0.43 s | 16x |
| `chunked write 1xNxN` (baseline) | 0.028 s | **37 s** | **1300x** |
| `chunked write 1xNxN` (VOL, 4-node) | 0.18 s | **52 s** | 290x |

8x more data, 1300x the cost, and it is **plain HDF5** — no CLIO in the
baseline's path. The cause is in the chunk geometry the test name refers to:
doubling the chunk edge to 128³ makes each chunk `128³ × 4 B = 8 MiB`, so one
`1x512x512` slab spans a 4x4 grid of chunks = **128 MiB of chunks against HDF5's
67 MB chunk cache**. Every slab evicts the chunks the next slab needs, so each
one is read, modified and written repeatedly instead of once. At 256³/64³ a
chunk is 1 MiB and a slab's 16 chunks (16 MiB) fit the cache comfortably —
which is why the same operation costs 28 ms there.

That is a chunk-cache sizing problem inside the application's own process. It is
invisible to a VFD or VOL connector, which only sees the amplified I/O that
results, and it is equally invisible to three more nodes of runtime.

## The 512³ attempt itself

Two 90-minute runs, side by side: job 23577 is one node with **no CLIO at all**
(the control the question needs), job 23578 is the CLIO VOL on a 4-node cluster.
Both were killed by `timeout` at exactly 5400 s. Seconds of CPU time, in the
order `tst_chunks3` prints them:

| # | timing | 1 node, plain HDF5 | 4-node cluster, CLIO VOL | cluster / 1 node |
| ---: | --- | ---: | ---: | ---: |
| 1 | `contiguous write 1x512x512` | 0.43 | 1.7 | 4.0x |
| 2 | `chunked write 1x512x512` | 37 | 52 | 1.4x |
| 3 | `compressed write 1x512x512` | **3900** | **5200** | 1.3x |
| 4 | `contiguous write 512x1x512` | 5.3 | 11 | 2.1x |
| 5 | `chunked write 512x1x512` | 38 | 52 | 1.4x |
| 6–18 | *(never reached)* | — | — | — |
| | **Σ completed** | **3981** | **5317** | **1.34x** |

Both stop in the same place, having completed **5 of 18 timings** — still inside
the *write* half of the first of three access shapes. The 13 that never ran
include the compressed writes along the other two axes and all nine reads, and
at 256³ it was exactly those later shapes that were the most expensive.

So the 90-minute question has a clear answer, and the cluster is on the wrong
side of it: it did not complete more of the test than a single node did — it
completed the same five operations and took 1.34x as long.

### Why more nodes cannot help here

Line 3 is the whole story. `compressed write 1x512x512` at 128³ chunks costs
3900 s of CPU on stock HDF5 with no adapter in the path — 9100x the contiguous
write of the same slab, and ~65 of the 90 minutes on its own. Two effects
multiply:

1. **Chunk-cache thrash.** A 128³ float chunk is 8 MiB, so one `1x512x512` slab
   spans a 4x4 grid = 128 MiB of chunks against HDF5's 67 MB chunk cache. Each
   slab evicts what the next one needs, so chunks are read-modify-written many
   times instead of once.
2. **Deflate on every eviction.** Each of those repeated writes re-compresses a
   full 8 MiB chunk at deflate 6. That is CPU work in the application's own
   process, and it is why line 3 is 100x line 2 (same thrash, no compression).

Neither effect is I/O the cluster could absorb or parallelize:

* It happens **above** the VFD/VOL boundary, inside HDF5's chunk cache and
  filter pipeline. A connector only ever sees the amplified traffic that comes
  out the other side.
* `tst_chunks3` is **one process, one thread**, issuing strictly ordered
  operations. Four nodes of CTE capacity and four sets of runtime workers cannot
  make that thread compress or issue faster; they only add a network hop
  whenever CTE places a buffer off-node — which is why every row above is
  *slower* on the cluster, and why the small operations (rows 1 and 4) are worst
  hit in relative terms.

The 4-node cluster does exactly what it is built for — it formed cleanly, spread
`neighborhood=4` targets over four nodes, and quadrupled tier capacity. None of
that is what this workload is short of.

## The bottleneck, traced

The above was inferred from the shape of the numbers. It was then measured
directly: `nc4_clio_profile.sbatch` starts the workload, waits until it has
printed the first two timings — so the third, the expensive one, is what is
executing — and then samples it with gdb, `strace -c` and `perf`. (`perf` on
these nodes is built against a different kernel than the one running and
produced nothing; gdb sampling and strace carried the result.)

### The call chain

Every one of the 5 baseline samples landed on the same stack, leaf to root:

```
main                                        tst_chunks3.c
 nc_put_vara                                libnetcdf
  NC_put_vara
   NC4_put_vara
    NC4_put_vars
     H5Dwrite                               libhdf5
      H5D__write_api_common
       H5VL_dataset_write
        H5VL__native_dataset_write
         H5D__write
          H5D__chunk_write
           H5D__chunk_lock                  <- needs a cache slot for this chunk
            H5D__chunk_cache_evict          <- cache full: evict another chunk
             H5D__chunk_flush_entry         <- the victim is dirty: write it out
              H5Z_pipeline                  <- ... through the filter pipeline
               H5Z__filter_deflate
                compress2                   libz
                 deflate
                  deflate_slow              <- 5/5 samples here
```

`H5D__chunk_lock -> H5D__chunk_cache_evict -> H5D__chunk_flush_entry` is the
signature of cache thrash, and it is *not* on the path of a normal chunked
write: it appears only when acquiring a slot for the chunk being written
requires throwing out a dirty one. The CLIO VOL samples show the other half of
the same cycle — `H5D__chunk_lock -> H5Z_pipeline -> inflate`, i.e. reading an
evicted chunk back in and decompressing it. Across both variants, 14 of 15
samples are inside zlib, reached through `H5D__chunk_lock`.

### It is not I/O — `strace -c` over 60 s

| | baseline | CLIO VOL |
| --- | ---: | ---: |
| `pwrite64` | 277 | 280 |
| `pread64` | 277 | 280 |
| total syscalls | **651** | **2,060,681** |
| total syscall time | **0.026 s** | 69.6 s (mostly idle threads blocking) |

The baseline spends 26 *milliseconds* of a 60-second window in the kernel. The
operation is 100% user-space CPU — zlib — so no storage tier, node-local NVMe,
or extra cluster node can address it.

The VOL column is the other half of the cluster answer: the *chunk* I/O is
identical (280 vs 277 `pwrite64` — CLIO changes nothing about the amplification),
while the CLIO client adds ~2 M syscalls per minute, of which **989 k `getpid`
and 867 k `gettid`** — roughly 3,500 identity syscalls per chunk written. That
is where the VOL's extra 34% comes from, and adding nodes only adds to it.

### Why no connector can help: where CLIO sits

The VOL's own frame is visible in the stack, and its position is the point:

```
     H5Dwrite
      H5VL_dataset_write
       clio_dataset_write            <- libclio_hdf5_vol.so  (the CLIO VOL)
        H5VLdataset_write            <- pass-through to the native under-VOL
         H5VL__native_dataset_write
          H5D__write ... H5D__chunk_lock ... deflate   <- all the cost is here
```

The connector is entered **once per `H5Dwrite`**, above HDF5's chunk cache and
filter pipeline, and immediately delegates. Everything expensive happens inside
the native VOL it delegates to. A VFD sits even lower but sees only the already
amplified stream of chunk reads and writes. Neither layer can see that the same
64 chunks are being compressed over and over, let alone stop it.

### Proof by removing it

The diagnosis predicts one thing: give the chunk cache room for a slab's working
set and the cost disappears. `tst_chunks3` takes the cache size as `argv[8]`, so
this is a one-line change — same dimensions, same chunks, same deflate level,
same node, `6 512 128 512 128 512 128 2147483648` (2 GiB):

| timing | 67 MB cache (default) | 2 GiB cache | change |
| --- | ---: | ---: | ---: |
| `compressed write 1x512x512` | **3900 s** | **0.61 s** | **6400x faster** |
| `chunked write 1x512x512` | 37 s | 0.61 s | 61x faster |
| `contiguous write 1x512x512` | 0.43 s | 0.43 s | unchanged |
| **whole test (18 timings)** | **5/18 in 90 min** | **18/18, 195 s CPU / 202 s wall** | — |

The case that four nodes could not finish in 90 minutes finishes on **one node
in three and a half minutes**, with no CLIO and no configuration change other
than the chunk cache. The unchunked operations (`contiguous write 512x512x1`,
100 s) are untouched, exactly as expected: they have no chunks to cache.

**And with that one change the CLIO VOL passes too** — on a single node, no
cluster (job 23584):

| 512³ / chunk 128³, 2 GiB chunk cache | 18 timings | wall |
| --- | ---: | ---: |
| baseline (1 node) | 194.6 s | 202 s |
| CLIO VOL (1 node) | 245.6 s (**1.26x**) | 209 s |

That 1.26x is the same flat tax the VOL charged at every smaller size on
2026-08-13 — the adapter was never the problem at 512³, and once the chunk cache
stops thrashing it behaves exactly as it does everywhere else.

### What would actually pass

Not a cluster change — a chunk-cache or chunk-geometry change on the application
side. The size is called the "large chunk" case for a reason: the chunks
outgrew the cache.

**Raising the chunk cache is measured above and it is sufficient**: 2 GiB via
`argv[8]` (`nc_set_chunk_cache` / `H5Pset_chunk_cache` in a real application)
turns 5-of-18-in-90-minutes into all 18 in 202 s, and the CLIO VOL passes with
it. Two alternatives that attack the same line and were not run:

* **Keep chunks near 1 MiB** as the dimensions grow, instead of doubling the
  chunk edge with the dimension edge. At 512³ with 64³ chunks the per-slab chunk
  working set is 16 MiB and fits the default cache — which is exactly why the
  256³/64³ case in yesterday's sweep behaved normally.
* **Drop deflate** for scaling runs: it is what turns each redundant chunk write
  into ~0.5 s of CPU rather than a memcpy.

Any of these is worth more than three extra nodes here. The cluster result
stands on its own: for a serial, latency-bound, CPU-bound netCDF workload,
distributing the CLIO runtime is a cost, not a speedup.

## Jobs

| job | nodes | what | outcome |
| --- | ---: | --- | --- |
| 23575 | 4 | 64³ cluster smoke, VOL | 18/18, cluster verified 4/4 daemons |
| 23576 | 4 | 256³ cluster, VOL + VFD | 18/18 both; VFD's dominant op 1.5x slower than 1 node |
| 23577 | 1 | 512³ plain HDF5, 90 min, line-buffered | **5/18**, killed at cap |
| 23578 | 4 | 512³ cluster VOL, 90 min | **5/18**, killed at cap, 1.34x slower |
| 23580 | 1 | profile of the expensive op, baseline | 5/5 samples in `deflate` under `H5D__chunk_cache_evict`; 651 syscalls/60 s |
| 23582 / 23583 | 1 | profile of the expensive op, CLIO VOL | same HDF5 stack under `clio_dataset_write`; 2.06 M syscalls/60 s |
| 23581 | 1 | 512³ baseline, **2 GiB chunk cache** | **18/18 in 202 s** |
| 23584 | 1 | 512³ CLIO VOL + VFD, 2 GiB chunk cache | VOL **18/18 in 209 s** (1.26x); VFD phase in flight at the time of writing |

23578's queued VFD phase was cancelled rather than run: the VOL had just failed
to finish 5 of 18 timings in 90 minutes and the VFD is 1.5x slower than the VOL
on the dominant operation at 256³, so another 90 minutes on four nodes would
only have confirmed a foregone conclusion.

Results and full logs: `/mnt/common/hyoklee/nc4-clio-work/results/<tag>_<jobid>/`.
