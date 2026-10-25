"""
edit.py - mesh edits and the model report for Blender jobs (tools/blender/jobs.mjs, DECISIONS B74):
  blender -b --factory-startup --python edit.py -- inspect  <model.glb>
  blender -b --factory-startup --python edit.py -- decimate <model.glb> <out.glb> <triangles>
  blender -b --factory-startup --python edit.py -- reshape  <model.glb> <out.glb> <bone> <scale> <children 0|1>
  blender -b --factory-startup --python edit.py -- remove   <model.glb> <out.glb> <children 0|1> <bone> [<bone> ...]

The edits write a static GLB (mesh and skin, no clips); jobs.mjs moves only its geometry back into the shipped model (merge.mjs), so
materials, textures and clips are never Blender's re-export. Positions are in Blender's Z-up armature space, the space recipes use.
"""
import json
import os
import sys

import bpy
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common  # noqa: E402


def load(path):
    """Import a model (rigged or not): (armature or None, [meshes])."""
    common.reset_scene()
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=path)
    new = [o for o in bpy.data.objects if o not in before]
    arms = [o for o in new if o.type == 'ARMATURE']
    arm = arms[0] if arms else None
    shapes = {pb.custom_shape for pb in arm.pose.bones if pb.custom_shape} if arm else set()
    meshes = [o for o in new if o.type == 'MESH' and o not in shapes]
    for o in shapes:
        bpy.data.objects.remove(o, do_unlink=True)
    if arm:
        common.clear_actions(arm)
    return arm, meshes


def skinned(meshes):
    ms = [m for m in meshes if m.vertex_groups] or meshes
    if not ms:
        raise SystemExit('the model has no mesh')
    return ms[0]


def dominant(mesh):
    """Vertex index -> name of its strongest group (or None)."""
    gname = {g.index: g.name for g in mesh.vertex_groups}
    out = {}
    for v in mesh.data.vertices:
        if v.groups:
            top = max(v.groups, key=lambda g: g.weight)
            out[v.index] = gname.get(top.group)
    return out


def bone_set(arm, names, children):
    have = {b.name for b in arm.data.bones}
    missing = [n for n in names if n not in have]
    if missing:
        raise SystemExit(f'no bone {", ".join(missing)} (inspect lists the bones)')
    out = set(names)
    if children:
        for n in names:
            out |= {c.name for c in arm.data.bones[n].children_recursive}
    return out


def tri_count(meshes):
    return sum(sum(len(p.vertices) - 2 for p in m.data.polygons) for m in meshes)


def inspect(path):
    arm, meshes = load(path)
    rep = {'triangles': tri_count(meshes), 'meshes': len(meshes)}
    mats, texs = [], []
    for m in meshes:
        for s in m.material_slots:
            if s.material and s.material.name not in mats:
                mats.append(s.material.name)
                for n in (s.material.node_tree.nodes if s.material.use_nodes else []):
                    if n.type == 'TEX_IMAGE' and n.image:
                        texs.append({'name': n.image.name, 'size': list(n.image.size)})
    rep['materials'], rep['textures'] = mats, texs
    pts = [m.matrix_world @ v.co for m in meshes for v in m.data.vertices]
    lo = Vector((min(p[i] for p in pts) for i in range(3)))
    hi = Vector((max(p[i] for p in pts) for i in range(3)))
    rep['bounds'] = {'min': [round(x, 3) for x in lo], 'max': [round(x, 3) for x in hi]}
    if arm:
        mesh = skinned(meshes)
        dom = dominant(mesh)
        inv = arm.matrix_world.inverted()
        count, low = {}, {}
        for v in mesh.data.vertices:
            b = dom.get(v.index)
            if b is None:
                continue
            count[b] = count.get(b, 0) + 1
            z = (inv @ (mesh.matrix_world @ v.co)).z
            low[b] = min(low.get(b, z), z)
        rep['armature'] = {'object': arm.name, 'matrix_world_is_identity': all(abs(arm.matrix_world[i][j] - (1 if i == j else 0)) < 1e-4 for i in range(4) for j in range(4))}
        rep['bones'] = [{
            'name': b.name, 'parent': b.parent.name if b.parent else None,
            'head': [round(x, 3) for x in b.head_local], 'tail': [round(x, 3) for x in b.tail_local],
            'children': len(b.children), 'vertices': count.get(b.name, 0),
            **({'lowest': round(low[b.name], 3)} if b.name in low else {}),
        } for b in arm.data.bones]
    print('RESULT ' + json.dumps(rep))


def export(out):
    bpy.ops.object.select_all(action='DESELECT')
    common.export_static(out)


def decimate(path, out, target):
    arm, meshes = load(path)
    mesh = skinned(meshes)
    before = tri_count([mesh])
    if target >= before:
        raise SystemExit(f'the mesh has {before} triangles, already at or under {target}')
    mod = mesh.modifiers.new('decimate', 'DECIMATE')
    mod.decimate_type = 'COLLAPSE'
    mod.ratio = target / before
    mod.use_collapse_triangulate = True
    bpy.context.view_layer.objects.active = mesh
    bpy.ops.object.modifier_apply(modifier=mod.name)
    export(out)
    print('RESULT ' + json.dumps({'triangles': [before, tri_count([mesh])]}))


def reshape(path, out, bone, scale, children):
    arm, meshes = load(path)
    if not arm:
        raise SystemExit('reshape needs a rigged model')
    mesh = skinned(meshes)
    names = bone_set(arm, [bone], children)
    idx = {mesh.vertex_groups[n].index for n in names if n in mesh.vertex_groups}
    pivot_world = arm.matrix_world @ arm.data.bones[bone].head_local
    to_mesh = mesh.matrix_world.inverted()
    pivot = to_mesh @ pivot_world
    moved = 0
    for v in mesh.data.vertices:
        w = sum(g.weight for g in v.groups if g.group in idx)
        tot = sum(g.weight for g in v.groups) or 1.0
        w = min(1.0, w / tot)
        if w <= 1e-4:
            continue
        v.co = pivot + (v.co - pivot) * (1.0 + (scale - 1.0) * w)
        moved += 1
    if not moved:
        raise SystemExit(f'bone {bone} moves no vertices')
    mesh.data.update()
    export(out)
    print('RESULT ' + json.dumps({'vertices': moved, 'bones': sorted(names)}))


def remove(path, out, children, bones):
    import bmesh
    arm, meshes = load(path)
    if not arm:
        raise SystemExit('remove needs a rigged model')
    mesh = skinned(meshes)
    names = bone_set(arm, bones, children)
    dom = dominant(mesh)
    bm = bmesh.new()
    bm.from_mesh(mesh.data)
    gone = [f for f in bm.faces if all(dom.get(v.index) in names for v in f.verts)]
    if not gone:
        raise SystemExit(f'no face is moved mostly by {", ".join(bones)}')
    before = len(bm.faces)
    bmesh.ops.delete(bm, geom=gone, context='FACES')
    loose = [v for v in bm.verts if not v.link_faces]
    bmesh.ops.delete(bm, geom=loose, context='VERTS')
    bm.to_mesh(mesh.data)
    bm.free()
    mesh.data.update()
    export(out)
    print('RESULT ' + json.dumps({'faces': [before, before - len(gone)], 'bones': sorted(names)}))


def main():
    a = common.script_args()
    op = a[0]
    if op == 'inspect':
        inspect(a[1])
    elif op == 'decimate':
        decimate(a[1], a[2], int(a[3]))
    elif op == 'reshape':
        reshape(a[1], a[2], a[3], float(a[4]), a[5] == '1')
    elif op == 'remove':
        remove(a[1], a[2], a[3] == '1', a[4:])
    else:
        raise SystemExit(f'unknown edit {op}')


main()
