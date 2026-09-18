"""Rechunk MISR Red_Radiance from one 755 MB chunk to one chunk per SOM block,
then measure the subset read the discrepancy pipeline actually needs."""
import netCDF4, numpy as np, time, os, json
SRC='/mnt/common/datasets-staging/TERRA_BF_L1B_O10204_20011118010522_F000_V001.h5'
OUT='/mnt/common/hyoklee/bench/tf_misr_rechunk.nc'
NEED=json.load(open('misr_blocks_needed.json')) if os.path.exists('misr_blocks_needed.json') else None

d=netCDF4.Dataset(SRC)
rr=d['MISR']['AN']['Data_Fields']['Red_Radiance']
print(f'# source {rr.shape} chunk={rr.chunking()} filters={ {k:rr.filters()[k] for k in ("zlib","complevel")} }', flush=True)

# which SOM blocks does the pipeline need?
gl=d['MISR']['Geolocation']
la=np.asarray(gl['GeoLatitude'][:],'f8'); lo=np.asarray(gl['GeoLongitude'][:],'f8')
m=np.isfinite(la)&np.isfinite(lo)&(np.abs(la)<=90)&(np.abs(lo)<=180)&((la!=0)|(lo!=0))
m&=(la>=33.06)&(la<=50.20)&(lo>=138.47)&(lo<=145.46)
need=np.unique(np.nonzero(m)[0]); print(f'# pipeline needs SOM blocks {need.min()}..{need.max()} ({need.size} of {rr.shape[0]})', flush=True)

# --- baseline: whole-chunk read as the pipeline does today
t=time.time(); _=np.asarray(rr[:],'f8'); t_full=time.time()-t
print(f'# ORIGINAL full read           : {t_full:6.2f}s  (755 MB single chunk)', flush=True)
t=time.time(); _=np.asarray(rr[need[0]:need[-1]+1],'f8'); t_sub_orig=time.time()-t
print(f'# ORIGINAL subset read (15 blk): {t_sub_orig:6.2f}s  <- no saving, chunk is atomic', flush=True)

# --- rechunk to one chunk per SOM block
if not os.path.exists(OUT):
    t=time.time()
    dst=netCDF4.Dataset(OUT,'w',format='NETCDF4')
    for i,n in enumerate(rr.shape): dst.createDimension(f'd{i}', n)
    nv=dst.createVariable('misr_red', rr.dtype, tuple(f'd{i}' for i in range(3)),
                          zlib=True, complevel=1, chunksizes=[1, rr.shape[1], rr.shape[2]])
    # Read the source ONCE. Writing block-by-block from a single-chunk source
    # re-inflates all 755 MB on every one of the 180 iterations -- 180x the work,
    # which is the very pathology this rechunk exists to remove.
    whole=np.asarray(rr[:])
    for b in range(rr.shape[0]): nv[b,:,:]=whole[b]
    del whole
    dst.close(); print(f'# rechunk write: {time.time()-t:.1f}s -> {os.path.getsize(OUT)//1048576} MiB', flush=True)

d2=netCDF4.Dataset(OUT); v2=d2['misr_red']
print(f'# rechunked chunk={v2.chunking()}', flush=True)
os.system(f'python3 evict.py {OUT} 2>/dev/null')
t=time.time(); _=np.asarray(v2[need[0]:need[-1]+1],'f8'); t_sub_new=time.time()-t
os.system(f'python3 evict.py {OUT} 2>/dev/null')
t=time.time(); _=np.asarray(v2[:],'f8'); t_full_new=time.time()-t
print(f'# RECHUNKED subset read        : {t_sub_new:6.2f}s', flush=True)
print(f'# RECHUNKED full read          : {t_full_new:6.2f}s', flush=True)
print(f'\n# subset speedup from rechunking: {t_sub_orig/max(t_sub_new,1e-9):.1f}x  ({t_sub_orig:.2f}s -> {t_sub_new:.2f}s)')
