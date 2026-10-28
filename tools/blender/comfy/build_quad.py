# blender -b --python build_quad.py -- <static.glb> <out.glb> [--fwd 0,1,0] [--leg-top 0.5] [--report <json>]
# --leg-top: how far each leg's top joint sits from where the leg meets the body up to the spine (0.5). Raise it (0.8) when hanging cloth or a hollow
# ribcage meets the legs low: the report's legTopShare (top joint height / spine height) then reads under ~0.8 and the run crouches flat.
# The standard four-legged skeleton, built from nothing on a static body: quad.py finds the joints from the shape, the bones are made with the
# standard names (Root, Hip, Spine1, Spine2, Chest, Neck1, Neck2, Head, Tail_A-D, FL/FR_Upper/Lower/Paw, HL/HR_Thigh/Shin/Meta/Paw), and the body
# is skinned by geodesic voxel binding (geoskin.py) on every bone but Root. Legs roll so their bend axis is the body's side axis; spine, neck, head
# and tail roll with their Z up. Exports the rigged body with no clips (tools/blender/procedural.py makes the clips from a recipe).
import bpy, sys, os, json, time
import numpy as np
from mathutils import Vector
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from solid import mesh_arrays
from quad import find_quad
from geoskin import weights, smooth, fill_missing, weld

a = sys.argv[sys.argv.index('--') + 1:]
STATIC, OUT = a[0], a[1]
REPORT = a[a.index('--report') + 1] if '--report' in a else ''
FWD = [float(x) for x in a[a.index('--fwd') + 1].split(',')] if '--fwd' in a else [0, 1, 0]
t0 = time.time()
for o in list(bpy.data.objects):
    bpy.data.objects.remove(o, do_unlink=True)


def select_only(*objs, active=None):
    bpy.ops.object.select_all(action='DESELECT')
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = active or objs[0]


bpy.ops.import_scene.gltf(filepath=STATIC)
meshes = [o for o in bpy.data.objects if o.type == 'MESH' and len(o.data.vertices) > 100]
for o in list(bpy.data.objects):
    if o not in meshes:
        bpy.data.objects.remove(o, do_unlink=True)
if len(meshes) > 1:
    select_only(*meshes)
    bpy.ops.object.join()
body = [o for o in bpy.data.objects if o.type == 'MESH'][0]
select_only(body)
bpy.ops.object.parent_clear(type='CLEAR_KEEP_TRANSFORM')
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
co, tri = mesh_arrays(body.data)
LEG_TOP = float(a[a.index('--leg-top') + 1]) if '--leg-top' in a else 0.5
J, rep, g = find_quad(co, tri, fwd=FWD, leg_top=LEG_TOP)
rep.pop('legProf', None)
rep.pop('cand', None)
H = rep['H']
fwd, lat = Vector(g['fwd']), Vector(g['lat'])

PARENT = {'Root': None, 'Hip': 'Root', 'Spine1': 'Hip', 'Spine2': 'Spine1', 'Chest': 'Spine2', 'Neck1': 'Chest', 'Neck2': 'Neck1', 'Head': 'Neck2',
          'Tail_A': 'Hip', 'Tail_B': 'Tail_A', 'Tail_C': 'Tail_B', 'Tail_D': 'Tail_C'}
for s in ('FL', 'FR'):
    PARENT.update({s + '_Upper': 'Chest', s + '_Lower': s + '_Upper', s + '_Paw': s + '_Lower'})
for s in ('HL', 'HR'):
    PARENT.update({s + '_Thigh': 'Hip', s + '_Shin': s + '_Thigh', s + '_Meta': s + '_Shin', s + '_Paw': s + '_Meta'})

data = bpy.data.armatures.new('Armature')
arm = bpy.data.objects.new('Armature', data)
bpy.context.scene.collection.objects.link(arm)
select_only(arm)
bpy.ops.object.mode_set(mode='EDIT')
eb = data.edit_bones
for n in PARENT:
    if n not in J:
        continue
    b = eb.new(n)
    h, t = J[n]
    b.head, b.tail = Vector(h), Vector(t)
    if (b.tail - b.head).length < 0.01 * H:                                         # never a zero-length bone
        b.tail = b.head + (b.tail - b.head).normalized() * 0.01 * H if (b.tail - b.head).length > 1e-9 else b.head + fwd * 0.01 * H
    leg = n[:2] in ('FL', 'FR', 'HL', 'HR')
    b.align_roll(fwd if leg else Vector((0, 0, 1)))
    if leg and abs((b.tail - b.head).normalized().dot(fwd)) > 0.9:
        b.align_roll(Vector((0, 0, 1)))
for n, p in PARENT.items():
    if n in eb and p:
        eb[n].parent = eb[p]
        eb[n].use_connect = False
bpy.ops.object.mode_set(mode='OBJECT')
for b in data.bones:
    b.use_deform = b.name != 'Root'

# ---- geodesic skin
me = body.data
ed = np.empty(len(me.edges) * 2, np.int64)
me.edges.foreach_get('vertices', ed)
ed = ed.reshape(-1, 2)
bl = [(b.name, np.array(b.head_local), np.array(b.tail_local)) for b in data.bones if b.use_deform]
def region_test(m, lo_, cell_):
    def f(p):
        i = np.floor((p - lo_) / cell_).astype(int)
        ok = np.all((i >= 0) & (i < np.array(m.shape)), 1)
        out = np.zeros(len(p), bool)
        out[ok] = m[tuple(i[ok].T)]
        return out
    return f


allow = {}
if '--no-leg-regions' not in a:
    for k, m in g['legRegion'].items():
        for n in PARENT:
            if n.startswith(k + '_'):
                allow[n] = region_test(m, g['lo'], g['cell'])
W, st = weights(co, tri, co, bl, H=H, allow=allow)
u = weld(co)
W, st['filled'], st['loose'] = fill_missing(W, ed, co, u)
W = smooth(W, ed, weld=u)
W[W < 1e-3] = 0
W /= np.maximum(W.sum(1, keepdims=True), 1e-9)
for vg in list(body.vertex_groups):
    body.vertex_groups.remove(vg)
for i, (n, _, _) in enumerate(bl):
    vg = body.vertex_groups.new(name=n)
    nz = np.nonzero(W[:, i])[0]
    for v in nz:
        vg.add([int(v)], float(W[v, i]), 'REPLACE')
mod = body.modifiers.new('Armature', 'ARMATURE')
mod.object = arm
body.parent = arm
rep['geo'] = st
rep['bones'] = len(data.bones)
rep['share'] = {n: round(float(W[:, i].sum() / len(W)), 3) for i, (n, _, _) in enumerate(bl)}
select_only(body, arm, active=arm)
bpy.ops.export_scene.gltf(filepath=OUT, export_format='GLB', export_yup=True, export_animations=False, export_skins=True, export_def_bones=False,
                          export_tangents=True, use_selection=True)
rep['s'] = round(time.time() - t0, 1)
print('QUAD', json.dumps(rep))
if REPORT:
    json.dump(rep, open(REPORT, 'w'))
