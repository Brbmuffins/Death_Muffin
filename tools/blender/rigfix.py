"""
rigfix.py - add bones to a Tripo rig and move vertex weights onto them:
  blender -b --python rigfix.py -- <in_rig.glb> <recipe.json> <out.glb>

The recipe's "rigfix" section lists legs to add. Example (the cinderhound has no front-leg bones at all: both forelegs are
skinned to its neck/chest bone, so no clip can ever walk them):

  "rigfix": { "from": "rig.glb", "legs": [{
      "prefix": "FL", "parent": "tripo::0_Right_Limb_1", "x": -0.105,
      "joints": [[-0.105, 0.21, 0.44], [-0.105, 0.17, 0.30], [-0.105, 0.20, 0.12], [-0.105, 0.25, 0.01]],
      "names": ["FL_Upper", "FL_Lower", "FL_Paw"],
      "select": { "radius": 0.045, "radiusLow": 0.075, "zLow": 0.2, "yMin": 0.12, "zTop": [0.40, 0.30] },
      "blend": 0.03
  }]}

`joints` are shoulder, elbow, wrist, toe in WORLD coordinates of the imported scene (Blender Z up). Every vertex within
`radius` (x distance from the leg's axis; `radiusLow` below height `zLow`, where the paw spreads) and below `zTop[0]` gives
up part of ALL its old influences (chest, neck, stubs: so no old bone can drag the leg) to the new bones: everything below
`zTop[1]`, fading out above it, so the shoulder stays attached to the chest. Along the leg the weight changes bone at the
elbow and wrist heights with a `blend` metre cross-fade. Vertex groups are renormalised; the glTF exporter keeps the four
strongest influences per vertex.
"""
import os
import sys

import bpy
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common  # noqa: E402
from kin import smoothstep  # noqa: E402


def seg_dist(p, a, b):
    """Distance from p to segment a-b and the clamped parameter along it."""
    ab = b - a
    t = max(0.0, min(1.0, (p - a).dot(ab) / max(1e-12, ab.dot(ab))))
    return (p - (a + ab * t)).length, t


def reweight_capsule(mesh, spec, names, skip_idx):
    """
    Capsule selection (hound, tails): every vertex within `radii[i]` of bone i's segment moves its old influences onto the
    new bones (shared by how close it is to each segment), fading out over `soft` metres at the surface and over
    select.zTop (full, zero) in height so the top of the limb stays on the body. `rootFade` ramps in the first bone's
    first part (a tail must stay joined to the rump). Vertices already owned by earlier new chains (`skip_idx`) are left alone.
    """
    sel = spec['select']
    J = [Vector(j) for j in spec['joints']]
    radii = sel['radii']
    soft = sel.get('soft', 0.02)
    zfull, zzero = sel.get('zTop', [9, 10])
    rf = sel.get('rootFade')
    new_idx = {mesh.vertex_groups[nm].index for nm in names}
    moved = 0
    for v in mesh.data.vertices:
        p = mesh.matrix_world @ v.co
        if p.z > zzero:
            continue
        s = []
        for i in range(len(names)):
            d, t = seg_dist(p, J[i], J[i + 1])
            sc = 1.0 - smoothstep((d - (radii[i] - soft)) / soft)
            if i == 0 and rf:
                # parameter measured unclamped so points behind the root get nothing
                ab = J[1] - J[0]
                tu = (p - J[0]).dot(ab) / max(1e-12, ab.dot(ab))
                sc *= smoothstep(tu / rf)
            s.append(sc)
        legness = max(s)
        if legness <= 1e-3:
            continue
        old = [(g.group, g.weight) for g in v.groups if g.group not in new_idx]
        taken = sum(g.weight for g in v.groups if g.group in skip_idx)
        total = sum(w for _, w in old)
        if total <= 0 or taken > 0.3:
            continue
        wleg = legness * (1.0 if p.z <= zfull else 1.0 - smoothstep((p.z - zfull) / max(1e-6, zzero - zfull)))
        ssum = sum(s) or 1.0
        for gi, w in old:
            mesh.vertex_groups[gi].add([v.index], w * (1 - wleg), 'REPLACE')
        for nm, part in zip(names, s):
            w = wleg * total * part / ssum
            if w > 1e-4:
                mesh.vertex_groups[nm].add([v.index], w, 'ADD')
        moved += 1
    return moved


def add_leg(arm, mesh, spec, skip_idx=frozenset()):
    off = Vector(arm.location)
    joints = [Vector(j) - off for j in spec['joints']]
    names = spec['names']
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.mode_set(mode='EDIT')
    eb = arm.data.edit_bones
    parent = eb[spec['parent']]
    prev = parent
    for i, nm in enumerate(names):
        b = eb.new(nm)
        b.head = joints[i]
        b.tail = joints[i + 1]
        b.parent = prev
        b.use_connect = False
        prev = b
    bpy.ops.object.mode_set(mode='OBJECT')
    # Vertex groups
    for nm in names:
        if nm not in mesh.vertex_groups:
            mesh.vertex_groups.new(name=nm)
    sel = spec['select']
    if 'radii' in sel:
        return reweight_capsule(mesh, {**spec, 'joints': [list(j) for j in joints_world(spec)]}, names, skip_idx)
    new_idx = {mesh.vertex_groups[nm].index for nm in names}
    zfull, zzero = sel['zTop'][1], sel['zTop'][0]
    el, wr = spec['joints'][1][2], spec['joints'][2][2]
    bl = spec.get('blend', 0.035)
    moved = 0
    for v in mesh.data.vertices:
        p = mesh.matrix_world @ v.co
        # the foot spreads wider than the limb above it
        radius = sel['radiusLow'] if p.z <= sel.get('zLow', 0.2) else sel['radius']
        if p.y < sel.get('yMin', -9) or abs(p.x - spec['x']) > radius or p.z > zzero:
            continue
        old = [(g.group, g.weight) for g in v.groups if g.group not in new_idx]
        total = sum(w for _, w in old)
        if total <= 0:
            continue
        wleg = 1.0 if p.z <= zfull else 1.0 - smoothstep((p.z - zfull) / max(1e-6, zzero - zfull))
        # upper = above the elbow band; lower = between elbow and wrist; paw = below the wrist band
        a_up = smoothstep((p.z - (el - bl)) / (2 * bl))
        a_lo = smoothstep((p.z - (wr - bl)) / (2 * bl))
        parts = [a_up, (1 - a_up) * a_lo, (1 - a_lo)]
        tot = sum(parts) or 1.0
        # Every old influence (chest, neck, stubs) gives up the same share, so no bone left behind can drag the leg.
        for gi, w in old:
            mesh.vertex_groups[gi].add([v.index], w * (1 - wleg), 'REPLACE')
        for nm, part in zip(names, parts):
            w = wleg * total * part / tot
            if w > 1e-4:
                mesh.vertex_groups[nm].add([v.index], w, 'ADD')
        moved += 1
    return moved


def joints_world(spec):
    return spec['joints']


def main():
    a = common.script_args()
    src, recipe_path, dst = a[0], a[1], a[2]
    recipe = common.load_json(recipe_path)
    common.reset_scene()
    arm, meshes = common.import_glb(src)
    common.clear_actions(arm)
    mesh = [m for m in meshes if m.vertex_groups][0]
    report = []
    owned = set()
    for spec in recipe['rigfix']['legs']:
        n = add_leg(arm, mesh, spec, frozenset(owned))
        if spec.get('exclusive', True):
            owned |= {mesh.vertex_groups[nm].index for nm in spec['names'] if not spec.get('tail')}
        report.append({'leg': spec['prefix'], 'vertices': n})
        print('RIGFIX', spec['prefix'], n, 'vertices re-weighted')
    # Normalise so each vertex's weights sum to 1 (the exporter keeps the top four).
    bpy.context.view_layer.objects.active = mesh
    bpy.ops.object.vertex_group_normalize_all(group_select_mode='ALL', lock_active=False)
    common.export_static(dst)
    import json
    print('RESULT ' + json.dumps(report))


main()
