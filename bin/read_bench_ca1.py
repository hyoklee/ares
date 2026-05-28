#!/usr/bin/env python
"""Read-bound benchmark over MiV CA1 NeuroH5 files.

Streams every dataset of each listed HDF5 file through h5py, releasing memory
between datasets so the harness can run on a single node without OOM. Reports
per-iteration MB/s; running >=2 iterations is what isolates the re-read regime
where the IOWarp CTE tier is supposed to beat NFS.
"""
import argparse
import gc
import os
import sys
import time
import h5py


def read_file(path, chunk_rows=1 << 20):
    """Read every dataset in `path` chunk-by-chunk; return (bytes_read, n_datasets)."""
    total = 0
    n = 0
    with h5py.File(path, "r") as f:
        def visit(name, obj):
            nonlocal total, n
            if isinstance(obj, h5py.Dataset):
                n += 1
                size = obj.size * obj.dtype.itemsize
                if obj.ndim == 0 or obj.shape == ():
                    _ = obj[()]
                else:
                    nrows = obj.shape[0]
                    step = max(1, chunk_rows)
                    for i in range(0, nrows, step):
                        _ = obj[i : i + step]
                total += size
        f.visititems(visit)
    return total, n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("paths", nargs="+", help="HDF5 file paths to read in order")
    ap.add_argument("--iterations", type=int, default=2)
    ap.add_argument("--label", default="run")
    args = ap.parse_args()

    paths = args.paths
    for p in paths:
        if not os.path.isfile(p):
            print(f"ERROR: missing file: {p}", file=sys.stderr)
            sys.exit(2)

    print(f"# label={args.label} iterations={args.iterations} files={len(paths)}")
    for it in range(1, args.iterations + 1):
        gc.collect()
        t0 = time.time()
        total = 0
        nds = 0
        for p in paths:
            b, n = read_file(p)
            total += b
            nds += n
        t1 = time.time()
        dt = t1 - t0
        mb = total / (1024 * 1024)
        print(
            f"iter {it} files={len(paths)} datasets={nds} "
            f"bytes={total} MB={mb:.1f} sec={dt:.2f} MBps={mb/dt:.1f}"
        )
        sys.stdout.flush()


if __name__ == "__main__":
    main()
