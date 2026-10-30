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
