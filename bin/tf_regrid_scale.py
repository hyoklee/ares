"""Scaling of the per-block regrid. pytaf's reproject.c is already OpenMP, so
this measures OMP threads vs block-level processes vs both, to find the right
shape of parallelism for 32 independent blocks on a 40-core node."""
import os, sys, time, json, numpy as np
NPROC=int(sys.argv[1]); NOMP=int(sys.argv[2])
os.environ['OMP_NUM_THREADS']=str(NOMP)
sys.path.insert(0,os.path.expanduser('~/src/TerraFusion/pytaf'))
import pytaf
from multiprocessing import Pool

D=np.load('regrid_inputs.npz', allow_pickle=True)
SRC={k:D[k] for k in D.files}
blocks=json.load(open('aster_blocks.json')); RES=0.02; PAD=0.05; MAXR=3000.0

def one(i):
    b=blocks[i]
    la=np.arange(b['lat0'],b['lat1']+RES,RES); lo=np.arange(b['lon0'],b['lon1']+RES,RES)
    TLA,TLO=np.meshgrid(la,lo,indexing='ij')
    tla=TLA.ravel(); tlo=TLO.ravel(); nT=tla.size; n=0
    for k in ('MODIS','MISR'):
        sla=SRC[k+'_lat']; slo=SRC[k+'_lon']; sv=SRC[k+'_val']
        m=(sla>=b['lat0']-PAD)&(sla<=b['lat1']+PAD)&(slo>=b['lon0']-PAD)&(slo<=b['lon1']+PAD)
        if m.sum()<5: continue
        sL=sla[m].reshape(1,-1).copy(); sO=slo[m].reshape(1,-1).copy()
        tL=tla.reshape(1,-1).copy(); tO=tlo.reshape(1,-1).copy()
        nnid=np.full(nT,-1,dtype=np.int32); nnd=np.zeros((1,nT))
        pytaf.find_nn_block_index(sL,sO,int(m.sum()),tL,tO,nnid,nnd,nT,MAXR)
        tv=np.full((1,nT),np.nan); pytaf.interpolate_nn(sv[m].reshape(1,-1).copy(),tv,nnid,nT)
        n+=int((nnid>=0).sum())
    return n

t=time.time()
if NPROC==1: r=[one(i) for i in range(len(blocks))]
else:
    with Pool(NPROC) as p: r=p.map(one, range(len(blocks)))
el=time.time()-t
print(f'{NPROC},{NOMP},{NPROC*NOMP},{el:.2f},{sum(r)}')
