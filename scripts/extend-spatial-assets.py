"""Bake 20 licensed finished models for the native SceneKit catalog. Requires trimesh, requests, numpy, Pillow.
Preserves separate material parts, textures and baked world transforms. No Blender.
Source advanced glTF optical extensions are approximated by native PBR. Skeletal animation is not imported.
"""
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
import requests, json, hashlib, struct, sys
import trimesh, numpy as np
from PIL import Image
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'JarvisPhone/Resources'
CACHE=Path(sys.argv[1]) if len(sys.argv)>1 else ROOT/'scripts/.spatial-source'
BASE='https://raw.githubusercontent.com/KhronosGroup/glTF-Sample-Assets/main/Models/'
SPECS=[('Avocado','Abacate'),('WaterBottle','Garrafa'),('Lantern','Lanterna antiga'),('ToyCar','Carro de corrida'),('BarramundiFish','Peixe'),('SheenChair','Poltrona'),('GlamVelvetSofa','Sofá de veludo'),('MaterialsVariantsShoe','Tênis'),('SciFiHelmet','Capacete espacial'),('FlightHelmet','Capacete de piloto'),('AntiqueCamera','Câmera antiga'),('TrafficCone','Cone de trânsito'),('CommercialRefrigerator','Geladeira'),('ChronographWatch','Relógio'),('ChairDamaskPurplegold','Cadeira clássica'),('SpecularSilkPouf','Pufe'),('SheenWoodLeatherSofa','Sofá de couro'),('AnisotropyBarnLamp','Luminária'),('IridescenceAbalone','Concha'),('GlassVaseFlowers','Vaso de flores')]
def download(url,path):
 path.parent.mkdir(parents=True,exist_ok=True)
 if not path.exists():
  r=requests.get(url,timeout=120);r.raise_for_status();path.write_bytes(r.content)
 return path
index={x['name']:x for x in requests.get(BASE+'model-index.json',timeout=30).json()}
def source(pair):
 name,title=pair;folder=CACHE/name
 readme=download(BASE+name+'/README.md',folder/'README.md').read_text(encoding='utf-8')
 legal=readme.split('## Legal')[-1].split('<!--')[0].strip()
 assert 'creativecommons.org' in legal,(name,legal)
 variants=index[name]['variants'];kind='glTF-Binary' if 'glTF-Binary' in variants else 'glTF'
 url=BASE+name+'/'+kind+'/'+variants[kind];path=download(url,folder/variants[kind])
 if kind=='glTF':
  doc=json.loads(path.read_text())
  for item in doc.get('buffers',[])+doc.get('images',[]):
   uri=item.get('uri','')
   if uri and not uri.startswith('data:'):download(BASE+name+'/'+kind+'/'+uri,folder/uri)
 return name,title,url,path,legal
sources=list(ThreadPoolExecutor(6).map(source,SPECS))
manifest=json.loads((OUT/'SPATIAL_ASSETS.json').read_text(encoding='utf-8'))
manifest=[x for x in manifest if x['id'] in ['mossrock','fern','radio']]
licenses=(OUT/'SPATIAL_LICENSES.txt').read_text(encoding='utf-8').split('\n\nADDITIONAL CATALOG')[0]
for name,title,url,path,legal in sources:
 key=name.lower();scene=trimesh.load(path,force='scene');meshes=[]
 for node in scene.graph.nodes_geometry:
  matrix,g=scene.graph[node];m=scene.geometry[g].copy()
  if not isinstance(m,trimesh.Trimesh):continue
  m.apply_transform(matrix);meshes.append(m)
 lower=np.min([m.bounds[0] for m in meshes],axis=0);upper=np.max([m.bounds[1] for m in meshes],axis=0)
 center=(lower+upper)/2;center[1]=lower[1];scale=max(upper-lower)
 asset={'id':key,'title':title,'source':BASE+name+'/README.md','download':url,'sourceSHA256':hashlib.sha256(path.read_bytes()).hexdigest(),'licenseNotice':legal,'license':'CC0-1.0' if 'Attribution 4.0' not in legal else 'CC-BY-4.0','parts':[],'files':[],'triangles':0,'vertices':0}
 for i,m in enumerate(meshes):
  m.vertices=(m.vertices-center)/scale
  uv=getattr(m.visual,'uv',None)
  uv=np.zeros((len(m.vertices),2)) if uv is None else uv.copy();uv[:,1]=1-uv[:,1]
  verts=np.column_stack([m.vertices,m.vertex_normals,uv]).astype('<f4');faces=m.faces.astype('<u4')
  assert len(verts)<300000 and len(faces)<300000,(name,len(verts),len(faces))
  stem='Spatial_'+key+'_'+str(i);meshfile=OUT/(stem+'.mesh')
  meshfile.write_bytes(b'JSP1'+struct.pack('<II',len(verts),len(faces))+verts.tobytes()+faces.tobytes())
  mat=m.visual.material
  if not hasattr(mat,'baseColorFactor'):mat=mat.to_pbr()
  factor=mat.baseColorFactor
  part={'mesh':meshfile.name,'baseColor':(factor/255).tolist() if factor is not None else [1,1,1,1],'metalness':float(mat.metallicFactor if mat.metallicFactor is not None else 1),'roughness':float(mat.roughnessFactor if mat.roughnessFactor is not None else 1),'doubleSided':bool(mat.doubleSided),'alphaMode':mat.alphaMode or 'OPAQUE'}
  files=[meshfile]
  channels=[('Color',mat.baseColorTexture),('NormalGL',mat.normalTexture),('Emission',mat.emissiveTexture)]
  if mat.metallicRoughnessTexture is not None:
   arm=mat.metallicRoughnessTexture.convert('RGB');channels += [('Roughness',arm.getchannel(1)),('Metalness',arm.getchannel(2))]
  for ch,im in channels:
   if im is None:continue
   im=im.copy();im.thumbnail((1024,1024),Image.Resampling.LANCZOS)
   alpha=ch=='Color' and 'A' in im.getbands() and im.getextrema()[-1][0]<255
   target=OUT/(stem+'_'+ch+('.texture' if alpha else '.jpg'))
   if alpha:im.save(target,format='PNG',optimize=True)
   else:im.convert('RGB').save(target,quality=88)
   part[ch]=target.name;files.append(target)
  # Preserve original emission factor; dark glass must not turn into opaque white.
  if mat.emissiveFactor is not None:part['emissionFactor']=mat.emissiveFactor.tolist()
  if 'glass' in str(mat.name).lower() or 'lens' in str(mat.name).lower():part['glass']=True
  asset['parts'].append(part);asset['triangles']+=len(faces);asset['vertices']+=len(verts)
  for f in files:asset['files'].append({'file':f.name,'sha256':hashlib.sha256(f.read_bytes()).hexdigest(),'bytes':f.stat().st_size})
 manifest.append(asset)
 print(name,len(meshes),'parts',asset['triangles'],'triangles',round(sum(x['bytes'] for x in asset['files'])/1e6,2),'MB',flush=True)
(OUT/'SPATIAL_ASSETS.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf-8')
(OUT/'SPATIAL_LICENSES.txt').write_text(licenses+'\n\nADDITIONAL CATALOG — models modified: baked world transforms, normalized scale, mobile texture conversion, static geometry. Native PBR approximates advanced optical extensions.\n\n'+'\n\n'.join(x['title']+'\n'+x['source']+'\n'+x['licenseNotice'] for x in manifest[3:]),encoding='utf-8')
assert len(manifest)==23
print('TOTAL',sum(sum(f['bytes'] for f in a['files']) for a in manifest)/1e6,'MB')
