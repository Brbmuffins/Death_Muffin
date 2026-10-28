# blender -b --python align.py -- <reference.glb> <model.glb> <out.glb> [<min tilt to fix, degrees: 15>] [<xform.json>] : turns (and scales) a model onto a reference of the same subject (a Pixal3D model onto the
# TRELLIS.2 or Tripo one, which face forward): similarity ICP from 8 starting turns, the best kept. Prints the turn (about the up axis), the tilt left over (degrees
# between the model's up and the reference's), the scale and the mean gap (% of height), and writes the model turned, standing on the ground, as <out.glb>.
import bpy, sys, math, json, os
import mathutils
import numpy as np
from mathutils.bvhtree import BVHTree
from mathutils.kdtree import KDTree

a = sys.argv[sys.argv.index('--') + 1:]
REF, SRC, OUT = a[0], a[1], a[2]
TILT_MIN = float(a[3]) if len(a) > 3 else 15.0   # degrees
MAX_TILT = float(os.environ.get('ALIGN_MAX_TILT', '180'))   # degrees: a start whose fit tilts more is passed over unless all do (a model from level views stands upright)
for o in list(bpy.data.objects):
    bpy.data.objects.remove(o, do_unlink=True)


def imp(path):
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=path)
    return [o for o in bpy.data.objects if o not in before]


ref_objs = imp(REF)
ref_meshes = [o for o in ref_objs if o.type == 'MESH' and (len(o.vertex_groups) > 0 or not any(m.vertex_groups for m in ref_objs if m.type == 'MESH'))]
wverts, tris = [], []
for o in ref_meshes:
    me = o.data
    base = len(wverts)
    wverts += [o.matrix_world @ v.co for v in me.vertices]
    me.calc_loop_triangles()
    tris += [tuple(base + i for i in t.vertices) for t in me.loop_triangles]
bvh = BVHTree.FromPolygons(wverts, tris)
src_objs = imp(SRC)
src_meshes = [o for o in src_objs if o.type == 'MESH']
if len(src_meshes) > 1:
    bpy.ops.object.select_all(action='DESELECT')
    for o in src_meshes:
        o.select_set(True)
    bpy.context.view_layer.objects.active = src_meshes[0]
    bpy.ops.object.join()
st = src_meshes[0]
smw = st.matrix_world.copy()
src = np.array([tuple(smw @ v.co) for v in st.data.vertices])
dst = np.array([tuple(v) for v in wverts])
height = dst[:, 2].max() - dst[:, 2].min()
sample = src[::max(1, len(src) // 4000)]
dsample = dst[::max(1, len(dst) // 4000)]


def nearest_surface(P):
    return np.array([tuple(bvh.find_nearest(mathutils.Vector(p))[0]) for p in P])


def umeyama(P, Q):
    pm, qm = P.mean(0), Q.mean(0)
    A, B = P - pm, Q - qm
    U, S, Vt = np.linalg.svd(B.T @ A / len(P))
    D = np.eye(3)
    if np.linalg.det(U @ Vt) < 0:
        D[2, 2] = -1
    R = U @ D @ Vt
    M = (np.trace(np.diag(S) @ D) / (A ** 2).sum() * len(P)) * R
    return M, qm - M @ pm


def fit_from(yaw):
    c, s_ = math.cos(yaw), math.sin(yaw)
    M = height / (src[:, 2].max() - src[:, 2].min()) * np.array([[c, -s_, 0], [s_, c, 0], [0, 0, 1]])
    cur = sample @ M.T
    t = dst.mean(0) - cur.mean(0)
    for it in range(30):
        cur = sample @ M.T + t
        Q1 = nearest_surface(cur)
        kd = KDTree(len(cur))
        for i, p in enumerate(cur):
            kd.insert(p, i)
        kd.balance()
        j = np.array([kd.find(p)[1] for p in dsample])
        M, t = umeyama(np.vstack([sample, sample[j]]), np.vstack([Q1, dsample]))
    cur = sample @ M.T + t
    return np.linalg.norm(nearest_surface(cur) - cur, axis=1).mean(), M, t


def tilt_of(M):
    R = M / abs(np.linalg.det(M)) ** (1 / 3)
    return math.degrees(math.acos(max(-1, min(1, (R @ np.array([0, 0, 1.0]))[2]))))


fits = [fit_from(k * math.pi / 4) for k in range(8)]
upright = [f for f in fits if tilt_of(f[1]) <= MAX_TILT]
g, M, t = min(upright or fits, key=lambda f: f[0])
sc = abs(np.linalg.det(M)) ** (1 / 3)
R = M / sc
up = R @ np.array([0, 0, 1.0])
tilt = math.degrees(math.acos(max(-1, min(1, up[2]))))
fwd = R @ np.array([0, -1.0, 0])
turn = math.degrees(math.atan2(fwd[0], -fwd[1]))
# a few degrees of tilt against a reference in another pose (a Tripo character) is the pose, not the model: below TILT_MIN only the turn is kept
tilt_fixed = tilt >= TILT_MIN
if not tilt_fixed:
    yaw = math.atan2(R[1, 0] - R[0, 1], R[0, 0] + R[1, 1])
    Rz = np.array([[math.cos(yaw), -math.sin(yaw), 0], [math.sin(yaw), math.cos(yaw), 0], [0, 0, 1]])
    M2 = sc * Rz
    t = (sample @ M.T + t).mean(0) - (sample @ M2.T).mean(0)
    M = M2
for v, p in zip(st.data.vertices, src):
    v.co = smw.inverted() @ mathutils.Vector(tuple(M @ p + t))
st.data.update()
bpy.context.view_layer.update()
zmin = min((st.matrix_world @ v.co).z for v in st.data.vertices)
for v in st.data.vertices:
    v.co = smw.inverted() @ ((smw @ v.co) - mathutils.Vector((0, 0, zmin)))
for o in ref_objs:
    if o.name in bpy.data.objects:
        bpy.data.objects.remove(o, do_unlink=True)
bpy.ops.object.select_all(action='DESELECT')
st.select_set(True)
bpy.context.view_layer.objects.active = st
bpy.ops.export_scene.gltf(filepath=OUT, use_selection=True, export_format='GLB', export_yup=True)
print('ALIGN', json.dumps({'model': SRC.split('/')[-1], 'turnDeg': round(turn, 1), 'tiltDeg': round(tilt, 1), 'scale': round(sc, 3), 'gapPct': round(100 * g / height, 2), 'tiltFixed': tilt_fixed}))
# the whole move in world space (turn and scale, then standing on the ground), for apply_xform.py on other versions of the same model
X = np.eye(4); X[:3, :3] = M; X[:3, 3] = t; X[2, 3] -= zmin
if len(a) > 4:
    json.dump({'matrix': X.tolist()}, open(a[4], 'w'))
