"""Render one block's five regridded sensor fields as PNGs.

Block 13 (42.62-43.32N, 141.52-142.58E, central Hokkaido) is the top
discrepancy under every configuration tried in parts 10-13, and the one block
whose low congruence survives the reanalysis control (residual z = -2.81, part
13). These images are what the congruence statistic is actually computed on.

Two views per run:

  tf_blk<N>_<SENSOR>.png   each sensor's regridded radiance in its own units
  tf_blk<N>_panel.png      all five on the COMMON rank scale, restricted to the
                           cells where all five are valid -- i.e. exactly the
                           matrix the congruence eigen-decomposition sees

The second is the one to read for congruence. The per-sensor images carry
different physical quantities in different units, so their colours are NOT
comparable across panels; the rank view removes that.

Colour: a single monotonic-lightness sequential ramp (cividis) for every panel,
never a rainbow, with no-data cells drawn in a neutral grey that appears in the
caption. Using one ramp everywhere keeps the reader comparing magnitude within
a panel rather than inferring identity from hue.

Usage:
    TF_BLK=13 python3 bin/tf_block_png.py        # -> tf_blk13_*.png
"""
import numpy as np, json, os, sys
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.colors import ListedColormap
import netCDF4
sys.path.insert(0, os.path.expanduser('~/src/TerraFusion/pytaf'))
import pytaf

BLK = int(os.environ.get('TF_BLK', '13'))
NPZ = os.environ.get('TF_NPZ', 'regrid_inputs_b31_WN.npz')
TAG = os.environ.get('TF_TAG', 'b31_WN')
OUT = os.environ.get('TF_OUT', '.')
RES = 0.02; PAD = 0.05
F = '/mnt/common/datasets-staging/TERRA_BF_L1B_O10204_20011118010522_F000_V001.h5'
MAXR = {'ASTER': 3000., 'MODIS': 3000., 'MISR': 3000.,
        'CERES': 25000., 'MOPITT': 25000.}
INST = ['ASTER', 'MODIS', 'MISR', 'CERES', 'MOPITT']
# What each panel actually shows, for honest titles.
DESC = {
    'ASTER': ('TIR ImageData10', '8.29 um', 'DN'),
    'MODIS': ('EV_1KM_Emissive band 31', '11.03 um', 'W/m2/um/sr'),
    'MISR':  ('AN Red_Radiance', '0.67 um', 'W/m2/um/sr'),
    'CERES': ('WN_Radiance', '8-12 um', 'W/m2/sr'),
    'MOPITT': ('MOPITTRadiances ch4', 'n/a', 'W/m2/sr'),
}
NODATA = '#d4d4d8'


def ok(la, lo):
    return (np.isfinite(la) & np.isfinite(lo) & (np.abs(la) <= 90) &
            (np.abs(lo) <= 180) & ((la != 0) | (lo != 0)))


def vmask(v, a):
    m = np.isfinite(a)
    for att, op in (('valid_min', np.greater_equal), ('valid_max', np.less_equal)):
        x = getattr(v, att, None)
        if x is not None: m &= op(a, float(x))
    vr = getattr(v, 'valid_range', None)
    if vr is not None and len(vr) == 2:
        m &= (a >= float(vr[0])) & (a <= float(vr[1]))
    fv = getattr(v, '_FillValue', None)
    if fv is not None: m &= (a != float(fv))
    return m


def regrid(sla, slo, sv, tla, tlo, r):
    nS = sla.size; nT = tla.size
    sL = sla.reshape(1, -1).copy(); sO = slo.reshape(1, -1).copy()
    tL = tla.reshape(1, -1).copy(); tO = tlo.reshape(1, -1).copy()
    nn = np.full(nT, -1, np.int32); nd = np.zeros((1, nT))
    pytaf.find_nn_block_index(sL, sO, nS, tL, tO, nn, nd, nT, r)
    tv = np.full((1, nT), np.nan)
    pytaf.interpolate_nn(sv.reshape(1, -1).copy(), tv, nn, nT)
    o = tv.ravel().copy(); o[nn < 0] = np.nan
    return o


D = np.load(NPZ)
B = json.load(open('aster_blocks.json'))[BLK]
CG = {r['blk']: r for r in json.load(open(f'congruence_{TAG}.json'))}
load = CG.get(BLK, {}).get('loadings', {})
C5 = CG.get(BLK, {}).get('congruence', float('nan'))

la = np.arange(B['lat0'], B['lat1'] + RES, RES)
lo = np.arange(B['lon0'], B['lon1'] + RES, RES)
TLA, TLO = np.meshgrid(la, lo, indexing='ij')
tla = np.ascontiguousarray(TLA.ravel()); tlo = np.ascontiguousarray(TLO.ravel())
shape = TLA.shape
extent = [lo[0], lo[-1], la[0], la[-1]]

f = {}
d = netCDF4.Dataset(F)
g = d['ASTER'][B['granule']]['TIR']; IM = g['ImageData10']
ala = np.asarray(g['Geolocation']['Latitude'][:], 'f8').ravel()
alo = np.asarray(g['Geolocation']['Longitude'][:], 'f8').ravel()
av = np.asarray(IM[:], 'f8'); am = ok(ala, alo) & vmask(IM, av).ravel()
av = av.ravel()
if am.sum() > 100:
    f['ASTER'] = regrid(ala[am].copy(), alo[am].copy(), av[am].copy(),
                        tla, tlo, MAXR['ASTER'])
for k in ['MODIS', 'MISR', 'CERES', 'MOPITT']:
    sla = D[k + '_lat']; slo = D[k + '_lon']; sv = D[k + '_val']
    m = ((sla >= B['lat0'] - PAD) & (sla <= B['lat1'] + PAD) &
         (slo >= B['lon0'] - PAD) & (slo <= B['lon1'] + PAD))
    if m.sum() >= 5:
        f[k] = regrid(sla[m].copy(), slo[m].copy(), sv[m].copy(),
                      tla, tlo, MAXR[k])

cmap = plt.get_cmap('cividis').copy(); cmap.set_bad(NODATA)
os.makedirs(OUT, exist_ok=True)

names = [k for k in INST if k in f]
common = np.all(np.vstack([np.isfinite(f[k]) for k in names]), axis=0)
print(f'# block {BLK}  {B["lat0"]:.2f}-{B["lat1"]:.2f}N  '
      f'{B["lon0"]:.2f}-{B["lon1"]:.2f}E   grid {shape[0]}x{shape[1]} '
      f'= {tla.size} cells, {int(common.sum())} with all five valid   C5={C5:.3f}')

# ---- one PNG per sensor, native units -------------------------------------
for k in names:
    a = f[k].reshape(shape)
    v = a[np.isfinite(a)]
    lo_p, hi_p = (np.percentile(v, [2, 98]) if v.size else (0, 1))
    fig, ax = plt.subplots(figsize=(5.6, 4.6), dpi=170)
    im = ax.imshow(np.ma.masked_invalid(a), origin='lower', extent=extent,
                   cmap=cmap, vmin=lo_p, vmax=hi_p, aspect='auto',
                   interpolation='nearest')
    field, wl, unit = DESC[k]
    ax.set_title(f'{k} — block {BLK}\n{field}'
                 + (f' ({wl})' if wl != 'n/a' else '')
                 + f'   loading {load.get(k, float("nan")):.2f}',
                 fontsize=10, pad=8)
    ax.set_xlabel('longitude (°E)', fontsize=9)
    ax.set_ylabel('latitude (°N)', fontsize=9)
    ax.tick_params(labelsize=8)
    cb = fig.colorbar(im, ax=ax, fraction=0.046, pad=0.03)
    cb.set_label(unit, fontsize=8); cb.ax.tick_params(labelsize=7)
    nan_pct = 100.0 * (~np.isfinite(a)).sum() / a.size
    ax.text(0.01, -0.17, f'grey = no neighbour within {MAXR[k]/1000:.0f} km '
                         f'({nan_pct:.0f}% of cells); colour range = 2nd-98th pct',
            transform=ax.transAxes, fontsize=7, color='#52525b')
    fig.tight_layout()
    p = os.path.join(OUT, f'tf_blk{BLK}_{k}.png')
    fig.savefig(p, bbox_inches='tight'); plt.close(fig)
    print(f'  wrote {p}   valid {100-nan_pct:5.1f}%  range [{v.min():.4g}, {v.max():.4g}]')

# ---- combined panel on the COMMON rank scale ------------------------------
fig, axes = plt.subplots(1, len(names), figsize=(3.05 * len(names), 4.0), dpi=170)
fig.subplots_adjust(top=0.78)
if len(names) == 1: axes = [axes]
for ax, k in zip(axes, names):
    a = np.full(f[k].shape, np.nan)
    v = f[k][common]
    r = np.empty(v.size); r[np.argsort(v, kind='stable')] = np.arange(v.size)
    a[common] = r / max(v.size - 1, 1)
    im = ax.imshow(np.ma.masked_invalid(a.reshape(shape)), origin='lower',
                   extent=extent, cmap=cmap, vmin=0, vmax=1, aspect='auto',
                   interpolation='nearest')
    ax.set_title(f'{k}\nloading {load.get(k, float("nan")):.2f}', fontsize=9)
    ax.set_xlabel('°E', fontsize=8)
    ax.tick_params(labelsize=7)
    if k != names[0]: ax.set_yticklabels([])
    else: ax.set_ylabel('°N', fontsize=8)
fig.suptitle(f'Block {BLK} ({B["lat0"]:.2f}–{B["lat1"]:.2f}°N, '
             f'{B["lon0"]:.2f}–{B["lon1"]:.2f}°E) — rank-transformed on the '
             f'{int(common.sum())} cells where all five sensors are valid '
             f'  ·  congruence C₅ = {C5:.3f}', fontsize=10, y=1.02)
cb = fig.colorbar(im, ax=axes, fraction=0.02, pad=0.015)
cb.set_label('within-block rank (0 = lowest, 1 = highest)', fontsize=8)
cb.ax.tick_params(labelsize=7)
p = os.path.join(OUT, f'tf_blk{BLK}_panel.png')
fig.savefig(p, bbox_inches='tight'); plt.close(fig)
print(f'  wrote {p}')
