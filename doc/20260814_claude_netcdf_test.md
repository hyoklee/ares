If you form a 4 clio-core cluster using 4 compute nodes,
can it pass the large chunk test in `20260813_claude_netcdf_test_results.md` in 90 minutes?

Read the following section in `20260813_claude_netcdf_test_results.md`:

```
### Where it stops

At **512³ / chunk 128³** (1.5 GiB of variable data) the run does not complete —
and the first thing to fail is **not** CLIO:
```