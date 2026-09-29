"""Does the block congruence ranking correspond to a real weather pattern?

Parts 10-12 closed the "processing error" branch of CLAUDE.md's question for
this orbit: every sensor-level anomaly turned out to be band selection or
correct physics. That leaves the weather branch, and answering it needs data
from outside the granule.

This compares the per-block congruence C5 against NCEP/NCAR Reanalysis 1
surface fields at the analysis time nearest the overpass (2001-11-18 00Z; the
overpass is 01:05Z, 65 min later).

THE RESOLUTION CAVEAT IS THE WHOLE STORY HERE. R1 is a 2.5 degree grid -- about
275 km -- while an ASTER block is 0.7 x 1.0 degrees, roughly 70 km. A block is
therefore SMALLER THAN ONE GRID CELL, and the 32 blocks span 17 degrees of
latitude along a single track, which is about 7 grid rows. Neighbouring blocks
draw nearly the same reanalysis value, so a correlation computed over n=32 has
far fewer than 32 independent samples. The script reports the number of
distinct grid cells the blocks fall into, and repeats every correlation over
cell-averaged values so the inflated version can be compared against an honest
one.

What this CAN establish: whether the low-congruence blocks sit in a
synoptically distinct environment (stronger pressure or thermal gradient, more
moisture) than the high-congruence ones. What it CANNOT establish: anything
about structure inside a block.

Usage:  python3 bin/tf_reanalysis.py     # needs reanal/*.2001.nc
"""
import netCDF4, numpy as np, json, os, datetime as dt
from scipy.stats import spearmanr

TAG = os.environ.get('TF_TAG', 'b31_WN')
OVERPASS = dt.datetime(2001, 11, 18, 1, 5)
RE = os.environ.get('TF_REANAL', 'reanal')
FIELDS = {'slp': 'slp', 'air': 'air.sig995', 'pr_wtr': 'pr_wtr.eatm',
          'uwnd': 'uwnd.sig995', 'vwnd': 'vwnd.sig995'}

rows = json.load(open(f'congruence_{TAG}.json'))
B = json.load(open('aster_blocks.json'))

# ---- load the reanalysis slice nearest the overpass -------------------------
G = {}
for name, stem in FIELDS.items():
    d = netCDF4.Dataset(f'{RE}/{stem}.2001.nc')
    t = d['time']; tt = netCDF4.num2date(t[:], t.units)
    idx = int(np.argmin([abs((x - OVERPASS).total_seconds()) for x in tt]))
    lat = np.asarray(d['lat'][:], 'f8'); lon = np.asarray(d['lon'][:], 'f8')
    G[name] = dict(v=np.asarray(d[name][idx], 'f8'), lat=lat, lon=lon,
                   when=str(tt[idx]))
print(f"# reanalysis slice: {G['slp']['when']}  (overpass {OVERPASS}Z)")
print(f"# grid {G['slp']['lat'][1]-G['slp']['lat'][0]:+.1f} deg lat, "
      f"{G['slp']['lon'][1]-G['slp']['lon'][0]:+.1f} deg lon")


def bilin(g, la, lo):
    """Bilinear sample of a 2.5 deg field; lat descends, lon ascends 0..357.5."""
    lat, lon, v = g['lat'], g['lon'], g['v']
    lo = lo % 360.0
    i = np.clip(np.searchsorted(-lat, -la) - 1, 0, len(lat) - 2)
    j = np.clip(np.searchsorted(lon, lo) - 1, 0, len(lon) - 2)
    fy = (lat[i] - la) / (lat[i] - lat[i + 1])
    fx = (lo - lon[j]) / (lon[j + 1] - lon[j])
    return ((1-fy)*(1-fx)*v[i, j] + (1-fy)*fx*v[i, j+1] +
            fy*(1-fx)*v[i+1, j] + fy*fx*v[i+1, j+1])


def grad_mag(g, la, lo):
    """|grad| per 100 km, central differences on the native grid."""
    lat, lon, v = g['lat'], g['lon'], g['v']
    i = int(np.clip(np.searchsorted(-lat, -la) - 1, 1, len(lat) - 2))
    j = int(np.clip(np.searchsorted(lon, lo % 360.0) - 1, 1, len(lon) - 2))
    dy = (lat[i-1] - lat[i+1]) * 111.0
    dx = (lon[j+1] - lon[j-1]) * 111.0 * np.cos(np.radians(la))
    return float(np.hypot((v[i-1, j] - v[i+1, j]) / dy,
                          (v[i, j+1] - v[i, j-1]) / dx) * 100.0)


rec = []
for r in rows:
    b = B[r['blk']]
    la = (b['lat0'] + b['lat1']) / 2.0; lo = (b['lon0'] + b['lon1']) / 2.0
    u = bilin(G['uwnd'], la, lo); v = bilin(G['vwnd'], la, lo)
    cell = (int(np.argmin(np.abs(G['slp']['lat'] - la))),
            int(np.argmin(np.abs(G['slp']['lon'] - lo % 360))))
    rec.append(dict(blk=r['blk'], C=r['congruence'], weakest=r['weakest'],
                    lat=la, lon=lo, cell=cell,
                    slp=float(bilin(G['slp'], la, lo)) / 100.0,
                    slp_grad=grad_mag(G['slp'], la, lo) / 100.0,   # hPa/100km
                    air=float(bilin(G['air'], la, lo)) - 273.15,
                    air_grad=grad_mag(G['air'], la, lo),           # K/100km
                    pr_wtr=float(bilin(G['pr_wtr'], la, lo)),
                    wspd=float(np.hypot(u, v))))

cells = sorted({r['cell'] for r in rec})
print(f"# {len(rec)} blocks fall into {len(cells)} distinct 2.5 deg cells "
      f"-- effective sample size, not 32\n")

VARS = ['slp', 'slp_grad', 'air', 'air_grad', 'pr_wtr', 'wspd']
C = np.array([r['C'] for r in rec])
print(f"{'variable':10} {'rho(block,n=32)':>16} {'p':>8} | "
      f"{'rho(cell-avg)':>14} {'p':>8} {'n':>3}")
for k in VARS:
    x = np.array([r[k] for r in rec])
    s = spearmanr(x, C)
    ca, cc = [], []
    for c in cells:
        m = [i for i, r in enumerate(rec) if r['cell'] == c]
        ca.append(np.mean([rec[i][k] for i in m])); cc.append(np.mean(C[m]))
    s2 = spearmanr(ca, cc)
    print(f"{k:10} {s.statistic:+16.3f} {s.pvalue:8.3f} | "
          f"{s2.statistic:+14.3f} {s2.pvalue:8.3f} {len(ca):3d}")

o = sorted(rec, key=lambda r: r['C'])
print(f"\n{'':4}{'blk':>4} {'lat':>5} {'lon':>6} {'C5':>6} {'SLP':>7} "
      f"{'|dP|':>6} {'T':>6} {'|dT|':>6} {'PW':>5} {'wspd':>5}")
for lab, sel in (('LOW ', o[:5]), ('HIGH', o[-5:])):
    for r in sel:
        print(f"{lab} {r['blk']:4d} {r['lat']:5.1f} {r['lon']:6.1f} {r['C']:6.3f} "
              f"{r['slp']:7.1f} {r['slp_grad']:6.2f} {r['air']:6.1f} "
              f"{r['air_grad']:6.2f} {r['pr_wtr']:5.1f} {r['wspd']:5.1f}")
json.dump(rec, open(f'reanalysis_{TAG}.json', 'w'), indent=1)
print("\n# |dP| hPa/100km, |dT| K/100km, PW kg/m2, wspd m/s")
