"""Is MOPITT measuring something else, or measuring nothing?

Part 11 eliminated three explanations for MOPITT's persistently low loading on
the five-sensor common mode -- spectral band, target-grid resolution, per-block
support -- and left one hypothesis untested: that MOPITT retrieves CO, whose
spatial structure need not follow the thermal field, so a low loading is correct
physics rather than a defect.

This discriminates it WITHOUT leaving the data already on disk. MOPITT's four
populated channel indices share footprints, geolocation and search radius, and
differ only in what they measure. So:

  * MOPITT channels agree with EACH OTHER but not with ASTER/MODIS
        -> MOPITT carries coherent structure that is simply not the thermal
           common mode. Supports "different quantity".
  * MOPITT channels do not agree with each other either
        -> the regridded MOPITT field is noise-dominated at this scale, and the
           low loading says nothing about CO.

The comparison that matters is within-MOPITT vs MOPITT-to-thermal, measured the
same way (Spearman on the same target cells), so the two numbers are directly
comparable.

CAVEAT the output repeats: shared geolocation means high inter-channel
agreement does NOT rule out a geolocation error -- it rules out noise.

Usage:  python3 bin/tf_mopitt_coherence.py     # writes mopitt_coherence.json
"""
import numpy as np, json, os, sys, time
sys.path.insert(0, os.path.expanduser('~/src/TerraFusion/pytaf'))
import pytaf

RES = float(os.environ.get('TF_RES', '0.02')); PAD = 0.05
MAXR_MOPITT = 25000.0; MAXR_FINE = 3000.0
# Channel index -> the npz that carries it as MOPITT_*. m40 lives in the base
# b31_WN build; 5/6/7 were built by part 11's channel control.
CHAN_NPZ = {4: 'regrid_inputs_b31_WN.npz',
            5: 'regrid_inputs_b31_WN_m50.npz',
            6: 'regrid_inputs_b31_WN_m60.npz',
            7: 'regrid_inputs_b31_WN_m70.npz'}
# Thermal references. ASTER is read per-block from its own granule by
# tf_congruence.py and is not in the strip-wide npz, so the reference pair here
# is MODIS band 31 (11.03 um) and CERES WN (8-12 um) -- both thermal, both
# strong loaders on the common mode, and each with its own search radius.
REF = {'MODIS': MAXR_FINE, 'CERES': MAXR_MOPITT}

blocks = json.load(open('aster_blocks.json'))


def regrid(sla, slo, sval, tla, tlo, maxr):
    nS = sla.size; nT = tla.size
    sL = sla.reshape(1, -1).copy(); sO = slo.reshape(1, -1).copy()
    tL = tla.reshape(1, -1).copy(); tO = tlo.reshape(1, -1).copy()
    nnid = np.full(nT, -1, dtype=np.int32); nnd = np.zeros((1, nT))
    pytaf.find_nn_block_index(sL, sO, nS, tL, tO, nnid, nnd, nT, maxr)
    tv = np.full((1, nT), np.nan)
    pytaf.interpolate_nn(sval.reshape(1, -1).copy(), tv, nnid, nT)
    out = tv.ravel().copy(); out[nnid < 0] = np.nan
    return out


def rankz(a):
    out = np.full(a.shape, np.nan); m = np.isfinite(a)
    if m.sum() < 10: return out
    r = np.empty(m.sum()); r[np.argsort(a[m], kind='stable')] = np.arange(m.sum())
    out[m] = (r - r.mean()) / (r.std() if r.std() > 0 else 1)
    return out


D = {c: np.load(p) for c, p in CHAN_NPZ.items()}
base = D[4]

t0 = time.time(); rows = []
for i, b in enumerate(blocks):
    la = np.arange(b['lat0'], b['lat1'] + RES, RES)
    lo = np.arange(b['lon0'], b['lon1'] + RES, RES)
    TLA, TLO = np.meshgrid(la, lo, indexing='ij')
    tla = np.ascontiguousarray(TLA.ravel()); tlo = np.ascontiguousarray(TLO.ravel())

    f = {}
    for c, Dc in D.items():
        sla = Dc['MOPITT_lat']; slo = Dc['MOPITT_lon']; sv = Dc['MOPITT_val']
        m = ((sla >= b['lat0'] - PAD) & (sla <= b['lat1'] + PAD) &
             (slo >= b['lon0'] - PAD) & (slo <= b['lon1'] + PAD))
        if m.sum() >= 5:
            f[f'MOPITT{c}'] = regrid(sla[m].copy(), slo[m].copy(), sv[m].copy(),
                                     tla, tlo, MAXR_MOPITT)
    for k, rad in REF.items():
        sla = base[k + '_lat']; slo = base[k + '_lon']; sv = base[k + '_val']
        m = ((sla >= b['lat0'] - PAD) & (sla <= b['lat1'] + PAD) &
             (slo >= b['lon0'] - PAD) & (slo <= b['lon1'] + PAD))
        if m.sum() >= 5:
            f[k] = regrid(sla[m].copy(), slo[m].copy(), sv[m].copy(),
                          tla, tlo, rad)

    names = [k for k in f]
    if len(names) < 4: continue
    M = np.vstack([rankz(f[k]) for k in names])
    good = np.all(np.isfinite(M), axis=0)
    if good.sum() < 50: continue
    M = M[:, good]
    for r in range(M.shape[0]):
        s = M[r].std(); M[r] = (M[r] - M[r].mean()) / (s if s > 0 else 1)
    R = np.corrcoef(M)
    idx = {k: q for q, k in enumerate(names)}
    mop = [k for k in names if k.startswith('MOPITT')]

    within = [abs(R[idx[a], idx[bq]])
              for q, a in enumerate(mop) for bq in mop[q + 1:]]
    cross = [abs(R[idx[a], idx[k]]) for a in mop for k in REF if k in idx]
    ref = ([abs(R[idx['MODIS'], idx['CERES']])]
           if 'MODIS' in idx and 'CERES' in idx else [])
    rows.append(dict(blk=i, ncell=int(good.sum()), nchan=len(mop),
                     within_mopitt=float(np.mean(within)) if within else None,
                     mopitt_vs_thermal=float(np.mean(cross)) if cross else None,
                     modis_vs_ceres=float(ref[0]) if ref else None))

print(f'# {len(rows)} blocks, {time.time()-t0:.1f}s')
w = np.array([r['within_mopitt'] for r in rows if r['within_mopitt'] is not None])
x = np.array([r['mopitt_vs_thermal'] for r in rows if r['mopitt_vs_thermal'] is not None])
a = np.array([r['modis_vs_ceres'] for r in rows if r['modis_vs_ceres'] is not None])
print(f'\n{"quantity":34} {"min":>6} {"median":>7} {"max":>6}')
print(f'{"|rho| MOPITT channel vs channel":34} {w.min():6.3f} {np.median(w):7.3f} {w.max():6.3f}')
print(f'{"|rho| MOPITT vs MODIS/CERES":34} {x.min():6.3f} {np.median(x):7.3f} {x.max():6.3f}')
print(f'{"|rho| MODIS vs CERES (control)":34} {a.min():6.3f} {np.median(a):7.3f} {a.max():6.3f}')
print(f'\n# blocks where within-MOPITT exceeds MOPITT-vs-thermal: '
      f'{int((w > x).sum())}/{len(w)}')
print(f'# ratio of medians: {np.median(w)/np.median(x):.2f}x')
json.dump(rows, open('mopitt_coherence.json', 'w'), indent=1)
