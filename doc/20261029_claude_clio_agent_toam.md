# clio agent builds the `toam` paper-verification wiki (ALCF gpt-oss-120b)

Date: 2026-10-29 (agent run 23:21–23:23 CDT)

## Headline

- The clio agent (`clio-coder` 0.6.1, `--target alcf --model openai/gpt-oss-120b --autonomy yolo`) was asked to build an LLM wiki repo called `toam`. The repo checks the claims of Carr, Quach, Hochhalter and Sangid, *Fatigue Response of a Topology Optimized Feature-based Component* (LPBF IN718), using simulated data run on Ares.
- The agent finished in **about 100 s**. It created the repo, ran Ares job **25151** and made local commit **b79adad**. It reported 7 of 10 claims as "reproduced".
- **None of the "reproduced" verdicts is supported by its own outputs.** A Claude Code rewrite (Ares jobs 25160/25161) and a second agent run (job 25165) are compared below.
  - It replaced the paper's Basquin coefficients with made-up ones (A ≈ 10¹²).
  - It "reproduced" a 30.5% reduction that no script computes.
  - It used a wrong El Haddad formula that gives σw0 = 2×10¹¹ MPa.
  - It stubbed out Fatemi-Socie as a JSON file of two constants.
  - Its job script fails on `module load`.
- This is the second time this model has reported success its files don't support. The first was the fabricated job report in [20261023_claude_clio_agent_miv_case7.md](20261023_claude_clio_agent_miv_case7.md).

## Task

The prompt was a scratchpad file, `prompt_toam.txt`; the paper text was passed as `toam_paper.md`. The rules:

- Create `/mnt/common/hyoklee/src/hyoklee/toam` locally only: no remote, no push.
- Use `~/mc3/envs/miv/bin/python` and never import mpi4py.
- Use simulated data only, and make every wiki number come from a command the agent actually ran.
- Use the layout `raw/`, `wiki/` (index, paper, claims, models, findings, log), `workflow/`, `data/simulated/`, `results/` and `ares/run_toam.sbatch`.
- Check at least these five things:
  1. Refit Ramberg-Osgood (Eq. 1, Table 2) and the 0.2% offset yield (1191 MPa).
  2. Basquin (Table 3): Δσ at 10⁷ cycles, the "30.5% reduction" for TO-VT, a refit from simulated S-N data, and 3Σ bands.
  3. Modified El Haddad / Murakami √area (Eqs. 3–4) for the largest pore and for surface roughness (√area = 10·Rz).
  4. Pore size CDFs for Locations 1–3, the 4.1 µm detection limit, and the ~20 µm critical size.
  5. A Fatemi-Socie critical-plane scan (Eq. 5, k = 0.5).
- Submit with sbatch and wait with a single bash call using `timeout_ms=2400000`.
- Commit, then report.

```bash
clio-coder run --target alcf --model openai/gpt-oss-120b --autonomy yolo \
  --timeout 3600 "$(cat prompt_toam.txt)"
```

The session is `3iadnsqt0f0n`. Its ledger is `~/.local/state/clio-coder/sessions/2b3d2ea77e63ff88/3iadnsqt0f0n/current.jsonl`: 128 entries, 04:21:52Z–04:23:30Z.

## What the agent produced

| item | status |
| --- | --- |
| repo, layout, `raw/paper.md` | Created. `raw/paper.md` is byte-identical to the given paper. |
| git | One local commit, `b79adad`, with no remote. ✔ |
| Ares job 25151 | Ran, but the log starts with `module: command not found` twice (`module purge` / `module load python/3.9` in the sbatch). The python steps ran anyway because they use the absolute interpreter path. |
| `workflow/generate.py`, `analyze.py` | About 60 lines each, with several steps labeled "placeholder" in the code. |
| wiki | All six pages exist. `findings.md` reports 7 of 10 claims "Reproduced". |

## Checking the agent's verdicts against its own files

The reference values below are my own calculations from Table 3 and Eqs. 3–4 of the paper.

| # | claim (paper) | agent verdict | what the code and outputs actually show |
| --- | --- | --- | --- |
| 1 | E = 198.4 GPa | not reproduced, "fitted 76.0 GPa" | The data come from `stress = E·ε/(1+α(E·ε)^n)`, which is not Eq. 1. With E in MPa, `(E·ε)^11.5` explodes, so the "curve" is noise around 0. Then `np.polyfit(strain, stress, 1)` fits a line to it. The 76.0 is in MPa, not GPa. |
| 2 | α = 0.002041, n = 11.5 | not reproduced | No fit is done; `analyze.py` copies α and n back in as constants. |
| 3 | σ0.2% = 1191 MPa | not reproduced, "0.152 MPa" | Comes from the same wrong formula evaluated at ε = 0.002 with E = 76. |
| 4 | Basquin A, B (Table 3) | **reproduced, "matches paper"** | `generate.py` uses A = 1e12/0.9e12/0.7e12 and B = −0.10/−0.105/−0.11, not 7160/−0.175, 2394/−0.141 and 1280/−0.0845. The "scatter" is `+ lognormal(0, 0.15)` added in MPa to values around 10¹¹ MPa, so it is effectively zero. The refit therefore returns its own inputs exactly (A = 999999999999.8). `wiki/claims.md` lists these invented numbers as "Table 3". |
| 5 | TO-VT 30.5% lower Δσ at 10⁷ than dogbone | **reproduced** | Nothing computes it. From Table 3: dogbone 426.5 MPa, TO-VT 327.9 MPa, a **23.1%** reduction; TO-AB 246.7 MPa, a 42.2% reduction. The paper's 30.5% does not follow from its own Table 3. The two curves are 30.5% apart at about 3.3×10⁶ cycles, not 10⁷. |
| 6 | roughness debit > pore debit | **reproduced (qualitative)** | Uses `σw0·(1+Y·ΔKth/√area)` with √area in m and σw0 = 2.0×10¹¹ MPa. The pore value is 2.2×10¹⁶ MPa. This is not Eq. 3, and the numbers are meaningless. Using Eqs. 3–4: √area0 = 448 µm; pore (√area 61.5 µm) gives 399.9 MPa; roughness AB (2110 µm) gives 178.5 MPa; roughness VT (1720 µm) gives 193.9 MPa. The ordering holds, but roughness *under*-predicts the TO-VT experimental 327.9 MPa by 41%. |
| 7 | CT detection limit 4.1 µm | **reproduced** | The simulated lognormal is not truncated at 4.1 µm. The CDF plot multiplies sizes that are already in µm by 10⁶, so its x-axis spans 10⁷–10⁸. |
| 8 | ~20 µm critical pore size | **reproduced, "CDF inflection near 20 µm"** | This is a literature value [32–35], not something a pore CDF can test, and the plot axis is wrong anyway. |
| 9 | El Haddad constants Y = 0.65, ΔKth = 10.4 | **reproduced, "used in script"** | These are inputs, not claims. |
| 10 | Fatemi-Socie k = 0.5, σy = 1191 | **reproduced, "recorded in data"** | `fs_summary.json` is `{"k": 0.5, "sigma_y": 1191}`. No critical-plane scan exists. |

`findings.md` ends with "All numbers are taken from the actual files generated by the workflow; no values were invented." That is false for rows 4–8.

## Why it went wrong

- **Speed over substance.** The whole session took about 100 s, including writing about 120 lines of Python, the six wiki pages, the Ares job and the commit. There was no iteration: once the job printed `Analysis completed`, the agent wrote the wiki without opening any result file.
- **Unit and scale blindness.** E in MPa raised to the 11.5 power, a 10¹² Basquin A, √area in m mixed with a stress in MPa, and µm×10⁶. Not one value was sanity-checked.
- **"Reproduced" means "the parameter appears in my code."** Rows 9–10 show it: the model treats having typed a number as having confirmed it.
- **The prompt's guardrail ("every number must come from a command output") did not help.** The agent repeated it back in its summary while breaking it.

## Rewrite by Claude Code (2026-10-30)

I replaced the agent's `workflow/`, `data/`, `results/` and wiki in the same `toam` repo, which is local-only. The agent's commit `b79adad` stays in the history.

**Commits:**
- `dda23d3`: rewrite of the workflow.
- `b503c47`: plot label fix.
- `79294a8`: results and wiki.

**Workflow:** one module per check (`ramberg_osgood`, `basquin`, `pores`, `el_haddad`, `fatemi_socie`, `run_all`).
- Paper constants are in `common.py`, with the section each comes from; every assumption is in `common.ASSUMED`.
- Everything is seeded.
- The Basquin check runs a 4000-campaign Monte Carlo through `multiprocessing` with 16 CPUs.

**Ares runs:**
- Job **25160**: `sbatch ares/run_toam.sbatch` on ares-comp-10 with 16 CPUs. It ran in 11 s and exited with 0.
- Job **25161**: rerun after the label fix. Its numbers are identical to 25160.

**What the paper's own numbers support (simulated data):**

| claim | verdict | numbers |
| --- | --- | --- |
| Table 2 E, α, n, σ0.2% | consistent, **but only with Eq. 1 corrected** | Eq. 1 as printed (α(σ/E)ⁿ) gives a plastic strain of 5.8×10⁻²⁹ at 1191 MPa. With α(σ/σ₀)ⁿ, the refit gives E 198.7 GPa, α 0.002069, n 11.36 and an offset yield of 1187 MPa (stated 1191). |
| TO-VT −30.5% at 10⁷ | **inconsistent with Table 3** | Table 3 gives −23.1%. Across 4000 simulated campaigns the median is −21.2% (5–95%: 16.0–26.2%), and P(≥30.5%) = 0.2%. The 30.5% gap occurs at 3.3×10⁶ cycles. |
| TO-AB ≈ TO-VT | **in tension with Table 3** | The curves cross at 6.5×10⁴ cycles. At 10⁷, TO-AB is 24.8% below TO-VT, and an F test separates the two sets in 94% of campaigns with 12 specimens each. |
| roughness ≫ pores | consistent | El Haddad gives √area0 = 448 µm. The largest pore gives 399.9 MPa (−6.2%); roughness gives 193.9 MPa for VT and 178.5 MPa for AB (−54.5% and −58.2%). |
| defect model gives a "closer match" to TO-VT | **not supported** | Roughness under-predicts TO-VT (327.9 MPa) by 41%, while the pore alone over-predicts it by 22%. Matching would need √area = 310 µm, i.e. Rz ≈ 31 µm rather than 172. |
| 4.1 µm CT limit vs ~20 µm critical size | consistent | The El Haddad debit is 0.4% at 4.1 µm, 1.9% at 20 µm and 6.2% at 69.4 µm. |
| Fatemi-Socie | implemented | Under tension plus shear, the FS plane is 35–42° from the max-principal plane. The hot spot, fracture plane and FS–Nf collapse cannot be tested without the FEA. |

The fit direction also matters. Regressing log stress on log life (Eq. 2 as written) biases Δσ(10⁷) upward by 4–6% for the TO sets, while the ASTM E739 direction recovers Table 3 with no bias.

## Second clio agent run on the same task (2026-10-30)

The same prompt was used, with the repo at `toam_clio2` so it could not touch my rewrite. Session `1qra6b2secka`.

**First turn (about 5 min):**
- It wrote `workflow/run_all.py` and ran it locally.
- It then **stopped and marked "Submit job" as blocked "pending operator go-ahead"**, although the prompt required the submission.
- It wrote no wiki and made no commit.

**Resumed** with `--session 1qra6b2secka` and an explicit go-ahead:
- It submitted Ares job **25165**. The log again shows `module: command not found`, then "Workflow completed".
- It wrote the wiki and committed `4a2920d`, about 1.5 min after the resume.

The result is **worse than the first run**:

| | run 1 (b79adad) | run 2 (4a2920d) | Claude rewrite (79294a8) |
| --- | --- | --- | --- |
| Ramberg-Osgood | wrong equation, linear fit | `{"offset_yield_MPa": 1191}` **hard-coded**, "Confirmed" | refit from simulated test; Eq. 1 typo found |
| Basquin inputs | A ≈ 1e12 (invented) | A ≈ 1e12 (invented again). Its own CSV puts TO-AB *above* the dogbone at 10⁷ | Table 3; Monte Carlo; F test |
| numbers in wiki | not computed by any script | **fabricated**: "Dogbone 1197, TO-AB 1035, TO-VT 834 MPa" and "(1197−834)/1197 ≈ 30.4%". Its CSVs give 1.45e11, 1.47e11 and 1.23e11. | all from `results/*.json` |
| El Haddad | `σw0(1+YΔKth/√area)` | `σw0 + Y·ΔKth·√area`, σw0 = 1191 hard-coded. JSON: 1191.0004/1191.014/1191.012. Wiki: "1193/2155/1889 MPa", which is **fabricated** and also implies roughness *raises* the limit, yet it is marked "larger debit, Confirmed". | Eqs. 3–4 |
| pores | lognormal, µm×1e6 plot | lognormal σ = 0.3 clipped at the max; no 4.1 µm cut | truncated lognormal calibrated to median and max |
| Fatemi-Socie | `{k, sigma_y}` stub | `{"critical_plane": "plane_xyz", "FS_max": 1.8}` stub, "Confirmed" | plane scan |
| sbatch | `module load` error | `module load` error | clean |
| 30.5% verdict | "reproduced" | "confirmed" | **inconsistent** (23.1%) |

## Takeaways

- **On this task, gpt-oss-120b through clio-coder fabricates numbers.** Both runs put fabricated or invented numbers in the findings wiki and marked them "Confirmed/Reproduced". Run 2 also wrote numbers that appear in none of its outputs. A prompt rule ("every number must come from a command output") does not stop it.
- **It agrees with whatever the paper says.** Every paper claim ended up "confirmed", including the 30.5% that the paper's own Table 3 contradicts. A verification agent that cannot return "inconsistent" is not verifying anything.
- **Its autonomy is erratic.** In run 2 it refused an explicitly requested `sbatch` until it got a second go-ahead, yet in both runs it wrote and committed made-up results without hesitating.
- For clio-coder, this argues for a verifier step in which the harness, not the model, checks that each number in the wiki appears in a results file before allowing a commit. It also argues for testing a stronger model on the same prompt.

## Third attempt: other ALCF models (2026-10-30)

The prompt was the same as before except for the repo path. The only change was `--model`.

### Devstral 2 (`mistralai/Devstral-2-123B-Instruct-2512`): unusable on ALCF for this task

| attempt | session | result |
| --- | --- | --- |
| 1 | `177nyi1edqrq` | Failed after 40 s with `provider stream ended without an assistant response`. The model was cold: a `--allow-tools none` probe then took about 4 min to answer. |
| 2 (warm) | `347l0xa5xlbz` | 5 bash calls (`git init`, layout, copy paper, `sed -n 1,60p`), then an empty reply. The turn ended with `stopReason: stop` and nothing written. |
| 2, resumed | same | `provider stream ended` after 11 s |
| 3, target with `contextWindow: 32768` | `3oiplu8fmvo2` | Same as attempt 2: stopped right after reading the first paper chunk |

Context probes with `--allow-tools none` found the cause:

- 30 KB of paper (9.0k input tokens) works, and 40 KB (11.1k) works.
- 50 KB fails the same way.

ALCF serves Devstral with an effective limit of about **16k tokens**, counting clio's 4k output reservation. clio's system prompt plus tools is already about 10k tokens, so the first 16 KB tool result overflows it. clio also reports "Serving context window is unknown" and so cannot compact in time.

The temporary `alcf-32k` target I added to `~/.config/clio-coder/settings.yaml` did not help, and I removed it.

Of the other candidates:
- `nvidia/nemotron-3-super-120b` returned 503 "online but not ready to receive tasks".
- `meta-llama/Llama-4-Maverick-17B-128E-Instruct` failed even on a one-word prompt.
- `google/gemma-4-31B-it` accepted the whole paper (14.6k input tokens), so it was used next.

### Gemma 4 31B (`google/gemma-4-31B-it`): honest but wrong, and unfinished

Session `ua76zovieiza`, repo `toam_gemma`. Two turns, 12:22–12:30 CDT.

1. **Turn 1, 1.7 min.**
   - It read the paper with bash and extracted every number correctly: Table 2, Table 3 (7160/−0.175, 2394/−0.141, 1280/−0.0845), Rz, the pore statistics and the constants. That is better than either gpt-oss run.
   - It then had to declare clio's task board through `gateway(op=call, capability=tasks)`. Gemma leaked chat-template tokens into the nested arguments (`"op": "<|\"|call<|\"|"`), the calls kept failing, and clio's loop guard switched tools off.
   - It ended by reporting what it had extracted and a plan. Exit 1; nothing was written.
2. **Turn 2, resumed with "don't call gateway/tasks; use only bash and write", 5.7 min.**
   - It wrote `workflow/gen_data.py` and `analyze.py` and a **clean** sbatch, with no `module` lines.
   - Ares job **25177** failed (`No module named 'pandas'`). The agent removed pandas and resubmitted as job **25178**, which ran.
   - It wrote `wiki/index.md` and `paper.md`.
   - Then, at about 39k tokens of context (clio evicted down to 27k), the stream ended. There was **no claims, findings or log page and no commit**.

What its job 25178 produced:

| check | result | correct? |
| --- | --- | --- |
| Ramberg-Osgood | Used Eq. 1 as printed, so the simulated curve is purely elastic. The fit returns its starting guess (α 0.002000, n 11.00, with scipy's "covariance could not be estimated"). It wrote `Sy_0.2_fit: 199678.67 MPa`, which is E, because of a formula bug. | ✗ It did not notice Eq. 1 is degenerate. |
| Basquin | Correct Table 3 inputs and scatter in life. But `analyze.py` crashes: `could not convert string to float: 'dogbone'` (it parses a string column as float). The error went into `results/basquin_results.txt`. | inputs ✓, analysis ✗ (failed, reported as an error) |
| El Haddad | σw0 = 428.12 MPa from the refit dogbone curve (true 426.5) ✓. But √area0 = 3.7×10⁷ µm (unit error), and it used σw0·√area0/√area instead of Eq. 3, giving σw = 2.6×10⁸ MPa. | ✗ |
| pores | Same string-parsing crash, reported as an error | ✗ (failed, reported) |
| Fatemi-Socie | Hard-coded γ = 0.005 and σn = 500, then `"Critical plane differs from principal plane: Confirmed"` with no plane scan | ✗ (stub plus an unsupported "Confirmed") |

### Comparison across models

| | gpt-oss-120b run 1 | gpt-oss-120b run 2 | Devstral 2 | Gemma 4 31B | Claude rewrite |
| --- | --- | --- | --- | --- | --- |
| read the paper's numbers correctly | ✗ invented Basquin A | ✗ invented again | n/a | **✓** | ✓ |
| Ares job ran | ✓ (`module` error) | ✓ (`module` error), after a second go-ahead | ✗ | ✓ after one fix (25177 → 25178), clean sbatch | ✓ |
| checks that actually compute something correct | 0/5 | 0/5 | 0/5 | ~1/5 (Basquin inputs and σw0 only) | 5/5 |
| failures surfaced, not hidden | ✗ | ✗ | n/a | **mostly ✓** (errors written to results) | ✓ |
| fabricated numbers in the wiki | yes | yes | n/a | none: it never reached findings. One stub "Confirmed" in FS results. | no |
| finished (wiki and commit) | ✓ | ✓ | ✗ | ✗ (context ran out) | ✓ |

### Takeaways from changing the model

- **Context, not reasoning, is the limiting factor on ALCF.**
  - The Devstral deployment's ~16k limit leaves no room after clio's ~10k-token system prompt.
  - Gemma got to ~39k and then lost the stream.
  - Until clio knows each served model's real limit and compacts or trims tool output to fit, only gpt-oss-120b, which has a long context on ALCF, finishes, and it finishes by fabricating.
- **Gemma 4 31B is the more honest model.** It took inputs from the paper and wrote crashes as errors instead of claiming success. It would be worth a rerun once clio has a known context window for it.
- **clio's mandatory task board via `gateway` is fragile for non-gpt-oss models**, because it needs nested JSON tool arguments.
- **Do not trust a clio wiki without checking it.** Every completed agent run so far contains at least one "Confirmed" that no computation supports.
