import netCDF4, os, time
SRC='/mnt/common/datasets-staging/TERRA_BF_L1B_O10204_20011118010522_F000_V001.h5'
OUT='/mnt/common/hyoklee/bench/tf_misr.nc'
os.makedirs(os.path.dirname(OUT), exist_ok=True)
src=netCDF4.Dataset(SRC)
v=src['MISR/AN/Data_Fields']['Red_Radiance']
f=v.filters() or {}; ck=v.chunking()
print('src shape',v.shape,'chunk',ck,'filters',{k:f.get(k) for k in ('zlib','complevel','shuffle')},flush=True)
dst=netCDF4.Dataset(OUT,'w',format='NETCDF4')
for i,n in enumerate(v.shape): dst.createDimension(f'misr_d{i}', n)
nv=dst.createVariable('misr_red', v.dtype, tuple(f'misr_d{i}' for i in range(len(v.shape))),
                      zlib=bool(f.get('zlib')), complevel=f.get('complevel',1),
                      shuffle=bool(f.get('shuffle')), chunksizes=ck)
t=time.time(); nv[...] = v[...]
print(f'copied 755 MB logical in {time.time()-t:.1f}s',flush=True)
dst.close(); src.close()
print('size on disk:', os.path.getsize(OUT)//1048576, 'MiB')
print('MISR-FLATTEN-DONE')
