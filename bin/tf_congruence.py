"""Multi-sensor congruence per block.

Replaces the pairwise z-score RMS of part 2 with:
  - Spearman (rank) correlation, because different wavelengths relate
    monotonically, not linearly;
  - sign alignment against the leading eigenvector, so anti-correlated sensors
    (ASTER TIR vs MISR red over cloud) count as CONGRUENT structure;
  - congruence C = lambda1/n, the variance fraction in the leading common mode;
  - per-sensor loadings, which separate "one sensor is wrong" (processing error)
    from "all sensors see structure" (weather).
"""
import numpy as np, json, os, sys, time
sys.path.insert(0,os.path.expanduser('~/src/TerraFusion/pytaf'))
import pytaf
D=np.load('regrid_inputs.npz', allow_pickle=True); SRC={k:D[k] for k in D.files}
blocks=json.load(open('aster_blocks.json'))
import netCDF4
F='/mnt/common/datasets-staging/TERRA_BF_L1B_O10204_20011118010522_F000_V001.h5'
d=netCDF4.Dataset(F)
RES=0.02; PAD=0.05
# Per-sensor search radius matched to NATIVE FOOTPRINT. A uniform 3 km radius
# leaves MOPITT (22 km footprint, 6-19 pixels/block) covering almost no target
# cells, so requiring all five sensors at the same cell yields zero cells.
# Extrapolating a 1 km sensor 25 km would be wrong; covering 25 km with a 22 km
# footprint is not.
MAXR={'ASTER':3000.0,'MODIS':3000.0,'MISR':3000.0,'CERES':25000.0,'MOPITT':25000.0}
INST=['ASTER','MODIS','MISR','CERES','MOPITT']

def vmask(var,a):
    m=np.isfinite(a)
    for att,op in (('valid_min',np.greater_equal),('valid_max',np.less_equal)):
        v=getattr(var,att,None)
        if v is not None: m &= op(a,float(v))
    fv=getattr(var,'_FillValue',None)
    if fv is not None: m &= (a!=float(fv))
    return m
def ok(la,lo): return np.isfinite(la)&np.isfinite(lo)&(np.abs(la)<=90)&(np.abs(lo)<=180)&((la!=0)|(lo!=0))

def regrid(sla,slo,sval,tla,tlo,maxr):
    nS=sla.size; nT=tla.size
    sL=sla.reshape(1,-1).copy(); sO=slo.reshape(1,-1).copy()
    tL=tla.reshape(1,-1).copy(); tO=tlo.reshape(1,-1).copy()
    nnid=np.full(nT,-1,dtype=np.int32); nnd=np.zeros((1,nT))
    pytaf.find_nn_block_index(sL,sO,nS,tL,tO,nnid,nnd,nT,maxr)
    tv=np.full((1,nT),np.nan); pytaf.interpolate_nn(sval.reshape(1,-1).copy(),tv,nnid,nT)
    out=tv.ravel().copy(); out[nnid<0]=np.nan
    return out

def rankz(a):
    """rank-transform (Spearman basis), NaN-preserving"""
    out=np.full(a.shape,np.nan); m=np.isfinite(a)
    if m.sum()<10: return out
    r=np.empty(m.sum()); r[np.argsort(a[m],kind='stable')]=np.arange(m.sum())
    out[m]=(r-r.mean())/(r.std() if r.std()>0 else 1)
    return out

def kendall_w(Z):
    """Kendall's W from sign-aligned fields. The statistic is defined on ACTUAL
    ranks 1..n per rater; feeding it standardised z-scores makes the numerator
    vanish against an m^2(n^3-n) denominator and W collapses to 0."""
    m,n=Z.shape
    if n<3: return np.nan
    R=np.empty_like(Z)
    for i in range(m):
        order=np.argsort(Z[i],kind='stable'); rk=np.empty(n)
        rk[order]=np.arange(1,n+1); R[i]=rk
    S=R.sum(axis=0)
    return float(12*((S-S.mean())**2).sum()/(m*m*(n**3-n)))

rows=[]; t0=time.time()
for i,b in enumerate(blocks):
    la=np.arange(b['lat0'],b['lat1']+RES,RES); lo=np.arange(b['lon0'],b['lon1']+RES,RES)
    TLA,TLO=np.meshgrid(la,lo,indexing='ij'); tla=TLA.ravel(); tlo=TLO.ravel()
    f={}
    g=d['ASTER'][b['granule']]['TIR']; IM=g['ImageData10']
    ala=np.asarray(g['Geolocation']['Latitude'][:],'f8').ravel()
    alo=np.asarray(g['Geolocation']['Longitude'][:],'f8').ravel()
    av=np.asarray(IM[:],'f8'); am=ok(ala,alo)&vmask(IM,av).ravel(); av=av.ravel()
    if am.sum()>100: f['ASTER']=regrid(ala[am].copy(),alo[am].copy(),av[am].copy(),tla,tlo,MAXR['ASTER'])
    for k in ['MODIS','MISR','CERES','MOPITT']:
        sla=SRC[k+'_lat']; slo=SRC[k+'_lon']; sv=SRC[k+'_val']
        m=(sla>=b['lat0']-PAD)&(sla<=b['lat1']+PAD)&(slo>=b['lon0']-PAD)&(slo<=b['lon1']+PAD)
        if m.sum()>=5: f[k]=regrid(sla[m].copy(),slo[m].copy(),sv[m].copy(),tla,tlo,MAXR[k])
    names=[k for k in INST if k in f]
    M=np.vstack([rankz(f[k]) for k in names])
    good=np.all(np.isfinite(M),axis=0)
    if good.sum()<50 or len(names)<3: continue
    M=M[:,good]
    for r in range(M.shape[0]):                      # re-standardise on common cells
        M[r]=(M[r]-M[r].mean())/(M[r].std() if M[r].std()>0 else 1)
    R=np.corrcoef(M)
    w,v=np.linalg.eigh(R); k1=int(np.argmax(w)); lead=v[:,k1]; lam1=w[k1]
    sign=np.sign(lead); sign[sign==0]=1
    Ms=M*sign[:,None]                                # sign-align to the common mode
    Rs=np.corrcoef(Ms); ws,vs=np.linalg.eigh(Rs); j=int(np.argmax(ws))
    C=float(ws[j]/len(names))                        # congruence in [1/n, 1]
    load={names[q]: float(abs(vs[q,j])) for q in range(len(names))}
    W=float(kendall_w(Ms))
    lo_s=min(load,key=load.get); hi=sorted(load.values())[-1]
    gap=float(hi-load[lo_s])
    DEN=[q for q,k in enumerate(names) if k in ('ASTER','MODIS','MISR')]
    Cd=np.nan
    if len(DEN)>=3:
        Rd=np.corrcoef(Ms[DEN]); wd,_=np.linalg.eigh(Rd); Cd=float(wd.max()/len(DEN))
    rows.append(dict(blk=i,lat0=b['lat0'],lat1=b['lat1'],lon0=b['lon0'],lon1=b['lon1'],
                     congruence_dense=Cd,
                     n=len(names),ncell=int(good.sum()),congruence=C,kendall_w=W,
                     loadings=load,weakest=lo_s,load_gap=gap,
                     signs={names[q]:int(sign[q]) for q in range(len(names))}))
print(f'# {len(rows)} blocks, {time.time()-t0:.1f}s')
rows.sort(key=lambda r:r['congruence'])
print(f'\n# LEAST congruent first (C=1/n means fully incongruent, 1.0 fully congruent)')
print(f'{"rk":>2} {"blk":>3} {"lat0":>6} {"lat1":>6} {"n":>2} {"C5":>6} {"Cd":>6} {"W":>6} {"weakest":>7} {"gap":>5}  loadings (sign-aligned)')
for r,x in enumerate(rows[:10]):
    ld=' '.join(f'{k[:4]}={v:.2f}' for k,v in sorted(x['loadings'].items(),key=lambda y:-y[1]))
    print(f'{r:2d} {x["blk"]:3d} {x["lat0"]:6.2f} {x["lat1"]:6.2f} {x["n"]:2d} {x["congruence"]:6.3f} {x["congruence_dense"]:6.3f} {x["kendall_w"]:6.3f} {x["weakest"]:>7} {x["load_gap"]:5.2f}  {ld}')
json.dump(rows, open('congruence.json','w'), indent=1)
cs=[r['congruence'] for r in rows]
print(f'\n# congruence across 32 blocks: min={min(cs):.3f} median={np.median(cs):.3f} max={max(cs):.3f}')
from collections import Counter
print(f'# weakest sensor tally: {dict(Counter(r["weakest"] for r in rows))}')
