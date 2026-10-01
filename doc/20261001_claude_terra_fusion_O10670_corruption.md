# Terra Fusion: why O10670 will not open — root group metadata overwritten by raw data

Run on **ares**, 2026-10-01. Follows
[part 17](20260930_claude_terra_fusion_discrepancy_17_all_granules.md), which
had to exclude `TERRA_BF_L1B_O10670_20011220010522_F000_V001.h5` (42.3 GB)
because nothing could open it.

## Headline

* **The root group's object header continuation chunk has been overwritten with
  compressed data.** HDF5 fails at `H5O__chunk_deserialize(): message not
  aligned`, before any dataset can be reached.
* **The superblock's EOF is stale by 229 MiB.** It says the file ends at
  45,133,547,913; the file is 45,373,827,465 bytes.
* **The file is not truncated.** Its last 4 KiB hold a complete, readable
  provenance manifest listing the MOD021KM/MOD03 source granules for
  **A2001354** — day 354 of 2001, i.e. 2001-12-20, which matches the orbit.
* Together these say the file was **captured or copied while still being
  written**, or its writer died before the closing metadata flush.
* **Separately, and worth reporting upstream: `h5ls` on this file is OOM-killed
  rather than erroring.** A corrupt message length becomes an unbounded
  allocation. With `RLIMIT_AS` set it fails cleanly instead.
* **Not recoverable in place.** The file needs re-fetching.

## Symptom

```
netCDF4:  [Errno -101] NetCDF: HDF error
h5ls:     Killed (exit 137)   -- OOM, on a 94 GB host
h5debug:  cannot open file
```

## Where it fails

Opening with the error stack enabled and the address space capped at 8 GiB so
the allocation reports instead of inviting the OOM killer:

```
 #005: H5Fint.c  line 2141 in H5F_open(): unable to read root group
 #006: H5Groot.c line  218 in H5G_mkroot(): can't check if symbol table message exists
 #007: H5Omessage.c line 791 in H5O_msg_exists(): unable to protect object header
 #010: H5Centry.c line 3154 in H5C_protect(): can't load entry
 #012: H5Ocache.c line  720 in H5O__cache_chk_deserialize(): unable to destroy object header chunk
 #016: H5Ocache.c line 1271 in H5O__chunk_deserialize(): message not aligned
```

`H5O__cache_chk_deserialize` is the **continuation chunk** path, so the damage is
not in the root header's first chunk but in what it points to.

## What is actually wrong

### The superblock is fine, and so is chunk 0

Decoding both files by hand — the broken one and the working O10204:

| field | O10670 | O10204 |
| --- | --- | --- |
| signature | valid | valid |
| superblock version | 0 | 0 |
| offset / length size | 8 / 8 | 8 / 8 |
| root OH address | 96 | 96 |
| root OH version | 1 | 1 |
| chunk 0 size | 24 | 24 |
| first message | type 16, size 16 | type 16, size 16 |
| **EOF address** | **45,133,547,913** | 32,871,364,681 |
| **actual file size** | **45,373,827,465** | 32,871,364,681 |
| | **mismatch: −229.1 MiB** | **exact match** |

Message type 16 is `H5O_CONT_ID`, the continuation pointer. Both files have the
same shape here; O10670's only superblock anomaly is the stale EOF.

### The continuation chunk is not an object header at all

Following that pointer:

| | O10670 | O10204 |
| --- | --- | --- |
| continuation address | 45,131,496,033 | 32,567,513,205 |
| continuation length | 208 | 224 |
| first 16 bytes | `e2 f0 4f da 76 78 36 4c 18 76 0d cf 86 07 c3 6b` | `10 00 10 00 00 00 00 00 2d cd 2c 95 07 00 00 00` |
| parsed as a message | type **61666**, size **55887** — not 8-aligned | type 16, size 16 — valid |
| first messages | — | 3 messages, all 8-aligned |

The healthy file begins its continuation chunk with `10 00 10 00`: type 16,
size 16. O10670 has high-entropy bytes there — **6.87 bits/byte over the 208-byte
chunk**, and **7.85 over a 4 KiB window** around it. (A 208-byte sample cannot
exceed log₂(208) ≈ 7.70, so the two figures agree; both say compressed payload,
not metadata.)

**The root group's metadata has been overwritten by dataset data.**

### The file is complete, just mis-stamped

Entropy across the file, including the 229 MiB past the declared EOF:

| region | offset | entropy | content |
| --- | --- | --- | --- |
| just before declared EOF | 45,133,543,817 | 7.85 | compressed |
| at declared EOF | 45,133,547,913 | 7.85 | compressed |
| mid extra region | 45,253,547,913 | 7.91 | compressed |
| **last 4 KiB** | 45,373,823,369 | **4.08** | **ASCII manifest** |

The tail is readable text:

```
...MOD02HKM.A2001354.0210.006.2014230070534.hdf,
   MOD02QKM.A2001354.0210.006.2014230033646.hdf,
   MOD03.A2001354.0210.006.2012262101925.hdf, ...
```

A complete provenance list of the MODIS L1B granules this fusion file was built
from, for **A2001354** = 2001-12-20, matching O10670's date. So the 229 MiB
beyond the declared EOF is **real content, correctly terminated** — the file was
not cut short.

## What this means

The combination — stale superblock EOF, root metadata overwritten by raw data,
and a complete trailer — points at the file being **snapshotted or copied while
the writer was still running**, or the writer dying before its final metadata
flush. HDF5 updates the superblock and object headers at close; a file captured
mid-write carries an older EOF, and metadata the writer had not yet relocated
can be sitting under space since reused for raw data.

**It is not recoverable in place.** Reconstructing a root group object header
from the surrounding data is not a supported operation, and `h5clear` only
resets status flags — it cannot repair a corrupt header. The file should be
re-fetched from the Terra Fusion archive.

**No attempt was made to modify the file.** Everything above is read-only
inspection; `h5clear` was deliberately not run on it.

## A robustness note worth passing on

`h5ls` on this file is **OOM-killed**, not refused. The corrupt chunk parses as
a message of size 55,887 with a nonsense type, and the library allocates on that
basis without a sanity check against the chunk's own declared length (208
bytes). On a 94 GB host that was enough to reach the OOM killer.

Running the same open with `RLIMIT_AS` capped at 8 GiB produced the clean error
stack quoted above instead. A bound on message size against the enclosing chunk
length would turn an OOM kill into the diagnostic that HDF5 already knows how to
emit — the `message not aligned` check exists and fires correctly once the
allocation does not kill the process first.

## Reproducing

```sh
# the diagnostic, with the error stack on and memory bounded
h5cc -O2 -o h5diag h5diag.c      # source inline in this part's commit
./h5diag <granule> 8192          # 8 GiB cap

# superblock / object header decode, read-only
python3 bin/tf_h5_forensics.py <granule> [reference-granule]
```

## Caveats

* One file. Whether the other granules share a milder form of this was not
  checked — O10204's superblock EOF matches its size exactly, and the five
  others opened and processed without complaint in part 17, which is evidence
  but not a scan.
* The "captured mid-write" reading is an inference from three consistent
  observations, not something the file records. A deliberate truncation of the
  superblock, or storage-level corruption that happened to land on the metadata,
  would look similar.
* The entropy figures are 4 KiB samples, not a whole-file profile.
* No checksum or archive copy was available to compare against.
