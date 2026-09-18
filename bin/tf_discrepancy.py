"""Stage 2/3: regrid 5 Terra instruments into each ASTER block with pytaf and
rank blocks by cross-sensor pattern discrepancy."""
import netCDF4, numpy as np, json, time, sys, os
sys.path.insert(0, os.path.expanduser('~/src/TerraFusion/pytaf'))
import pytaf

F='/mnt/common/datasets-staging/TERRA_BF_L1B_O10204_20011118010522_F000_V001.h5'
RES=float(os.environ.get('RES','0.02')); PAD=0.05; MAXR=float(os.environ.get('MAXR','5000'))
blocks=json.load(open('aster_blocks.json'))
d=netCDF4.Dataset(F)
def ok(la,lo): return np.isfinite(la)&np.isfinite(lo)&(np.abs(la)<=90)&(np.abs(lo)<=180)&((la!=0)|(lo!=0))

def vmask(var, a):
    """Valid-data mask from the variable's own metadata. valid_min/valid_max is
    the only reliable test here: MOPITT carries a SECOND sentinel (-8888) beyond
    its _FillValue of -9999, and a fill-value-only test lets it through."""
    m=np.isfinite(a)
    vmin=getattr(var,'valid_min',None); vmax=getattr(var,'valid_max',None)
    if vmin is not None: m &= (a>=float(vmin))
    if vmax is not None: m &= (a<=float(vmax))
    fv=getattr(var,'_FillValue',None)
    if fv is not None: m &= (a!=float(fv))
    if vmin is None and vmax is None: m &= (np.abs(a)<1e30)
    return m
LA0=min(b['lat0'] for b in blocks)-PAD; LA1=max(b['lat1'] for b in blocks)+PAD
LO0=min(b['lon0'] for b in blocks)-PAD; LO1=max(b['lon1'] for b in blocks)+PAD
T={}

# ---------- load strip-wide sources once ----------
t=time.time(); SRC={}
mla=[];mlo=[];mv=[]
for gn,g in d['MODIS'].groups.items():
    if '_1KM' not in g.groups: continue
    G=g['_1KM']['Geolocation']
    la=np.asarray(G['Latitude'][:],'f8'); lo=np.asarray(G['Longitude'][:],'f8')
    m=ok(la,lo)&(la>=LA0)&(la<=LA1)&(lo>=LO0)&(lo<=LO1)
    if not m.any(): continue
    EV=g['_1KM']['Data_Fields']['EV_1KM_Emissive']
    v=np.asarray(EV[0,:,:],'f8')                                           # band 0, one chunk
    m &= vmask(EV,v)
    mla.append(la[m]); mlo.append(lo[m]); mv.append(v[m])
SRC['MODIS']=(np.concatenate(mla),np.concatenate(mlo),np.concatenate(mv)); T['read_MODIS']=time.time()-t

t=time.time()
gl=d['MISR']['Geolocation']
la=np.asarray(gl['GeoLatitude'][:],'f8'); lo=np.asarray(gl['GeoLongitude'][:],'f8')
m=ok(la,lo)&(la>=LA0)&(la<=LA1)&(lo>=LO0)&(lo<=LO1)
bidx=np.unique(np.nonzero(m)[0])
rr=d['MISR']['AN']['Data_Fields']['Red_Radiance']                # single 755 MB chunk
v=np.asarray(rr[:],'f8')                                          # must read whole chunk
# Red_Radiance is (180,512,2048); geoloc is (180,128,512) -> subsample radiance 4x to match
v=v[:, ::4, ::4]
m &= vmask(rr,v)
SRC['MISR']=(la[m],lo[m],v[m]); T['read_MISR']=time.time()-t

t=time.time(); cla=[];clo=[];cv=[]
for gn,g in d['CERES'].groups.items():
    for fm in ('FM1','FM2'):
        if fm not in g.groups: continue
        tp=g[fm]['Time_and_Position']
        la=np.asarray(tp['Latitude'][:],'f8'); lo=np.asarray(tp['Longitude'][:],'f8')
        m=ok(la,lo)&(la>=LA0)&(la<=LA1)&(lo>=LO0)&(lo<=LO1)
        if not m.any(): continue
        LW=g[fm]['Radiances']['LW_Radiance']
        v=np.asarray(LW[:],'f8'); m &= vmask(LW,v)
        cla.append(la[m]); clo.append(lo[m]); cv.append(v[m])
SRC['CERES']=(np.concatenate(cla),np.concatenate(clo),np.concatenate(cv)); T['read_CERES']=time.time()-t

t=time.time()
G=d['MOPITT']['granule_20011118']['Geolocation']
la=np.asarray(G['Latitude'][:],'f8'); lo=np.asarray(G['Longitude'][:],'f8')
m=ok(la,lo)&(la>=LA0)&(la<=LA1)&(lo>=LO0)&(lo<=LO1)
MR=d['MOPITT']['granule_20011118']['Data_Fields']['MOPITTRadiances']
v=np.asarray(MR[:,:,:,4,0],'f8')          # only channels [4,*] and [6,*] hold data
m &= vmask(MR,v)
SRC['MOPITT']=(la[m],lo[m],v[m]); T['read_MOPITT']=time.time()-t

for k,(a,b,c) in SRC.items():
    good=np.isfinite(c)
    SRC[k]=(np.ascontiguousarray(a[good]),np.ascontiguousarray(b[good]),np.ascontiguousarray(c[good]))
    print(f'# {k:7} {SRC[k][0].size:8d} pts  read {T["read_"+k]:6.2f}s  val[{SRC[k][2].min():.3g},{SRC[k][2].max():.3g}]', flush=True)

def regrid(sla,slo,sval,tla,tlo):
    """pytaf nearest-neighbour onto the target grid; returns flat target field.

    NOTE: nearestNeighborBlockIndex converts BOTH source and target lat/lon from
    degrees to radians IN PLACE (reproject.c:200-207), mutating the caller's
    arrays. np.ascontiguousarray is a no-op on an already-contiguous float64
    array, so passing one straight in silently destroys it for the next call --
    which is why only the first instrument per block ever matched. Every array
    handed to pytaf must therefore be a fresh copy."""
    nS=sla.size; nT=tla.size
    sL=sla.reshape(1,-1).copy(); sO=slo.reshape(1,-1).copy()
    tL=tla.reshape(1,-1).copy(); tO=tlo.reshape(1,-1).copy()
    nnid=np.full(nT,-1,dtype=np.int32); nndis=np.zeros((1,nT))
    pytaf.find_nn_block_index(sL,sO,nS,tL,tO,nnid,nndis,nT,MAXR)
    tv=np.full((1,nT),np.nan)
    pytaf.interpolate_nn(sval.reshape(1,-1).copy(),tv,nnid,nT)
    out=tv.ravel().copy()
    out[nnid<0]=np.nan          # pytaf writes -999 for "no neighbour", not NaN
    return out

def z(a):
    m=np.isfinite(a)
    if m.sum()<10: return None
    s=a[m].std()
    if not np.isfinite(s) or s==0: return None
    out=np.full(a.shape,np.nan); out[m]=(a[m]-a[m].mean())/s
    return out

INST=['ASTER','MODIS','MISR','CERES','MOPITT']
rows=[]; t_regrid=0.0
for i,b in enumerate(blocks):
    la=np.arange(b['lat0'],b['lat1']+RES,RES); lo=np.arange(b['lon0'],b['lon1']+RES,RES)
    TLA,TLO=np.meshgrid(la,lo,indexing='ij')
    tla=np.ascontiguousarray(TLA.ravel()); tlo=np.ascontiguousarray(TLO.ravel())
    # ASTER: this block's own granule, TIR band 10
    g=d['ASTER'][b['granule']]['TIR']
    ala=np.asarray(g['Geolocation']['Latitude'][:],'f8').ravel()
    alo=np.asarray(g['Geolocation']['Longitude'][:],'f8').ravel()
    IM=g['ImageData10']
    av=np.asarray(IM[:],'f8')
    am=ok(ala,alo)&vmask(IM,av).ravel(); av=av.ravel()
    fields={}
    t0=time.time()
    if am.sum()>100:
        fields['ASTER']=regrid(np.ascontiguousarray(ala[am]),np.ascontiguousarray(alo[am]),
                               np.ascontiguousarray(av[am]),tla,tlo)
    for k in ['MODIS','MISR','CERES','MOPITT']:
        sla,slo,sv=SRC[k]
        m=(sla>=b['lat0']-PAD)&(sla<=b['lat1']+PAD)&(slo>=b['lon0']-PAD)&(slo<=b['lon1']+PAD)
        if m.sum()<5: continue
        fields[k]=regrid(np.ascontiguousarray(sla[m]),np.ascontiguousarray(slo[m]),
                         np.ascontiguousarray(sv[m]),tla,tlo)
    t_regrid+=time.time()-t0
    Z={k:z(v) for k,v in fields.items()}; Z={k:v for k,v in Z.items() if v is not None}
    pairs={}
    for a in range(len(INST)):
        for c in range(a+1,len(INST)):
            ka,kc=INST[a],INST[c]
            if ka in Z and kc in Z:
                m=np.isfinite(Z[ka])&np.isfinite(Z[kc])
                if m.sum()>=20: pairs[f'{ka}-{kc}']=float(np.sqrt(np.mean((Z[ka][m]-Z[kc][m])**2)))
    if not pairs: continue
    worst=max(pairs,key=pairs.get)
    rows.append(dict(blk=i, granule=b['granule'], lat0=b['lat0'], lat1=b['lat1'],
                     lon0=b['lon0'], lon1=b['lon1'], ncell=int(tla.size),
                     nsensor=len(Z), worst_pair=worst, worst_rms=pairs[worst],
                     mean_rms=float(np.mean(list(pairs.values()))), pairs=pairs))
    print(f'  blk {i:2d} cells={tla.size:6d} sensors={len(Z)} worst={worst}:{pairs[worst]:.3f} mean={np.mean(list(pairs.values())):.3f}', flush=True)

T['regrid_total']=t_regrid
rows.sort(key=lambda r:-r['worst_rms'])
json.dump(dict(timings=T,res=RES,rows=rows), open('discrepancy.json','w'), indent=1)
print(f'\n# regrid total {t_regrid:.2f}s over {len(rows)} blocks ({t_regrid/max(len(rows),1):.3f}s/block)')
print(f'\n# RANKED by worst-pair z-score RMS discrepancy')
print(f'{"rank":>4} {"blk":>3} {"lat0":>6} {"lat1":>6} {"sens":>4} {"worst_pair":>14} {"worst":>7} {"mean":>7}')
for r,x in enumerate(rows[:12]):
    print(f'{r:4d} {x["blk"]:3d} {x["lat0"]:6.2f} {x["lat1"]:6.2f} {x["nsensor"]:4d} {x["worst_pair"]:>14} {x["worst_rms"]:7.3f} {x["mean_rms"]:7.3f}')
