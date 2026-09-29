"""Why is block 13 incongruent? Ask MODIS's own 16 emissive bands.

MOD35/MOD06 need Earthdata Login credentials this environment does not have
(both LAADS endpoints redirect to urs.earthdata.nasa.gov OAuth). But the fusion
granule carries EV_1KM_Emissive in full -- all 16 bands, including the exact
pairs MOD35's cloud tests are built on -- so the question can be attacked from
inside the data already on disk.

Two analyses, both per block:

1. SPECTRAL COHERENCE WITHIN ONE INSTRUMENT. Run the part-12 coherence test on
   MODIS alone: rank-transform all 16 bands on the block grid and take
   C16 = lambda1/16. One instrument, one footprint, one geolocation, one
   resampling -- every cross-sensor confound removed. If block 13's five-sensor
   incongruence is a property of the SCENE, MODIS's own bands should disagree
   there too. If C16 is high while C5 is low, the scene is spectrally simple and
   the disagreement lives in the cross-sensor comparison instead.

2. MOD35-STYLE CLOUD DIAGNOSTICS from the emissive bands:
      BT31                 11.03 um window -- cold means high cloud
      BT31 - BT32          split window -- thin cirrus / moisture
      BT29 - BT31          8.55-11.03 -- cloud phase, also dust
      BT31 - BT35          11.03-13.94 -- CO2, high cloud
      heterogeneity        local std of BT31 -- broken vs uniform scene
   These are the discriminators MOD35 itself uses; what is missing is its
   thresholds, its ancillary surface data and its clear-sky restoral logic, so
   what comes out is a PROXY and is labelled as one, never as a cloud mask.

Brightness temperature is the inverse Planck in wavelength form,
    T = c2 / (lambda * ln(1 + c1 / (lambda^5 * L)))
with L in W/m^2/um/sr, which is the unit EV_1KM_Emissive carries.

Usage:
    python3 bin/tf_modis_spectral.py           # all 32 blocks
    TF_BLKS=13,3 python3 bin/tf_modis_spectral.py
"""
import netCDF4, numpy as np, json, os, sys, time
sys.path.insert(0, os.path.expanduser('~/src/TerraFusion/pytaf'))
import pytaf

F = os.environ.get(
    'TF_GRANULE',
    '/mnt/common/datasets-staging/TERRA_BF_L1B_O10204_20011118010522_F000_V001.h5')
RES = float(os.environ.get('TF_RES', '0.02')); PAD = 0.05
MAXR = 3000.0
C1 = 1.191042e8   # W um^4 / (m^2 sr)
C2 = 1.4387752e4  # um K

# MODIS emissive band central wavelengths, um, in EV_1KM_Emissive order.
BANDS = [20, 21, 22, 23, 24, 25, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36]
WL = {20: 3.750, 21: 3.959, 22: 3.959, 23: 4.050, 24: 4.465, 25: 4.515,
      27: 6.715, 28: 7.325, 29: 8.550, 30: 9.730, 31: 11.030, 32: 12.020,
      33: 13.335, 34: 13.635, 35: 13.935, 36: 14.235}
IDX = {b: i for i, b in enumerate(BANDS)}

blocks = json.load(open('aster_blocks.json'))
want = os.environ.get('TF_BLKS')
want = [int(x) for x in want.split(',')] if want else list(range(len(blocks)))


def bt(L, lam):
    """Inverse Planck; non-positive radiance -> NaN."""
    L = np.asarray(L, 'f8')
    out = np.full(L.shape, np.nan)
    m = np.isfinite(L) & (L > 0)
    out[m] = C2 / (lam * np.log1p(C1 / (lam ** 5 * L[m])))
    return out


def vmask(var, a):
    m = np.isfinite(a)
    vmin = getattr(var, 'valid_min', None); vmax = getattr(var, 'valid_max', None)
    if vmin is not None: m &= (a >= float(vmin))
    if vmax is not None: m &= (a <= float(vmax))
    fv = getattr(var, '_FillValue', None)
    if fv is not None: m &= (a != float(fv))
    return m


def ok(la, lo):
    return (np.isfinite(la) & np.isfinite(lo) & (np.abs(la) <= 90) &
            (np.abs(lo) <= 180) & ((la != 0) | (lo != 0)))


def regrid(sla, slo, sv, tla, tlo, r=MAXR):
    nS = sla.size; nT = tla.size
    sL = sla.reshape(1, -1).copy(); sO = slo.reshape(1, -1).copy()
    tL = tla.reshape(1, -1).copy(); tO = tlo.reshape(1, -1).copy()
    nn = np.full(nT, -1, np.int32); nd = np.zeros((1, nT))
    pytaf.find_nn_block_index(sL, sO, nS, tL, tO, nn, nd, nT, r)
    tv = np.full((1, nT), np.nan)
    pytaf.interpolate_nn(sv.reshape(1, -1).copy(), tv, nn, nT)
    o = tv.ravel().copy(); o[nn < 0] = np.nan
    return o


def rankz(a):
    out = np.full(a.shape, np.nan); m = np.isfinite(a)
    if m.sum() < 10: return out
    r = np.empty(m.sum()); r[np.argsort(a[m], kind='stable')] = np.arange(m.sum())
    out[m] = (r - r.mean()) / (r.std() if r.std() > 0 else 1)
    return out


# ---- load every emissive band once, over the strip --------------------------
d = netCDF4.Dataset(F)
LA0 = min(b['lat0'] for b in blocks) - PAD; LA1 = max(b['lat1'] for b in blocks) + PAD
LO0 = min(b['lon0'] for b in blocks) - PAD; LO1 = max(b['lon1'] for b in blocks) + PAD
t0 = time.time()
mla = []; mlo = []; mv = []
for gn, g in d['MODIS'].groups.items():
    if '_1KM' not in g.groups: continue
    G = g['_1KM']['Geolocation']
    la = np.asarray(G['Latitude'][:], 'f8'); lo = np.asarray(G['Longitude'][:], 'f8')
    m = ok(la, lo) & (la >= LA0) & (la <= LA1) & (lo >= LO0) & (lo <= LO1)
    if not m.any(): continue
    EV = g['_1KM']['Data_Fields']['EV_1KM_Emissive']
    cube = np.asarray(EV[:], 'f8')                     # (16, ny, nx)
    good = np.ones(m.shape, bool)
    for i in range(len(BANDS)):
        good &= vmask(EV, cube[i])
    sel = m & good
    if not sel.any(): continue
    mla.append(la[sel]); mlo.append(lo[sel])
    mv.append(np.vstack([cube[i][sel] for i in range(len(BANDS))]))
LAT = np.concatenate(mla); LON = np.concatenate(mlo)
VAL = np.hstack(mv)                                     # (16, npts)
print(f'# {VAL.shape[1]} MODIS pixels with all 16 bands valid, '
      f'read {time.time()-t0:.1f}s')
TB = np.vstack([bt(VAL[i], WL[b]) for i, b in enumerate(BANDS)])
for i, b in enumerate(BANDS):
    v = TB[i][np.isfinite(TB[i])]
    print(f'#   band {b:2d}  {WL[b]:6.3f} um   BT {v.min():6.1f} - {v.max():6.1f} K')

# ---- per block ---------------------------------------------------------------
rows = []
for i in want:
    b = blocks[i]
    la = np.arange(b['lat0'], b['lat1'] + RES, RES)
    lo = np.arange(b['lon0'], b['lon1'] + RES, RES)
    TLA, TLO = np.meshgrid(la, lo, indexing='ij')
    tla = np.ascontiguousarray(TLA.ravel()); tlo = np.ascontiguousarray(TLO.ravel())
    shape = TLA.shape
    m = ((LAT >= b['lat0'] - PAD) & (LAT <= b['lat1'] + PAD) &
         (LON >= b['lon0'] - PAD) & (LON <= b['lon1'] + PAD))
    if m.sum() < 50: continue
    sla = np.ascontiguousarray(LAT[m]); slo = np.ascontiguousarray(LON[m])
    fields = np.vstack([regrid(sla.copy(), slo.copy(),
                               np.ascontiguousarray(TB[k][m]), tla, tlo)
                        for k in range(len(BANDS))])
    good = np.all(np.isfinite(fields), axis=0)
    if good.sum() < 50: continue

    # 1. spectral coherence across MODIS's own 16 bands
    M = np.vstack([rankz(fields[k]) for k in range(len(BANDS))])[:, good]
    for r in range(M.shape[0]):
        s = M[r].std(); M[r] = (M[r] - M[r].mean()) / (s if s > 0 else 1)
    R = np.corrcoef(M)
    w, v = np.linalg.eigh(R); j = int(np.argmax(w))
    sign = np.sign(v[:, j]); sign[sign == 0] = 1
    Rs = np.corrcoef(M * sign[:, None])
    ws, _ = np.linalg.eigh(Rs)
    C16 = float(ws.max() / len(BANDS))

    # 2. MOD35-style diagnostics
    g31 = fields[IDX[31]]; g32 = fields[IDX[32]]
    g29 = fields[IDX[29]]; g35 = fields[IDX[35]]
    # BT20 - BT31 is MOD35's daytime snow/cloud discriminator. At 3.75 um a
    # water cloud REFLECTS sunlight, inflating its apparent BT well above the
    # 11 um value; snow is dark at 3.7 um and gives a small or negative
    # difference. The overpass is 10:32 local solar time, so the solar term is
    # present.
    g20 = fields[IDX[20]]
    het = np.full(shape, np.nan)
    A = g31.reshape(shape)
    for r in range(1, shape[0]-1):
        for c in range(1, shape[1]-1):
            w3 = A[r-1:r+2, c-1:c+2]
            if np.isfinite(w3).sum() >= 5: het[r, c] = np.nanstd(w3)
    rows.append(dict(
        blk=i, ncell=int(good.sum()),
        C16=C16,
        bt31_mean=float(np.nanmean(g31[good])), bt31_std=float(np.nanstd(g31[good])),
        bt31_min=float(np.nanmin(g31[good])),
        btd_31_32=float(np.nanmean((g31 - g32)[good])),
        btd_29_31=float(np.nanmean((g29 - g31)[good])),
        btd_31_35=float(np.nanmean((g31 - g35)[good])),
        btd_20_31=float(np.nanmean((g20 - g31)[good])),
        btd_20_31_p90=float(np.nanpercentile((g20 - g31)[good], 90)),
        het_bt31=float(np.nanmean(het)),
    ))
    print(f'  blk {i:2d} cells={int(good.sum()):5d} C16={C16:.3f} '
          f'BT31={rows[-1]["bt31_mean"]:6.1f}K sd={rows[-1]["bt31_std"]:5.2f} '
          f'31-32={rows[-1]["btd_31_32"]:+5.2f} 29-31={rows[-1]["btd_29_31"]:+5.2f} '
          f'31-35={rows[-1]["btd_31_35"]:+6.2f} 20-31={rows[-1]["btd_20_31"]:+6.2f} '
          f'het={rows[-1]["het_bt31"]:5.2f}',
          flush=True)

json.dump(rows, open('modis_spectral.json', 'w'), indent=1)
print(f'\n# wrote modis_spectral.json ({len(rows)} blocks)')
