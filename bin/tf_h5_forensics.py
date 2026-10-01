"""Read-only forensics on an HDF5 file that will not open.

Decodes the superblock and walks the root group's object header far enough to
say WHERE a file is damaged, without using the HDF5 library -- which is the
point, since the library cannot open the file in the first place.

Written for TERRA_BF_L1B_O10670, whose root group continuation chunk turned out
to have been overwritten with compressed data. See
doc/20261001_claude_terra_fusion_O10670_corruption.md

Never writes to the file.

Usage:
    python3 bin/tf_h5_forensics.py <suspect.h5> [known-good.h5]
"""
import collections, math, os, struct, sys


def entropy(b):
    c = collections.Counter(b); n = len(b)
    return -sum(v / n * math.log2(v / n) for v in c.values()) if n else 0.0


def report(path):
    size = os.path.getsize(path)
    print(f"=== {os.path.basename(path)}")
    print(f"    size {size:,}")
    with open(path, 'rb') as f:
        b = f.read(128)
    if b[:8] != b'\x89HDF\r\n\x1a\n':
        print("    !!! not an HDF5 signature"); return
    ver = b[8]
    print(f"    superblock version {ver}")
    if ver not in (0, 1):
        print("    (only v0/v1 decoded here)"); return
    soff = b[13]
    o = 24 if ver == 0 else 28
    fmt = {8: '<Q', 4: '<I'}[soff]
    base, free, eof, drv = (struct.unpack(fmt, b[o + i * soff:o + (i + 1) * soff])[0]
                            for i in range(4))
    flag = "MATCHES file size" if eof == size else f"MISMATCH ({eof - size:+,} vs file)"
    print(f"    EOF address {eof:,}   <- {flag}")

    o2 = o + 4 * soff
    link_off, oh = struct.unpack('<QQ', b[o2:o2 + 16])
    print(f"    root object header @ {oh:,}")
    with open(path, 'rb') as f:
        f.seek(oh); hdr = f.read(16)
    if hdr[0] != 1:
        print(f"    root OH version {hdr[0]} (v2+ not decoded here)"); return
    nmesg = struct.unpack('<H', hdr[2:4])[0]
    chunk0 = struct.unpack('<I', hdr[8:12])[0]
    print(f"    v1 OH: {nmesg} messages, chunk0 {chunk0} bytes")
    with open(path, 'rb') as f:
        f.seek(oh + 16); m = f.read(24)
    mtype, msize = struct.unpack('<HH', m[0:4])
    print(f"    first message: type {mtype} size {msize}"
          f"{'  (continuation)' if mtype == 16 else ''}")
    if mtype != 16:
        return
    caddr, clen = struct.unpack('<QQ', m[8:24])
    print(f"    continuation -> {caddr:,} len {clen:,}")
    if caddr + clen > size:
        print("    !!! continuation extends past EOF"); return
    with open(path, 'rb') as f:
        f.seek(caddr); chunk = f.read(clen)
    print(f"    chunk first 16: {chunk[:16].hex(' ')}")
    print(f"    chunk entropy : {entropy(chunk):.2f} bits/byte"
          f"   {'<- looks like DATA, not metadata' if entropy(chunk) > 7.0 else ''}")
    off = n = 0
    while off + 8 <= len(chunk) and n < 64:
        t, s = struct.unpack('<HH', chunk[off:off + 4])
        if s % 8 != 0:
            print(f"    !!! message {n} at offset {off}: type={t} size={s} NOT 8-aligned")
            return
        off += 8 + s; n += 1
    print(f"    {n} messages parsed, all 8-aligned")


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print(__doc__); sys.exit(2)
    for p in sys.argv[1:]:
        report(p); print()
