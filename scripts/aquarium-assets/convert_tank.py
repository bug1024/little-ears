#!/usr/bin/env python3
"""Convert a bounded reef scene and all 28 local fish species for Little Ears."""
import argparse
from collections import defaultdict
import hashlib
import json
import math
from pathlib import Path
import struct
import wave

from resource_format import Reader, child, decode_dds, mesh_data

IDENTITY = [1.0 if i % 5 == 0 else 0.0 for i in range(16)]
SCENE_SCALE = 0.70

# Apply one uniform coordinate conversion to the complete authored scene.
# Independent cluster offsets would separate rocks from their connecting reef.
def reef_point(p, rid):
    if rid == 299:
        # The star is a local animal mesh, not a positioned scenery frame.
        return [p[0] * 0.50 + 0.35, (p[1] - 0.025) * 0.50 - 2.18, 2.1 - p[2] * 0.50]
    return scene_point(p)


def scene_point(p):
    return [p[0] * SCENE_SCALE, p[1] * SCENE_SCALE + 0.2, 2.5 - p[2] * SCENE_SCALE]


def scene_motion(rid, name, points):
    low = [min(p[i] for p in points) for i in range(3)]
    high = [max(p[i] for p in points) for i in range(3)]
    height = max(0.05, high[1] - low[1])
    roots = [p for p in points if p[1] <= low[1] + height * 0.09]
    pivot = [sum(p[i] for p in roots) / len(roots) for i in range(3)]
    phase = rid * 0.73 + sum(ord(c) for c in name) * 0.013
    kind, amplitude, frequency = 0, 0.0, 0.0
    if rid in [400, 420, 423, 431, 435]:
        kind, amplitude, frequency = 1, min(0.18, height * 0.065), 0.46 + (sum(map(ord, name)) % 7) * 0.027
    elif rid in [405, 406, 407]:
        phase = rid * 1.37
        kind, amplitude, frequency = (3, 0.0, 0.24) if "Mantle" in name else (2, -0.13 if "Near" in name else 0.13, 0.24)
    elif rid == 415:
        kind, amplitude, frequency = 4, 0.06, 0.40
    elif rid == 438:
        pivot = [high[0], (low[1] + high[1]) * 0.5, low[2]]
        height = max(0.05, high[0] - low[0])
        kind, amplitude, frequency, phase = 5, 0.055, 0.8, 0.4
    elif rid == 299:
        pivot = [0.35, -2.18, 2.1]
        kind, amplitude, frequency = 6, 0.004, 0.60
    return pivot + [height], [float(kind), amplitude, frequency, phase]


def matrix_mul(a, b):
    return [sum(a[row * 4 + k] * b[k * 4 + col] for k in range(4)) for row in range(4) for col in range(4)]


def point(p, m, normal=False):
    return [sum(p[k] * m[k * 4 + i] for k in range(3)) + (0 if normal else m[12 + i]) for i in range(3)]


def load_tree(path):
    r = Reader(path.read_bytes())
    if struct.unpack(">I", r.take(4))[0] != 3:
        raise ValueError("Unsupported mesh version")
    r.take(12); r.take(r.take(1)[0])
    return r.node()


def walk(node, matrix=IDENTITY, path=""):
    transform = next((c for c in node["children"] if c["kind"] == "fXfm"), None)
    if transform:
        local = list(struct.unpack(">16f", transform["data"]))
        matrix = matrix_mul(local, matrix)
    path += "/" + node["name"]
    if node["kind"] == "mesh":
        yield node, matrix, path
    for c in node["children"]:
        yield from walk(c, matrix, path)


def build(source, output):
    catalog = json.loads((source / "resource-catalog.json").read_text())
    output.mkdir(parents=True, exist_ok=True)
    texture_dir = output / "tank-textures"; texture_dir.mkdir(exist_ok=True)
    texture_entries = {e["name"].lower(): e for e in catalog if e["type"] == ".dds"}
    textures, texture_index, manifest = [], {}, []

    def read_entry(e):
        p = source / e["local_path"]
        if hashlib.sha256(p.read_bytes()).hexdigest() != e["sha256"]:
            raise ValueError("Asset digest mismatch: " + str(p))
        if not any(x["type"] == e["type"] and x["id"] == e["id"] for x in manifest):
            manifest.append({k: e[k] for k in ["type", "id", "name", "sha256"]})
        return p

    def texture(name):
        key = name.lower()
        if key in texture_index:
            return texture_index[key]
        if key not in texture_entries:
            raise ValueError("Missing texture: " + name)
        entry = texture_entries[key]
        w, h, rgba = decode_dds(read_entry(entry))
        if key == "barnacles3.dds":
            # The bottom-left atlas strip is a numbered construction legend,
            # not an animal surface. It was occluded in the authored scene.
            clean = bytearray(rgba)
            for y in range(480, h):
                for x in range(min(280, w)):
                    clean[(y * w + x) * 4 + 3] = 0
            rgba = bytes(clean)
        path = f"tank-textures/{entry['id']}.rgba"
        (output / path).write_bytes(rgba)
        index = len(textures); texture_index[key] = index
        textures.append(dict(name=name, file=path, width=w, height=h, transparent=any(rgba[i] < 250 for i in range(3, len(rgba), 4))))
        return index

    def asset(rid, scene):
        e = next(e for e in catalog if e["type"] == "fish" and e["id"] == rid)
        tree = load_tree(read_entry(e)); nodes = list(walk(tree))
        bend_mesh = next((mesh_data(n["data"]) for n, _, _ in nodes if n["name"] == "fishbend"), None)
        bend = bend_mesh[0] if bend_mesh else None
        parts, collisions, margins = [], [], []
        eel_target = next((mesh_data(n["data"]) for n, _, _ in nodes if n["name"] == "Mesh_MorayOpen"), None)
        mantle_target = next((mesh_data(n["data"])[0] for n, _, _ in nodes if n["name"] == "Mesh_Mantle3"), None)
        for n, matrix, path in nodes:
            if not scene and ("Wholefish" not in path or n["name"] == "fishbend"):
                continue
            if not scene and matrix != IDENTITY:
                raise ValueError("Animated fish with nonidentity frames is not supported")
            if scene and not any(c["kind"] == "txtL" for c in n["children"]):
                if (rid in [405, 406, 407] and n["name"] in ["Mesh_Mantle1", "Mesh_Mantle3"]) or (rid == 438 and n["name"] == "Mesh_MorayOpen"):
                    continue  # Morph targets, not additional visible surfaces.
                raise ValueError("Visible mesh without UV: " + n["name"])
            positions, indices = mesh_data(n["data"])
            if rid == 438 and (eel_target is None or len(eel_target[0]) != len(positions) or eel_target[1] != indices):
                raise ValueError("Eel mouth morph topology mismatch")
            # Achilles stores a one-triangle placeholder in its morph mesh;
            # its 185 ordered target vertices are used, never those faces.
            if not scene and n["name"] == "fishbody" and bend_mesh and (len(bend) != len(positions) or (rid != 326 and bend_mesh[1] != indices)):
                raise ValueError("Fish morph topology mismatch: " + e["name"])
            normals, normal_indices = mesh_data(child(n, "mshN")["data"])
            data = child(n, "txtL")["data"]
            count, = struct.unpack_from(">H", data)
            if len(data) != 2 + count * 8 or count != len(positions) or len(normal_indices) != len(indices):
                raise ValueError("Mesh/UV/normal topology mismatch")
            uvs = [struct.unpack_from(">2f", data, 2 + i * 8) for i in range(count)]
            material_node = child(n, "mtlL")
            material_count, face_count = struct.unpack_from(">HH", material_node["data"])
            face_materials = material_node["data"][4:]
            materials = [c for c in material_node["children"] if c["kind"] == "matl"]
            if len(face_materials) != face_count or face_count * 3 != len(indices) or material_count != len(materials):
                raise ValueError("Material face table mismatch")
            transformed = [point(p, matrix) for p in positions]
            if scene:
                # Authored left-handed reef -> right-handed observation tank.
                transformed = [reef_point(p, rid) for p in transformed]
            pivot, motion = scene_motion(rid, n["name"], transformed) if scene else ([0, 0, 0, 1], [0, 0, 0, 0])
            grouped = defaultdict(list)
            for face in range(face_count):
                mi = face_materials[face]
                if mi >= len(materials):
                    raise ValueError("Invalid face material")
                mat = materials[mi]; tex_node = child(mat, "txtf"); tex_data = tex_node["data"]
                tex = texture(tex_data[1:1 + tex_data[0]].decode("mac_roman"))
                for corner in range(face * 3, face * 3 + 3):
                    index = indices[corner]; normal = point(normals[normal_indices[corner]], matrix, True)
                    if scene:
                        normal = [normal[0], normal[1], -normal[2]]
                    delta = [bend[index][i] - positions[index][i] for i in range(3)] if n["name"] == "fishbody" and bend else [0, 0, 0]
                    if scene and motion[0] == 3 and mantle_target:
                        if len(mantle_target) != len(positions): raise ValueError("Clam morph topology mismatch")
                        target = reef_point(point(mantle_target[index], matrix), rid)
                        delta = [target[i] - transformed[index][i] for i in range(3)]
                    if scene and rid == 438:
                        target = reef_point(point(eel_target[0][index], matrix), rid)
                        delta = [target[i] - transformed[index][i] for i in range(3)]
                    part_id = 5 if n["name"] == "fishbody" else 0 if n["name"] == "eyes" else 1 if "fin" in n["name"] else 6
                    grouped[tex].append(transformed[index] + normal + list(uvs[index]) + delta + [part_id])
                if scene and rid not in [411, 419]:
                    collisions.extend(transformed[index] for index in indices[face * 3:face * 3 + 3])
                    margins.append(motion[1] * 1.5 if motion[0] == 1 else 0.46 if motion[0] == 3 else 0.20 if motion[0] == 2 else 0.06 if motion[0] == 4 else 0.30 if motion[0] == 5 else 0.32 if motion[0] == 6 else 0)
            for tex, vertices in grouped.items():
                parts.append(dict(name=n["name"], texture=tex, vertices=vertices, sway=0, pivot=pivot, motion=motion))
        if not parts:
            raise ValueError("No visible geometry: " + e["name"])
        points = [v[:3] for p in parts for v in p["vertices"]]
        bounds = [[f(p[i] for p in points) for i in range(3)] for f in [min, max]]
        result = dict(id=rid, name=e["name"], parts=parts, bounds=bounds)
        if not scene:
            scale = 0.52 if rid in [325, 327] else 0.55 if rid in [304, 305, 317] else 0.64 if rid == 306 else 0.62
            # Bound body morph, tail flex and fin flutter as well as the rest pose.
            envelope = []
            for part in parts:
                for v in part["vertices"]:
                    q = [abs(x) for x in v[:3]]
                    if part["name"] == "fishbody":
                        q = [q[i] + abs(v[8 + i]) * 0.10 for i in range(3)]
                        q[2] += 0.018
                    elif "fin" in part["name"]:
                        q[2] *= 1.14
                    envelope.append(math.sqrt(sum(x * x for x in q)))
            result.update(spawnScale=scale, collisionRadius=max(envelope) * scale + 0.035)
        return result, collisions, margins

    species_ids = sorted(e["id"] for e in catalog if e["type"] == "fish" and 300 <= e["id"] <= 327)
    if species_ids != list(range(300, 328)):
        raise ValueError("Expected complete fish catalog 300…327")
    species = [asset(i, False)[0] for i in species_ids]
    # Preserve authored relative locations and per-frame transforms. Baked shadow
    # overlays are replaced by the renderer's geometric shadow pass.
    scene_ids = [299, 438, 400, 401, 402, 403, 404, 405, 406, 407, 411, 412, 413, 414, 415, 416, 417, 418, 419, 420, 421, 422, 423, 424, 425, 426, 427, 428, 429, 430, 431, 434, 435, 436]
    scenery, triangles, collision_margins = [], [], []
    for rid in scene_ids:
        a, c, m = asset(rid, True); scenery.append(a); triangles.extend(c); collision_margins.extend(m)
    sound = next(e for e in catalog if e["type"] == "sond" and e["id"] == 128)
    sound_path = read_entry(sound)
    with wave.open(str(sound_path)) as audio:
        if (audio.getnchannels(), audio.getsampwidth(), audio.getframerate()) != (2, 2, 22050):
            raise ValueError("Unexpected bubble audio format")
    (output / "bubbles.wav").write_bytes(sound_path.read_bytes())
    texture("Lightplay.dds")
    bubble_texture = texture("bubbles.DDS")
    result = dict(species=species, scenery=scenery, textures=textures, collisionTriangles=triangles, collisionMargins=collision_margins, lightplayTexture=texture_index["lightplay.dds"], bubbleTexture=bubble_texture)
    (output / "fish-species.json").write_text(json.dumps([{k: a[k] for k in ["id", "name", "bounds", "spawnScale", "collisionRadius"]} for a in species], indent=2))
    (output / "tank.json").write_text(json.dumps(result, separators=(",", ":")))
    stats = dict(species=[s["name"] for s in species], sceneObjects=len(scenery), textures=len(textures), triangles=sum(len(p["vertices"]) // 3 for a in scenery for p in a["parts"]), collisionTriangles=len(triangles) // 3, sourceAssets=manifest, limitations=["Local exploration assets only", "Authored reef and seabed retain their relative positions under one uniform transform", "Soft coral, clam and feather-duster motion are new approximations; original simulation is not restored"])
    (output / "tank-conversion.json").write_text(json.dumps(stats, indent=2))
    print(json.dumps({k: v for k, v in stats.items() if k != "sourceAssets"}, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, default=Path("local-assets/MarineAquarium3"))
    parser.add_argument("--output", type=Path, default=Path("build/aquarium-assets"))
    args = parser.parse_args(); build(args.source, args.output)
