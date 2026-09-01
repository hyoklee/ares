# IOR over clio-fs on the updated `dev` — 2x throughput, and the durable tier goes quiet

Run on **ares**, 2026-09-01. Follows
[`20260811_claude_ior_dev_update.md`](20260811_claude_ior_dev_update.md).

Builds compared (all built identically: Release, CTE + filesystem + replication
+ cache + indexer + FUSE adapter, compressor off, ELF and MPI off, spack
libfuse 3.16.2 headers, conda toolchain):

| tag | revision | what it is |
| --- | --- | --- |
| `dev1` | `2992817c` | `dev` as measured on 08-04 |
| `dev2` | `66353084` | `dev` as measured on 08-11 — v2.2.0, the build the last report called a 12-node write regression |
| `dev3` | `3357ac99` | **`dev` today** — v2.2.1 + 296 commits (`v2.2.0-296-g3357ac99`), 289 commits past dev2 |
| `dev3nv` | `3357ac99` | the **same dev3 binaries** launched with `CLIO_VIZ_ENABLE=0` |

`dev3`'s cmake options were recovered from `dev2`'s `CMakeCache.txt` and passed
explicitly, so the A/B moves the source revision and nothing else.

`dev3nv` exists because 3357ac99's `clio_run runtime start` now serves an HTTP
dashboard on every node **by default** (issue #990/#993, `EnableVizForDaemon` in
`clio_run_cmd_runtime_start.cc`); dev2 has no such thing. It is a wrapper prefix
— symlinked `lib/`, a two-line `bin/clio_run` that sets `CLIO_VIZ_ENABLE=0` and
execs dev3's real binary — so `run_ior_cliofs.sh` stays byte-identical across
every phase.

Method is unchanged and still non-negotiable on this cluster: **all comparisons
are phases inside one allocation**, same nodes, minutes apart. Only within-job
ratios are reported as results. This run used the `datacrumbs` partition
(`ares-comp-[03-08,10,12,14-16,29]`) because another user held 16 of `compute`'s
nodes; absolute numbers are ~2x the 08-11 job's on identical software, which is
exactly the cross-job drift the method exists to defeat.

## Headline

* **dev3 is ~2x faster than dev2 at both scales, in every phase.**
  12 nodes: write **+88%**, read **+71%**. 8 nodes: write **+102%**, read **+80%**.
  Every individual dev3 phase beats every individual dev1/dev2 phase; there is no
  overlap in the distributions.
* **But dev3's replication layer is inert, and that is part of the 2x.** From
  the same `num_replicas: 1` config, dev1 and dev2 land **4.4-4.5 GiB/node** on
  the durable NVMe tier every single time; dev3 lands 0-1.34 GiB/node, erratically,
  and extra settle time does not close the gap. Asking dev3 for **zero** replicas
  costs nothing (+5.5% write, if anything faster) and removes only **188 MiB/node**
  of tier traffic — so dev3's real durable-replica output is ~188 MiB/node against
  the 1536 MiB/node one full copy would be. The two builds are not doing the same
  work, and the speedup is not a like-for-like win.
* **The #915 error storm is gone.** dev2 still logs ~2,600–3,000
  `[AggregateOut CONTRACT VIOLATION]` lines per node per run; dev3 logs **zero**,
  and 0–5 ERROR lines total. `#1027 / 915-aggregateout-no-copy` landed between
  the two revisions.
* **The 08-11 12-node write regression did not reproduce.** dev2 vs dev1 is
  **+1.0%** at 12 nodes and **-0.9%** at 8 nodes here, against -14%/-15%/-20% in
  three allocations on 08-11. Same builds, different node set. Treat the 08-11
  regression as node-set-dependent, not a property of dev2.
* **The dashboard costs nothing measurable.** dev3nv vs dev3 is +1.3%/-1.5% on
  writes and +0.5%/+4.8% on reads — inside the phase-to-phase spread.
* **dev2 failed to read back its own data twice in four read phases.** dev1,
  dev3 and dev3nv: zero such failures.

## Numbers

All values MiB/s aggregate, IOR 3.3.0 `-a POSIX -w -r -F -e -t 1m -b 64m -s 1
-i 1`, 24 ranks/node, file-per-process on each node's local clio-fs mount.

### 12 nodes / 288 ranks (job 23810)

| round | build | write | read |
| --- | --- | ---: | ---: |
| r1 | dev1 | 5040.94 | 9789.54 |
| r2 | dev1 | 5141.98 | 9059.34 |
| r1 | dev2 | 5069.00 | *(read failed)* |
| r2 | dev2 | 5214.31 | 9832.03 |
| r1 | **dev3** | **9994.23** | **16723.32** |
| r2 | **dev3** | **9321.30** | **16850.30** |
| r1 | dev3nv | *(phase lost — shm flake)* | |
| r2 | dev3nv | 9785.44 | 16875.71 |

| build | write | read |
| --- | ---: | ---: |
| dev1 | 5091.46 | 9424.44 |
| dev2 | 5141.66 | 9832.03 |
| **dev3** | **9657.76** | **16786.80** |
| dev3nv | 9785.44 | 16875.70 |

dev3 vs dev2: write **+87.8%**, read **+70.7%**.
dev3 vs dev1: write **+89.7%**, read **+78.1%**.
dev2 vs dev1: write +1.0%, read +4.3%.
dev3nv vs dev3: write +1.3%, read +0.5%.

### 8 nodes / 192 ranks (job 23811)

| round | build | write | read |
| --- | --- | ---: | ---: |
| r1 | dev1 | 3596.12 | 6499.45 |
| r2 | dev1 | 3488.57 | 6617.06 |
| r1 | dev2 | 3460.38 | 6134.67 |
| r2 | dev2 | 3559.62 | *(read failed)* |
| r1 | **dev3** | **7252.40** | **11077.54** |
| r2 | **dev3** | **6925.20** | **10980.29** |
| r1 | dev3nv | 6984.68 | 11473.10 |
| r2 | dev3nv | 6983.99 | 11652.71 |

| build | write | read |
| --- | ---: | ---: |
| dev1 | 3542.35 | 6558.26 |
| dev2 | 3510.00 | 6134.67 |
| **dev3** | **7088.80** | **11028.90** |
| dev3nv | 6984.34 | 11562.90 |

dev3 vs dev2: write **+102.0%**, read **+79.8%**.
dev3 vs dev1: write +100.1%, read +68.2%.
dev2 vs dev1: write -0.9%, read -6.5%.
dev3nv vs dev3: write -1.5%, read +4.8%.

## The durable-bytes gap

The harness snapshots `du` (allocated blocks, not apparent size) on each node's
`cte_disk_tier.dat_node*` right after IOR, because that is the only evidence the
replication layer actually wrote anything. dev1 and dev2 are metronomic at
~4.4–4.5 GiB/node. dev3 is not, and is always far lower.

Replication is **asynchronous write-through**: the put is acked once the
authoritative copy is down and the durable NVMe copy is scheduled behind it. A
faster build therefore ends IOR sooner after its last put and gets snapshotted
with more still in flight — so the raw `du` undercounts dev3 structurally. To
separate "still draining" from "never written", `run_ior_cliofs.sh` gained a
`SETTLE=<seconds>` knob (default 0, so every throughput phase above is
unaffected) that prints the pre-settle number, sleeps, and then takes the real
snapshot.

Every durable-bytes measurement taken today, sorted by build:

| job | phase | settle | durable bytes |
| --- | --- | ---: | ---: |
| 23810 12n | r1 dev1 | 0 s | 4522.7 MiB/node |
| 23810 12n | r2 dev1 | 0 s | 4505.6 MiB/node |
| 23811 8n | r1 dev1 | 0 s | 4480.0 MiB/node |
| 23811 8n | r2 dev1 | 0 s | 4492.8 MiB/node |
| 23810 12n | r1 dev2 | 0 s | 4462.9 MiB/node |
| 23810 12n | r2 dev2 | 0 s | 4505.6 MiB/node |
| 23811 8n | r1 dev2 | 0 s | 4467.2 MiB/node |
| 23811 8n | r2 dev2 | 0 s | 4403.2 MiB/node |
| 23812 12n | r1 dev2 | 120 s | 4377.5 MiB/node (4343.3 pre-settle) |
| 23810 12n | r1 **dev3** | 0 s | **0.0 MiB/node** |
| 23810 12n | r2 **dev3** | 0 s | **1190.6 MiB/node** |
| 23811 8n | r1 **dev3** | 0 s | **0.0 MiB/node** |
| 23811 8n | r2 **dev3** | 0 s | **364.4 MiB/node** |
| 23812 12n | r1 **dev3** | 120 s | **1339.4 MiB/node** (1100.2 pre-settle) |
| 23813 12n | r1 **dev3** | 420 s | **790.6 MiB/node** (2.6 pre-settle) |
| 23810 12n | r2 dev3nv | 0 s | 1217.1 MiB/node |
| 23811 8n | r1 dev3nv | 0 s | 142.1 MiB/node |
| 23811 8n | r2 dev3nv | 0 s | 289.5 MiB/node |

Two things fall out, and the second is the one that matters:

1. **It is not async lag.** dev2 is done draining at t+0 (+34 MiB over the next
   two minutes). dev3 keeps trickling after IOR ends — 1100 -> 1339 MiB over
   120 s — but seven minutes of settle in job 23813 produced **790 MiB/node**,
   *less* than two minutes of settle produced in job 23812. More time does not
   close the gap.
2. **dev3's durable output is nondeterministic.** Across six measurements it
   ranges from **0 to 1339 MiB/node** with no relation to settle time, while
   dev1 and dev2 sit inside a 3% band across eight measurements. dev3nv, the
   same binaries with the dashboard off, scatters the same way (142–1217), so
   this is dev3 the revision, not the dashboard.

Each node's primary data is 24 ranks x 64 MiB = **1536 MiB**, so one durable
replica of it would be ~1536 MiB and dev2's 4.4 GiB is **2.9x** that. It is
tempting to read dev3's ~1.3 GiB high-water mark as "one correct replica" and
dev2's 4.4 GiB as the #915 defect duplicating replicas — the guard's own error
text, which dev2 emits thousands of times per node and dev3 emits zero of, says
*"This task's `AggregateOut` is copying the whole replica"*. But the 0 MiB and
364 MiB runs kill that reading as a complete explanation: a correct
single-replica path would not land 0 bytes on the durable tier in two of six
runs.

What the evidence supports is narrower and worse: **under this config dev3's
replication layer places a variable and often near-zero number of durable
replicas, where dev2 reliably placed ~3 copies' worth.** The next section pins
that down.

### Replication in dev3 is effectively inert

Bytes on a tier are a proxy. The direct test is to ask dev3 for **zero**
replicas and see what changes. Job **23814** runs `num_replicas: 1` and
`num_replicas: 0` back to back in one allocation, 12 nodes, `SETTLE=120`
(`run_replica_probe.sh`):

| dev3 config | write MiB/s | read MiB/s | durable at t+0 | durable at t+120s |
| --- | ---: | ---: | ---: | ---: |
| `num_replicas: 1` | 9756.33 | 16584.41 | 367.8 MiB/node | **977.5 MiB/node** |
| `num_replicas: 0` | 10294.71 | 16935.99 | 0.0 MiB/node | **789.3 MiB/node** |

Turning replication off entirely makes dev3 **+5.5% faster on writes and +2.1%
on reads** — the wrong sign for a layer that was doing work, and in any case
inside the spread of repeated dev3 phases (12-node writes ranged 9163–10295
across six phases today). And it removes only
**188 MiB/node** of tier traffic: the ~789 MiB that survives `num_replicas: 0`
is not replicas at all, it is the core's own spill and metadata.

So dev3's actual durable-replica output is on the order of **188 MiB/node**
against the **1536 MiB/node** one full copy would be, and against dev2's
**4.4 GiB/node**. **Replication is inert in dev3 under this config**, and a
meaningful share of the 2x is the reliability layer not doing its job rather
than doing it faster.

`#1052` (`e3bde630`, *"Let the configured tier score decide placement, not a
bandwidth guess"*) is the first commit to bisect against: it changes which tier
a put lands on under the `dpe_type: max_bw` this config uses, and a replica that
cannot find a tier satisfying `REPLICA_PERSISTENT` is a replica that never gets
written. `#1010` (CTE eviction trigger) and `#1019` (bdev preallocate budget)
are the next two.

## The error storm is fixed

Counts on a single node in a single run, from the daemon log:

| build | 8n AggregateOut | 8n all ERROR | 12n AggregateOut | 12n all ERROR |
| --- | ---: | ---: | ---: | ---: |
| dev1 | 0 | 12–16 | 0 | 21 |
| dev2 | 2594–3006 | 2595–3035 | 2847 | 3037 |
| **dev3** | **0** | **3–5** | **0** | **0** |
| dev3nv | 0 | 1 | 0 | 0 |

`fb735bdb Make AggregateOut merge OUT fields only, never whole-task Copy`
(`#1027`) is the fix. The 08-11 report flagged the storm as "the first thing to
check when someone picks this up" and left open whether the logging itself was
on the measured path; that A/B never produced a usable pair. It is moot now —
the lines are gone and the throughput doubled, but with the durable-bytes caveat
above, how much of the doubling is *not* writing the log versus *not* writing
the duplicate replicas is not separable from these runs.

## dev2 cannot always read back what it wrote

Two of dev2's four read phases died on data it had just written, on the clio-fs
mount, with no corresponding failure in dev1, dev3 or dev3nv:

```
# job 23810, 12n, r1
ior ERROR: open64("/mnt/nvme/hyoklee/clio886/mnt/ior.bin.00000179", 2) failed,
           errno 2, No such file or directory (aiori-POSIX.c:473)
# job 23811, 8n, r2
ior ERROR: read(22, 0x5557f0b41000, 1048576) failed,
           errno 2, No such file or directory (aiori-POSIX.c:550)
```

The 12-node case wedged mpiexec afterwards and burned the harness's full 900 s
timeout. This is a dev2 defect that dev3 does not show; it is recorded here
because the 08-11 report's dev2 numbers were collected without noticing it, and
because "dev3 is 2x faster" should be read alongside "dev2 sometimes lost data
that dev3 does not".

## What else landed between dev2 and dev3

289 commits. The ones that plausibly touch these numbers:

* `#1027` **`fb735bdb`** `AggregateOut` merges OUT fields only, never a whole-task
  `Copy` — kills the error storm, and by its own description was duplicating
  replicas.
* `#1052` **`e3bde630`** *"Let the configured tier score decide placement, not a
  bandwidth guess"* — changes which tier a put lands on under `dpe_type: max_bw`.
  Prime suspect for the durable-bytes shift.
* `#1009` client put sieving, plus the fsx/xfstests correctness family
  (`38a8174a`, `ccc6328b`, `02f43d66`) — put ordering, gap zeroing, drains on
  `O_TRUNC` reopen. The likely reason dev3 never fails a read-back.
* `#1019` bdev preallocate budget; `#1010` CTE eviction trigger;
  `#1032` rwlock exclusion; `#997` per-container method stats;
  `#993` the C++ context visualizer (the new default dashboard).

## Harness notes

* One phase was lost to the known `shm_open failed ... (chi_main_segment_hyoklee_9413)`
  flake in the FUSE clients (dev3nv, 12n, r1 — 50 occurrences on one node). This
  is the same systemd-logind `RemoveIPC` race documented on 08-11; the keepalive
  session reduces but does not eliminate it. No failed phase contributed a number.
* `run_ior_cliofs.sh` gained `SETTLE=<seconds>` (default 0). Every phase in the
  tables above ran with the default, so the change is additive and the earlier
  runs remain comparable.
* IOR without `-R` does not verify content, so the throughput runs say nothing
  about correctness — except where the read phase failed outright, which it did
  only for dev2.

## Reproduce

```
# builds
/mnt/common/hyoklee/cliodev/install     dev1    (2992817c)
/mnt/common/hyoklee/cliodev2/install    dev2    (66353084)
/mnt/common/hyoklee/cliodev3/install    dev3    (3357ac99, worktree of
                                        ~/src/iowarp/clio-core/dev/conda)
/mnt/common/hyoklee/cliodev3nv/install  dev3nv  (same binaries, CLIO_VIZ_ENABLE=0)

# build recipe
/mnt/common/hyoklee/cliodev3/build_dev3.sh
/mnt/common/hyoklee/cliodev3/make_nv_prefix.sh

# throughput (jobs 23810 @ -N12, 23811 @ -N8)
B="dev1:/mnt/common/hyoklee/cliodev/install dev2:/mnt/common/hyoklee/cliodev2/install"
B="$B dev3:/mnt/common/hyoklee/cliodev3/install dev3nv:/mnt/common/hyoklee/cliodev3nv/install"
sbatch -D /mnt/common/hyoklee/clio886/runs -N12 -p datacrumbs -t 01:00:00 \
  --export=ALL,BUILDS="$B",ROUNDS=2,CHAIN=chain \
  /mnt/common/hyoklee/clio886/runs/run_multi_paired.sh

# durable-bytes settle probe (job 23812)
sbatch -D /mnt/common/hyoklee/clio886/runs -N12 -p datacrumbs -t 00:45:00 \
  --export=ALL,BUILDS="dev2:/mnt/common/hyoklee/cliodev2/install dev3:/mnt/common/hyoklee/cliodev3/install",ROUNDS=1,CHAIN=chain,SETTLE=120 \
  /mnt/common/hyoklee/clio886/runs/run_multi_paired.sh

# 420 s convergence probe (job 23813)
sbatch -D /mnt/common/hyoklee/clio886/runs -N12 -p datacrumbs -t 00:40:00 \
  --export=ALL,BUILDS="dev3:/mnt/common/hyoklee/cliodev3/install",ROUNDS=1,CHAIN=chain,SETTLE=420 \
  /mnt/common/hyoklee/clio886/runs/run_multi_paired.sh

# num_replicas 1-vs-0 discriminator, one allocation (job 23814)
sbatch -D /mnt/common/hyoklee/clio886/runs -N12 -p datacrumbs \
  --export=ALL,PREFIX=/mnt/common/hyoklee/cliodev3/install,TAG=dev3,SETTLE=120 \
  /mnt/common/hyoklee/clio886/runs/run_replica_probe.sh
```

Artifacts (config used, per-node daemon/FUSE logs, raw IOR output) in
`/mnt/common/hyoklee/clio886/runs/run_<build>_chain_<N>n_<jobid>_r<round>/`.

## Jobs

| job | nodes | what | outcome |
| --- | ---: | --- | --- |
| 23810 | 12 | dev1/dev2/dev3/dev3nv x2 rounds | 6 of 8 phases clean; dev2 r1 read failed, dev3nv r1 lost to the shm flake |
| 23811 | 8 | same | 7 of 8 phases clean; dev2 r2 read failed |
| 23812 | 12 | dev2 vs dev3, `SETTLE=120` durable-bytes probe | both clean |
| 23813 | 12 | dev3 alone, `SETTLE=420` convergence probe | clean; settled *lower* than 23812's 120 s |
| 23814 | 12 | dev3 `num_replicas` 1 vs 0, `SETTLE=120` | clean; replication off is free and removes only 188 MiB/node |
