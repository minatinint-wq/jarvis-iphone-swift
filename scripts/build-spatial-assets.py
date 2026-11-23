"""Download licensed finished models and bake mobile meshes. No generative service/Blender.
Requires requests, trimesh, numpy, Pillow. Source cache may be supplied as argv[1].
"""
from pathlib import Path
import sys, json, hashlib, struct
import requests, trimesh, numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1] / 'JarvisPhone/Resources'
CACHE = Path(sys.argv[1]) if len(sys.argv)>1 else Path(__file__).resolve().parent / '.spatial-source'
SPECS = [
    ('mossrock', 'rock_moss_set_01', 'rock_moss_set_01_rock03', 'Kless Gyzen', 'https://polyhaven.com/a/rock_moss_set_01'),
    ('fern', 'fern_02', 'fern_02_a', 'Rob Tuytel / Rico Cilliers', 'https://polyhaven.com/a/fern_02'),
    ('radio', 'BoomBox', 'BoomBox', 'Microsoft', 'https://github.com/KhronosGroup/glTF-Sample-Assets/tree/main/Models/BoomBox')]

def download(url, path):
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists():
        response = requests.get(url, timeout=120); response.raise_for_status(); path.write_bytes(response.content)

manifest = []
for key, source, node, author, url in SPECS:
    directory = CACHE/source
    if source == 'BoomBox':
        source_url = 'https://raw.githubusercontent.com/KhronosGroup/glTF-Sample-Assets/main/Models/BoomBox/glTF-Binary/BoomBox.glb'
        source_file = directory/'BoomBox.glb'; download(source_url, source_file)
    else:
        metadata = requests.get('https://api.polyhaven.com/files/'+source, timeout=60).json()['gltf']['2k']['gltf']
        source_url = metadata['url']; source_file = directory/(source+'.gltf'); download(source_url, source_file)
        for relative, item in metadata['include'].items(): download(item['url'], directory/relative)
    scene = trimesh.load(source_file, force='scene')
    matrix, geometry = scene.graph[node]
    mesh = scene.geometry[geometry].copy(); mesh.apply_transform(matrix)
    # One complete rock/fern, not the source's whole scattered asset sheet.
    lower, upper = mesh.bounds; center = (lower+upper)/2; center[1] = lower[1]
    mesh.vertices = (mesh.vertices-center)/max(upper-lower)
    uv = mesh.visual.uv.copy(); uv[:,1] = 1-uv[:,1]
    vertices = np.column_stack([mesh.vertices,mesh.vertex_normals,uv]).astype('<f4')
    faces = mesh.faces.astype('<u4')
    name = 'Spatial_'+key
    binary = ROOT/(name+'.mesh')
    binary.write_bytes(b'JSP1'+struct.pack('<II',len(vertices),len(faces))+vertices.tobytes()+faces.tobytes())
    mat = mesh.visual.material
    data = {'id':key,'author':author,'source':url,'download':source_url,'license':'CC0-1.0',
            'sourceSHA256':hashlib.sha256(source_file.read_bytes()).hexdigest(),
            'triangles':len(faces),'vertices':len(vertices),'files':[],
            'doubleSided':bool(mat.doubleSided),'alphaMode':mat.alphaMode or 'OPAQUE',
            'baseColor':(mat.baseColorFactor/255).tolist() if mat.baseColorFactor is not None else [1,1,1,1],
            'metalness':float(mat.metallicFactor if mat.metallicFactor is not None else 1),
            'roughness':float(mat.roughnessFactor if mat.roughnessFactor is not None else 1)}
    for channel, image in [('Color',mat.baseColorTexture),('NormalGL',mat.normalTexture),('ARM',mat.metallicRoughnessTexture),('Emission',mat.emissiveTexture)]:
        if image is None: continue
        image = image.copy()
        if source == 'fern_02' and channel == 'Color':
            alpha_path = directory/'fern_alpha.png'
            download('https://dl.polyhaven.org/file/ph-assets/Models/png/2k/fern_02/fern_02_alpha_2k.png',alpha_path)
            image=image.convert('RGBA'); image.putalpha(Image.open(alpha_path).convert('L').resize(image.size))
        image.thumbnail((2048,2048),Image.Resampling.LANCZOS)
        ext = 'png' if channel=='Color' and 'A' in image.getbands() and image.getextrema()[-1][0]<255 else 'jpg'
        path = ROOT/(name+'_'+channel+'.'+ext)
        if ext=='jpg': image.convert('RGB').save(path,quality=88)
        else: image.save(path,optimize=True)
        data[channel] = path.name
    # Split packed maps so SceneKit's channel defaults cannot swap roughness/metalness.
    if mat.metallicRoughnessTexture is not None:
        arm=mat.metallicRoughnessTexture.convert('RGB');arm.thumbnail((2048,2048),Image.Resampling.LANCZOS)
        for channel,index in [('Roughness',1),('Metalness',2)]:
            path=ROOT/(name+'_'+channel+'.jpg');arm.getchannel(index).save(path,quality=90);data[channel]=path.name
    for path in [binary]+[ROOT/data[c] for c in ['Color','NormalGL','Roughness','Metalness','Emission'] if c in data]:
        data['files'].append({'file':path.name,'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'bytes':path.stat().st_size})
    manifest.append(data)
    print(key,len(faces),'triangles',sum(f['bytes'] for f in data['files']),'bytes')
(ROOT/'SPATIAL_ASSETS.json').write_text(json.dumps(manifest,indent=2),encoding='utf-8')
(ROOT/'SPATIAL_LICENSES.txt').write_text('Finished models, modified for mobile: isolated specimen, baked transforms, normalized scale, texture conversion.\n\n'+ '\n\n'.join(f"{a['id']} — {a['author']}\n{a['source']}\nLicense: CC0 1.0 https://creativecommons.org/publicdomain/zero/1.0/" for a in manifest),encoding='utf-8')
