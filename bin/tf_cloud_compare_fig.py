import netCDF4, numpy as np, json, os, sys
import matplotlib; matplotlib.use('Agg')
import matplotlib.pyplot as plt
sys.path.insert(0,os.path.expanduser('~/src/TerraFusion/pytaf')); import pytaf
F='/mnt/common/datasets-staging/TERRA_BF_L1B_O10204_20011118010522_F000_V001.h5'
C1,C2=1.191042e8,1.4387752e4
BANDS=[20,21,22,23,24,25,27,28,29,30,31,32,33,34,35,36]
WL={20:3.750,29:8.550,31:11.030,32:12.020}
IDX={b:i for i,b in enumerate(BANDS)}
RES=0.02; PAD=0.05; MAXR=3000.
blocks=json.load(open('aster_blocks.json'))
CG={r['blk']:r for r in json.load(open('congruence_b31_WN.json'))}
def bt(L,lam):
    L=np.asarray(L,'f8'); o=np.full(L.shape,np.nan); m=np.isfinite(L)&(L>0)
    o[m]=C2/(lam*np.log1p(C1/(lam**5*L[m]))); return o
def vmask(v,a):
    m=np.isfinite(a)
    for att,op in (('valid_min',np.greater_equal),('valid_max',np.less_equal)):
        x=getattr(v,att,None)
        if x is not None: m&=op(a,float(x))
    fv=getattr(v,'_FillValue',None)
    if fv is not None: m&=(a!=float(fv))
    return m
def ok(la,lo): return np.isfinite(la)&np.isfinite(lo)&(np.abs(la)<=90)&(np.abs(lo)<=180)&((la!=0)|(lo!=0))
def rg(sla,slo,sv,tla,tlo):
    nS=sla.size;nT=tla.size
    sL=sla.reshape(1,-1).copy();sO=slo.reshape(1,-1).copy();tL=tla.reshape(1,-1).copy();tO=tlo.reshape(1,-1).copy()
    nn=np.full(nT,-1,np.int32);nd=np.zeros((1,nT))
    pytaf.find_nn_block_index(sL,sO,nS,tL,tO,nn,nd,nT,MAXR)
    tv=np.full((1,nT),np.nan);pytaf.interpolate_nn(sv.reshape(1,-1).copy(),tv,nn,nT)
    o=tv.ravel().copy();o[nn<0]=np.nan;return o
d=netCDF4.Dataset(F)
LA0=min(b['lat0'] for b in blocks)-PAD; LA1=max(b['lat1'] for b in blocks)+PAD
LO0=min(b['lon0'] for b in blocks)-PAD; LO1=max(b['lon1'] for b in blocks)+PAD
mla=[];mlo=[];mv=[]
for gn,g in d['MODIS'].groups.items():
    if '_1KM' not in g.groups: continue
    G=g['_1KM']['Geolocation']
    la=np.asarray(G['Latitude'][:],'f8');lo=np.asarray(G['Longitude'][:],'f8')
    m=ok(la,lo)&(la>=LA0)&(la<=LA1)&(lo>=LO0)&(lo<=LO1)
    if not m.any(): continue
    EV=g['_1KM']['Data_Fields']['EV_1KM_Emissive']; cube=np.asarray(EV[:],'f8')
    good=np.ones(m.shape,bool)
    for i in range(16): good&=vmask(EV,cube[i])
    sel=m&good
    if not sel.any(): continue
    mla.append(la[sel]);mlo.append(lo[sel])
    mv.append(np.vstack([cube[IDX[b]][sel] for b in (20,31,32)]))
LAT=np.concatenate(mla);LON=np.concatenate(mlo);V=np.hstack(mv)
T20=bt(V[0],WL[20]);T31=bt(V[1],WL[31]);T32=bt(V[2],WL[32])
fig,axes=plt.subplots(2,3,figsize=(13.0,7.4),dpi=165)
specs=[('BT$_{31}$ (11.03 µm)','K','cividis',None),
       ('BTD(31−32) split window','K','cividis',None),
       ('BTD(20−31) 3.7 µm solar','K','cividis',None)]
for row,blk in enumerate((13,3)):
    b=blocks[blk]
    la=np.arange(b['lat0'],b['lat1']+RES,RES);lo=np.arange(b['lon0'],b['lon1']+RES,RES)
    TLA,TLO=np.meshgrid(la,lo,indexing='ij');tla=np.ascontiguousarray(TLA.ravel());tlo=np.ascontiguousarray(TLO.ravel())
    ext=[lo[0],lo[-1],la[0],la[-1]]
    m=(LAT>=b['lat0']-PAD)&(LAT<=b['lat1']+PAD)&(LON>=b['lon0']-PAD)&(LON<=b['lon1']+PAD)
    sla=np.ascontiguousarray(LAT[m]);slo=np.ascontiguousarray(LON[m])
    f31=rg(sla.copy(),slo.copy(),np.ascontiguousarray(T31[m]),tla,tlo)
    f32=rg(sla.copy(),slo.copy(),np.ascontiguousarray(T32[m]),tla,tlo)
    f20=rg(sla.copy(),slo.copy(),np.ascontiguousarray(T20[m]),tla,tlo)
    data=[f31,f31-f32,f20-f31]
    for col,(arr,(ttl,unit,cm,_)) in enumerate(zip(data,specs)):
        ax=axes[row,col]; A=arr.reshape(TLA.shape); v=A[np.isfinite(A)]
        lo_p,hi_p=np.percentile(v,[2,98])
        cmap=plt.get_cmap(cm).copy(); cmap.set_bad('#d4d4d8')
        im=ax.imshow(np.ma.masked_invalid(A),origin='lower',extent=ext,cmap=cmap,
                     vmin=lo_p,vmax=hi_p,aspect='auto',interpolation='nearest')
        if row==0: ax.set_title(ttl,fontsize=10)
        if col==0: ax.set_ylabel(f"block {blk}\n°N",fontsize=9)
        ax.tick_params(labelsize=7); ax.set_xlabel('°E',fontsize=8)
        cb=fig.colorbar(im,ax=ax,fraction=0.046,pad=0.02); cb.set_label(unit,fontsize=7); cb.ax.tick_params(labelsize=6)
        ax.text(0.02,0.02,f"mean {np.nanmean(A):.1f}  sd {np.nanstd(A):.2f}",transform=ax.transAxes,
                fontsize=7,color='w',bbox=dict(fc='#00000066',ec='none',pad=1.5))
fig.suptitle("MODIS emissive-band diagnostics: block 13 (C₅=0.508, least congruent) vs block 3 (C₅=0.867, most congruent)\n"
             "Block 13 is colder, far flatter, and has a much stronger 3.7 µm solar-reflection signature — an optically thick, uniform water-cloud deck",
             fontsize=10,y=1.00)
fig.tight_layout()
fig.savefig('png/tf_cloud_blk13_vs_blk3.png',bbox_inches='tight')
print("wrote png/tf_cloud_blk13_vs_blk3.png")
