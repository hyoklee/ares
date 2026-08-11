# IOR over clio-fs on the updated `dev` — regression at 12 nodes

Run on **ares**, 2026-08-11. Follows
[`20260803_claude_ior_test_results.md`](20260803_claude_ior_test_results.md).

Builds compared (all built identically: Release, CTE + filesystem + replication
+ cache + FUSE adapter, compressor off, spack libfuse 3.16.2 headers):

| tag | revision | what it is |
| --- | --- | --- |
| `v886` | `a7a0fea3` | `886-blob-replicas`, the original chain measurement |
| `dev1` | `2992817c` | `dev` as measured on 08-04 (chain + the first perf pass) |
| `dev2` | `66353084` | **`dev` today** — v2.2.0, CFS refactor, indexer split out of the core, leader-election/failover (#856), `AggregateOut` contract work (#915), placement against real free space |

Method is unchanged and non-negotiable on this cluster: **all comparisons are
phases inside one allocation**, same nodes, minutes apart, each build measured
twice per job (`runs/run_multi_paired.sh`). Absolute numbers move by 2x between
jobs on identical software, so only within-job ratios are reported as results.

## Headline

* **12-node writes regress, consistently: -14%, -15%, -20%** against dev1 in
  three independent allocations. This is the solid result.
* **12-node reads are mixed** (-0.5%, -16%, -27% in those same three jobs), so
  the read side is not a claim I can stand behind either way.
* **8 nodes: no regression.** Writes are within noise (-1% to -5%); reads are
  neutral to better (-1%, +23%).
* **dev2 emits a flood of runtime errors that dev1 does not**: ~3,000 (8n) to
  ~5,000 (12n) `[AggregateOut CONTRACT VIOLATION]` lines *per node per run*, on
  the CTE core / replication / cache pools. The guard is new in dev2 (#915) and
  it is firing on the chain's own tasks.

## Numbers

All values MiB/s aggregate, IOR 3.3.0 `-a POSIX -w -r -F -e -t 1m -b 64m -s 1
-i 1`, 24 ranks/node, file-per-process on each node's local clio-fs mount.

### 8 nodes / 192 ranks

| job | phase | build | write | read |
| --- | --- | --- | --- | --- |
| 23503 | r1 | v886 | 3447.69 | 3056.86 |
| 23503 | r2 | v886 | 3505.43 | 3073.34 |
| 23503 | r1 | dev1 | 3635.18 | 6371.91 |
| 23503 | r2 | dev1 | 3622.14 | 6534.47 |
| 23503 | r1 | **dev2** | 3450.84 | **7924.12** |
| 23505 | r1 | dev1 | 3548.18 | 7407.64 |
| 23505 | r2 | **dev2** | 3514.93 | 7317.57 |
| 23507 | r1 | dev1 | 3496.63 | 6505.67 |

Within-job deltas (dev2 vs dev1): job 23503 write **-4.9%**, read **+22.8%**;
job 23505 write **-0.9%**, read **-1.2%**. Means across jobs: dev1 3575/6705,
dev2 3483/7621. Against the original chain baseline, both dev builds still read
~2.2x faster than `v886` (3065 MiB/s).

### 12 nodes / 288 ranks

| job | phase | build | write | read |
| --- | --- | --- | --- | --- |
| 23504 | r1 | v886 | 2073.01 | 1625.88 |
| 23504 | r1 | dev1 | 2463.43 | 3408.21 |
| 23504 | r2 | dev1 | 2484.73 | 3727.37 |
| 23504 | r2 | **dev2** | 2099.34 | 2984.05 |
| 23506 | r1 | dev1 | 2444.71 | 3443.33 |
| 23506 | r2 | dev1 | 2465.36 | 3577.07 |
| 23506 | r1 | **dev2** | 1930.57 | 2591.23 |
| 23506 | r2 | **dev2** | 1983.80 | 2519.52 |
| 23508 | r1 | dev1 | 1894.88 | 2638.40 |
| 23510 | r1 | dev1 | 2534.82 | 3557.82 |
| 23510 | r2 | dev1 | 2669.71 | 3515.69 |
| 23510 | r2 | **dev2** | 2237.89 | 3518.20 |

Within-job dev2-vs-dev1 deltas, one row per allocation:

| job | phases used | write | read |
| --- | --- | --- | --- |
| 23504 | dev1 x2, dev2 x1 | **-15.1%** | -16.4% |
| 23506 | dev1 x2, dev2 x2 (all four completed) | **-20.3%** | -27.2% |
| 23510 | dev1 x2, dev2 x1 | **-14.0%** | -0.5% |

Job **23506** is the cleanest — all four phases completed on the same 12 nodes:

| build | write | read |
| --- | --- | --- |
| dev1 | 2455.0 | 3510.2 |
| **dev2** | **1957.2** | **2555.4** |
| **delta** | **-20.3%** | **-27.2%** |

The write regression reproduces in every allocation; the read delta does not
(-27% in 23506, essentially zero in 23510), so treat "12-node reads regressed" as
unproven. dev2 is still well ahead of the original `v886` baseline on reads
(2555–3518 vs 1626), so nothing here undoes the 08-04 gains — this is a
regression against the *previous dev*, not against the pre-perf-work state.

## The error storm (new in dev2)

Every dev2 phase logs, per node:

```
ipc/ipc_run2run.cc:674 ERROR [AggregateOut CONTRACT VIOLATION]
  pool=PoolId(major:561, minor:0) method=23: the origin's task_id_ changed
  during aggregation (... net_key:0  ->  ... net_key:140131025614256).
  This task's AggregateOut is copying the whole replica ... See issue #915.
  Restoring the origin's identity to avoid corruption.
```

Counts on a single node in a single run: **2951 (8n)**, **4957 (12n)**. Zero in
dev1 and v886 — the guard itself is new. Distribution by pool/method on one
12-node node:

| pool | method | count |
| --- | --- | --- |
| 512.0 (CTE core) | 18 | 1812 |
| 561.0 (replication) | 23 | 1550 |
| 561.0 (replication) | 15 | 1414 |
| 561.0 (replication) | 16 | 142 |
| 563.0 (cache) | 14 | 39 |

Two things this says:

1. **The #915 defect is live on the chain's hot path.** The guard's own comment
   says ~26 `AggregateOut` implementations delegate to `Copy()` and are "currently
   only routed single-replica"; on this workload the CTE core, replication and
   cache tasks *are* routed multi-replica, so the origin's identity is being
   clobbered and repaired thousands of times per node per run. The repair keeps
   it from corrupting memory, but these implementations need fixing.
2. **It may not be free.** Each violation formats and writes a multi-line error
   record while the I/O is in flight, and in this harness the runtime log lives on
   NFS, so that logging sits on the measured path. A dedicated A/B (same dev2
   build, log on NFS vs on node-local NVMe, job 23509) was run to quantify it but
   produced **no usable pair** — every node-local-log phase died on a stale FUSE
   mountpoint left by the preceding phase. So this remains a hypothesis, not a
   measurement. It is the first thing to check when someone picks this up.

The counts scale with node count (2951 → 4957 going 8 → 12 nodes), which lines up
with the write regression showing at 12 nodes and not at 8.

## Other candidates for the 12-node regression

Not isolated, listed for whoever picks this up — all landed between `2992817c`
and `66353084` and all touch the cross-node path that 12 nodes exercises harder
than 8:

* `9ed79ace` place blobs against real free space, not the last stats tick
* `e2615fc4` re-check blob liveness under the read pin, not before it
* `01b36164` one persistent task-stat model per pool, in a real static container
* `#856` leader election / failover, `10066431` create pools across LIVE nodes only
* `ac2c3627` / `e2050b6b` filesystem logic moved out of the POSIX adapter into the
  chimod client (the clio-fs path itself)

A useful next step would be bisecting these across the ~90 commits between the
two revisions with the same paired harness at 12 nodes — writes are the stable
signal, so a 3-4 step bisect on the write number should land it.

## Harness notes

* Several phases were lost to `shm_open failed: No such file or directory
  (chi_main_segment_hyoklee_9413)` in the FUSE clients — the runtime's shm
  disappearing between phases. Holding an idle ssh session per node for the whole
  job (systemd-logind `RemoveIPC` fires when the user's last session on a node
  closes) reduced but did not eliminate it. Failed phases are shown as missing
  rows above; no failed phase contributed a number.
* Data correctness was checked separately: a 64 MiB byte-compare round trip
  through a dev2 mount passes (`runs/smoke_local.sh`). IOR without `-R` does not
  verify content, so the throughput runs say nothing about correctness either way.

## Reproduce

```
# builds
/mnt/common/hyoklee/clio886/install   v886  (a7a0fea3)
/mnt/common/hyoklee/cliodev/install   dev1  (2992817c)
/mnt/common/hyoklee/cliodev2/install  dev2  (66353084, worktree on branch dev)

cd /mnt/common/hyoklee/clio886/runs
sbatch -N12 -p compute -t 01:00:00 \
  --export=ALL,BUILDS="dev1:/mnt/common/hyoklee/cliodev/install dev2:/mnt/common/hyoklee/cliodev2/install",ROUNDS=2,CHAIN=chain \
  ./run_multi_paired.sh
```

Artifacts (config used, per-node daemon/FUSE logs, raw IOR output) in
`runs/run_<build>_chain_<N>n_<jobid>_r<round>/`.
