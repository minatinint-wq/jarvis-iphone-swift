"""Export only the explicitly licensed public resource manifests to Cloudflare."""
from pathlib import Path
import json,hashlib,shutil,requests
ROOT=Path(__file__).resolve().parents[1]/'JarvisPhone/Resources'
OUT=Path('D:/JARVIS/PROJETO/apps/jarvis-spatial-library/public')
OUT.mkdir(parents=True,exist_ok=True)
def publish(name):
    assert Path(name).name==name and not name.startswith(('RoomScan','JarvisLatest','JARVIS'))
    data=(ROOT/name).read_bytes();digest=hashlib.sha256(data).hexdigest()
    dest=OUT/'assets'/digest/name;dest.parent.mkdir(parents=True,exist_ok=True);dest.write_bytes(data)
    return {'file':name,'bytes':len(data),'sha256':digest,'url':'/assets/'+digest+'/'+name}
models=[]
for original in json.loads((ROOT/'SPATIAL_ASSETS.json').read_text(encoding='utf-8')):
    if original['id'].startswith('demo_'):continue
    item=dict(original);item['title']=item.get('title') or {'mossrock':'Pedra com musgo','fern':'Samambaia','radio':'Rádio retrô'}[item['id']]
    item['category']='personagem' if item.get('rig') else 'natureza' if item['id'] in ['mossrock','fern','treestump'] else 'objeto'
    item['files']=[publish(f['file']) for f in item['files']]
    for f in item['files']:
        spec=next(x for x in original['files'] if x['file']==f['file']);assert spec['sha256']==f['sha256'] and spec['bytes']==f['bytes']
    if item.get('rig'):
        url=item['source'];r=requests.get(url,timeout=60);r.raise_for_status();data=r.content
        assert hashlib.sha256(data).hexdigest()==item['sourceSHA256']
        name=item['id']+'.glb';digest=hashlib.sha256(data).hexdigest();dest=OUT/'assets'/digest/name;dest.parent.mkdir(parents=True,exist_ok=True);dest.write_bytes(data);item['previewGLB']='/assets/'+digest+'/'+name
    models.append(item)
materials=[publish(f['file']) for f in json.loads((ROOT/'AR_MATERIALS.json').read_text(encoding='utf-8'))]
themes=[('room_forest','Meu quarto tomado pela floresta','natureza',['fern','mossrock','treestump']),('forest','Bosque','natureza',['fern','mossrock']),('enchanted','Floresta noturna','natureza',['fern','mossrock']),('aquarium','Jardim aquático','natureza',['barramundifish','fern','mossrock']),('studio','Estúdio interativo','ambiente',['radio']),('garage','Garagem','ambiente',['toycar','trafficcone']),('lounge','Sala interativa','ambiente',['sheenchair','anisotropybarnlamp'])]
catalog={'version':1,'models':models,'materials':materials,'environments':[{'id':i,'title':t,'category':c,'models':m,'usesPrivateRoomLocally':i=='room_forest'} for i,t,c,m in themes]}
(OUT/'catalog.json').write_text(json.dumps(catalog,ensure_ascii=False,separators=(',',':')),encoding='utf-8')
shutil.copy2(ROOT/'SPATIAL_LICENSES.txt',OUT/'LICENSES.txt')
three=Path('D:/JARVIS/PROJETO/apps/jarvis-remote/node_modules/three')
for path in ['build/three.module.js','build/three.core.js','examples/jsm/controls/OrbitControls.js','examples/jsm/loaders/GLTFLoader.js','examples/jsm/utils/BufferGeometryUtils.js','examples/jsm/utils/SkeletonUtils.js','examples/jsm/environments/RoomEnvironment.js','examples/jsm/geometries/RoundedBoxGeometry.js']:
    relative=path.replace('build/','').replace('examples/jsm/','addons/');dest=OUT/'vendor'/relative;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(three/path,dest)
files=list((OUT/'assets').glob('*/*'));assert all(p.stat().st_size<25*1024*1024 for p in files)
print(json.dumps({'public_models':len(models),'environments':len(themes),'public_files':len(files),'bytes':sum(p.stat().st_size for p in files),'private_scan_exported':False}))
