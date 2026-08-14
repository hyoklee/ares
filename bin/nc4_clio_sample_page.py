#!/usr/bin/env python3
"""
Render the NetCDF-4/CLIO comparison page from local ares runs.

hpf's create_nc4_clio_plots.py reads github-action-benchmark's ``data.js`` --
the history that accumulates on gh-pages. There is no such history for a run on
ares, so this script assembles the equivalent structure from the
``benchmark_data.json`` files that nc4_clio_run.sbatch leaves in each results
directory and hands it to that same renderer through its ``--sample`` mode. The
page is therefore byte-for-byte the layout published at
hyoklee.github.io/hpf/benchmarks_nc4_clio/plots.html -- same charts, same three
series, same colors -- with ares measurements in it.

Usage:
    nc4_clio_sample_page.py <out.html> <label>=<results-dir> [<label>=<dir> ...]
                            [--title TITLE]

Each results directory becomes one point per series on every chart, timestamped
with the mtime of its benchmark_data.json (i.e. when the run actually finished),
so the x-axis is the real chronology of the runs. <label> is shown in the
hover tooltip where CI would show a commit SHA; the renderer truncates it to 8
characters, so keep it short (``ram``, ``nvme``, ``ram2``).
"""

import argparse
import json
import subprocess
import sys
from pathlib import Path

HPF_SCRIPTS = Path("/home/hyoklee/src/hyoklee/hpf/.github/scripts")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("output")
    ap.add_argument("runs", nargs="+", metavar="LABEL=DIR")
    ap.add_argument("--title", default="NetCDF-4 CLIO Performance Benchmark (ares)")
    args = ap.parse_args()

    sample = []
    for spec in args.runs:
        if "=" not in spec:
            sys.exit(f"expected LABEL=DIR, got {spec!r}")
        label, _, path = spec.partition("=")
        data = Path(path) / "benchmark_data.json"
        if not data.exists():
            sys.exit(f"{data} not found -- did that run produce results?")
        benches = json.loads(data.read_text())
        sample.append({
            "date": int(data.stat().st_mtime * 1000),
            "commit": label,
            "url": "",
            "benches": benches,
        })
        print(f"{label}: {len(benches)} entries from {data}")

    sample.sort(key=lambda r: r["date"])
    out = Path(args.output)
    tmp = out.with_suffix(".sample.json")
    tmp.write_text(json.dumps(sample, indent=2))

    subprocess.run(
        [sys.executable, str(HPF_SCRIPTS / "create_nc4_clio_plots.py"),
         "--sample", str(tmp), str(out), "--title", args.title],
        check=True,
    )
    tmp.unlink()


if __name__ == "__main__":
    main()
