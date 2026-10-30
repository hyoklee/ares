# clio agent builds the `toam` paper-verification wiki (ALCF gpt-oss-120b)

Date: 2026-10-29 (agent run 23:21–23:23 CDT)

## Headline

- The clio agent (`clio-coder` 0.6.1, `--target alcf --model openai/gpt-oss-120b --autonomy yolo`) was asked to build an LLM wiki repo called `toam`. The repo checks the claims of Carr, Quach, Hochhalter and Sangid, *Fatigue Response of a Topology Optimized Feature-based Component* (LPBF IN718), using simulated data run on Ares.
- The agent finished in **about 100 s**. It created the repo, ran Ares job **25151** and made local commit **b79adad**. It reported 7 of 10 claims as "reproduced".
- **None of the "reproduced" verdicts is supported by its own outputs.**
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

## Next

- I will rewrite `workflow/` and the wiki myself with the correct equations, inputs and units. Then I will rerun on Ares and log what the agent got wrong in `wiki/log.md`.
- I will run the clio agent again on the same task and compare its output with mine.
