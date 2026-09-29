# Terra Fusion 5-sensor discrepancy, part 9: the CAE tests that stored nothing

Run on **ares**, 2026-09-28. Follows
[part 8](20260918_claude_terra_fusion_discrepancy_08_cae_telemetry.md), which
added `CLIO_CAE_TELEMETRY` and made assimilation failures reach the `clio_cae`
exit status. Pushing that work as a PR turned up a second instance of the same
class of defect — a success signal that was never connected to the thing it
claimed to report — this time in clio-core's own test suite.

## Headline

* **Five CAE unit tests were passing on macOS and Windows while storing no
  data.** Every `PutBlob` returned **rc 11** (`available_targets` empty) and the
  test asserted on a field the failure never reached.
* **Cause: the fixture's CTE pool has no storage unless ambient config supplies
  it.** The macOS runner log says so in one line —
  `Create Warning: No storage devices configured`.
* **Fix: the fixture registers its own 256 MB RAM target**, so it depends on
  neither a config file nor host DRAM. **Confirmed on both runners**, see below.
* **This is the same bug shape as part 8's.** There, `clio_cae` read
  `GetReturnCode()` while `ParseOmni` wrote `result_code_`. Here, the *test*
  read `GetReturnCode()` while `ParseOmni` wrote `result_code_`. Fixing the
  client exposed the test.

## How it surfaced

Part 8's change made `ParseOmni` mirror its failure onto the task-framework
code:

```cpp
task->result_code_ = result;
task->error_message_ = std::string("Assimilator failed");
task->SetReturnCode(static_cast<clio::run::u32>(result));   // <- added
```

That one line turned this assertion, which had never been able to fail, into a
live one:

```cpp
REQUIRE(task->GetReturnCode() == 0);   // test_cae_comprehensive.cc:278
```

Linux stayed green. macOS-15 and Windows-2025 went red on
`cae_parseomni_binary`, `cae_parseomni_binaryrange`, `cae_parseomni_multi`,
`cae_verifybinarydata` and `cae_comprehensive_force_net`.

## The runner log names the cause

```
core_runtime.cc:742  WARNING  Create Warning: No storage devices configured
binary_file_assimilator.cc:191  ERROR  BinaryFileAssimilator: Failed to store
    description for tag 'cae_binary_test', return_code: 11
```

`rc=11` is raised in `core_runtime.cc:6716-6734`:

```cpp
available_targets = target_list_;
if (available_targets.empty()) {
  if (shortfall != nullptr) { *shortfall = additional_size; }
  error_code = 1;
  CLIO_CO_RETURN;
}
```

So the CTE had registered no storage targets at all, and the very first write of
every assimilator failed.

## Why the pool had no storage

The fixture creates the CTE pool with a **default-constructed `CreateParams`**:

```cpp
clio::cte::core::CreateParams cte_params;
auto cte_create = cte_client->AsyncCreate(
    clio::run::PoolQuery::Dynamic(), kCtePoolName, kCtePoolId, cte_params);
```

That object carries no storage, and cannot:

| step | what happens |
| --- | --- |
| client → wire | `CreateParams::config_` is **not serialized**; only four scalars are (`core_tasks.h:168-181`) |
| server fill | `CreateParams::LoadConfig` reads `pool_config.config_`, populated **only for a pool declared in a `compose:` section** |
| `Runtime::Create` | `storage_devices_ = config_.storage_.devices_` — empty → the warning at line 742, no `RegisterTarget` calls |

So storage comes down to whatever server config is ambient. And these five tests
are precisely the ones whose CTest `ENVIRONMENT` block **omits
`CLIO_SERVER_CONF`**:

```cmake
# context-assimilation-engine/test/unit/CMakeLists.txt:353
ENVIRONMENT "LD_LIBRARY_PATH=...;CLIO_BIND_ADDR=127.0.0.1;CLIO_PORT=10500"
```

Their siblings at lines 82, 120, 526 and 901 all set
`CLIO_SERVER_CONF=${CMAKE_CURRENT_SOURCE_DIR}/clio_config.yaml`, which composes
`clio_cte_core` with a `ram::cte_ram_tier1` tier. These do not.

**That is the whole platform split.** With no `CLIO_SERVER_CONF`,
`ConfigManager::GetConfigPath` falls back to `~/.clio/clio.yaml`; the container
images seed exactly that file from `context-runtime/config/clio_default.yaml`
(`jarvis_clio_core/.../clio_runtime/build.sh:139-143`), so Linux gets the
default tiers. The macOS and Windows runners have no such file and get nothing.
Nothing in the failure is Apple- or Windows-specific.

## The fix

The fixture now registers its own target before any test runs — the same remedy
`test_putblob_priv.cc::RegisterRamTarget` already applies to the identical
symptom, where the comment reads *"fails with rc 11 (no targets)"*:

```cpp
static bool RegisterRamTarget() {
  auto *cte = CLIO_CTE_CLIENT;
  clio::run::PoolId bdev_pool_id(918, 0);
  clio::run::bdev::Client bdev_client(bdev_pool_id);
  auto create = bdev_client.AsyncCreate(clio::run::PoolQuery::Dynamic(),
                                        kTargetName, bdev_pool_id,
                                        clio::run::bdev::BdevType::kRam,
                                        kRamTargetBytes);
  create.Wait();
  auto reg = cte->AsyncRegisterTarget(kTargetName,
                                      clio::run::bdev::BdevType::kRam,
                                      kRamTargetBytes,
                                      clio::run::PoolQuery::Local(),
                                      bdev_pool_id);
  reg.Wait();
  return reg->GetReturnCode() == 0;
}
```

256 MB of RAM against a largest test file of 1 KB. Sized to match
`test_putblob_priv` rather than to any host's DRAM, so it registers on a 14 GB
macOS runner as readily as in a container. The `SetReturnCode()` mirror, which
had been deferred in `22183d83` so it would not land with the failure hidden, is
restored in the same commit.

## Confirmation

PR #5 at `7d1e68bb`, all 21 non-skipped checks green:

| runner | result | the five tests |
| --- | --- | --- |
| `build-test (macos-15)` | 100% of 283 | `cae_parseomni_binary` 2.05 s, `binaryrange` 2.12 s, `multi` 2.65 s, `verifybinarydata` 2.05 s |
| `build-test (windows-2025)` | 100% of 242 | the same four plus `cae_comprehensive_force_net` 1.63 s |
| `icx (windows-2025)` | 0 failed of 241 | all five |

`cae_comprehensive_force_net` is Windows-only here because
`clio_add_force_net_test()` is a no-op on Apple.

The decisive evidence is what the logs no longer contain. Grepping both for
`No storage devices configured` and `return_code: 11` returns nothing; those
lines appeared on every one of these tests in the previous macOS run. And
because the `SetReturnCode()` mirror is restored in the same commit, the
assertion is live — so the tests pass *because* the data lands, not in spite of
it never landing. The runtimes agree: `cae_parseomni_binary` took **1.36 s**
when it was failing fast on an empty target list and **2.05 s** now that it
does the writes.

## What this means for the Terra Fusion pipeline

Part 8 established that `clio_cae` now reports assimilation failure through its
exit status. Part 9 adds the reason not to stop there:

* **A green suite was not evidence the CAE stores anything.** On two of three
  platforms it had been storing nothing, indefinitely, with every test passing.
  The part 8 practice of confirming with `cte_search` after the async settle,
  rather than trusting `rc=0`, is the right default and is not paranoia.
* **`Tasks scheduled: N` counts scheduling, not landing.** Both defects sit
  downstream of it.
* **Check the runtime log for `No storage devices configured`** before timing
  anything. An ingest against a target-less CTE fails fast and cheap, which is
  exactly what makes it easy to mistake for a fast ingest. The measured CAE
  numbers in parts 7-8 were taken against a runtime composed from
  `clio_default.yaml`, whose tiers register, and the telemetry
  `datasets_filtered` counts there are non-zero — so those timings are not
  affected by this.

## A pattern worth naming

Three defects in this series now share one shape: **a check that reads a
different field from the one the failure is written to.**

| where | writes failure to | check reads | result |
| --- | --- | --- | --- |
| `clio_cae` client (part 8) | `result_code_` | `GetReturnCode()` | exit 0 on a failed ingest |
| `test_cae_comprehensive` (part 9) | `result_code_` | `GetReturnCode()` | green tests that stored nothing |
| CAE sweep harness (part 8) | — | `/dev/shm` for a memfd | false "runtime ready" |

In each case the check looked sufficient and tested the wrong thing, and in each
case the symptom was silence rather than an error.

## Caveats

* **Linux could not verify the fix; CI did.** This host has an ambient
  `~/.clio/clio.yaml`, so it registers targets either way. The 20 local ctest
  entries passing here showed only that the configured path does not regress.
  The bare-config path was verified on the runners, as recorded above.
* `CLIO_TEST_MODE=1` suppresses the `~/.clio/clio.yaml` fallback and looked like
  a local reproduction, but it was not — the failure it produced was
  `ChiMod 'clio_cte_core' not found` from an incomplete build, a different bug.
  The diagnosis rests on the macOS runner log, not on a local repro.
* Only the five reported tests were traced. Other suites that omit
  `CLIO_SERVER_CONF` may have the same latent gap; they were not audited.
* Whether the CTest `ENVIRONMENT` omission at `CMakeLists.txt:353` is deliberate
  was not established. Registering the target in the fixture is hermetic either
  way, which is why it was preferred over adding `CLIO_SERVER_CONF` there.

## Reproducing

```sh
# the diagnosis, from the CI log rather than locally
gh run view <macos-run-id> --log-failed \
  | grep -E "No storage devices|return_code: 11"

# the local regression check (configured path only)
cmake -S ~/src/hyoklee/core -B build-cae-ci -DBUILD_TESTING=ON \
      -DCLIO_CORE_ENABLE_TESTS=ON -DCLIO_CORE_ENABLE_CAE=ON
cmake --build build-cae-ci -j
LD_LIBRARY_PATH=$PWD/build-cae-ci/bin \
  ./build-cae-ci/bin/test_cae_comprehensive "[cae]"
```

Source: `context-assimilation-engine/test/unit/test_cae_comprehensive.cc` and
`context-assimilation-engine/core/src/core_runtime.cc` on branch
`hyoklee/cae-telemetry` (hyoklee/core PR #5).
