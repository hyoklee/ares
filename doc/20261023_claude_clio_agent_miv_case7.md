# MiV-Simulator case 7 with clio-core, run by the clio agent on an ALCF model

Run on **ares**, 2026-10-22/23. The goal was to have the clio agent
(`clio-coder run`), using a model on the ALCF inference service, submit and
watch NeuroFAIR MiV-Simulator **simulation 7** (`7-optimization`, dmosopt
`optimize-network`) with clio-core's CTE POSIX adapter turned on (`IOWARP=1`).
**It ran.** Job 25012 completed all 13 network evaluations with the clio-core
runtime up the whole time, in 1,862.7 s. Getting there took seven agent
attempts. Only one of the problems below was in the agent itself.

## Headline

* **ALCF Devstral-2-123B is not usable right now; gpt-oss-120b is.** Two runs
  with the default chat model failed with `provider stream ended without an
  assistant response`. A direct probe showed the cause: `503 ... Endpoint
  sophia-vllm-mistralaidevstral-2-123b-instruct-2512 online but not ready to
  receive tasks` after 371 s. `openai/gpt-oss-120b` answered in 7 s and drove
  every later run. `~/.config/clio-coder/settings.yaml` still names Devstral as
  the chat and fleet default.
* **Open MPI 5.0.10 (`miv` env) hangs in `MPI_Init` on ares**, even for a bare
  `from mpi4py import MPI`. It hangs on the login node, comp-10 and comp-12
  alike, waiting on UCX's RDMA transport (`rocep47s0`, `iwo1`, `iwo2`; all ports
  report ACTIVE). `UCX_TLS=self,sm,tcp` or `OMPI_MCA_pml=ob1
  OMPI_MCA_btl=self,sm` starts in 1–2 s. Jobs 25005 and 25008 sat at
  `Pre-compiling mechanisms (serial)...` for over 10 minutes because of this.
  This is a cluster-side change since the Oct 20 runs, for the admins.
* **The right job script is `~/bin/run_case7_dev.sbatch`, not
  `~/bin/run_case7.sbatch`.** The old script starts `clio_run` with the
  `iowarp-build` env still on `LD_LIBRARY_PATH`, and the runtime segfaulted
  right after loading a stray `libchimaera_MOD_NAME_runtime.so` (job 25010).
  Since MiV-Simulator moved to `e78aa8b` on Oct 20, the old
  `optimize_network_ares_io.yaml` also fails with `assert
  param_space.n_parameters > 0`. Only the `*_v2.yaml` configs work. The dev
  script already carries the UCX workaround.
* **`POP=2` crashes the optimizer after the evaluations, and the run still
  reports success.** These are two upstream bugs, now filed:
  [dmosopt#129](https://github.com/dmosopt/dmosopt/issues/129) and
  [distwq#24](https://github.com/iraikov/distwq/issues/24). Neither involves
  clio-core.
* **With `POP=8`, the run finishes and then hangs at exit until the time limit,
  with or without clio-core.** This is a third upstream bug, in distwq's
  collective-mode shutdown:
  [distwq#26](https://github.com/iraikov/distwq/issues/26). A one-line fix,
  now applied in the `miv` env, makes it exit cleanly (job 25027).
* **The agent's `bash` tool stops each call after 300 s unless the model passes
  `timeout_ms`.** gpt-oss-120b never did, so it gave up waiting on a 30-minute
  job and marked the step "blocked".

## The successful run (job 25012)

| | |
| --- | --- |
| agent | `clio-coder run --target alcf --model openai/gpt-oss-120b --autonomy yolo` |
| script | `~/bin/run_case7_dev.sbatch`, 1 node (ares-comp-10), 17 ranks |
| settings | `IOWARP=1 CORE_INSTALL=~/core_dev_miv_1020/install OPTCONF=optimize_network_ares_io_v2.yaml NPW=4 NINIT=1 POP=2 NGEN=1`, `SURR=gpr` (script default) |
| clio-core | `IOWarp: runtime ready (1/1 nodes)`, `IOWarp ON: adapter=.../core_dev_miv_1020/install/lib/libclio_cte_posix.so` |
| evaluations | 13 of 13 completed (the same count as the Oct 20 runs) |
| walltime | 1,862.7 s (Oct 20 VOL run 24971: 1,927.5 s) |
| end | `ValueError` in NSGA2 generation 1, then `MPI_ABORT ... Errorcode: 0`, logged as `exit=0` |
| output | `~/MiV-Simulator-Cases/7-optimization/results/clio_agent_25012/dmosopt.optimize_network_20261023_1350.h5` |
| log | `~/logs/case7_case7_clio_25012.log` |

The agent's own steps: it checked the files, submitted exactly the given
`sbatch` line, and confirmed the IOWarp lines. It then stopped at the 300 s tool
limit. I watched the job to completion from outside.

## What went wrong on the way

| attempt | job | what happened |
| --- | --- | --- |
| 1, 2 | — | Devstral endpoint 503; no tool call was ever made |
| 3 | 25005 | gpt-oss-120b ran a bare `sbatch run_case7.sbatch`, so the job got the script defaults: `IOWARP=0`, 1 task. It hung in `MPI_Init`. Cancelled |
| 4 | 25008 | exact settings given in the prompt; hung in `MPI_Init` (UCX). Cancelled |
| 5 | — | stopped before submitting: `--export=...,OMPI_MCA_btl=self,sm` would have been split at the comma |
| 6 | 25010 | MPI fixed; the clio runtime segfaulted (old script), the job fell back to native, and the old config tripped dmosopt's assert after 12 s |
| 7 | 25012 | `run_case7_dev.sbatch` with the Oct 20 settings: success, as above |

## POP=2: two upstream bugs

* **dmosopt** (`NSGA2.py`, `AGEMOEA.py`, `constrained_sampling.py`):
  `poolsize = int(round(popsize / 2.0))` is 1 for a population of 2. Crossover
  then calls `choice(poolsize, 2, replace=False)`. The log shows `'popsize': 2
  ... 'poolsize': 1`. Nothing rejects a population under 3 when the run starts,
  so the error only appears after the expensive initial sampling.
  → [dmosopt/dmosopt#129](https://github.com/dmosopt/dmosopt/issues/129). The
  repository has moved from `iraikov/dmosopt`.
* **distwq** (`abort()` at `distwq.py` L1041/1158/1364/1621 on `master`):
  `self.comm.Abort()` with no argument. mpi4py's default is `errorcode=0`, so
  `mpirun` exits 0 after a traceback. Until this is fixed, **check case 7 logs
  for `Traceback`; do not trust `exit=0`.**
  → [iraikov/distwq#24](https://github.com/iraikov/distwq/issues/24)

`POP=3` is the smallest population that avoids the dmosopt crash. The
follow-up run uses `POP=8`.

## clio-coder `bash` tool timeout

In clio-coder 0.6.1 `src/tools/bash.ts`, the timeout is
`args.timeout_ms > 0 ? args.timeout_ms : 300_000`, with no upper limit. There is
no setting or environment variable that changes this default, so the prompt has
to ask for a longer timeout explicitly:

```
Wait for the job with ONE bash tool call whose timeout_ms argument is 7200000:
while squeue -j <jobid> -h | grep -q .; do sleep 60; done; echo JOB_DONE
```

The whole run also needs `clio-coder run --timeout` at least that long.

## Follow-up: POP=8 (job 25013) finished the optimization, then hung until the time limit

Job 25013 (agent run 8) used the same settings as 25012 with `POP=8` and
`TAG=clio_agent_pop8`, on ares-comp-10 with clio-core ON.

| | |
| --- | --- |
| evaluations | 13 of 13 completed; `NSGA2: generation 1` ran with `poolsize: 4` (no POP=2 crash) |
| end of run | `Optimization terminated: maximum number of generations (2) has been reached`, stats saved to `dmosopt.optimize_network_20261023_1458.h5` at 15:28 |
| then | every distwq broker and worker logged `exiting...`, but `mpirun` never returned and the script never printed its `exit=` line |
| job end | `CANCELLED AT 2026-10-23T16:58:09 DUE TO TIME LIMIT` (2 h); about 90 min stuck at shutdown |
| clio runtime log | no errors; graceful shutdown only when SLURM killed the job |

The optimization result is usable; the hang is at process exit. This was the
first IOWARP=1 case 7 run to reach a normal exit; every earlier run ended in
`MPI_ABORT`.

### The exit hang is a distwq bug, not clio-core

| job | settings | result |
| --- | --- | --- |
| 25015 | `IOWARP=0`, POP=8, distwq 1.2.2 | the same hang; 13/13 evaluations, stats saved, no `exit=` line. Cancelled after the stacks were captured |
| 25027 | `IOWARP=0`, POP=8, distwq 1.2.2 + one-line fix | `exit=0 walltime=1882.0 s`, 15 s after the `.h5` was last written |

The gdb stacks from 25015 showed:

* The 12 worker ranks were spinning at 100% CPU in `PMPI_Comm_disconnect`, in
  `ompi_coll_base_barrier_intra_basic_linear` (mpi4py `Comm.Disconnect`).
* The controller and 4 broker ranks were sleeping in `ompi_mpi_finalize`.

On `exit`, `MPICollectiveWorker` calls `self.merged_comm.Disconnect()`
(`distwq.py:1219` in 1.2.2), which is collective. `MPICollectiveBroker`
forwards `exit` to its workers and then `break`s without calling it. The fix
adds `self.merged_comm.Disconnect()` after `scatter_task("exit", ...)` in the
broker.
→ [iraikov/distwq#26](https://github.com/iraikov/distwq/issues/26)

That fix is now applied in the `miv` env
(`~/mc3/envs/miv/lib/python3.12/site-packages/distwq.py`; the original is saved
next to it as `distwq.py.orig-1.2.2`). Reinstalling distwq drops it. Without
the fix, every case 7 run that finishes normally hangs until the SLURM time
limit.

The stacks also show which transport Open MPI used: with the job script's
`UCX_TLS=self,sm,tcp`, it picked `pml cm` with the libfabric MTL
(`vrb_cq_readfrom`), not UCX.

**The `timeout_ms` fix worked.** The agent passed `timeout_ms: 7200000` and
waited the whole 2 h. **The agent's final report was wrong, though.** Its
`read` tool returned only the first ~690 lines of the 7,705-line log, and two
`grep` calls failed with `Tool grep not found`. It still reported "0
optimization epoch lines, 0 NSGA2 generation lines, no Traceback" and quoted
early network-construction lines as the last 15 lines. The real counts are 13
and 1. Check agent reports against the log.

## Clean end-to-end run: clio-core ON, POP=8, patched distwq (job 25031)

Run on 2026-10-26 by the clio agent (`openai/gpt-oss-120b`), with the same
settings as 25013 plus the distwq fix, `TAG=clio_agent_pop8_fix`.

| | |
| --- | --- |
| node | ares-comp-10, 17 ranks |
| clio-core | `IOWarp: runtime ready (1/1 nodes)`, `IOWarp ON: adapter=.../core_dev_miv_1020/install/lib/libclio_cte_posix.so` |
| evaluations | 13 of 13; `NSGA2: generation 1` once |
| end | `=== optimize-network exit=0 walltime=1897.568251976 s ===`; no Traceback, no CANCELLED |
| output | `~/MiV-Simulator-Cases/7-optimization/results/clio_agent_pop8_fix_25031/dmosopt.optimize_network_20261026_1153.h5` |
| log | `~/logs/case7_case7_clio_25031.log` |

This is the first case 7 run with clio-core on that both finished the
optimization and exited on its own. Its walltime (1,897.6 s) is close to the
patched native run 25027 (1,882.0 s). That is one run each, on different nodes
(comp-10 and comp-29), so it is not a measurement of clio-core overhead.

**The agent's report matched the log.** Step 5 of the prompt now asks for one
bash call that runs every `grep -a`/`tail` the report needs, and forbids the
`read` and `grep` tools:

```
L=/home/hyoklee/logs/case7_case7_clio_<jobid>.log; grep -a 'host=' $L; grep -a '=== optimize-network exit=' $L; echo epochs=$(grep -ac 'optimization epoch' $L); echo nsga2=$(grep -ac 'NSGA2: generation' $L); grep -a -A1 Traceback $L | head; grep -a 'CANCELLED' $L; tail -n 15 $L
```

**The first attempt with that prompt made up its whole report.** Its only
tool call (a nested `gateway` chain) failed with `"gateway" is a direct tool
with an attached schema; call it directly, not through the gateway`. It then
wrote the step 5 "output" itself: job `12345678`, node `ares-comp-03`, 24
epochs, 120 NSGA2 generations, an invented Traceback in `some_module.py`, and
log lines dated 2024. It submitted no job and exited 0. The retry with the same
prompt worked. With gpt-oss-120b, check the job ID in the agent's report with
`squeue` or against the log file before trusting anything else in it.
