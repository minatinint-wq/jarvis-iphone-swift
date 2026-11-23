"""Bake licensed GLB rigs into native SceneKit data. Run with Blender Python."""
import bpy
import hashlib
import json
import math
import struct
from mathutils import Matrix, Vector
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "JarvisPhone/Resources"
SOURCES = ROOT / "SpatialAuthoring/Sources"
PROVENANCE = {row["id"]: row for row in json.loads((SOURCES / "provenance.json").read_text())}

def matrix_values(matrix):
    return [round(matrix[row][column], 6) for column in range(4) for row in range(4)]

def digest(path):
    return {"file": path.name, "bytes": path.stat().st_size, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}

def export(name, height, clips, title, author, license_name):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=str(SOURCES / (name + ".glb")))
    imported = [obj for obj in bpy.context.scene.objects if obj not in before]
    arm = next(obj for obj in imported if obj.type == "ARMATURE")
    meshes = [obj for obj in imported if obj.type == "MESH" and (obj.parent == arm or obj.find_armature() == arm)]
    for track in arm.animation_data.nla_tracks:
        track.mute = True
    arm.animation_data.action = None
    for obj in meshes:
        if obj.data.shape_keys:
            if obj.data.shape_keys.animation_data:
                obj.data.shape_keys.animation_data.action = None
                for track in obj.data.shape_keys.animation_data.nla_tracks:
                    track.mute = True
            for shape in obj.data.shape_keys.key_blocks[1:]:
                shape.value = 0
    arm.data.pose_position = "REST"
    bpy.context.view_layer.update()
    bounds = [obj.matrix_world @ vertex.co for obj in meshes for vertex in obj.data.vertices]
    low = Vector(tuple(min(point[i] for point in bounds) for i in range(3)))
    high = Vector(tuple(max(point[i] for point in bounds) for i in range(3)))
    scale = height / (high.z - low.z)
    center = (low + high) / 2
    normalize = Matrix(((scale, 0, 0, -center.x * scale), (0, 0, scale, -low.z * scale),
                        (0, -scale, 0, center.y * scale), (0, 0, 0, 1)))
    bones = list(arm.data.bones)
    bone_index = {bone.name: i for i, bone in enumerate(bones)}
    assert len(bones) < 256
    rest = [normalize @ arm.matrix_world @ bone.matrix_local for bone in bones]
    skeleton = []
    for i, bone in enumerate(bones):
        parent = bone_index[bone.parent.name] if bone.parent else -1
        local = rest[parent].inverted() @ rest[i] if parent >= 0 else rest[i]
        skeleton.append({"name": bone.name, "parent": parent, "local": matrix_values(local), "inverseBind": matrix_values(rest[i].inverted())})
    parts, files, validation = [], [], []
    total_triangles = 0
    for obj in meshes:
        mesh = obj.data
        mesh.calc_loop_triangles()
        world = normalize @ obj.matrix_world
        normal_matrix = world.to_3x3().inverted().transposed()
        for material_index in sorted({triangle.material_index for triangle in mesh.loop_triangles}):
            vertices, skin, indices, samples = [], [], [], []
            uv = mesh.uv_layers.active
            for triangle in mesh.loop_triangles:
                if triangle.material_index != material_index:
                    continue
                for loop_index in triangle.loops:
                    vertex_index = mesh.loops[loop_index].vertex_index
                    vertex = mesh.vertices[vertex_index]
                    point = world @ vertex.co
                    normal = normal_matrix @ vertex.normal
                    normal.normalize()
                    texcoord = uv.data[loop_index].uv if uv else (0, 0)
                    vertices.append((*point, *normal, texcoord[0], 1 - texcoord[1]))
                    weights = []
                    for group in vertex.groups:
                        group_name = obj.vertex_groups[group.group].name
                        if group_name in bone_index and group.weight > 0:
                            weights.append((bone_index[group_name], group.weight))
                    if not weights:
                        weights = [(bone_index.get(obj.parent_bone, 0), 1)]
                    weights = sorted(weights, key=lambda row: -row[1])[:4]
                    total = sum(weight for _, weight in weights)
                    weights = [(bone, weight / total) for bone, weight in weights]
                    weights += [(0, 0)] * (4 - len(weights))
                    skin.append(struct.pack("<4B4f", *(bone for bone, _ in weights), *(weight for _, weight in weights)))
                    indices.append(len(indices))
                    if len(samples) < 12:
                        samples.append((vertex_index, point.copy(), weights))
            stem = f"Spatial_animated_{name}_{len(parts)}"
            path = OUT / (stem + ".mesh")
            path.write_bytes(b"JSP1" + struct.pack("<II", len(vertices), len(indices) // 3)
                             + b"".join(struct.pack("<8f", *vertex) for vertex in vertices)
                             + struct.pack(f"<{len(indices)}I", *indices))
            files.append(digest(path))
            path = OUT / (stem + ".skin")
            path.write_bytes(b"".join(skin));files.append(digest(path))
            part = {"mesh": stem + ".mesh", "skin": stem + ".skin", "roughness": 0.65, "metalness": 0.05}
            material = obj.data.materials[material_index] if obj.data.materials else None
            if material:
                part["baseColor"] = list(material.diffuse_color)
                bsdf = next((node for node in material.node_tree.nodes if node.type == "BSDF_PRINCIPLED"), None) if material.use_nodes else None
                if bsdf:
                    part["baseColor"] = list(bsdf.inputs["Base Color"].default_value)
                    part["metalness"] = float(bsdf.inputs["Metallic"].default_value)
                    part["roughness"] = float(bsdf.inputs["Roughness"].default_value)
                    if bsdf.inputs["Base Color"].links:
                        texture = bsdf.inputs["Base Color"].links[0].from_node
                        if texture.type == "TEX_IMAGE" and texture.image:
                            path = OUT / (stem + "_Color.texture")
                            texture.image.filepath_raw = str(path);texture.image.file_format = "PNG";texture.image.save()
                            part["Color"] = path.name;files.append(digest(path));part["baseColor"] = [1, 1, 1, 1]
            parts.append(part)
            validation.append((obj, samples))
            total_triangles += len(indices) // 3
    arm.data.pose_position = "POSE"
    animations = []
    worst_error = 0
    worst_detail = None
    fps = bpy.context.scene.render.fps / bpy.context.scene.render.fps_base
    for clip in clips:
        action = bpy.data.actions[clip]
        arm.animation_data.action = action
        arm.animation_data.action_slot = next(slot for slot in action.slots if slot.target_id_type == "OBJECT")
        start, end = action.frame_range
        duration = (end - start) / fps
        frames = max(2, math.ceil(duration * 24) + 1)
        animation = []
        for frame in range(frames):
            moment = start + (end - start) * frame / (frames - 1)
            bpy.context.scene.frame_set(int(moment), subframe=moment % 1)
            bpy.context.view_layer.update()
            world = [normalize @ arm.matrix_world @ arm.pose.bones[bone.name].matrix for bone in bones]
            animation.append([matrix_values(world[bone_index[bone.parent.name]].inverted() @ world[i] if bone.parent else world[i]) for i, bone in enumerate(bones)])
            if frame in [0, frames // 2, frames - 1]:
                depsgraph = bpy.context.evaluated_depsgraph_get()
                for obj, samples in validation:
                    evaluated = obj.evaluated_get(depsgraph)
                    mesh = evaluated.to_mesh()
                    for index, point, weights in samples:
                        actual = normalize @ obj.matrix_world @ mesh.vertices[index].co
                        predicted = Vector((0, 0, 0, 0))
                        for bone, weight in weights:
                            predicted += (world[bone] @ rest[bone].inverted() @ point.to_4d()) * weight
                        error=(actual-predicted.xyz).length
                        if error>worst_error:
                            worst_error=error;worst_detail=(clip,frame,obj.name,index,list(actual),list(predicted),weights)
                    evaluated.to_mesh_clear()
        animations.append({"name": clip, "duration": duration, "frames": animation})
    assert worst_error < 0.005, (name, worst_error,worst_detail)
    rig = {"heightMeters": height, "bones": skeleton, "animations": animations}
    path = OUT / f"Spatial_animated_{name}_rig.json"
    path.write_bytes(json.dumps(rig, separators=(",", ":")).encode());files.append(digest(path))
    print("ANIMATED_ASSET_OK", name, "bones", len(bones), "triangles", total_triangles, "maxSkinErrorMeters", round(worst_error, 7), flush=True)
    return {"id": "animated_" + name, "title": title, "author": author, "license": license_name,
            "source": PROVENANCE[name]["source"], "sourceSHA256": PROVENANCE[name]["sha256"],
            "rig": path.name, "heightMeters": height, "triangles": total_triangles, "parts": parts, "files": files,
            "animationSkinErrorMeters": worst_error}

assets = [export("robot", 1.70, ["Idle", "Wave", "Walking", "Punch", "Dance", "Running"],
                 "Robô expressivo · animado", "Tomás Laulhé / Don McCurdy", "CC0-1.0"),
          export("fox", 0.45, ["Survey", "Walk", "Run"], "Raposa · animada",
                 "PixelMannen / tomkranis / AsoboStudio / scurest", "CC-BY-4.0")]
path = OUT / "SPATIAL_ASSETS.json"
manifest = json.loads(path.read_text(encoding="utf-8"))
path.write_bytes(json.dumps([row for row in manifest if row["id"] not in {asset["id"] for asset in assets}] + assets,
                           indent=2, ensure_ascii=False).encode())
path = OUT / "SPATIAL_LICENSES.txt"
notice = "\n\nANIMATED CHARACTERS\nRobotExpressive — Tomás Laulhé, modifications Don McCurdy, CC0 1.0.\n" + PROVENANCE["robot"]["licenseSource"]
notice += "\nFox — model PixelMannen (CC0), rigging/animation tomkranis (CC BY 4.0), glTF conversion AsoboStudio and scurest (CC BY 4.0).\n" + PROVENANCE["fox"]["licenseSource"]
notice += "\nhttps://creativecommons.org/licenses/by/4.0/legalcode\nChanges: unit normalization, native geometry/rig conversion and animation sampling for SceneKit.\n"
text = path.read_text(encoding="utf-8")
if "ANIMATED CHARACTERS" not in text:
    path.write_bytes((text + notice).encode())
