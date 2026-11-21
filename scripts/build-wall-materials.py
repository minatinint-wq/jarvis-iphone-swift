"""Build 2K PBR maps: original plaster/cement, CC0 Poly Haven wood. Offline at runtime."""
from pathlib import Path
import hashlib, json
import urllib.request
import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1] / 'JarvisPhone/Resources'
N = 2048
rng = np.random.default_rng(1701)

def noise():
    out = np.zeros((N,N), np.float32)
    for cells, amplitude in [(4,.35),(12,.24),(32,.18),(96,.13),(256,.07),(768,.03)]:
        grid = rng.random((cells,cells)).astype(np.float32)
        # Tile a 3x3 neighborhood before resize so opposite boundaries interpolate identically.
        tile = Image.fromarray(np.tile(grid,(3,3)), mode='F')
        big = np.asarray(tile.resize((N*3,N*3),Image.Resampling.BICUBIC))
        out += big[N:2*N,N:2*N] * amplitude
    return out

cloud = noise()
y,x = np.mgrid[0:N,0:N].astype(np.float32)/N
grain = .5 + .5*np.sin(2*np.pi*(65*x + 1.6*np.sin(2*np.pi*y) + 1.1*np.sin(2*np.pi*3*y)))
fine = rng.random((N,N)).astype(np.float32)
wood = np.clip(.53 + .22*cloud + .13*grain + .035*np.sin(2*np.pi*(220*x+2*np.sin(2*np.pi*y))),0,1)
manifest=[]
for kind in ['plaster','concrete']:
    if kind=='plaster':
        h=.75*cloud+.25*fine
        c=np.repeat(np.clip(.94+.035*(cloud-.5)+.015*(fine-.5),0,1)[...,None],3,axis=2)
        r=np.clip(.86+.12*(cloud-.5),0,1); strength=1.0
    elif kind=='wood':
        h=.7*grain+.3*cloud
        c=wood[...,None]*np.array([.86,.65,.40],np.float32)
        r=np.clip(.49+.13*cloud+.06*grain,0,1); strength=2.0
    else:
        h=.85*cloud+.15*fine
        base=np.clip(.49+.22*(cloud-.5)+.025*(fine-.5),0,1)
        c=base[...,None]*np.array([1.02,1.01,1.0],np.float32)
        r=np.clip(.79+.17*cloud,0,1);strength=1.5
    dx=(np.roll(h,-1,axis=1)-np.roll(h,1,axis=1))*strength
    dy=(np.roll(h,-1,axis=0)-np.roll(h,1,axis=0))*strength
    norm=np.stack([-dx,dy,np.ones_like(h)],axis=2)
    norm/=np.linalg.norm(norm,axis=2)[...,None]
    for channel,a in [('Color',c),('NormalGL',norm*.5+.5),('Roughness',r)]:
        file=ROOT/f'AR_{kind}_{channel}.jpg'
        Image.fromarray(np.uint8(np.clip(a,0,1)*255)).save(file,quality=95,subsampling=0)
        manifest.append(dict(file=file.name,sha256=hashlib.sha256(file.read_bytes()).hexdigest(),width=N,height=N,source='Original procedural material; scripts/build-wall-materials.py'))
for channel,suffix in [('Color','diff'),('NormalGL','nor_gl'),('Roughness','rough')]:
    url=f'https://dl.polyhaven.org/file/ph-assets/Textures/jpg/2k/wood_table_001/wood_table_001_{suffix}_2k.jpg'
    file=ROOT/f'AR_wood_{channel}.jpg'
    file.write_bytes(urllib.request.urlopen(url,timeout=30).read())
    manifest.append(dict(file=file.name,sha256=hashlib.sha256(file.read_bytes()).hexdigest(),width=N,height=N,source=url,license='CC0-1.0'))
(ROOT/'AR_MATERIALS.json').write_text(json.dumps(manifest,indent=2))
(ROOT/'AR_MATERIALS_LICENSE.txt').write_text('Original procedural plaster and concrete created for JARVIS, seed 1701.\nWood: Wood Table 001, Poly Haven, CC0 1.0. Photography: Dimitrios Savva; processing: Rico Cilliers.\nhttps://polyhaven.com/a/wood_table_001\nhttps://polyhaven.com/license\n2048 x 2048 base color, OpenGL normal and roughness.\nSee AR_MATERIALS.json for provenance and SHA-256 hashes.\n')
print('Generated',len(manifest),'2K material maps.')
