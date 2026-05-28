#!/usr/bin/env python
"""Stage NFS files into a CTE-managed path, then read them back.

Single-process variant of run_caseread_staged so the LD_PRELOAD adapter only
inits its chimaera client once (avoids the per-subshell-init log pollution that
breaks bash arithmetic).

Phase 1 (STAGE): copy each src file to dest_dir/basename via os.read/os.write.
  Under LD_PRELOAD, writes to dest are routed into the CTE storage tier.
Phase 2 (READ): run the read_bench_ca1 inner loop over the staged paths for
  --iterations iterations. Reads should serve from the tier (NVMe, 1.5 GB/s).
"""
import argparse
import gc
import os
import sys
import time
import h5py


def stage_one(src, dst, chunk=1 << 22):
    """Copy src -> dst in 4 MB chunks via raw os.read/os.write, looping on partial writes."""
    fi = os.open(src, os.O_RDONLY)
    try:
        fo = os.open(dst, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
        try:
            total = 0
            while True:
                buf = os.read(fi, chunk)
                if not buf:
                    break
                mv = memoryview(buf)
                off = 0
                while off < len(buf):
                    n = os.write(fo, mv[off:])
                    if n <= 0:
                        raise IOError(f"write returned {n} to {dst} at offset {total + off}")
                    off += n
                total += len(buf)
            return total
        finally:
            os.close(fo)
    finally:
        os.close(fi)


def read_file(path, chunk_rows=1 << 20):
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
    ap.add_argument("--dest-dir", required=True,
                    help="virtual path the LD_PRELOAD adapter intercepts for writes")
    ap.add_argument("--iterations", type=int, default=3)
    ap.add_argument("--label", default="staged")
    ap.add_argument("--skip-stage", action="store_true",
                    help="skip the copy phase (e.g. tier already populated)")
    ap.add_argument("paths", nargs="+", help="source HDF5 file paths")
    args = ap.parse_args()

    src_paths = args.paths
    for p in src_paths:
        if not os.path.isfile(p):
            print(f"ERROR: missing src: {p}", file=sys.stderr)
            sys.exit(2)
    os.makedirs(args.dest_dir, exist_ok=True)
    # Prefix each staged file name with the CTE adapter's "clio::" marker so
    # the LD_PRELOAD adapter intercepts open/read/write at that path and
    # routes the data into the chimaera storage tier rather than letting it
    # fall through to the underlying filesystem.
    dst_paths = [os.path.join(args.dest_dir, "clio::" + os.path.basename(p)) for p in src_paths]

    print(f"# label={args.label} iterations={args.iterations} files={len(src_paths)} dest={args.dest_dir}")
    sys.stdout.flush()

    if not args.skip_stage:
        t0 = time.time()
        total = 0
        for src, dst in zip(src_paths, dst_paths):
            n = stage_one(src, dst)
            total += n
            print(f"  staged {os.path.basename(src)}: {n} bytes", flush=True)
        t1 = time.time()
        dt = t1 - t0
        mb = total / (1024 * 1024)
        print(f"stage: files={len(src_paths)} bytes={total} MB={mb:.1f} "
              f"sec={dt:.2f} MBps={mb/dt:.1f}", flush=True)
    else:
        print("stage: SKIPPED", flush=True)

    for it in range(1, args.iterations + 1):
        gc.collect()
        t0 = time.time()
        total = 0
        nds = 0
        for p in dst_paths:
            b, n = read_file(p)
            total += b
            nds += n
        t1 = time.time()
        dt = t1 - t0
        mb = total / (1024 * 1024)
        print(f"iter {it} files={len(dst_paths)} datasets={nds} "
              f"bytes={total} MB={mb:.1f} sec={dt:.2f} MBps={mb/dt:.1f}",
              flush=True)


if __name__ == "__main__":
    main()
