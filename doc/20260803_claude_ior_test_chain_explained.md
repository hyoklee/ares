# What "chain" means in `20260803_claude_ior_test_results.md`

"Chain" is the term the branch itself uses — `context-runtime/config/clio_default.yaml`
on `886-blob-replicas` has a section headed *"The interposition chain (issue #886)"*.
It means a stack of chimods that each speak the **same** CTE core Put/Get task
interface and are linked by `next_pool_id`, so each one is transparent to its
caller: point a client at the top pool and it thinks it is talking to the CTE core.

In the report, "the chain" is concretely these four pools, per node:

```
clio_cte_filesystem  560.0   clio-fs: paths → tags, offsets → 1 MiB page blobs
        │ next_pool_id
        ▼
clio_cte_cache       563.0   LOCALITY    — raw node-local copy, async write-through
        │ next_pool_id
        ▼
clio_cte_replication 561.0   RELIABILITY — N persistent replicas on the disk tier
        │ next_pool_id
        ▼
clio_cte_core        512.0   the actual blob store + tiers (DRAM, NVMe)
```

A write from IOR goes FUSE → 560 → 563 → 561 → 512 and lands on a tier; on the
way back up, the cache layer keeps a raw local copy and the replication layer
schedules the durable copy. A read is served by the cache copy if present,
otherwise it falls through the same hops to the blob's owner node.

There is a fifth optional link, `clio_cte_compressor` at 562.0 (encoding layer,
sits between cache and replication), which this build does not have —
`CLIO_CTE_ENABLE_COMPRESS=OFF`.

## How the term is used in the results tables

| label | meaning |
| --- | --- |
| **full chain** | all four pools above, `num_replicas: 1` |
| **chain, 0 replicas** | same four pools, same hops, but replication asked for zero copies — isolates the cost of *being in the path* from the cost of *writing replicas* |
| **no chain** | `clio_cte_filesystem` points straight at `512.0`; cache and replication are not composed at all — the baseline the chain is measured against |

The single config line that decides which of these you get is `next_pool_id` on
the filesystem pool (`563.0` vs `512.0`), which is why the report calls it
"the line that makes the chain real."
