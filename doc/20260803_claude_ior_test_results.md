# IOR over `clio-fs` at 8 and 12 nodes — branch `886-blob-replicas`

Answer to `20260803_claude_ior_test.md`. Run on **ares**, 2026-08-03.

Branch under test: `origin/886-blob-replicas` @ `a7a0fea3`
("docs(config): chain intro reflects async write-through + coherent reads").

> **Update 2026-08-04:** re-tested against `origin/dev` @ `2992817c`, which now
> carries the #886 chain plus four perf commits written in response to this
> report. Paired A/B result: **reads ~1.9x faster, writes ~+7%**. See
> [Re-test after the dev update](#re-test-after-the-dev-update--2026-08-04) at
> the end — and note that the absolute numbers in the 2026-08-03 tables below are
> **not** comparable with the 08-04 ones (same build re-measured 2x lower a day
> later; that is why the re-test is paired inside one allocation).

## TL;DR

* The full stack **does** run, and the config **does** do something: with
  `clio_cte_cache (563.0) -> clio_cte_replication (561.0) -> clio_cte_core (512.0)`
  composed under `clio_cte_filesystem (560.0)`, the daemon logs
  `filesystem: Create over CTE core pool 563.0` — every clio-fs op is dispatched
  through the cache and replication chimods, and turning one persistent replica
  on adds ~1x the application bytes to each node's durable tier. Data round-trips
  byte-identical.
* 8 nodes / 192 ranks: **3420 MiB/s write, 2942 MiB/s read**.
  12 nodes / 288 ranks: **3815 MiB/s write, 4052 MiB/s read**.
* The same clio-fs with the chain removed (CFS straight onto the core) does
  **5065 / 7636 MiB/s** at 8n and **7191 / 10321 MiB/s** at 12n — so on this
  workload the reliability+locality layers cost roughly **a third of write and
  ~60% of read bandwidth**, and they scale noticeably worse: baseline write
  throughput grows 1.42x from 8n to 12n, the chain only 1.12x.
* Splitting it (`num_replicas: 0`, both chimods still in the path) shows **almost
  all of that is the interposer hops, not the replica writes**: one durable
  replica on top costs ~0% more write at 8 nodes, ~17% at 12.
* Seven things had to be fixed before a single multi-node run completed; six are
  environment/packaging traps that will bite the next person too, one was my own
  driver bug (details in *Getting it to run at all*). None were in the #886 code.

## Configuration actually used

Per node, composed by the daemon itself at startup out of `CLIO_SERVER_CONF`
(`clio::run::Manager::ServerInit` -> default compose), so the pools exist before
any client shows up:

| pool | id | forwards to | key settings |
| --- | --- | --- | --- |
| `clio_bdev` (`ram::chi_default_bdev`) | 301.0 | — | ram, 8 GiB |
| `clio_cte_core` | 512.0 | — | tier1 `ram::cte_ram_tier1` 16 GiB score 1.0; tier2 `/mnt/nvme/hyoklee/clio886/cte_disk_tier.dat` 64 GiB score 0.2 `persistence_level: temporary`; WAL on NVMe; dpe `max_bw`; neighborhood 1 |
| `clio_cte_replication` | 561.0 | 512.0 | `num_replicas: 1`, `cache_score: 1.0`, `replica_score: 0.2` |
| `clio_cte_cache` | 563.0 | 561.0 | `min_score: 0.5` |
| `clio_cte_filesystem` | 560.0 | **563.0** | chain top — this is the line that makes the chain real |

Templates: `/mnt/common/hyoklee/clio886/runs/clio_chain.yaml.tmpl` (and
`clio_nochain.yaml.tmpl`, identical minus the two interposers, CFS pointed at
512.0). The compressor stays out: this build is `CLIO_CTE_ENABLE_COMPRESS=OFF`.

Deviation from `clio_default.yaml` worth knowing about: the default file names
the core pool `cte_main`, while every client create-or-binds by the constant
`clio::cte::core::kCtePoolName == "clio_cte_core"`. `PoolManager::CreatePool`
looks up by *name* first and only then short-circuits on the pool *id*, so with
`cte_main` a client's `CLIO_CTE_CLIENT_INIT` issues a second create that lands
on the id check instead of the name check. It works (verified — see below), but
it is a race waiting to happen on multi-node, exactly as
`jarvis_clio_core/clio_cte/pkg.py` warns. The run configs use the canonical
names.

## Does the chain do anything? (yes — and one measurement that does *not* prove it)

1. **The filesystem chimod's forwarding target is the cache pool.** Daemon log:
   `filesystem: Create over CTE core pool 563.0`, with `clio_cte_cache` created
   at 563.0 over 561.0 and `clio_cte_replication` at 561.0 over 512.0. So every
   clio-fs op is dispatched through cache -> replication -> core. This is the
   definitive check, and it is config-driven: change `next_pool_id` and the log
   line changes with it.
   The FUSE adapter's `CLIO_CFS_CLIENT_INIT` hardcodes
   `params.next_pool_id_ = kCtePoolId` (512.0), but because the daemon already
   composed pool 560.0 the client's create is a get-or-create *by name* and binds
   to the composed pool. **Corollary: if a client ever reaches CFS first
   (ephemeral runtime, or a config without the CFS entry) the filesystem pool is
   created bypassing the whole chain, and nothing in the logs says so.** Worth
   making the client take `next_pool_id` from the composed config.
2. **The layers demonstrably do work**: identical hardware, identical IOR,
   identical tiers — only `next_pool_id` differs — and throughput changes by
   30–60% (numbers below). Whatever else is true, those chimods are executing
   in the data path.
3. **Data is correct through the chain**: 64 MiB and 1.5 GiB round-trips through
   the mount compare byte-identical, and IOR's own read-back verification passes
   at both scales.
4. **The shipped `context-runtime/config/clio_default.yaml` behaves the same**
   (only changes needed: drop the `clio_cae_core` entry, since this build is
   `-DCLIO_CORE_ENABLE_CAE=OFF`, and repoint `${HOME}/.clio`): same
   `Create over CTE core pool 563.0`. The default config as shipped is live, not
   decorative.

### Durable-tier bytes: what they do and don't tell you

The file bdev pre-grows in 1 GiB units, so apparent size proves nothing; `du`
(allocated blocks) is the signal. Measured allocated bytes on each node's own
NVMe/local tier file:

| case | app bytes/node | `num_replicas: 1` | `num_replicas: 0` |
| --- | --- | --- | --- |
| single writer, `dd bs=1M`, 1 node | 1536 MiB | 3073 MiB (2.0x) | 3073 MiB (2.0x) |
| IOR fpp, 24 ranks x 64 MiB, 8 nodes | 1536 MiB | 5.9 GiB (~3.9x) | 4.3 GiB (~2.9x) |
| IOR fpp, 24 ranks x 64 MiB, 12 nodes | 1536 MiB | 6.2 GiB (~4.1x) | — |

Two things follow, and the first one corrects an intuition that is easy to have:

* **Durable bytes are not by themselves evidence of replication.** With replicas
  turned off entirely, 2–2.9x the application bytes still land on the persistent
  tier — the CTE core's own periodic data flush / placement does that,
  independent of the #886 replication chimod. The DRAM tier is not the
  constraint (`RAM bdev ... 17180852224 of 17179869184 bytes mapped`, and only
  ~3 GiB is live).
* **The replication increment itself looks correct**: turning on one persistent
  replica adds ~1.6 GiB per node on the 8-node run, i.e. ~1x the application
  bytes, exactly as `num_replicas: 1` should. It adds *nothing* in the 1-node
  sequential case, which is unexplained and probably worth a look — the same
  config, same file size, differing only in writer concurrency.
* The footprint is **not** a leak that grows with time: after the write finishes
  it settles within ~10 s and then stays flat for at least 90 s idle, and a read
  pass adds nothing.

Reproduce with `runs/replica_growth.sh` (`NUM_REPLICAS=0|1`, `MB=`) and
`runs/replica_growth_read.sh`.

## Performance

IOR 3.3.0, `-a POSIX -w -r -F -e -t 1m -b 64m -s 1 -i 1`, 24 ranks/node,
file-per-process on each node's own clio-fs mount (a shared file is impossible
by construction here: each node's CTE pool and mount are node-local). OpenMPI
5.0.5. Aggregate bandwidth as reported by IOR:

| stack | nodes | ranks | data | write MiB/s | read MiB/s | write/node | read/node |
| --- | --- | --- | --- | --- | --- | --- | --- |
| cache + replication (full chain) | 8 | 192 | 12 GiB | **3420.20** | **2941.94** | 427.5 | 367.7 |
| cache + replication (full chain) | 12 | 288 | 18 GiB | **3814.98** | **4051.81** | 318.0 | 337.7 |
| cache + replication, 0 replicas | 8 | 192 | 12 GiB | 3459.31 | 3553.17 | 432.4 | 444.1 |
| cache + replication, 0 replicas | 12 | 288 | 18 GiB | 4609.45 | 4654.62 | 384.1 | 387.9 |
| clio-fs only (CFS -> core, no chain) | 8 | 192 | 12 GiB | 5065.45 | 7636.19 | 633.2 | 954.5 |
| clio-fs only (CFS -> core, no chain) | 12 | 288 | 18 GiB | 7191.32 | 10321.24 | 599.3 | 860.1 |

A repeat of the 8n full-chain run landed at 3485.26 / 2945.33 MiB/s — within 2%
of 3420.20 / 2941.94, so run-to-run variance is not what these gaps are made of.

Scaling 8n -> 12n (ideal 1.50x):

| stack | write | read |
| --- | --- | --- |
| full chain | 1.12x | 1.38x |
| chain, 0 replicas | 1.33x | 1.31x |
| no chain | 1.42x | 1.35x |

Where the cost sits (8n / 12n, relative to the stack one row above it):

| step | write | read |
| --- | --- | --- |
| inserting cache+replication with 0 replicas | -31.7% / -35.9% | -53.5% / -54.9% |
| then asking for 1 persistent replica | -1.1% / -17.2% | -17.2% / -12.9% |

Reading the numbers:

* **Most of the cost is the interposer hops themselves, not the replica writes.** Turning one
  durable replica on is nearly free for writes at 8 nodes (-1%) and noticeable
  at 12 (-17%) — consistent with the replica write-through being asynchronous
  but its placement work growing with the cluster. Simply *inserting* the two
  chimods between CFS and the core — with no replica writes at all — already
  costs a third of write and more than half of read bandwidth at both scales.
* **The read result inverts the cache layer's purpose on this workload.** Every
  rank reads back exactly the file it just wrote, on the same node, so every read
  should be a cache hit served from the raw local copy — yet it is ~55% slower
  than going straight to the core. That points at per-op overhead in the
  interposer hop rather than at data movement.
* **The chain scales worse than the bare filesystem on writes.** Baseline
  per-node write bandwidth is essentially flat 8n -> 12n (633 -> 599 MiB/s),
  while the full chain drops 26% (427 -> 318 MiB/s) and the 0-replica chain drops
  11% (432 -> 384 MiB/s). With `neighborhood: 1` and hash-spread containers, the
  extra nodes add cross-node work in the chain that the no-chain path never pays.
* Absolute numbers are modest because every byte goes through FUSE: kernel
  round-trip per 1 MiB transfer, `direct_io=0`, attribute caching disabled
  (`attr_timeout=0`) by the adapter. The no-chain column is the right yardstick
  for judging the chain, not raw NVMe or DRAM bandwidth.

## Getting it to run at all

Seven distinct failures stood between "branch builds" and "8 nodes report a
number". Recording them because five are environment traps that are not
discoverable from the code, and the eighth (fd limits) will hit anyone running
clio-fs under real rank counts.

1. **spack libfuse's `fusermount3` is not setuid.** `clio_cte_fuse` links
   libfuse 3.16.2 from spack (ares has no system fuse3 *headers*), and
   `libfuse3.so.3` has the absolute path of *its own* `bin/fusermount3` baked in
   — spack installs it 0755, so the `mount(2)` inside fails and the only symptom
   is `fusermount3: mount failed: Operation not permitted`. Fix used:
   `LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libfuse3.so.3` (the distro 3.10.5 lib,
   same soname, whose `/usr/bin/fusermount3` *is* setuid). This is exactly the
   pairing `fuse_cte_main.cc` documents (3.16 headers, >=3.2 runtime via dlsym).
2. **`clio_cte_fuse` starts its own runtime by default.** It calls
   `CLIO_INIT(kClient, /*default_with_runtime=*/true)`, so with a real daemon
   already on port 9413 the FUSE process brings up an embedded runtime, fails to
   bind, and takes the fresh mount down with it. Needs `CLIO_WITH_RUNTIME=0`
   (which is what `jarvis_clio_core/clio_cte_libfuse/pkg.py` sets).
3. **File-descriptor exhaustion in the FUSE process.** Every libfuse worker
   thread creates a signalfd and attaches the runtime's SHM segments; at 24
   ranks/node the 4096 soft limit is exhausted mid-run
   (`signalfd failed: Too many open files`, `shm_open failed: Too many open
   files`, 1063 occurrences on one node) and the read phase dies in `MPI_ABORT`.
   With `ulimit -n` raised to the hard limit (131072) the same 8n run went from
   2278 MiB/s write + failed read to 3420 + 2942.
4. **conda's `LD_LIBRARY_PATH` breaks prted's remote spawn** — `/usr/bin/ssh` is
   built against OpenSSL 3.0.x, conda ships 3.6.x: `OpenSSL version mismatch`,
   then "PRTE has lost communication with a remote daemon". Fix: `unset
   LD_LIBRARY_PATH` before the module load, plus
   `--prtemca plm_rsh_agent 'env -u LD_LIBRARY_PATH ssh'`.
5. **prterun ships the app name unresolved.** Passing `ior` (on PATH via module)
   fails on every remote node with *"prterun was unable to find the specified
   executable"* — and the message prints the locally-resolved absolute path,
   which makes it look like an NFS visibility problem. It is not: the remote
   prted has no module environment. Pass the absolute path and `-x PATH`.
6. **PRTE core binding vs the allocation.** `--ntasks-per-node=1
   --cpus-per-task=40` + 24 ranks/node makes PRTE refuse to bind
   ("would require binding processes to more cpus than are available").
   `--bind-to none --oversubscribe`.
7. **(my driver's own bug, noted so the script is understood)** `exec > >(tee
   ...)` plus a bare `wait` deadlocks: the process-substitution subshell is a
   child of the script, so `wait` never returns. Every ssh fan-out in the driver
   waits on an explicit pid list instead.

Also worth knowing: detaching the daemon (`nohup setsid`, ssh returns
immediately) lets logind tear down the user session, and `RemoveIPC` then wipes
`/dev/shm` — including the memfd symlink dir clients resolve — out from under the
running daemon. The driver keeps each daemon in the foreground of a persistent
ssh session instead.

## How to reproduce

```
# build (worktree of origin/886-blob-replicas)
/mnt/common/hyoklee/clio886          source
/mnt/common/hyoklee/clio886/build    ninja, Release
/mnt/common/hyoklee/clio886/install  prefix
# cmake: RUNTIME+CTE on; CAE/CEE/tests/benchmarks/python off;
#        CLIO_CTE_ENABLE_{FILESYSTEM,FUSE_ADAPTER,REPLICATION,CACHE}=ON;
#        CLIO_CTE_ENABLE_COMPRESS=OFF; CMAKE_PREFIX_PATH=<spack libfuse>;/home/hyoklee/mc3

cd /mnt/common/hyoklee/clio886/runs
sbatch -N8  -p compute -t 00:30:00 -o $PWD/slurm-%j.out -e $PWD/slurm-%j.err \
       --export=ALL,CHAIN=chain,PPN=24,BLOCK=64m ./run_ior_cliofs.sh
sbatch -N12 -p compute -t 00:30:00 -o $PWD/slurm-%j.out -e $PWD/slurm-%j.err \
       --export=ALL,CHAIN=chain,PPN=24,BLOCK=64m ./run_ior_cliofs.sh
# CHAIN=nochain for the baseline; NUM_REPLICAS=0 for cache-only
./smoke_local.sh          # 1-node functional check of the chain
./smoke_default_yaml.sh   # same, driven by the shipped clio_default.yaml
./replica_growth.sh       # durable-tier footprint over time
```

Artifacts (config actually used, per-node daemon/FUSE logs, raw IOR output,
hostfiles) are under `/mnt/common/hyoklee/clio886/runs/run_<chain>_<N>n_<jobid>/`:

| run | job |
| --- | --- |
| chain 8n | 22674 (repeat: 22680) |
| chain 12n | 22675 |
| no-chain 8n | 22676 |
| no-chain 12n | 22677 |
| cache-only 8n / 12n | 22678 / 22679 |

## Recommendations

1. Make `CLIO_CFS_CLIENT_INIT` (and the CTE core client) take `next_pool_id`
   from the composed config rather than hardcoding `kCtePoolId`. Today a client
   that wins the race silently bypasses cache+replication, and nothing in the
   logs says the chain was skipped.
2. Rename the core pool in `clio_default.yaml` from `cte_main` to
   `clio_cte_core` so the shipped default matches the name clients bind on.
3. Look at durable-tier footprint: with replicas *off* the core still writes
   2–2.9x the application bytes to the persistent tier while the DRAM tier is
   nearly empty. Also explain why the replica increment is ~1x app bytes under 24
   concurrent writers but zero for a single sequential writer.
4. Investigate the read-path cost of the cache interposer: a guaranteed-local
   cache hit is currently ~60% slower than bypassing the chain, which inverts
   the layer's purpose on this workload.
5. Raise the fd soft limit wherever `clio_cte_fuse` is launched (jarvis's
   `clio_cte_libfuse` pkg included), or bound the FUSE thread pool.

---

# Re-test after the dev update — 2026-08-04

`origin/dev` @ `2992817c` vs the previously tested `886-blob-replicas` @ `a7a0fea3`.
Same driver, same config templates, same IOR parameters.

## What landed upstream

`origin/dev` (and `main`) now contain the #886 chain plus four perf commits that
were written in response to this report — `ef3a9d68` cites "the ares IOR findings
(hyoklee/ares 20260803 doc)" by name:

| commit | what it changes |
| --- | --- |
| `ef3a9d68` | writer-local cache copies + probe-free reads (`PoolQuery::Local` hot path) — a put's raw copy used to land at the blob's *hash owner*, so a rank reading its own file always missed locally; every read also paid a size-probe task |
| `2be09359` | probe-free writer-local puts (`REPLICA_UPDATE_ONLY`, speculative create + owner verification) |
| `ddf31e36` | net: separate response lane + recycled SHM staging pool (#892) |
| `2d2d1fd9` | owner-node cache blind spot (dev only, not on the 886 branch) |

`clio_default.yaml` is byte-identical between the two revisions, so the configs
from the first round were reused unchanged.

## Methodology change: the first comparison was invalid

The obvious approach — run the new build and compare against yesterday's table —
gives a wrong answer here. Re-running the **identical old build with identical
parameters** (job 22733, 8n chain) produced **1577 / 1145 MiB/s** against
**3420 / 2942** the day before (jobs 22674/22680). Nothing about the software
changed; the node set shifted by one node and the cluster had other tenants.

So all conclusions below come from **A/B phases inside one allocation**: the same
8 (or 12) nodes run old, new, old, new back-to-back, ~2 minutes apart
(`runs/run_ab_paired.sh`). Cross-job absolute numbers are not comparable on this
cluster; ratios measured within a job are.

## Paired results (full chain, 24 ranks/node, 1 MiB xfer, 64 MiB blocks)

8 nodes / 192 ranks — job 22734:

| phase | build | write MiB/s | read MiB/s |
| --- | --- | --- | --- |
| r1A | old (`a7a0fea3`) | 1517.65 | 1204.61 |
| r1B | **dev (`2992817c`)** | 1516.54 | **2327.51** |
| r2A | old | 1500.83 | 1160.82 |
| r2B | **dev** | **1733.18** | **2284.80** |
| | old mean | 1509.2 | 1182.7 |
| | dev mean | 1624.9 | 2306.2 |
| | **delta** | **+7.7%** | **+95.0%** |

12 nodes / 288 ranks — job 22736:

| phase | build | write MiB/s | read MiB/s |
| --- | --- | --- | --- |
| r1A | old | 2068.14 | 1704.70 |
| r1B | **dev** | 2017.66 | **3188.12** |
| r2A | old | 2184.84 | 1797.08 |
| r2B | **dev** | **2531.58** | **3370.61** |
| | old mean | 2126.5 | 1750.9 |
| | dev mean | 2274.6 | 3279.4 |
| | **delta** | **+7.0%** | **+87.3%** |

A partially-completed earlier 12-node pairing (job 22735) agrees: old 2125/1684
and 1694/1811, dev 2413/3306.

## Verdict

* **Reads: ~1.9x faster** (+95% at 8 nodes, +87% at 12), consistent across all
  four paired measurements. This is the writer-local cache copy landing where the
  reader actually is, which is exactly the defect the first report flagged
  ("a guaranteed-local cache hit is ~60% slower than bypassing the chain").
  Upstream measured 90x per-rank for this path on their 4-node docker harness;
  through FUSE with 24 ranks/node the end-to-end gain is ~2x, so the remaining
  ceiling is the FUSE/kernel round trip, not the chain.
* **Writes: ~+7%**, at both scales — real but modest. The bigger upstream write
  wins (32 -> 76 MB/s/rank) came through `AsyncPutBlobDefer`; the FUSE adapter
  does not use the defer API, so this workload only picks up the probe removal.
  Wiring clio-fs writes onto the defer path looks like the next lever.
* **Scaling 8n -> 12n is unchanged in shape**: dev write 1.40x, read 1.42x vs old
  1.41x / 1.48x (ideal 1.50x). The perf work did not change how the chain scales;
  it changed where a read is served from.
* The absolute numbers in this section are ~2x below the 2026-08-03 table because
  the cluster was busier. Compare within a table, never across.

### One robustness note

In the first 12-node pairing, the fourth phase's daemons started but compose never
finished on any node (`0/12` for the full 90 s window) after three prior
bring-up/tear-down cycles on the same nodes; the daemons were alive and
scheduling. A 25 s settle between phases made it reproducible-free (job 22736 ran
4/4). Worth knowing if anything drives repeated runtime restarts on one node set.

Artifacts: `runs/run_{old,dev}_chain_{8,12}n_2273{4,6}_r{1,2}{A,B}/`, driver
`runs/run_ab_paired.sh`, dev install `/mnt/common/hyoklee/cliodev/install`.
