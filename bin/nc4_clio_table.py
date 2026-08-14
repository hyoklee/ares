#!/usr/bin/env python3
"""
Turn nc4_clio_run.sbatch result directories into the markdown tables used in
ares/doc.

Reads the per-variant ``nc4_<variant>.json`` files (what
parse_nc4_clio_results.py already extracted from tst_chunks3's output) rather
than re-parsing the text, so the numbers in the doc and the numbers on the plot
page come from one source.

Usage:
    nc4_clio_table.py <label>=<results-dir> [...] [--ratios] [--pivot]

    --ratios  one row per benchmark, columns = variant / baseline for the FIRST
              labelled run (the per-operation slowdown table)
    --pivot   one row per benchmark, columns = every label x variant (used to
              compare two tiers, or a run against its repeat)

Without either flag it prints the raw seconds, one row per benchmark.
"""

import argparse
import json
from pathlib import Path

VARIANTS = ["baseline", "clio_vfd", "clio_vol"]


def load(results_dir: Path) -> dict:
    """{variant: {benchmark name: seconds}} for one results directory."""
    out = {}
    for variant in VARIANTS:
        path = results_dir / f"nc4_{variant}.json"
        if not path.exists():
            out[variant] = {}
            continue
        out[variant] = {e["name"]: e["value"] for e in json.loads(path.read_text())}
    return out


def order(names) -> list:
    """tst_chunks3's own print order: write before read, then storage type."""
    def key(name: str):
        parts = name.split("_")
        storage, op = parts[0], parts[1]
        shape = parts[2] if len(parts) > 2 else ""
        return (0 if op == "write" else 1,
                shape,
                ["contiguous", "chunked", "compressed"].index(storage))
    return sorted(names, key=key)


def pretty(name: str) -> str:
    parts = name.split("_")
    label = f"{parts[0]} {parts[1]} {parts[2]}"
    if "chunks" in parts:
        label += f" / chunks {parts[parts.index('chunks') + 1]}"
    return label


def fmt(v):
    if v is None:
        return "—"
    if v >= 100:
        return f"{v:.0f}"
    if v >= 1:
        return f"{v:.2f}"
    return f"{v:.3g}"


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("runs", nargs="+", metavar="LABEL=DIR")
    ap.add_argument("--ratios", action="store_true")
    ap.add_argument("--pivot", action="store_true")
    args = ap.parse_args()

    runs = []
    for spec in args.runs:
        label, _, path = spec.partition("=")
        runs.append((label, load(Path(path))))

    names = order({n for _, data in runs for v in VARIANTS for n in data[v]})

    if args.ratios:
        label, data = runs[0]
        print(f"| benchmark | baseline (s) | CLIO VFD (s) | x base | CLIO VOL (s) | x base |")
        print("| --- | ---: | ---: | ---: | ---: | ---: |")
        for name in names:
            base = data["baseline"].get(name)
            row = [pretty(name), fmt(base)]
            for variant in ("clio_vfd", "clio_vol"):
                value = data[variant].get(name)
                row.append(fmt(value))
                row.append(f"{value / base:.1f}x" if base and value else "—")
            print("| " + " | ".join(row) + " |")
        return

    if args.pivot:
        header = ["benchmark"]
        for label, _ in runs:
            header += [f"{label} {v}" for v in VARIANTS]
        print("| " + " | ".join(header) + " |")
        print("| " + " | ".join(["---"] + ["---:"] * (len(header) - 1)) + " |")
        for name in names:
            row = [pretty(name)]
            for _, data in runs:
                row += [fmt(data[v].get(name)) for v in VARIANTS]
            print("| " + " | ".join(row) + " |")
        return

    for label, data in runs:
        print(f"\n### {label}\n")
        print("| benchmark | " + " | ".join(VARIANTS) + " |")
        print("| --- | ---: | ---: | ---: |")
        for name in names:
            print("| " + " | ".join([pretty(name)]
                                    + [fmt(data[v].get(name)) for v in VARIANTS]) + " |")


if __name__ == "__main__":
    main()
