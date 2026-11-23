"""Run with Blender --background --python. Models use meters and floor origins."""
import bpy
import hashlib
import json
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "JarvisPhone/Resources"
OUTPUT = ROOT / "SpatialAuthoring"
OUTPUT.mkdir(exist_ok=True)
bpy.ops.object.select_all(action="SELECT")
bpy.ops.object.delete(use_global=False)
bpy.context.scene.unit_settings.system = "METRIC"
bpy.context.scene.unit_settings.scale_length = 1

materials = []
for name, color in [("Graphite", (0.055, 0.08, 0.12, 1)), ("Steel", (0.55, 0.62, 0.7, 1)), ("Cyan", (0.02, 0.65, 0.8, 1))]:
    material = bpy.data.materials.new(name)
    material.diffuse_color = color
    materials.append(material)

def box(name, size, position, material=0):
    bpy.ops.mesh.primitive_cube_add(size=1, location=position)
    obj = bpy.context.object
    obj.name = name
    obj.dimensions = size
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    bevel = obj.modifiers.new("Rounded edges", "BEVEL")
    bevel.width = min(size) * 0.12
    bevel.segments = 3
    obj.data.materials.append(materials[material])
    return obj

specs = []
def export(identifier, title, height):
    objects = [obj for obj in bpy.context.scene.objects if obj.type == "MESH"]
    evaluated = bpy.context.evaluated_depsgraph_get()
    parts, files = [], []
    bounds = []
    triangles = 0
    for index, obj in enumerate(objects):
        mesh = obj.evaluated_get(evaluated).to_mesh()
        mesh.calc_loop_triangles()
        positions, indices = [], []
        for triangle in mesh.loop_triangles:
            for vertex_index in triangle.vertices:
                vertex = mesh.vertices[vertex_index]
                point = obj.matrix_world @ vertex.co
                normal = obj.matrix_world.to_3x3() @ vertex.normal
                normal.normalize()
                bounds.append(tuple(point))
                positions.append((point.x, point.z, -point.y, normal.x, normal.z, -normal.y, 0, 0))
                indices.append(len(indices))
        name = f"Spatial_{identifier}_{index}.mesh"
        data = b"JSP1" + struct.pack("<II", len(positions), len(indices) // 3)
        data += b"".join(struct.pack("<8f", *p) for p in positions)
        data += struct.pack(f"<{len(indices)}I", *indices)
        (RESOURCES / name).write_bytes(data)
        color = list(obj.data.materials[0].diffuse_color)
        parts.append({"mesh": name, "baseColor": color, "roughness": 0.38, "metalness": 0.3})
        files.append({"file": name, "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)})
        triangles += len(indices) // 3
        obj.evaluated_get(evaluated).to_mesh_clear()
    measured = max(p[2] for p in bounds) - min(p[2] for p in bounds)
    assert abs(measured - height) < 0.001, (identifier, measured, height)
    assert abs(min(p[2] for p in bounds)) < 0.001
    specs.append({"id": identifier, "title": title, "author": "JARVIS project", "license": "CC0-1.0", "source": "Blender procedural metric demo", "heightMeters": height, "triangles": triangles, "parts": parts, "files": files})
    bpy.ops.export_scene.gltf(filepath=str(OUTPUT / f"{identifier}.glb"), export_format="GLB")
    bpy.ops.wm.save_as_mainfile(filepath=str(OUTPUT / f"{identifier}.blend"))
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)

box("Torso", (.38, .24, .5), (0, 0, 1.10), 1)
box("Waist", (.28, .20, .16), (0, 0, .77))
box("Head", (.24, .23, .29), (0, 0, 1.555), 1)
box("Visor", (.205, .025, .09), (0, -.12, 1.59), 2)
for side in [-1, 1]:
    box("Leg", (.12, .15, .62), (.105 * side, 0, .39))
    box("Boot", (.15, .27, .16), (.105 * side, -.045, .08), 1)
    box("Arm", (.11, .15, .52), (.265 * side, 0, 1.05))
    box("Hand", (.12, .17, .16), (.265 * side, 0, .72), 1)
box("Core", (.12, .025, .12), (0, -.125, 1.15), 2)
export("demo_human", "Personagem · 1,70 m", 1.70)
box("Box", (.30, .30, .30), (0, 0, .15), 1)
export("demo_box", "Caixa · 30 cm", .30)
box("Seat", (.45, .45, .06), (0, 0, .45), 1)
box("Back", (.45, .065, .42), (0, .19, .69), 1)
for x in [-.18, .18]:
    for y in [-.18, .18]:
        box("Leg", (.045, .045, .42), (x, y, .21))
export("demo_chair", "Cadeira · 90 cm", .90)
box("Top", (1.10, .70, .06), (0, 0, .72), 1)
for x in [-.47, .47]:
    for y in [-.27, .27]:
        box("Leg", (.055, .055, .69), (x, y, .345))
export("demo_table", "Mesa · 75 cm", .75)
box("Panel", (.60, .035, .36), (0, 0, .18))
for x in [-.18, 0, .18]:
    box("Tile", (.15, .012, .23), (x, -.024, .18), 2)
export("demo_panel", "Painel de teste · 60 cm", .36)
manifest = RESOURCES / "SPATIAL_ASSETS.json"
old = json.loads(manifest.read_text(encoding="utf-8"))
manifest.write_text(json.dumps([s for s in old if not s["id"].startswith("demo_")] + specs, ensure_ascii=False, indent=2), encoding="utf-8")
(OUTPUT / "dimensions.json").write_text(json.dumps({s["id"]: {"heightMeters": s["heightMeters"], "triangles": s["triangles"]} for s in specs}, indent=2), encoding="utf-8")
print("METRIC_DEMO_OK", json.dumps({s["id"]: s["heightMeters"] for s in specs}))
