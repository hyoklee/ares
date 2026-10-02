# clio-fs silently returns wrong data

Found on **ares**, 2026-10-01, while investigating why the clio-fs arm of
[part 18](20261001_claude_terra_fusion_18_nvme_tier_study.md) reported 0.00 s.
clio-core dev @ `6cec5008`.

## Summary

**Files written through a clio-fs mount come back with the correct size and the
wrong content.** `cp` exits 0, the file size is exact, and neither the runtime
nor the FUSE daemon logs anything. Nothing at any layer reports a problem.

Reproduced with [`bin/tf_cliofs_corruption_repro.sh`](../bin/tf_cliofs_corruption_repro.sh):

```
  1: ok   (cp rc=0, size=1073741824)
  2: ok   (cp rc=0, size=1073741824)
  3: *** WRONG CONTENT ***  cp rc=0  size=1073741824 (correct)
  4: *** WRONG CONTENT ***  cp rc=0  size=1073741824 (correct)
  5: *** WRONG CONTENT ***  cp rc=0  size=1073741824 (correct)
  6: ok
  7: *** WRONG CONTENT ***  cp rc=0  size=1073741824 (correct)
  8: ok
  9: ok
 10: *** WRONG CONTENT ***  cp rc=0  size=1073741824 (correct)

RESULT: 5 of 10 read back with the wrong content
# runtime errors logged: 0
# tier usage: 9.7G of 200GB
```

> **FIXED on `gpu-vector-rewrite`.** The same test passes **50 x 1 GiB copies
> with zero corruption** on that branch, in both RAM-tier and disk-only modes,
> against 5 of 10 corrupt here on `dev`. See
> [testing gpu-vector-rewrite](20261002_claude_gpu_vector_rewrite_cliofs.md).
> Not yet reported on issue #1116.

## How it was found

Part 18 scored clio-fs at 0.00 s for three reps. That was not a speedup: the
benchmark opened the staged 30.6 GB granule successfully and then found **zero
MODIS granules**, so it read nothing. An HDF5 file that opens but whose group
structure has vanished is what a corrupted copy looks like from the outside, so
the question became whether clio-fs round-trips bytes at all.

It mostly does, which is why this had not been noticed: part 16's clio-fs
timings ran fine, and the first 64 MiB and 2048 MiB test files came back clean.

## Rates

| tier state | sieve | corrupt |
| --- | --- | --- |
| fresh, 8 GB RAM + 200 GB disk | default (on) | **1 of 12** (~8%) |
| after prior traffic | default (on) | **3 of 14** (~21%) |
| after prior traffic | `CLIO_FUSE_SIEVE=0` | **9 of 12** (~75%) |
| fresh, 200 GB disk (packaged repro) | default (on) | **5 of 10** (50%) |

Both FUSE write paths are affected, and disabling the sieve makes it *worse*, so
this is below the sieve — in the CTE deferred-write layer rather than the
adapter.

**It is not tier exhaustion.** It reproduces on a 200 GB tier holding 9.7 GB,
and no `PutBlob failed`, `out of space` or `shortfall` line appears in the
runtime log.

## Shape of the corruption

Measured on a corrupted 1 GiB round-trip:

* **Exactly one 1 MiB region differs** out of 1024. 1 MiB is `kFsPageSize`
  (`filesystem_tasks.h:41`) — the CTE page, i.e. one blob.
* Within that page, a 4 KiB agreement map gives:

  ```
  SAME  +0       .. +131,072     (128 KiB)
  DIFF  +131,072 .. +1,048,576   (896 KiB)
  ```

* The bytes at page + 128 KiB are **the bytes from page + 0** — the aliasing
  holds for exactly 131,072 bytes. A 128 KiB sub-block appears twice.
* 128 KiB is `cp`'s write size, and it is also
  `DeferRegistry::kBatchChunk = 128 * 1024` (`core_client.h:953`).

So a 1 MiB page is filled by eight 128 KiB partial puts at eight different
`page_off` values, and one of them lands with the wrong offset or over the
wrong neighbour.

**Both persistent and transient instances occur.** Re-reading minutes later:

| file | later read |
| --- | --- |
| h1, p5, p10 | still wrong — the bad bytes are durable |
| p11 | correct — that one was a read-your-writes miss |

So at minimum the write path is affected; the transient case suggests the
pending-extent composition in `DeferRegistry` may be a second, separate fault.

## Where it probably is, and why no patch is offered

`cte_fuse_write` (`fuse_cte.cc:1652`) splits each write at page boundaries and
issues `AsyncPutBlobDefer` per slice. In `AsyncPutBlobDefer`
(`core_client.h:1651`) the ordering guard is

```cpp
while (pending_count_ != 0 && KeyOverlapsPending(key, offset, offset+size, 0))
  DeferAwaitKey(key);
```

whose own comment warns that "the server's un-ordered write token can land the
old bytes last". That guard serialises **overlapping** ranges only, so eight
concurrent partial puts to *different offsets of the same blob* are never
ordered against each other — which is exactly the access pattern that corrupts.

I tested widening it to serialise on any pending put for the key. **That
experiment was confounded** — by then I had written ~40 GiB into a 40 GB tier,
so the 12/12 failure it produced cannot be attributed to the change. I reverted
it rather than report a fix I had not isolated.

A real fix belongs with the maintainers. This layer has a deferred-put registry,
sharded pending extents, a recycled staging pool and server-side blob extension
all interacting, and the comments show several ordering hazards already fought
here. A speculative change risks masking the fault rather than removing it.

## What this invalidates

* **Part 18's clio-fs number (0.00 s) is a corruption artifact**, not a
  measurement, and is marked as such there.
* **Part 16's clio-fs timings (+15% steady state) were never content-verified.**
  They are probably fine — the reads succeeded and returned plausible data —
  but nothing in that study checked the staged bytes against the source, so they
  should carry that caveat.
* Any clio-fs result in this series that did not checksum its data is now
  suspect.

## Reproducing

```sh
bash bin/tf_cliofs_corruption_repro.sh                  # 12 x 1 GiB, default tier
SIZE_MB=512 N=20 bash bin/tf_cliofs_corruption_repro.sh
CLIO_FUSE_SIEVE=0 bash bin/tf_cliofs_corruption_repro.sh   # worse
```

The script builds its own runtime, tier and mount, writes N copies of one file,
checksums each read-back, and reports `cp`'s exit status, the file size and the
runtime's error count alongside each result.

## Caveats

* One machine, one build. Not tried on a compute node in this form, though
  part 18's failure there is consistent with it.
* The rate is noisy — 8% to 75% across configurations — and no controlled
  sweep of tier geometry versus corruption rate was run.
* The 128 KiB aliasing was characterised on a single corrupted file. Other
  corrupted files were confirmed wrong but not dissected, so the pattern may
  not be universal.
* Whether the transient and persistent cases share one cause is unknown.
