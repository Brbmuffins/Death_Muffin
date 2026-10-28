# blender -b --python stand.py -- <model.glb> <frame.json> [--yaw 0] [--height 0] [--max-tilt 60] : the game placement of a model that has no older version
# to fit onto (align.py does that): Pixal3D leaves a model in its picture's camera frame, tilted by the camera's height. It is stood on the side it rests
# on, the biggest flat face of its convex hull within --max-tilt degrees of its own down (a creature's feet, a prop's base), so that face becomes the
# floor; turned --yaw degrees about the up axis (which way it faces is the picture's business: read it from a preview); scaled so it is --height metres
# tall (0 keeps its size); its footprint centred on the origin and its lowest point on the floor. Writes {"matrix": 4x4} in Blender's world space (z up),
# what place.py and the record's frame take, and prints STAND {tilt, height, scale}.
import bpy, bmesh, sys, json, math
import numpy as np
from mathutils import Matrix, Vector
a = sys.argv[sys.argv.index('--') + 1:]
SRC, OUT = a[0], a[1]
def opt(name, default):
    return float(a[a.index(name) + 1]) if name in a else default
YAW, HEIGHT, MAX_TILT = opt('--yaw', 0.0), opt('--height', 0.0), opt('--max-tilt', 60.0)
for o in list(bpy.data.objects):
    bpy.data.objects.remove(o, do_unlink=True)
bpy.ops.import_scene.gltf(filepath=SRC)
P = []
for o in bpy.data.objects:
    if o.type == 'MESH':
        P += [tuple(o.matrix_world @ v.co) for v in o.data.vertices]
P = np.array(P)
bm = bmesh.new()
for p in P[np.random.default_rng(0).choice(len(P), min(len(P), 60000), replace=False)]:
    bm.verts.new(p)
hull = bmesh.ops.convex_hull(bm, input=bm.verts)
faces = [f for f in hull['geom'] if isinstance(f, bmesh.types.BMFace)]
size = float(np.linalg.norm(P.max(0) - P.min(0)))
planes = []                                                                     # the hull's triangles grouped into flat faces: [normal, offset, area]
for f in faces:
    n = f.normal.normalized(); d = n.dot(f.verts[0].co); area = f.calc_area()
    if math.degrees(n.angle(Vector((0, 0, -1)))) > MAX_TILT:
        continue
    for pl in planes:
        if pl[0].angle(n) < math.radians(3) and abs(pl[1] - d) < 0.01 * size:
            pl[2] += area; break
    else:
        planes.append([n, d, area])
if not planes:
    sys.exit('stand: no face of the hull within %g degrees of down' % MAX_TILT)
down = max(planes, key=lambda pl: pl[2])[0]
R = down.rotation_difference(Vector((0, 0, -1))).to_matrix().to_4x4()            # the resting face turned to face the floor
R = Matrix.Rotation(math.radians(YAW), 4, 'Z') @ R
Q = np.array([tuple(R @ Vector(p)) for p in P])
h = float(Q[:, 2].max() - Q[:, 2].min())
sc = HEIGHT / h if HEIGHT > 0 else 1.0
lo, hi = Q.min(0) * sc, Q.max(0) * sc
X = Matrix.Translation(Vector((-(lo[0] + hi[0]) / 2, -(lo[1] + hi[1]) / 2, -lo[2]))) @ Matrix.Scale(sc, 4) @ R
json.dump({'matrix': [list(r) for r in X]}, open(OUT, 'w'))
print('STAND', json.dumps({'tiltDeg': round(math.degrees(down.angle(Vector((0, 0, -1)))), 1), 'height': round(h * sc, 4), 'scale': round(sc, 4)}))
