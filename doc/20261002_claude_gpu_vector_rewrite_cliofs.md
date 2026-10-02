# Testing `gpu-vector-rewrite`: clio-fs corruption is fixed, and Terra Fusion reads correctly through it

Run on **ares**, 2026-10-02. Tests
[`iowarp/clio-core@gpu-vector-rewrite`](https://github.com/iowarp/clio-core/tree/gpu-vector-rewrite)
(`9a9f4621`, 1034 commits ahead of `dev`) against the two things that failed on
`dev`: the silent data corruption of
[issue #1116](https://github.com/iowarp/clio-core/issues/1116), and the Terra
Fusion read that produced part 18's bogus 0.00 s.

## Headline

* **The corruption is fixed.** 50 × 1 GiB copies through clio-fs, **zero
  corrupt**. On `dev` the same test gave **5 of 10 corrupt**.
* **Terra Fusion now stages byte-exact and reads correctly**: 32,871,364,681
  bytes in, identical sha256, and the benchmark finds all **19 MODIS granules**
  where part 18's run found zero.
* **clio-fs is at near-parity for reads**: 10.90 s vs 10.57 s direct
  (**+3.1%**), on a workload part 18 established is decompression-bound anyway.
* The branch is already working this issue — its HEAD commit is
  *"clio_fs_suite: #1133 fsync test, zero-tail tears, **disk-only #1116 runs**"*,
  and it ships a `copy` test whose docstring describes the same **128 KiB
  sub-block** signature I measured independently.

## The corruption test

The branch ships `context-transfer-engine/test/integration/clio_fs_suite` with a
group written for this issue:

> `cp_1g_byte_exact` — *"cp a 1 GiB random file into the mount 10 times; every
> copy must match the source exactly (reports the bad 128 KiB sub-blocks and
> whose bytes they hold)."*

That is the same test I built for #1116, down to the 128 KiB granularity, which
is independent corroboration of the diagnosis.

| run | copies | tier | result |
| --- | --- | --- | --- |
| A | 10 × 1 GiB | 8 GB RAM + 30 GB disk | **PASS** — `silent_bad_copies: 0, reported_failed_copies: 0` |
| B | 20 × 1 GiB | 8 GB RAM + 40 GB disk | **PASS** |
| C | 20 × 1 GiB | **disk only** (`--ram-gb 0`) | **PASS** |

**50 copies, 0 corrupt.** For comparison, on `dev` at `6cec5008` my reproducer
gave 5 of 10 corrupt on a fresh tier, and up to 9 of 12 with the sieve disabled.

Run C matters because the commit message calls out "disk-only #1116 runs", and
because my own `dev` measurements implicated the RAM→disk spill — the first
failure there appeared at 9 GiB cumulative against an 8 GB RAM tier. Removing
the RAM tier entirely still passes here.

## Terra Fusion over clio-fs

The granule was staged through the mount and **verified before any timing was
taken** — the step part 18 omitted:

```
# stage: rc=0 in 218s
#   source sha 431c69e0b89e982fe7c94314a256bb38
#   staged sha 431c69e0b89e982fe7c94314a256bb38
#   BYTE-EXACT: True
#   sizes: 32871364681 vs 32871364681
```

Then the same benchmark used in parts 16 and 18:

| rep | direct | clio-fs |
| --- | --- | --- |
| 1 | 14.59 *(cold)* | 11.30 |
| 2 | 10.69 | 10.91 |
| 3 | 10.45 | 10.90 |

Steady-state medians (reps 2-3): **direct 10.57 s, clio-fs 10.90 s — +3.1%**.

**Every run found all 19 MODIS granules.** Part 18's clio-fs arm found zero,
which is what the 0.00 s was: a corrupted file that opened and contained
nothing. That number is now explained and superseded.

The remaining +3% is consistent with part 18's finding that this workload is
decompression-bound (96% CPU, zlib level 1): once clio-fs returns the right
bytes, the FUSE path costs a few percent and the inflate dominates.

## Getting it to run

Three obstacles, none of them the branch's fault but all worth recording:

1. **Build everything, not just the binaries you want.** `clio_run` and
   `clio_cte_fuse` alone link fine and then fail at runtime with
   `ChiMod 'clio_admin' not found` — the chimod *runtime* libraries are separate
   targets. A bare `cmake --build build` produced 11 of them.
2. **The dev-era server config does not work on this branch.** It composes
   `cte_core → replication → cache → stream → filesystem`; a config with only
   `cte_core` mounts and then wedges with
   `RouteLocal returned 4 for pool=PoolId(major:512…)` and
   `[stuck-wait] no completion after 60s`. Use the suite's generated
   `clio_server.yaml`, or `cluster.py`, rather than an older template.
3. **The suite does not preload the distro libfuse3.** Its mount fails with
   `fusermount3: mount failed: Operation not permitted`, which reads as a
   privilege problem and is not one — it is the spack-3.16.2-vs-distro-3.10.5
   mismatch from
   [part 16](20260929_claude_terra_fusion_discrepancy_16_clio_vol.md). I added a
   `CLIO_SUITE_FUSE_PRELOAD` hook to `cluster.py` to get past it
   ([`bin/gvr_cluster_fuse_preload.patch`](../bin/gvr_cluster_fuse_preload.patch));
   that is a portability fix worth upstreaming.

## What this means for the earlier parts

* **Part 18's clio-fs row is superseded**, not merely caveated. The 0.00 s was
  corruption; on a build without that corruption clio-fs reads at +3%.
* **Part 16's clio-fs timings (+15%) stand as plausible but remain
  unverified** — they were taken on `dev` without a content check, so whether
  those particular reads were clean is unknown.
* **Issue #1116 should be updated** with this result: the branch passes 50 × 1
  GiB where `dev` fails 5 of 10.

## Caveats

* **One branch build, one node** (ares-comp-19), one granule. The branch is 1034
  commits ahead of `dev`, so "fixed" here means "does not reproduce", not
  "the specific defect was located and removed" — I did not identify which
  commit fixed it.
* 50 copies is strong against a ~50% failure rate but says nothing about a rare
  residual case.
* The suite reported `worker stall warnings: {'ares-comp-19': 51}` on the
  passing run. Not investigated; it did not affect correctness here.
* Timings are 3 reps on a shared node with other users active, and `/mnt/nvme`
  free space moved from 76 GB to 34 GB during the session.
* The `cluster.py` preload change is local to my worktree and not submitted.

## Reproducing

```sh
git worktree add <dir> origin/gpu-vector-rewrite --detach
cmake -S <dir> -B <dir>/build -DCLIO_CTE_ENABLE_FUSE_ADAPTER=ON ...
cmake --build <dir>/build -j            # ALL targets, for the chimod runtimes

cd <dir>/context-transfer-engine/test/integration/clio_fs_suite
CLIO_SUITE_CP_COPIES=20 python3 suite.py --bin <dir>/build/bin \
    --out <out> --groups copy --nodes 1 --disk-gb 40 --ram-gb 0
```

Terra Fusion, after applying `bin/gvr_cluster_fuse_preload.patch` to the
branch:

```sh
cp bin/gvr_terra.py <dir>/context-transfer-engine/test/integration/clio_fs_suite/
srun -N1 --exclusive python3 .../gvr_terra.py <dir>/build/bin <out> \
     <granule.h5> <built tf_vol_read>
```

[`bin/gvr_terra.py`](../bin/gvr_terra.py) deploys through the suite's
`cluster.py`, stages the granule, sha256-verifies it against the source, and
only then times
[`bin/tf_vol_discrepancy_read.c`](../bin/tf_vol_discrepancy_read.c) against both
paths.
