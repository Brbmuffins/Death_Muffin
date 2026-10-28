# blender -b --python bend.py -- <detailed.glb> <out.glb> <bend.json> : a part of a detailed model turned about a joint (a hound's head raised at the neck),
# its paint and maps untouched. bend.json: {"frame": "<xform.json>", "pivot": [x, y, z], "axis": "x", "angle": 20, "blend": [y0, y1], "above": z0}, all
# positions shares of the model's size in the frame its xform.json moves it to (the game's placement: z up, the head toward +y). Each corner turns by
# angle x its weight: 0 behind blend y0, 1 past y1, smooth in between (the neck bends, the head turns whole), and only above "above" (fading over 0.04)
# so legs below the neck stay. The surface normals turn with their corners. Prints the turned part's share box in the new model's size (for
# finish.py --keep-regions).
import bpy, sys, json, math
import numpy as np

a = sys.argv[sys.argv.index('--') + 1:]
SRC, OUT, CFG = a[0], a[1], json.load(open(a[2]))
for o in list(bpy.data.objects):
    bpy.data.objects.remove(o, do_unlink=True)
bpy.ops.import_scene.gltf(filepath=SRC)
bpy.context.view_layer.update()
meshes = [o for o in bpy.data.objects if o.type == 'MESH']
X = np.array(json.load(open(CFG['frame']))['matrix']) if CFG.get('frame') else np.eye(4)
Xi = np.linalg.inv(X)


def to_frame(P):
    return P @ X[:3, :3].T + X[:3, 3]


def from_frame(P):
    return P @ Xi[:3, :3].T + Xi[:3, 3]


def smooth(t):
    t = np.clip(t, 0, 1)
    return t * t * (3 - 2 * t)


world = {o.name: np.array(o.matrix_world) for o in meshes}
pts = {}
for o in meshes:
    co = np.empty(len(o.data.vertices) * 3); o.data.vertices.foreach_get('co', co)
    M = world[o.name]
    pts[o.name] = to_frame(co.reshape(-1, 3) @ M[:3, :3].T + M[:3, 3])
allp = np.concatenate(list(pts.values()))
lo, sz = allp.min(0), allp.max(0) - allp.min(0)
ax = 'xyz'.index(CFG.get('axis', 'x'))
pivot = lo + np.array(CFG['pivot']) * sz
y0, y1 = CFG['blend']
zmin = CFG.get('above', 0.0)
ang = math.radians(CFG['angle'])
turned = []
for o in meshes:
    P = pts[o.name]
    S = (P - lo) / sz
    w = smooth((S[:, 1] - y0) / (y1 - y0)) * smooth((S[:, 2] - zmin) / 0.04)
    c, s_ = np.cos(w * ang), np.sin(w * ang)
    j, k = [i for i in range(3) if i != ax][0], [i for i in range(3) if i != ax][1]
    R = np.zeros((len(P), 3, 3)); R[:, ax, ax] = 1                 # about the axis, the right-hand way (x: +y turns toward +z)
    R[:, j, j], R[:, j, k], R[:, k, j], R[:, k, k] = c, -s_, s_, c
    Q = np.einsum('nij,nj->ni', R, P - pivot) + pivot
    turned.append(Q[w > 0.99])
    M = world[o.name]; Mi = np.linalg.inv(M)
    local = from_frame(Q)
    local = local @ Mi[:3, :3].T + Mi[:3, 3]
    me = o.data
    # the corner normals turn with their corners (frame and object turns are similarities: their rotation parts carry normals)
    n = np.empty(len(me.loops) * 3); me.corner_normals.foreach_get('vector', n); n = n.reshape(-1, 3)
    vi = np.empty(len(me.loops), int); me.loops.foreach_get('vertex_index', vi)
    L = M[:3, :3] / np.cbrt(np.linalg.det(M[:3, :3])); F = X[:3, :3] / np.cbrt(np.linalg.det(X[:3, :3]))
    nw = n @ L.T @ F.T                                            # to the frame
    nw = np.einsum('nij,nj->ni', R[vi], nw)                        # turned
    nl = nw @ np.linalg.inv(F).T @ np.linalg.inv(L).T              # back to the object
    nl /= np.maximum(np.linalg.norm(nl, axis=1, keepdims=True), 1e-12)
    me.vertices.foreach_set('co', local.astype(np.float32).ravel())
    me.normals_split_custom_set(nl.tolist())
    me.update()
new = np.concatenate([to_frame(np.array([(o.matrix_world @ v.co)[:] for v in o.data.vertices])) for o in meshes])
nlo, nsz = new.min(0), new.max(0) - new.min(0)
T = np.concatenate(turned)
box = np.concatenate([(T.min(0) - nlo) / nsz, (T.max(0) - nlo) / nsz])
print('BEND', OUT, 'turned %.3f of the corners whole' % (len(T) / len(new)), 'box', box.round(3).tolist())
bpy.ops.object.select_all(action='SELECT')
bpy.ops.export_scene.gltf(filepath=OUT, use_selection=True, export_format='GLB')
