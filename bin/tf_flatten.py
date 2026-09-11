import netCDF4, numpy as np, sys, time
SRC='/mnt/common/datasets-staging/TERRA_BF_L1B_O10204_20011118010522_F000_V001.h5'
OUT='/mnt/common/hyoklee/bench/tf_flat.nc'
import os; os.makedirs(os.path.dirname(OUT), exist_ok=True)
src=netCDF4.Dataset(SRC)
dst=netCDF4.Dataset(OUT,'w',format='NETCDF4')
specs=[('modis_ev','MODIS/granule_2001322_0110/_1KM/Data_Fields','EV_1KM_Emissive'),
       ('aster_swir','ASTER/granule_11182001013943/SWIR','ImageData4')]
for newname,gp,vn in specs:
    g=src[gp]; v=g[vn]
    dnames=[]
    for i,d in enumerate(v.dimensions):
        dn=f'{newname}_d{i}'
        if dn not in dst.dimensions: dst.createDimension(dn, v.shape[i])
        dnames.append(dn)
    f=v.filters() or {}
    ck=v.chunking()
    ck=None if ck=='contiguous' else ck
    nv=dst.createVariable(newname, v.dtype, tuple(dnames),
                          zlib=bool(f.get('zlib')), complevel=f.get('complevel',1),
                          shuffle=bool(f.get('shuffle')), chunksizes=ck)
    t=time.time(); nv[...] = v[...]
    print(f'{newname}: shape={v.shape} chunk={ck} zlib={f.get("zlib")} lvl={f.get("complevel")} copied in {time.time()-t:.1f}s', flush=True)
dst.close(); src.close()
print('FLATTEN-DONE  ->', OUT)
