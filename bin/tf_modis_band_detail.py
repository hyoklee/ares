"""Per-band detail of the 16-band coherence, for one block.

Part 14 reduced each block to a single number, C16 = lambda1/16, and found
block 13 second-lowest of 32. This opens that number up: which of MODIS's 16
emissive bands participate in the block's common mode, and which stand apart.

It is the 16-band analogue of the per-sensor loadings that drove parts 10-12,
and it answers a question C16 alone cannot: whether a low value is diffuse
(every band slightly out of step, i.e. weak signal) or structured (a specific
subset decoupling, i.e. a physical mechanism).

The bands split into three physical families, and the output groups them so the
answer is readable:

    3.7-4.5 um   20,21,22,23,24,25   solar-contaminated by day; 21/22 share a
                                     wavelength (21 is the high-gain fire band)
    6.7-9.7 um   27,28,29,30         water vapour (27,28), window (29), ozone (30)
    11-14.2 um   31,32,33,34,35,36   window (31,32) then CO2 slicing, which sees
                                     progressively higher in the atmosphere

Writes a per-band loading table, the family-mean correlation structure, and a
16-panel BT image.

Usage:
    TF_BLK=3  python3 bin/tf_modis_band_detail.py
    TF_BLK=13 python3 bin/tf_modis_band_detail.py
"""
import netCDF4, numpy as np, json, os, sys
import matplotlib; matplotlib.use('Agg')
import matplotlib.pyplot as plt
sys.path.insert(0, os.path.expanduser('~/src/TerraFusion/pytaf'))
import pytaf

F = os.environ.get(
    'TF_GRANULE',
    '/mnt/common/datasets-staging/TERRA_BF_L1B_O10204_20011118010522_F000_V001.h5')
BLK = int(os.environ.get('TF_BLK', '3'))
OUT = os.environ.get('TF_OUT', '.')
RES = 0.02; PAD = 0.05; MAXR = 3000.0
C1 = 1.191042e8; C2 = 1.4387752e4
BANDS = [20, 21, 22, 23, 24, 25, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36]
WL = {20: 3.750, 21: 3.959, 22: 3.959, 23: 4.050, 24: 4.465, 25: 4.515,
      27: 6.715, 28: 7.325, 29: 8.550, 30: 9.730, 31: 11.030, 32: 12.020,
      33: 13.335, 34: 13.635, 35: 13.935, 36: 14.235}
FAMILY = {b: ('3.7-4.5 solar' if b <= 25 else
              ('6.7-9.7 wv/win' if b <= 30 else '11-14.2 win/CO2'))
          for b in BANDS}
NODATA = '#d4d4d8'


def bt(L, lam):
    L = np.asarray(L, 'f8'); o = np.full(L.shape, np.nan)
    m = np.isfinite(L) & (L > 0)
    o[m] = C2 / (lam * np.log1p(C1 / (lam ** 5 * L[m])))
    return o


def vmask(v, a):
    m = np.isfinite(a)
    for att, op in (('valid_min', np.greater_equal), ('valid_max', np.less_equal)):
        x = getattr(v, att, None)
        if x is not None: m &= op(a, float(x))
    fv = getattr(v, '_FillValue', None)
    if fv is not None: m &= (a != float(fv))
    return m


def ok(la, lo):
    return (np.isfinite(la) & np.isfinite(lo) & (np.abs(la) <= 90) &
            (np.abs(lo) <= 180) & ((la != 0) | (lo != 0)))


def rg(sla, slo, sv, tla, tlo):
    nS = sla.size; nT = tla.size
    sL = sla.reshape(1, -1).copy(); sO = slo.reshape(1, -1).copy()
    tL = tla.reshape(1, -1).copy(); tO = tlo.reshape(1, -1).copy()
    nn = np.full(nT, -1, np.int32); nd = np.zeros((1, nT))
    pytaf.find_nn_block_index(sL, sO, nS, tL, tO, nn, nd, nT, MAXR)
    tv = np.full((1, nT), np.nan)
    pytaf.interpolate_nn(sv.reshape(1, -1).copy(), tv, nn, nT)
    o = tv.ravel().copy(); o[nn < 0] = np.nan
    return o


def rankz(a):
    o = np.full(a.shape, np.nan); m = np.isfinite(a)
    if m.sum() < 10: return o
    r = np.empty(m.sum()); r[np.argsort(a[m], kind='stable')] = np.arange(m.sum())
    o[m] = (r - r.mean()) / (r.std() if r.std() > 0 else 1)
    return o


b = json.load(open('aster_blocks.json'))[BLK]
CG = {r['blk']: r for r in json.load(open('congruence_b31_WN.json'))}
C5 = CG.get(BLK, {}).get('congruence', float('nan'))
la = np.arange(b['lat0'], b['lat1'] + RES, RES)
lo = np.arange(b['lon0'], b['lon1'] + RES, RES)
TLA, TLO = np.meshgrid(la, lo, indexing='ij')
tla = np.ascontiguousarray(TLA.ravel()); tlo = np.ascontiguousarray(TLO.ravel())
shape = TLA.shape; extent = [lo[0], lo[-1], la[0], la[-1]]

d = netCDF4.Dataset(F)
mla = []; mlo = []; mv = []
for gn, g in d['MODIS'].groups.items():
    if '_1KM' not in g.groups: continue
    G = g['_1KM']['Geolocation']
    gla = np.asarray(G['Latitude'][:], 'f8'); glo = np.asarray(G['Longitude'][:], 'f8')
    m = (ok(gla, glo) & (gla >= b['lat0'] - PAD) & (gla <= b['lat1'] + PAD) &
         (glo >= b['lon0'] - PAD) & (glo <= b['lon1'] + PAD))
    if not m.any(): continue
    EV = g['_1KM']['Data_Fields']['EV_1KM_Emissive']
    cube = np.asarray(EV[:], 'f8')
    good = np.ones(m.shape, bool)
    for i in range(16): good &= vmask(EV, cube[i])
    sel = m & good
    if not sel.any(): continue
    mla.append(gla[sel]); mlo.append(glo[sel])
    mv.append(np.vstack([cube[i][sel] for i in range(16)]))
LAT = np.concatenate(mla); LON = np.concatenate(mlo); VAL = np.hstack(mv)
TB = np.vstack([bt(VAL[i], WL[bd]) for i, bd in enumerate(BANDS)])
fields = np.vstack([rg(np.ascontiguousarray(LAT), np.ascontiguousarray(LON),
                       np.ascontiguousarray(TB[i]), tla, tlo)
                    for i in range(16)])
good = np.all(np.isfinite(fields), axis=0)

M = np.vstack([rankz(fields[i]) for i in range(16)])[:, good]
for r in range(16):
    s = M[r].std(); M[r] = (M[r] - M[r].mean()) / (s if s > 0 else 1)
R = np.corrcoef(M)
w, v = np.linalg.eigh(R); j = int(np.argmax(w))
sign = np.sign(v[:, j]); sign[sign == 0] = 1
Ms = M * sign[:, None]
Rs = np.corrcoef(Ms); ws, vs = np.linalg.eigh(Rs); j2 = int(np.argmax(ws))
C16 = float(ws[j2] / 16)
loads = {BANDS[i]: float(abs(vs[i, j2])) for i in range(16)}

print(f'# block {BLK}  {b["lat0"]:.2f}-{b["lat1"]:.2f}N {b["lon0"]:.2f}-{b["lon1"]:.2f}E'
      f'   {int(good.sum())} cells   C5={C5:.3f}   C16={C16:.3f}')
print(f'\n{"band":>5} {"um":>7} {"family":>16} {"BT mean":>8} {"sd":>6} '
      f'{"loading":>8} {"sign":>5}')
for i, bd in enumerate(BANDS):
    a = fields[i][good]
    print(f'{bd:5d} {WL[bd]:7.3f} {FAMILY[bd]:>16} {a.mean():8.1f} {a.std():6.2f} '
          f'{loads[bd]:8.3f} {int(sign[i]):5d}')

fams = sorted(set(FAMILY.values()))
print(f'\n# mean |rho| within / between families')
print(f'{"":16} ' + ' '.join(f'{f:>16}' for f in fams))
for fa in fams:
    ia = [i for i, bd in enumerate(BANDS) if FAMILY[bd] == fa]
    row = []
    for fb in fams:
        ib = [i for i, bd in enumerate(BANDS) if FAMILY[bd] == fb]
        vals = [abs(R[p, q]) for p in ia for q in ib if p != q]
        row.append(np.mean(vals) if vals else float('nan'))
    print(f'{fa:>16} ' + ' '.join(f'{x:16.3f}' for x in row))
print(f'\n# mean loading by family: ' + '  '.join(
    f'{f}={np.mean([loads[bd] for bd in BANDS if FAMILY[bd]==f]):.3f}' for f in fams))

json.dump(dict(blk=BLK, C5=C5, C16=C16, ncell=int(good.sum()),
               loadings=loads, signs={str(BANDS[i]): int(sign[i]) for i in range(16)},
               bt_mean={str(BANDS[i]): float(fields[i][good].mean()) for i in range(16)},
               bt_std={str(BANDS[i]): float(fields[i][good].std()) for i in range(16)}),
          open(f'modis_band_detail_blk{BLK}.json', 'w'), indent=1)

# ---- 16-panel BT image ------------------------------------------------------
os.makedirs(OUT, exist_ok=True)
cmap = plt.get_cmap('cividis').copy(); cmap.set_bad(NODATA)
fig, axes = plt.subplots(4, 4, figsize=(13.2, 12.0), dpi=150)
for i, bd in enumerate(BANDS):
    ax = axes[i // 4, i % 4]
    A = fields[i].reshape(shape); vv = A[np.isfinite(A)]
    lo_p, hi_p = np.percentile(vv, [2, 98])
    im = ax.imshow(np.ma.masked_invalid(A), origin='lower', extent=extent,
                   cmap=cmap, vmin=lo_p, vmax=hi_p, aspect='auto',
                   interpolation='nearest')
    ax.set_title(f'band {bd} — {WL[bd]:.2f} µm\nloading {loads[bd]:.2f}, '
                 f'sd {vv.std():.2f} K', fontsize=8)
    ax.tick_params(labelsize=6)
    if i % 4: ax.set_yticklabels([])
    if i // 4 < 3: ax.set_xticklabels([])
    cb = fig.colorbar(im, ax=ax, fraction=0.046, pad=0.02)
    cb.ax.tick_params(labelsize=5)
fig.suptitle(f'Block {BLK} ({b["lat0"]:.2f}–{b["lat1"]:.2f}°N, '
             f'{b["lon0"]:.2f}–{b["lon1"]:.2f}°E) — all 16 MODIS emissive bands '
             f'as brightness temperature\n'
             f'C₁₆ = {C16:.3f} across the {int(good.sum())} cells where all 16 are '
             f'valid   ·   five-sensor C₅ = {C5:.3f}', fontsize=11, y=0.995)
fig.tight_layout(rect=[0, 0, 1, 0.97])
p = os.path.join(OUT, f'tf_blk{BLK}_16band.png')
fig.savefig(p, bbox_inches='tight'); plt.close(fig)
print(f'\n# wrote {p}')
