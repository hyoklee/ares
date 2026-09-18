import netCDF4, numpy as np, json, time, sys
F='/mnt/common/datasets-staging/TERRA_BF_L1B_O10204_20011118010522_F000_V001.h5'
blocks=json.load(open('aster_blocks.json'))
PAD=0.05
d=netCDF4.Dataset(F)
T={}

def valid(la,lo):
    return np.isfinite(la)&np.isfinite(lo)&(np.abs(la)<=90)&(np.abs(lo)<=180)&((la!=0)|(lo!=0))

# strip envelope
LA0=min(b['lat0'] for b in blocks)-PAD; LA1=max(b['lat1'] for b in blocks)+PAD
LO0=min(b['lon0'] for b in blocks)-PAD; LO1=max(b['lon1'] for b in blocks)+PAD
print(f'# strip envelope lat[{LA0:.2f},{LA1:.2f}] lon[{LO0:.2f},{LO1:.2f}]')

t=time.time(); src={}
# ---- MODIS: per-granule bbox reject, then pixel select
keep=[]
for gn,g in d['MODIS'].groups.items():
    if '_1KM' not in g.groups: continue
    G=g['_1KM']['Geolocation']
    la=np.asarray(G['Latitude'][::8,::8],'f8'); lo=np.asarray(G['Longitude'][::8,::8],'f8')
    m=valid(la,lo)
    if not m.any(): continue
    if la[m].max()<LA0 or la[m].min()>LA1 or lo[m].max()<LO0 or lo[m].min()>LO1: continue
    keep.append(gn)
mla=[];mlo=[]
for gn in keep:
    G=d['MODIS'][gn]['_1KM']['Geolocation']
    la=np.asarray(G['Latitude'][:],'f8'); lo=np.asarray(G['Longitude'][:],'f8')
    m=valid(la,lo)&(la>=LA0)&(la<=LA1)&(lo>=LO0)&(lo<=LO1)
    mla.append(la[m]); mlo.append(lo[m])
src['MODIS']=(np.concatenate(mla),np.concatenate(mlo),f'{len(keep)}/{len(d["MODIS"].groups)} granules')
T['MODIS']=time.time()-t

t=time.time()
gl=d['MISR']['Geolocation']
la=np.asarray(gl['GeoLatitude'][:],'f8'); lo=np.asarray(gl['GeoLongitude'][:],'f8')
m=valid(la,lo)&(la>=LA0)&(la<=LA1)&(lo>=LO0)&(lo<=LO1)
nblk=np.unique(np.nonzero(m)[0]).size
src['MISR']=(la[m],lo[m],f'{nblk}/{la.shape[0]} SOM blocks')
T['MISR']=time.time()-t

t=time.time(); cla=[];clo=[];n=0
for gn,g in d['CERES'].groups.items():
    for fm in ('FM1','FM2'):
        if fm not in g.groups: continue
        tp=g[fm]['Time_and_Position']
        la=np.asarray(tp['Latitude'][:],'f8'); lo=np.asarray(tp['Longitude'][:],'f8'); n+=la.size
        m=valid(la,lo)&(la>=LA0)&(la<=LA1)&(lo>=LO0)&(lo<=LO1)
        cla.append(la[m]); clo.append(lo[m])
src['CERES']=(np.concatenate(cla),np.concatenate(clo),f'of {n} footprints')
T['CERES']=time.time()-t

t=time.time()
G=d['MOPITT']['granule_20011118']['Geolocation']
la=np.asarray(G['Latitude'][:],'f8'); lo=np.asarray(G['Longitude'][:],'f8'); ntot=la.size
m=valid(la,lo)&(la>=LA0)&(la<=LA1)&(lo>=LO0)&(lo<=LO1)
src['MOPITT']=(la[m],lo[m],f'of {ntot} pixels')
T['MOPITT']=time.time()-t

print(f'\n{"inst":8} {"in-strip":>10} {"frac":>8} {"sel_s":>7}  detail')
for k,(la,lo,det) in src.items():
    tot={'MODIS':len(keep)*2030*1354,'MISR':11796480,'CERES':390722,'MOPITT':50576}[k]
    print(f'{k:8} {la.size:10d} {100*la.size/tot:7.3f}% {T[k]:7.2f}  {det}')
    np.save(f'coloc_{k}_lat.npy', la); np.save(f'coloc_{k}_lon.npy', lo)

# per-block counts
print(f'\n# per-block source counts (first 6 and last 2 of 32)')
print(f'{"blk":>3} {"lat0":>6} {"lat1":>6} {"MODIS":>8} {"MISR":>8} {"CERES":>6} {"MOPITT":>7}')
rows=[]
for i,b in enumerate(blocks):
    r=[i,b['lat0'],b['lat1']]
    for k in ('MODIS','MISR','CERES','MOPITT'):
        la,lo,_=src[k]
        c=int(np.count_nonzero((la>=b['lat0']-PAD)&(la<=b['lat1']+PAD)&(lo>=b['lon0']-PAD)&(lo<=b['lon1']+PAD)))
        r.append(c)
    rows.append(r)
    if i<6 or i>=30: print(f'{r[0]:3d} {r[1]:6.2f} {r[2]:6.2f} {r[3]:8d} {r[4]:8d} {r[5]:6d} {r[6]:7d}')
json.dump(rows, open('coloc_counts.json','w'))
