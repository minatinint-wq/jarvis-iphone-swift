"""Extract the visible shell from a JARVIS V9 GLB; no electronics/stand in the app."""
import argparse, json, struct
from pathlib import Path
import numpy as np
import trimesh
from trimesh.transformations import quaternion_matrix
from PIL import Image, ImageDraw

def build(src,out):
    with src.open('rb') as f:
        assert f.read(4)==b'glTF';f.seek(12); n,kind=struct.unpack('<II',f.read(8));j=json.loads(f.read(n))
        n,kind=struct.unpack('<II',f.read(8));data=f.read(n)
    def accessor(i):
        a=j['accessors'][i];v=j['bufferViews'][a['bufferView']]
        dtype={5123:'<u2',5125:'<u4',5126:'<f4',5121:'u1'}[a['componentType']]
        count={'VEC3':3,'SCALAR':1}[a['type']]
        return np.ndarray((a['count'],count),dtype,data,offset=v.get('byteOffset',0)+a.get('byteOffset',0),
                          strides=(v.get('byteStride',np.dtype(dtype).itemsize*count),np.dtype(dtype).itemsize))
    wanted={'casco-traseiro':(0,14500),'coroa':(0,8500),'frente':(1,21500),'difusores-olhos':(2,2000),
            'LCD-superficie-240x320':(3,32),'OV7670':(3,500)}
    chunks=[];found=set()
    def walk(i,parent):
        o=j['nodes'][i]; q=o.get('rotation',[0,0,0,1]);mat=quaternion_matrix([q[3],*q[:3]])
        mat[:3,:3]@=np.diag(o.get('scale',[1]*3));mat[:3,3]=o.get('translation',[0]*3)
        mat=parent@(np.array(o['matrix']).reshape(4,4).T if 'matrix' in o else mat)
        name=o.get('name','').split('/')[-1]
        if 'mesh' in o and name in wanted:
            found.add(name);kind,limit=wanted[name]
            for p in j['meshes'][o['mesh']]['primitives']:
                verts=accessor(p['attributes']['POSITION'])@mat[:3,:3].T+mat[:3,3]
                mesh=trimesh.Trimesh(verts,accessor(p['indices']).reshape(-1,3),process=True)
                if len(mesh.faces)>limit: mesh=mesh.simplify_quadric_decimation(face_count=limit)
                chunks.append((kind,np.array(mesh.vertices),np.array(mesh.vertex_normals),np.array(mesh.faces)))
        for child in o.get('children',[]):walk(child,mat)
    for root in j['scenes'][j.get('scene',0)]['nodes']:walk(root,np.eye(4))
    assert found==set(wanted)
    pts=np.vstack([v for _,v,_,_ in chunks]);lo=pts.min(axis=0);hi=pts.max(axis=0)
    file=bytearray(b'XLV1'+struct.pack('<I',len(chunks))); polys=[]
    for kind,v,n,f in chunks:
        v=(v-(lo+hi)/2)*2/(hi[1]-lo[1])
        file+=struct.pack('<III',kind,len(v),len(f))+v.astype('<f4').tobytes()+n.astype('<f4').tobytes()+f.astype('<u4').tobytes()
        # Render a fixed three-quarter view from the same triangles for WidgetKit.
        a=-0.33;r=np.array([[np.cos(a),0,np.sin(a)],[0,1,0],[-np.sin(a),0,np.cos(a)]])
        xyz=v@r.T; ns=n@r.T; screen=xyz[:,:2]*np.array([207,-207])+[240,252]
        base=np.array([(177,23,43),(233,175,69),(91,230,249),(31,41,51)][kind])
        normals=ns[f].mean(axis=1);light=np.maximum(0,normals@[-.45,.48,.75])
        gloss=np.maximum(0,normals@[-.24,.33,.91])**18
        colors=np.clip(base*(.52+.55*light[:,None])+gloss[:,None]*74+(35 if kind==2 else 0),0,255).astype(int)
        for z,tri,c in zip(xyz[f,2].mean(axis=1),screen[f],colors):polys.append((z,tri,c))
    (out/'WakeHelmet.mesh').write_bytes(file)
    im=Image.new('RGBA',(480,512));d=ImageDraw.Draw(im)
    for _,tri,c in sorted(polys,key=lambda x:x[0]):d.polygon([tuple(pt) for pt in tri],fill=tuple(c)+(255,))
    im.thumbnail((180,192),Image.Resampling.LANCZOS);im.save(out/'WakePortrait.png')
    print(f'{len(chunks)} superfícies; {sum(len(f) for _,_,_,f in chunks)} triângulos; {len(file)} bytes')

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('glb',type=Path);p.add_argument('out',type=Path);a=p.parse_args();build(a.glb,a.out)
