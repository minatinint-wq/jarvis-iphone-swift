import bpy,json,struct,hashlib
from pathlib import Path
root=Path(__file__).resolve().parents[1];res=root/'JarvisPhone/Resources'
manifest=json.loads((res/'SPATIAL_ASSETS.json').read_text(encoding='utf-8'))
for name in ['treant','stone_golem','bog_monster']:
    source=root/'SpatialAuthoring/Sources'/(name+'.glb');blob=source.read_bytes();length=struct.unpack_from('<I',blob,12)[0]
    gltf=json.loads(blob[20:20+length]);binary=20+length+8;materials={m['name']:m for m in gltf['materials']}
    asset=next(a for a in manifest if a['id']=='animated_'+name)
    bpy.ops.wm.read_factory_settings(use_empty=True);bpy.ops.import_scene.gltf(filepath=str(source))
    arm=next(o for o in bpy.context.scene.objects if o.type=='ARMATURE')
    meshes=[o for o in bpy.context.scene.objects if o.type=='MESH' and (o.parent==arm or o.find_armature()==arm)]
    index=0
    for obj in meshes:
        mesh=obj.data;mesh.calc_loop_triangles();colors=mesh.color_attributes.active_color
        for material_index in sorted({t.material_index for t in mesh.loop_triangles}):
            part=asset['parts'][index];index+=1;raw=materials[obj.data.materials[material_index].name]
            assert part['sourceMaterial']==raw['name']
            pbr=raw.get('pbrMetallicRoughness',{});part['baseColor']=pbr.get('baseColorFactor',[1,1,1,1])
            if 'baseColorTexture' in pbr:
                image=gltf['images'][gltf['textures'][pbr['baseColorTexture']['index']]['source']]
                v=gltf['bufferViews'][image['bufferView']];start=binary+v.get('byteOffset',0)
                path=res/(Path(part['mesh']).stem+'_Color.texture');path.write_bytes(blob[start:start+v['byteLength']]);part['Color']=path.name
            if colors:
                values=[]
                for triangle in mesh.loop_triangles:
                    if triangle.material_index != material_index:continue
                    for loop in triangle.loops:
                        i=mesh.loops[loop].vertex_index if colors.domain=='POINT' else loop
                        values.extend(colors.data[i].color)
                mesh_data=(res/part['mesh']).read_bytes();count=struct.unpack_from('<I',mesh_data,4)[0]
                assert len(values)==count*4,(name,index,count,len(values))
                path=res/(Path(part['mesh']).stem+'.color');path.write_bytes(struct.pack('<'+'f'*len(values),*values));part['vertexColor']=path.name
    assert index==len(asset['parts'])
    files={f['file'] for f in asset['files']}
    for part in asset['parts']:
        for key in ['Color','vertexColor']:
            if key in part:files.add(part[key])
    asset['files']=[{'file':name,'bytes':(res/name).stat().st_size,'sha256':hashlib.sha256((res/name).read_bytes()).hexdigest()} for name in sorted(files)]
    print('SOURCE_COLORS_RESTORED',name,'painted',sum('vertexColor' in p for p in asset['parts']),'textures',sum('Color' in p for p in asset['parts']),flush=True)
(res/'SPATIAL_ASSETS.json').write_text(json.dumps(manifest,indent=2,ensure_ascii=False),encoding='utf-8',newline='\n')
