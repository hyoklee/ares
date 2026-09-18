import netCDF4, numpy as np, time, json, sys
F=sys.argv[1] if len(sys.argv)>1 else '/mnt/common/datasets-staging/TERRA_BF_L1B_O10204_20011118010522_F000_V001.h5'
d=netCDF4.Dataset(F)
S=10  # subsample stride

def clean(lat,lon):
    lat=np.asarray(lat,dtype='f8').ravel(); lon=np.asarray(lon,dtype='f8').ravel()
    m=np.isfinite(lat)&np.isfinite(lon)&(np.abs(lat)<=90)&(np.abs(lon)<=180)&((lat!=0)|(lon!=0))
    return lat[m],lon[m]

res={}
t0=time.time()

# ASTER: per-granule coarse 11x11 geoloc
la=[];lo=[]
for gn,g in d['ASTER'].groups.items():
    if 'Geolocation' in g.groups:
        a,b=clean(g['Geolocation']['Latitude'][:], g['Geolocation']['Longitude'][:]); la.append(a); lo.append(b)
res['ASTER']=(np.concatenate(la),np.concatenate(lo),len(d['ASTER'].groups))

# CERES: FM1+FM2 footprints
la=[];lo=[]
for gn,g in d['CERES'].groups.items():
    for fm in ('FM1','FM2'):
        if fm in g.groups:
            tp=g[fm]['Time_and_Position']
            a,b=clean(tp['Latitude'][::S], tp['Longitude'][::S]); la.append(a); lo.append(b)
res['CERES']=(np.concatenate(la),np.concatenate(lo),len(d['CERES'].groups))

# MISR: SOM-grid geolocation
gl=d['MISR']['Geolocation']
a,b=clean(gl['GeoLatitude'][::2,::S,::S], gl['GeoLongitude'][::2,::S,::S])
res['MISR']=(a,b,gl['GeoLatitude'].shape)

# MODIS: 1KM geoloc per granule
la=[];lo=[]
for gn,g in d['MODIS'].groups.items():
    if '_1KM' in g.groups and 'Geolocation' in g['_1KM'].groups:
        G=g['_1KM']['Geolocation']
        a,b=clean(G['Latitude'][::S,::S], G['Longitude'][::S,::S]); la.append(a); lo.append(b)
res['MODIS']=(np.concatenate(la),np.concatenate(lo),len(d['MODIS'].groups))

# MOPITT
G=d['MOPITT']['granule_20011118']['Geolocation']
a,b=clean(G['Latitude'][:], G['Longitude'][:])
res['MOPITT']=(a,b,G['Latitude'].shape)

print(f'# read in {time.time()-t0:.1f}s, stride={S}')
print(f'{"inst":8} {"npts":>9} {"lat_min":>8} {"lat_max":>8} {"lon_min":>9} {"lon_max":>9}  detail')
box={}
for k,(la,lo,det) in res.items():
    box[k]=(la.min(),la.max(),lo.min(),lo.max())
    print(f'{k:8} {la.size:9d} {la.min():8.2f} {la.max():8.2f} {lo.min():9.2f} {lo.max():9.2f}  {det}')

# latitude intersection along-track (the orbit is polar; latitude is the track coordinate)
lo_lat=max(b[0] for b in box.values()); hi_lat=min(b[1] for b in box.values())
print(f'\n# along-track latitude intersection of all 5: [{lo_lat:.2f}, {hi_lat:.2f}]  span={hi_lat-lo_lat:.2f} deg')
json.dump({k:[float(x) for x in v] for k,v in box.items()}, open('footprints.json','w'), indent=1)
