# Terra Fusion: why O10670 will not open — root group metadata overwritten by raw data

Run on **ares**, 2026-10-01. Follows
[part 17](20260930_claude_terra_fusion_discrepancy_17_all_granules.md), which
had to exclude `TERRA_BF_L1B_O10670_20011220010522_F000_V001.h5` (42.3 GB)
because nothing could open it.

## Headline

* **A resumed transfer duplicated 229.15 MiB**, inserting it at offset
  30,721,900,544. Everything after is intact but **shifted**, so HDF5's internal
  addresses miss their targets and it fails at
  `H5O__chunk_deserialize(): message not aligned`. Nothing is overwritten.
* **The superblock is CORRECT.** It says the file ends at 45,133,547,913 — and
  the authoritative copy in AWS S3 is **exactly 45,133,547,913 bytes**. The local
  file is 45,373,827,465, larger by precisely the duplicated run.
* **The file is not truncated.** Its last 4 KiB hold a complete, readable
  provenance manifest listing the MOD021KM/MOD03 source granules for
  **A2001354** — day 354 of 2001, matching the orbit. That trailer is genuine;
  it has merely been displaced 229 MiB by the insertion.
* The source in S3 is **intact**. Only this local copy is damaged, and only by
  duplication.
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

## VERIFIED against a fresh copy fetched through CAE

The granule was re-fetched from the public bucket through CAE
([`bin/tf_o10670_s3.omni.yaml`](../bin/tf_o10670_s3.omni.yaml)) and compared in
full. The new file is **45,133,547,913 bytes — exactly the size the corrupt
file's own superblock declares — and it opens**, reporting 411 root objects
where the local copy died at `H5G_mkroot`.

Three SHA-256 comparisons over the whole 45 GB, with
`PT = 30,721,900,544` and `SHIFT = 240,279,552`:

| # | comparison | result |
| --- | --- | --- |
| 1 | `old[0 : PT]` vs `new[0 : PT]` | **identical** (`cd83f409…`) |
| 2 | `old[PT+SHIFT : end]` vs `new[PT : end]` | **identical** (`f332ea03…`) |
| 3 | `old[PT : PT+SHIFT]` vs `old[PT−SHIFT : PT]` | **identical** (`3119a215…`) |

(1) and (2) together prove the local file is the authoritative file with a
single contiguous run inserted and **nothing else altered** — not one byte
outside the insertion differs. (3) proves that run is a verbatim duplicate of
the 229.15 MiB immediately before it.

**Final verdict: a resumed transfer re-sent a 229.15 MiB span instead of seeking
past it.** The source is intact, the damage is one duplicated block, and
everything downstream of it was merely displaced.

## How it was diagnosed before the re-fetch



Comparing against the authoritative S3 object by byte range settles the whole
thing, and it is a tidier fault than the symptoms suggested.

**The local file is the S3 file with 240,279,552 bytes inserted at offset
30,721,900,544, and that inserted block is a byte-identical copy of the
229.15 MiB immediately preceding it.**

Established by range comparison against `s3://terrafusiondatasampler`:

| region | local vs S3 |
| --- | --- |
| superblock (0, 512 B) | **identical** |
| 1 GiB in | **identical** |
| 10 GiB in | **identical** |
| 25 GiB in | **identical** |
| 40 GiB in | differs |
| root continuation chunk | differs — S3 has `10 00 10 00 …`, the valid message |
| last 4 KiB of the true file | differs |

and then, decisively:

| test | result |
| --- | --- |
| `local[x + 240,279,552] == s3[x]` at 40 GiB, 42 GiB, the root chunk, and true EOF−4K | **MATCH at every one** |
| first differing byte | **30,721,900,544** (0x7272B0000) |
| `local[first_diff + shift] == s3[first_diff]` | **YES — a pure insertion** |
| `inserted[0:4096] == local[30,481,620,992]` | **YES** — and 30,481,620,992 = insertion point − 240,279,552 |

The inserted run is an exact duplicate of the block that precedes it. The
insertion point is 64 KiB-aligned and the length is exactly 58,662 × 4 KiB
pages. That is the signature of a **transfer that resumed from a checkpoint
229 MiB back and re-sent that span instead of seeking** — not storage rot, not a
bad source.

### Why this looked like overwritten metadata

Nothing is overwritten. Everything after the insertion is **intact but shifted
by +240,279,552 bytes**. HDF5's internal addresses still point where the objects
used to be, so the root group's continuation pointer — correct for the original
layout — now lands 229 MiB short of the real chunk and reads whatever raw data
happens to sit there. The "message not aligned" error is the downstream symptom
of a shift, not of damage at that location.

The same explains the trailer: the ASCII provenance manifest really is the last
4 KiB of the genuine file, and in the local copy it has simply been pushed
240 MB further out.

**The file is therefore repairable in principle** — excising
`[30,721,900,544, 30,962,180,096)` would reproduce the original byte for byte.
Re-downloading is simpler and carries no risk of a second mistake, so that is
what was done; the corrupt copy is preserved unmodified as evidence.

## CORRECTION: the superblock was right, the copy is wrong

This note first concluded that the superblock's EOF was *stale* and inferred a
file "captured mid-write". **That was wrong**, and checking the authoritative
copy settles it.

The dataset is public on AWS S3 (`s3://terrafusiondatasampler`, `us-west-2`), and
a `HEAD` on the object gives:

```
Key:            P108/TERRA_BF_L1B_O10670_20011220010522_F000_V001.h5
Content-Length: 45133547913
ETag:           "f53ace0cff68db0a4888c248c932bca3-5381"
Last-Modified:  Fri, 06 Dec 2019 03:33:34 GMT
```

**45,133,547,913 is exactly the EOF this file's own superblock declares.** The
superblock is not stale; it is correct, and it has been correct all along. The
authoritative file is 45,133,547,913 bytes and the local copy is 45,373,827,465
— **229.1 MiB of bytes that do not belong to the file have been appended to it.**

That reverses the reading:

| | first inference (wrong) | what S3 shows |
| --- | --- | --- |
| superblock EOF | stale, writer never flushed | **correct** |
| extra 229 MiB | legitimate content past a stale marker | **garbage appended to a complete file** |
| cause | source captured mid-write | **the local copy is damaged** |
| the ASCII trailer | proof the file was complete | it is from the appended region, not the real file |

The corruption is not confined to the tail either: the clobbered root
continuation chunk sits at 45,131,496,033, which is **inside** the authoritative
45,133,547,913-byte range, about 2 MB before the true end. So this copy has both
extra bytes appended *and* interior bytes overwritten — the signature of a
botched transfer, not of a bad source file.

**What this means practically:** the archive copy is almost certainly fine, and
re-downloading is not merely the best option, it is expected to work. The S3
object's own size matching the superblock is the strongest evidence available
that the source is intact.

### What the earlier reasoning got wrong

The inference chain was: EOF mismatch → superblock stale → writer crashed. Every
step was plausible and the conclusion was still wrong, because the chain never
checked the one external fact that could decide it — how big the file is
*supposed* to be. The ASCII trailer was then read as confirming evidence
("complete manifest, so not truncated"), when it is in fact part of the appended
garbage. A finding that explains everything and is checkable against an
authority should be checked against that authority before it is written down.

**It is still not recoverable in place.** Reconstructing a root group object header
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
