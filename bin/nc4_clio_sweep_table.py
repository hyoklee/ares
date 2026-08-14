#!/usr/bin/env python3
"""
Summarize a nc4_clio_sweep.sbatch results tree into markdown tables.

The sweep leaves one directory per size (``d64_c16``, ``d128_c32``, ...), each
holding the same per-variant JSON a single run produces. Benchmark *names*
carry the dimensions, so they cannot be compared across sizes directly; this
script strips the dimensions down to the access shape -- yz (1xNxN), xz (Nx1xN),
xy (NxNx1) -- which is what stays constant as the problem grows.

Usage:
    nc4_clio_sweep_table.py <sweep-results-dir> [--op "contiguous write xy"]

Prints:
  1. totals per size and variant (sum of the 9 write timings, sum of the 9 read
     timings, and the single worst timing), plus the growth factor against the
     previous size -- the "effect of doubling" in one number;
  2. one table for the named operation across all sizes.
"""

import argparse
import json
import re
from pathlib import Path

VARIANTS = [("baseline", "baseline"), ("clio_vfd", "CLIO VFD"), ("clio_vol", "CLIO VOL")]


def shape_of(dims: str) -> str:
    """'1x256x256' -> 'yz'; '256x1x256' -> 'xz'; '256x256x1' -> 'xy'."""
    a, b, c = dims.split("x")
    if a == "1":
        return "yz"
    if b == "1":
        return "xz"
    return "xy"


def op_key(name: str) -> str:
    """'contiguous_write_256x256x1_chunks_64x64x64' -> 'contiguous write xy'."""
    parts = name.split("_")
    return f"{parts[0]} {parts[1]} {shape_of(parts[2])}"


def load_size(size_dir: Path) -> dict:
    """{variant: {op key: seconds}}."""
    out = {}
    for variant, _ in VARIANTS:
        path = size_dir / f"nc4_{variant}.json"
        if not path.exists():
            out[variant] = {}
            continue
        out[variant] = {op_key(e["name"]): e["value"]
                        for e in json.loads(path.read_text())}
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("root")
    ap.add_argument("--op", default="contiguous write xy")
    args = ap.parse_args()

    root = Path(args.root)
    sizes = []
    for d in root.iterdir():
        m = re.fullmatch(r"d(\d+)_c(\d+)", d.name)
        if m and d.is_dir():
            sizes.append((int(m.group(1)), int(m.group(2)), d))
    sizes.sort()

    print("| dim | chunk | data MiB | variant | Σ write (s) | Σ read (s) | worst op (s) | n |")
    print("| ---: | ---: | ---: | --- | ---: | ---: | ---: | ---: |")
    prev = {}
    for dim, chunk, d in sizes:
        mib = 3 * dim ** 3 * 4 // 1048576
        data = load_size(d)
        for variant, label in VARIANTS:
            vals = data[variant]
            if not vals:
                print(f"| {dim} | {chunk} | {mib} | {label} | no result | no result | — | 0 |")
                prev.pop(variant, None)
                continue
            w = sum(v for k, v in vals.items() if " write " in k)
            r = sum(v for k, v in vals.items() if " read " in k)
            worst = max(vals.values())
            growth = ""
            if variant in prev and prev[variant] > 0:
                growth = f" ({(w + r) / prev[variant]:.1f}x)"
            prev[variant] = w + r
            print(f"| {dim} | {chunk} | {mib} | {label} | {w:.3g}{growth} | {r:.3g} | "
                  f"{worst:.3g} | {len(vals)} |")

    print()
    print(f"| dim | chunk | " + " | ".join(label for _, label in VARIANTS)
          + " | VFD x base | VOL x base |")
    print("| ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    for dim, chunk, d in sizes:
        data = load_size(d)
        row = [str(dim), str(chunk)]
        vals = []
        for variant, _ in VARIANTS:
            v = data[variant].get(args.op)
            vals.append(v)
            row.append("—" if v is None else f"{v:.3g}")
        base = vals[0]
        for v in vals[1:]:
            row.append(f"{v / base:.1f}x" if base and v else "—")
        print("| " + " | ".join(row) + " |")
    print(f"\n(second table: `{args.op}`, seconds)")


if __name__ == "__main__":
    main()
