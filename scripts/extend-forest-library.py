"""Prepare licensed finished assets for the phone and the public library.
Downloads only public Poly Haven inputs. Never traverses or exports the room scan.
"""
from pathlib import Path
import sys,json,struct,hashlib,urllib.parse
sys.path.insert(0,'D:/JARVIS/CACHE/ios-dev/room-tools/lib')
import requests,numpy as np,trimesh
from PIL import Image

ROOT=Path(__file__).resolve().parents[1]/'JarvisPhone/Resources'
CACHE=Path('D:/JARVIS/CACHE/ios-dev/library-sources')
SPECS=[('treestump','tree_stump_01','Tronco com raízes','Rob Tuytel'),('rubberduck','rubber_duck_toy','Pato de borracha','Plat251')]
def fetch(url,path):
    if not path.exists():
        path.parent.mkdir(parents=True,exist_ok=True)
        r=requests.get(url,timeout=60);r.raise_for_status();path.write_bytes(r.content)
    return path

manifest=json.loads((ROOT/'SPATIAL_ASSETS.json').read_text(encoding='utf-8'))
for identifier,source,title,author in SPECS:
    if any(x['id']==identifier for x in manifest):continue
    folder=CACHE/source
    url=f'https://dl.polyhaven.org/file/ph-assets/Models/gltf/2k/{source}/{source}_2k.gltf'
    path=fetch(url,folder/(source+'.gltf'));doc=json.loads(path.read_bytes())
    assert sum(b.get('byteLength',0) for b in doc.get('buffers',[]))<15_000_000
    for item in doc.get('buffers',[])+doc.get('images',[]):
        relative=item.get('uri','')
        if relative.startswith('data:'):continue
        target=(folder/relative).resolve();assert target.is_relative_to(folder.resolve())
        fetch(f'https://dl.polyhaven.org/file/ph-assets/Models/{Path(relative).suffix[1:]}/2k/{source}/{Path(relative).name}' if relative.startswith('textures/') else urllib.parse.urljoin(url,relative),target)
    scene=trimesh.load(path,force='scene')
    pieces=[]
    for node in scene.graph.nodes_geometry:
        matrix,name=scene.graph[node];mesh=scene.geometry[name].copy();mesh.apply_transform(matrix);pieces.append(mesh)
    lower=np.min([m.bounds[0] for m in pieces],axis=0);upper=np.max([m.bounds[1] for m in pieces],axis=0)
    center=(lower+upper)/2;center[1]=lower[1];scale=max(upper-lower)
    entry={'id':identifier,'title':title,'author':author,'license':'CC0-1.0','source':'https://polyhaven.com/a/'+source,'download':url,'sourceSHA256':hashlib.sha256(path.read_bytes()).hexdigest(),'files':[],'parts':[],'triangles':0,'vertices':0}
    for index,mesh in enumerate(pieces):
        mesh.vertices=(mesh.vertices-center)/scale
        uv=mesh.visual.uv.copy();uv[:,1]=1-uv[:,1]
        vertices=np.column_stack([mesh.vertices,mesh.vertex_normals,uv]).astype('<f4');faces=mesh.faces.astype('<u4')
        assert len(faces)<150000 and len(vertices)<300000
        name=f'Spatial_{identifier}_{index}';binary=ROOT/(name+'.mesh')
        binary.write_bytes(b'JSP1'+struct.pack('<II',len(vertices),len(faces))+vertices.tobytes()+faces.tobytes())
        mat=mesh.visual.material
        part={'mesh':binary.name,'doubleSided':bool(mat.doubleSided),'alphaMode':mat.alphaMode or 'OPAQUE','metalness':float(mat.metallicFactor if mat.metallicFactor is not None else 0),'roughness':float(mat.roughnessFactor if mat.roughnessFactor is not None else 1),'baseColor':(mat.baseColorFactor/255).tolist() if mat.baseColorFactor is not None else [1,1,1,1]}
        paths=[binary]
        for channel,image in [('Color',mat.baseColorTexture),('NormalGL',mat.normalTexture),('ARM',mat.metallicRoughnessTexture)]:
            if image is None:continue
            image=image.copy();image.thumbnail((1024,1024),Image.Resampling.LANCZOS)
            if channel=='ARM':
                for key,n in [('Roughness',1),('Metalness',2)]:
                    file=ROOT/(name+'_'+key+'.jpg');image.convert('RGB').getchannel(n).save(file,quality=90);part[key]=file.name;paths.append(file)
            else:
                file=ROOT/(name+'_'+channel+'.jpg');image.convert('RGB').save(file,quality=91);part[channel]=file.name;paths.append(file)
        entry['parts'].append(part);entry['triangles']+=len(faces);entry['vertices']+=len(vertices)
        entry['files'] += [{'file':p.name,'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'bytes':p.stat().st_size} for p in paths]
    manifest.append(entry)
    print(identifier,entry['triangles'],'triangles',sum(f['bytes'] for f in entry['files']),'bytes')
(ROOT/'SPATIAL_ASSETS.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf-8')

materials=json.loads((ROOT/'AR_MATERIALS.json').read_text(encoding='utf-8'))
for suffix in ['diff','nor_gl','rough']:
    source=f'https://dl.polyhaven.org/file/ph-assets/Textures/jpg/1k/concrete_moss/concrete_moss_{suffix}_1k.jpg'
    file=ROOT/f'RoomForest_moss_{suffix}.jpg';fetch(source,file)
    if not any(x['file']==file.name for x in materials):materials.append({'file':file.name,'sha256':hashlib.sha256(file.read_bytes()).hexdigest(),'width':1024,'height':1024,'license':'CC0-1.0','source':'https://polyhaven.com/a/concrete_moss'})
(ROOT/'AR_MATERIALS.json').write_text(json.dumps(materials,indent=2),encoding='utf-8')
with (ROOT/'SPATIAL_LICENSES.txt').open('a',encoding='utf-8') as f:
    f.write('\nTree Stump 01 by Rob Tuytel; Rubber Duck Toy by Plat251; Concrete Moss by Rob Tuytel. Poly Haven, CC0-1.0. See SPATIAL_ASSETS.json and AR_MATERIALS.json for original URLs and file hashes.\n')
