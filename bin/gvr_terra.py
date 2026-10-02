#!/usr/bin/env python3
"""Terra Fusion read experiment over clio-fs on the gpu-vector-rewrite branch.

Deploys clio-fs with the suite's own cluster.py (the dev-era config does not
compose this branch's cte_core -> replication -> cache -> stream chain and the
mount fails), stages a Terra Fusion granule, VERIFIES IT BYTE FOR BYTE, then
runs the same read benchmark used in parts 16 and 18.

Part 18's clio-fs arm scored 0.00 s because the staged granule had been
corrupted (#1116): it opened and reported zero MODIS granules. The sha256 check
here is the step that was missing then -- a timing is only meaningful if the
bytes are right.
"""
import hashlib, json, os, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cluster import Cluster, sh

BIN = sys.argv[1]
OUT = sys.argv[2]
GRAN = sys.argv[3]
BENCH = sys.argv[4]
REPS = int(os.environ.get('REPS', '3'))
host = os.environ.get('TF_HOST') or subprocess.run(
    ['hostname'], capture_output=True, text=True).stdout.strip()

cl = Cluster([host], BIN, OUT, profile='persistent',
             disk_gb=60, ram_gb=8, neighborhood=1)
print(f'# deploying clio-fs on {host}', flush=True)
ok, msg = cl.up(wipe=True)
if not ok:
    print(f'!!! deploy failed: {msg}')
    raise SystemExit(1)
print(f'# mount: {cl.mnt}', flush=True)

def run(path, label):
    t = subprocess.run([BENCH, path], capture_output=True, text=True)
    tot = None
    for line in t.stdout.splitlines():
        if line.startswith('TOTAL'):
            tot = float(line.split(',')[1])
    gran = sum(1 for l in t.stdout.splitlines() if 'granules with _1KM' in l)
    ng = ''
    for l in t.stdout.splitlines():
        if 'granules with _1KM' in l:
            ng = l.strip('# ').strip()
    print(f'  {label}: TOTAL={tot}  [{ng}]', flush=True)
    return tot

def sha(p, bs=1 << 24):
    h = hashlib.sha256()
    with open(p, 'rb') as f:
        while True:
            b = f.read(bs)
            if not b:
                break
            h.update(b)
    return h.hexdigest()

try:
    dst = f'{cl.mnt}/granule.h5'
    print('# staging granule through clio-fs ...', flush=True)
    t0 = time.time()
    rc = subprocess.run(['cp', GRAN, dst]).returncode
    stage_s = time.time() - t0
    print(f'# stage: rc={rc} in {stage_s:.0f}s', flush=True)

    print('# verifying staged bytes (the check part 18 lacked) ...', flush=True)
    a = sha(GRAN)
    b = sha(dst)
    same = (a == b)
    print(f'#   source sha {a[:32]}')
    print(f'#   staged sha {b[:32]}')
    print(f'#   BYTE-EXACT: {same}', flush=True)
    print(f'#   sizes: {os.path.getsize(GRAN)} vs {os.path.getsize(dst)}')

    print('\nphase,rep,seconds')
    for r in range(1, REPS + 1):
        print(f'direct,{r},{run(GRAN, f"direct rep{r}")}')
    for r in range(1, REPS + 1):
        print(f'cliofs,{r},{run(dst, f"cliofs rep{r}")}')
    json.dump({'byte_exact': same, 'stage_s': stage_s},
              open(os.path.join(OUT, 'terra_result.json'), 'w'))
finally:
    try:
        cl.down(graceful=False)
    except Exception as e:
        print(f'# teardown: {e}')
print('GVR-TERRA-DONE')
