# blender -b --python build_rig.py -- <static.glb> <template rigged.glb> <out.glb> [--skin geo|heat] [--report <json>]
# The standard humanoid skeleton on a static body: the template's bones (names, parents, and each bone's own axes: the game's skeleton, as the Tripo
# biped heroes have it) moved onto the joints landmarks.py finds, each bone's axes turned by the least rotation that takes its old direction to its new
# one (so a hand's frame, which the game holds props in, stays the same frame relative to the arm), then the body skinned (--skin geo: geodesic
# voxel binding, geoskin.py; heat: Blender's bone heat) on the bones the game's skins use: the twist bones for the limbs, Waist, Spine01, Spine02, NeckTwist01, Head,
# the clavicles, hands, feet and toes. The body is first turned to the heroes' frame (+X forward; the game placement faces +Y, away from the game's
# camera, as render-model.sh's half turn shows): `facing` reads which way it faces, and a body whose feet then point backwards is refused. Exports the rigged body with no clips, facing +X like every hero body (its row turns it, as hero_gravecaller's yaw does).
import bpy, sys, os, json, math
import numpy as np
from mathutils import Matrix, Vector
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from solid import mesh_arrays
from landmarks import find

a = sys.argv[sys.argv.index('--') + 1:]
STATIC, TEMPLATE, OUT = a[0], a[1], a[2]
REPORT = a[a.index('--report') + 1] if '--report' in a else ''
SKIN = a[a.index('--skin') + 1] if '--skin' in a else 'geo'
for o in list(bpy.data.objects):
    bpy.data.objects.remove(o, do_unlink=True)


def imp(path):
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=path)
    return [o for o in bpy.data.objects if o not in before]


def select_only(*objs, active=None):
    bpy.ops.object.select_all(action='DESELECT')
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = active or objs[0]


# ---- the body
body_objs = imp(STATIC)
meshes = [o for o in body_objs if o.type == 'MESH' and len(o.data.vertices) > 100]
for o in body_objs:
    if o not in meshes:
        bpy.data.objects.remove(o, do_unlink=True)
if len(meshes) > 1:
    select_only(*meshes)
    bpy.ops.object.join()
body = [o for o in bpy.data.objects if o.type == 'MESH'][0]
select_only(body)
bpy.ops.object.parent_clear(type='CLEAR_KEEP_TRANSFORM')
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)


def facing(co):
    """which way the body faces, as a unit vector in the ground plane, and what told: the arms' span (T or A pose) gives the side axis, and the
    placement the axis comes from the sign: arms along X is the game placement (fit --stand: it faces +Y, away from the game's camera, so the
    preview's front column shows its face after the preview's half turn), along Y a Tripo hero's frame (+X; a fit onto one). No clear span: the
    game placement. (Not the feet: a robe trailing on the floor reads as toes.)"""
    z0, h = co[:, 2].min(), np.ptp(co[:, 2])
    band = co[(co[:, 2] > z0 + 0.7 * h) & (co[:, 2] < z0 + 0.86 * h)]
    span = np.percentile(band[:, :2], 99, axis=0) - np.percentile(band[:, :2], 1, axis=0)
    if span[1] > 1.15 * span[0]:
        return np.array([1.0, 0.0]), 'arms'
    return np.array([0.0, 1.0]), 'arms' if span[0] > 1.15 * span[1] else 'default'


# ---- the heroes' frame: +X forward, +Y its left (the template's, and what landmarks.find reads)
co, tri = mesh_arrays(body.data)
f, told = facing(co)
turn = -math.degrees(math.atan2(f[1], f[0]))
if abs(turn) > 1e-3:
    body.data.transform(Matrix.Rotation(math.radians(turn), 4, 'Z'))   # the mesh itself (the object's rotation is a glTF quaternion)
    body.data.update()
    co, tri = mesh_arrays(body.data)
J, rep, _ = find(co, tri)
rep['turn'] = {'degrees': round(turn, 1), 'from': told}
# a body facing +X has most of each foot ahead of the ankle (0.6 to 0.85 of it on the game's heroes; a hem hiding the feet about half): far less
# is a body turned backwards, which would walk heels first with its knees bent the wrong way
if rep['feetAhead'] < 0.35:
    raise SystemExit("rig: the feet point backwards (%.2f of each foot ahead of the ankle): the body faces the wrong way; check the frame's turn "
                     "(make.mjs fit --yaw)" % rep['feetAhead'])
H = rep['H']

# ---- the template skeleton
tpl = imp(TEMPLATE)
arm = next(o for o in tpl if o.type == 'ARMATURE')
for o in tpl:
    if o is not arm:
        bpy.data.objects.remove(o, do_unlink=True)
for act in list(bpy.data.actions):
    bpy.data.actions.remove(act)
if arm.animation_data:
    arm.animation_data.action = None
assert all(abs(arm.matrix_world[i][j] - (i == j)) < 1e-6 for i in range(4) for j in range(4)), 'template armature object must be identity'
select_only(arm)
bpy.ops.object.mode_set(mode='EDIT')
eb = arm.data.edit_bones
old = {b.name: (b.head.copy(), b.tail.copy(), b.z_axis.copy()) for b in eb}
th = old['Head'][0].z - min(old[n][0].z for n in ('L_ToeBase', 'R_ToeBase'))
s = (J['Head'][2] - min(J['L_ToeBase'][2], J['R_ToeBase'][2])) / th          # template -> body size, for bones with no joint pair
V = lambda k: Vector(J[k].tolist())
mid = lambda p, q: (V(p) + V(q)) / 2
place = {
    'Waist': (V('Hip'), V('Spine01')), 'Spine01': (V('Spine01'), V('Spine02')), 'Spine02': (V('Spine02'), V('NeckTwist01')),
    'NeckTwist01': (V('NeckTwist01'), V('NeckTwist02')), 'NeckTwist02': (V('NeckTwist02'), V('Head')), 'Head': (V('Head'), V('HeadEnd')),
}
for p in ('L_', 'R_'):
    place.update({
        p + 'Clavicle': (V(p + 'Clavicle'), V(p + 'Upperarm')),
        p + 'Upperarm': (V(p + 'Upperarm'), V(p + 'Forearm')),
        p + 'UpperarmTwist01': (V(p + 'Upperarm'), mid(p + 'Upperarm', p + 'Forearm')),
        p + 'UpperarmTwist02': (mid(p + 'Upperarm', p + 'Forearm'), V(p + 'Forearm')),
        p + 'Forearm': (V(p + 'Forearm'), V(p + 'Hand')),
        p + 'ForearmTwist01': (V(p + 'Forearm'), mid(p + 'Forearm', p + 'Hand')),
        p + 'ForearmTwist02': (mid(p + 'Forearm', p + 'Hand'), V(p + 'Hand')),
        p + 'Hand': (V(p + 'Hand'), V(p + 'HandEnd')),
        p + 'Thigh': (V(p + 'Thigh'), V(p + 'Calf')),
        p + 'ThighTwist01': (V(p + 'Thigh'), mid(p + 'Thigh', p + 'Calf')),
        p + 'ThighTwist02': (mid(p + 'Thigh', p + 'Calf'), V(p + 'Calf')),
        p + 'Calf': (V(p + 'Calf'), V(p + 'Foot')),
        p + 'CalfTwist01': (V(p + 'Calf'), mid(p + 'Calf', p + 'Foot')),
        p + 'CalfTwist02': (mid(p + 'Calf', p + 'Foot'), V(p + 'Foot')),
        p + 'Foot': (V(p + 'Foot'), V(p + 'ToeBase')),
        p + 'ToeBase': (V(p + 'ToeBase'), V(p + 'ToeEnd')),
    })
floor = Vector((J['Hip'][0], J['Hip'][1], min(J['L_ToeEnd'][2], J['R_ToeEnd'][2]) - 0.012 * H))
for n, head in (('Root', floor), ('Hip', V('Hip')), ('Pelvis', V('Hip'))):     # bones with no joint pair: moved and sized, direction kept
    h0, t0, _ = old[n]
    place[n] = (head, head + (t0 - h0) * s)
missing = [b.name for b in eb if b.name not in place]
assert not missing, 'no place for ' + ', '.join(missing)
for b in eb:
    b.use_connect = False
for b in eb:
    h0, t0, z0 = old[b.name]
    hd, tl = place[b.name]
    q = (t0 - h0).normalized().rotation_difference((tl - hd).normalized())
    b.head, b.tail = hd, tl
    b.align_roll(q @ z0)
moved = {n: round(((place[n][1] - place[n][0]).normalized() - (old[n][1] - old[n][0]).normalized()).length, 3) for n in place}
bpy.ops.object.mode_set(mode='OBJECT')

# ---- skin: Blender's automatic weights on the bones the game's skins use
DEFORM = {'Waist', 'Spine01', 'Spine02', 'NeckTwist01', 'Head'}
for p in ('L_', 'R_'):
    DEFORM |= {p + n for n in ('Clavicle', 'UpperarmTwist01', 'UpperarmTwist02', 'ForearmTwist01', 'ForearmTwist02', 'Hand',
                               'ThighTwist01', 'ThighTwist02', 'CalfTwist01', 'CalfTwist02', 'Foot', 'ToeBase')}
for b in arm.data.bones:
    b.use_deform = b.name in DEFORM
if SKIN == 'heat':
    select_only(body, arm, active=arm)
    bpy.ops.object.parent_set(type='ARMATURE_AUTO')
    # bone heat gives nothing to a vertex that sees no bone (loose cloth: a hanging sleeve, a robe's hem): filled from its neighbours
    from geoskin import fill_missing, weld
    me = body.data
    nv, ng = len(me.vertices), len(body.vertex_groups)
    W = np.zeros((nv, ng))
    for v in me.vertices:
        for g in v.groups:
            W[v.index, g.group] = g.weight
    ed = np.empty(len(me.edges) * 2, np.int64); me.edges.foreach_get('vertices', ed); ed = ed.reshape(-1, 2)
    W, rep['unweighted'], rep['loose'] = fill_missing(W, ed, co, weld(co))
    names = [vg.name for vg in body.vertex_groups]
else:
    from geoskin import weights, smooth, fill_missing, weld
    me = body.data
    nv = len(me.vertices)
    names = [b.name for b in arm.data.bones if b.use_deform]
    bl = [(b.name, np.array(b.head_local), np.array(b.tail_local)) for b in arm.data.bones if b.use_deform]
    W, st = weights(co, tri, co, bl, H=H)
    ed = np.empty(len(me.edges) * 2, np.int64); me.edges.foreach_get('vertices', ed); ed = ed.reshape(-1, 2)
    u = weld(co)
    W, st['filled'], st['loose'] = fill_missing(W, ed, co, u)
    W = smooth(W, ed, weld=u)
    rep['geo'] = st
    for n in names:
        body.vertex_groups.new(name=n)
    mod = body.modifiers.new('Armature', 'ARMATURE'); mod.object = arm
    body.parent = arm
W[W < 1e-3] = 0
W = W / np.maximum(W.sum(1, keepdims=True), 1e-9)
for gi, n in enumerate(names):
    vg = body.vertex_groups[n]
    vg.remove(list(range(nv)))
    nz = np.flatnonzero(W[:, gi] > 0)
    for i in nz:
        vg.add([int(i)], float(W[i, gi]), 'REPLACE')
rep['skin'] = SKIN
rep['groups'] = len(names)
select_only(arm, body)
bpy.ops.export_scene.gltf(filepath=OUT, export_format='GLB', export_yup=True, export_animations=False, export_skins=True, export_def_bones=False,
                          export_apply=False, export_tangents=True)
rep['joints'] = {k: [round(float(x), 4) for x in v] for k, v in J.items()}
print('RIG', json.dumps({k: v for k, v in rep.items() if k != 'joints'}))
if REPORT:
    json.dump(rep, open(REPORT, 'w'), indent=1)
