# blender -b --python parts.py -- <detailed.glb> <out.glb> <parts.json> [--report <json>]
# Close-up parts fitted onto a detailed body. Pixal3D reads a whole figure at 512-1024 px, so a hero's face or the skull on a shoulder plate is ~25 px and
# comes out as a lump; the same part drawn large on its own (a Gemini close-up of the concept's crop) and made into its own detailed model has the
# detail. Each part model first loses Pixal3D's white fill (where its close-up had no subject: a neck fading out under a head) and the pieces that
# leaves loose, is turned so the side its picture saw faces where the picture looked from (facing: front, back, left, right: the subject's own left
# and right, or top), sized to its box (what both pictures show: a side-facing part's height) times `scale`, then turned `tilt` degrees about its
# middle (a part drawn in another pose than the body wears it: the Gravecaller's plate, drawn from outside the arm, lies over the shoulder at tilt 40,
# scale 1.3), centred on the box and moved along the depth until its front meets the body's there (rays from the picture's side, the median gap).
# Fitting it to the picture as well (correlation of the two pictures' grey) moved parts to worse places on dark renders (2026-11-03), so the box is
# the placement. The body's own version of each part then goes (its surface inside the part, within `skin` of the part's size round it, within
# `front` over it on the side its picture saw, and the bits that leaves loose), and each part joins as its own material (finish.py moves every
# material's paint). mirror: a copy placed on the other side, mirrored across the body's middle (one shoulder plate made, both worn). rigid: armour
# that moves as one piece (a shoulder plate, a gorget): its material is named dm_rigid_<n>, which finish.py turns into the rig's piece numbers.
# parts.json: {"parts": [{"file": <part model .glb>, "box": [x0, z0, x1, z1], "facing": "front", "tilt": 0, "scale": 1, "mirror": false, "rigid": false}, ...],
# "skin": 0.08, "front": 0.15}
# The box is where the part is on the body's picture: shares of the detailed body's own box as Pixal3D made it, which is the picture's frame (x the
# picture's left to right, z bottom to top; Pixal3D's model faces -y, the picture's camera). The picture never shows depth, so the body's own surface
# under the box gives it.
import bpy, bmesh, sys, os, json, math, time
import numpy as np
from mathutils import Matrix, Vector
from mathutils.bvhtree import BVHTree

a = sys.argv[sys.argv.index('--') + 1:]
SRC, OUT, CFG = a[0], a[1], a[2]
REPORT = a[a.index('--report') + 1] if '--report' in a else ''
cfg = json.load(open(CFG))
base_dir = os.path.dirname(os.path.abspath(CFG))
t0 = time.time()
rep = {'parts': []}

# the way a part's front (its -y, the side its picture saw) points on the body, and the body's up
FACING = {'front': (0, -1, 0), 'back': (0, 1, 0), 'left': (1, 0, 0), 'right': (-1, 0, 0), 'top': (0, 0, 1)}
# the body's axes that both its picture and the part's picture show once the part is turned (a side-facing part's width runs front to back)
SEEN = {'front': [0, 2], 'back': [0, 2], 'left': [2], 'right': [2], 'top': [0]}


def load(path):
    """one mesh object (every mesh in the file joined, transforms applied), the scene's other objects removed"""
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=path)
    new = [o for o in bpy.data.objects if o not in before]
    ms = [o for o in new if o.type == 'MESH']
    bpy.ops.object.select_all(action='DESELECT')
    for o in ms:
        o.select_set(True)
    bpy.context.view_layer.objects.active = ms[0]
    if len(ms) > 1:
        bpy.ops.object.join()
    o = bpy.context.view_layer.objects.active
    bpy.ops.object.parent_clear(type='CLEAR_KEEP_TRANSFORM')
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    for x in new:
        if x is not o and x.name in bpy.data.objects:
            bpy.data.objects.remove(x, do_unlink=True)
    return o


def verts(o):
    co = np.empty(len(o.data.vertices) * 3)
    o.data.vertices.foreach_get('co', co)
    return co.reshape(-1, 3)


def bvh(o):
    bm = bmesh.new(); bm.from_mesh(o.data); bm.faces.ensure_lookup_table()
    t = BVHTree.FromBMesh(bm)
    bm.free()
    return t


def turn_to(facing, tilt=0.0):
    """rotation taking a part's front (-y) to `facing`, its up (z) staying up (for top: its up becomes the body's back, +y); then the side
    its picture saw raised `tilt` degrees toward up (a shoulder plate drawn from outside the arm lies over the shoulder)"""
    f = Vector(FACING[facing])
    if facing == 'top':
        return Matrix.Rotation(math.radians(-90), 4, 'X')                   # -y -> +z, z -> +y
    ang = math.atan2(f.x, -f.y)                                            # about z: -y turned by ang
    return Matrix.Rotation(math.radians(tilt), 4, f.cross(Vector((0, 0, 1)))) @ Matrix.Rotation(ang, 4, 'Z')


def seen_from(facing, tilt=0.0):
    """the way from where the part's picture looked into the part, on the body"""
    if facing == 'top':
        return Vector((0, 0, -1))
    return -(turn_to(facing, tilt).to_3x3() @ Vector((0, -1, 0)))


def pieces(me, use):
    """a piece number for each face of `use` (a mask over the faces): faces touching along an edge share it. By position, not by corner:
    the file splits corners at every texture seam."""
    co = np.empty(len(me.vertices) * 3); me.vertices.foreach_get('co', co); co = co.reshape(-1, 3)
    key = np.unique(np.round(co / max(float(np.ptp(co, 0).max()), 1e-9) * 1e6).astype(np.int64), axis=0, return_inverse=True)[1].ravel()
    lv = np.empty(len(me.loops), np.int64); me.loops.foreach_get('vertex_index', lv)
    start = np.empty(len(me.polygons), np.int64); me.polygons.foreach_get('loop_start', start)
    count = np.empty(len(me.polygons), np.int64); me.polygons.foreach_get('loop_total', count)
    faces = np.flatnonzero(use)
    parent = np.arange(len(me.polygons))
    def root(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]; i = parent[i]
        return i
    owner = {}
    for f in faces:
        k = key[lv[start[f]:start[f] + count[f]]]
        for a_, b_ in zip(k, np.roll(k, -1)):
            e = (a_, b_) if a_ < b_ else (b_, a_)
            g = owner.setdefault(e, f)
            if g != f:
                ra, rb = root(f), root(g)
                if ra != rb:
                    parent[ra] = rb
    out = np.full(len(me.polygons), -1)
    out[faces] = [root(f) for f in faces]
    return out


# ---- the body
body = load(SRC)
body.name = 'body'
B = verts(body)
blo, bhi = B.min(0), B.max(0)
bsize = bhi - blo
rep['bodyTris'] = sum(len(p.vertices) - 2 for p in body.data.polygons)

def lump(x0, z0, x1, z1):
    """the box (lo, hi) of the body's surface under a picture box (shares): its x and z, and the depth the body has there"""
    lo = blo + np.array([x0, 0, z0]) * bsize
    hi = blo + np.array([x1, 1, z1]) * bsize
    under = B[(B[:, 0] >= lo[0]) & (B[:, 0] <= hi[0]) & (B[:, 2] >= lo[2]) & (B[:, 2] <= hi[2]), 1]
    if len(under) >= 20:
        lo[1], hi[1] = np.quantile(under, 0.02), np.quantile(under, 0.98)
    return lo, hi


def near_body(lo, hi):
    """a BVH of the body's surface around a box (a quarter of its size more on every side)"""
    grow = (hi - lo) * 0.25
    near = np.all((B >= lo - grow) & (B <= hi + grow), axis=1)
    bm = bmesh.new(); bm.from_mesh(body.data); bm.verts.ensure_lookup_table()
    bmesh.ops.delete(bm, geom=[v for v in bm.verts if not near[v.index]], context='VERTS')
    tree = BVHTree.FromBMesh(bm); bm.free()
    return tree


WHITE = 0.93                                                               # paint this light and this grey is Pixal3D's fill where its picture had nothing


def unpainted(o):
    """cut away a part's faces painted Pixal3D's white (where its close-up had no subject: a neck fading out under a head), then the pieces
    that leaves loose (under 2% of the faces); returns the share of faces cut"""
    me = o.data
    img = None
    for m in me.materials:
        for n in (m.node_tree.nodes if m and m.use_nodes else []):
            if n.type == 'BSDF_PRINCIPLED' and n.inputs['Base Color'].links and n.inputs['Base Color'].links[0].from_node.type == 'TEX_IMAGE':
                img = n.inputs['Base Color'].links[0].from_node.image
    if img is None or not me.uv_layers:
        return 0.0
    w, h = img.size
    px = np.empty(w * h * 4, np.float32); img.pixels.foreach_get(px); px = px.reshape(h, w, 4)[..., :3]
    uv = np.empty(len(me.loops) * 2); me.uv_layers.active.data.foreach_get('uv', uv); uv = uv.reshape(-1, 2)
    start = np.empty(len(me.polygons), np.int64); me.polygons.foreach_get('loop_start', start)
    count = np.empty(len(me.polygons), np.int64); me.polygons.foreach_get('loop_total', count)
    fu = np.add.reduceat(uv, start, axis=0) / count[:, None]
    c = px[np.clip((fu[:, 1] * h).astype(int), 0, h - 1), np.clip((fu[:, 0] * w).astype(int), 0, w - 1)]
    white = (c.min(1) >= WHITE) & (c.max(1) - c.min(1) <= 0.05)
    piece = pieces(me, ~white)
    ids, size = np.unique(piece[~white], return_counts=True)
    cut = white | np.isin(piece, ids[size < 0.02 * len(me.polygons)])
    bm = bmesh.new(); bm.from_mesh(me); bm.faces.ensure_lookup_table()
    n0 = len(bm.faces)
    bmesh.ops.delete(bm, geom=[bm.faces[i] for i in np.flatnonzero(cut)], context='FACES')
    bmesh.ops.delete(bm, geom=[v for v in bm.verts if not v.link_faces], context='VERTS')
    cut = 1 - len(bm.faces) / n0
    bm.to_mesh(me); bm.free()
    return cut


def depth_onto(o, tree, back=False):
    """move a part along y so its surface seen from the picture's side (the back for a back-facing part) sits on the body's there:
    rays from that side over the part's outline, the median gap between where they meet the body and where they meet the part"""
    P = verts(o); plo, phi = P.min(0), P.max(0)
    pt = bvh(o)
    d = Vector((0, -1, 0)) if back else Vector((0, 1, 0))
    y = (phi[1] + 1.0) if back else (plo[1] - 1.0)
    gaps = []
    for x in np.linspace(plo[0], phi[0], 24):
        for z in np.linspace(plo[2], phi[2], 24):
            hp = pt.ray_cast(Vector((x, y, z)), d)[0]
            hb = tree.ray_cast(Vector((x, y, z)), d)[0]
            if hp is not None and hb is not None:
                gaps.append(hb.y - hp.y)
    if len(gaps) < 20:
        return 0.0
    dy = float(np.median(gaps))
    o.data.transform(Matrix.Translation((0, dy, 0)))
    return dy


def place(o, lo, hi, spec):
    """a part already turned and in its box, set to the body's depth there"""
    return {'depth': round(depth_onto(o, near_body(lo, hi), back=spec.get('facing') == 'back') / float(bsize[2]), 4)}


def make_rigid(o):
    """the part's own materials, named dm_rigid_<n>: finish.py numbers the piece's corners by it and the rig moves them as one"""
    global pieces_rigid
    pieces_rigid += 1
    for i, m in enumerate(o.data.materials):
        if m is not None:
            c = m.copy(); c.name = 'dm_rigid_%d' % pieces_rigid
            o.data.materials[i] = c


placed = []
pieces_rigid = 0
mid = (blo[0] + bhi[0]) / 2
for spec in cfg['parts']:
    x0, z0, x1, z1 = (float(v) for v in spec['box'])
    lo, hi = lump(x0, z0, x1, z1)
    part = load(os.path.join(base_dir, spec['file']))
    part.name = os.path.splitext(spec['file'])[0]
    white = unpainted(part)
    facing, tilt = spec.get('facing', 'front'), float(spec.get('tilt', 0))
    part.data.transform(turn_to(facing))
    P = verts(part)
    s0 = float(np.min(((hi - lo) / np.maximum(P.max(0) - P.min(0), 1e-9))[SEEN[facing]]))   # to what both pictures show of it, before any tilt
    s0 *= float(spec.get('scale', 1))                                      # a part drawn in another pose than the body wears it
    tilted = turn_to(facing, tilt) @ turn_to(facing).inverted()            # the tilt alone, about the part's middle: a pose, not a size
    part.data.transform(Matrix.Translation(Vector((lo + hi) / 2)) @ tilted @ Matrix.Scale(s0, 4) @ Matrix.Translation(Vector(-(P.min(0) + P.max(0)) / 2)))
    info = {'file': spec['file'], 'facing': spec.get('facing', 'front'), 'boxScale': round(s0, 4), 'whiteCut': round(white, 3), **place(part, lo, hi, spec)}
    part['dm_look'] = list(seen_from(facing, tilt))
    if spec.get('rigid'):
        make_rigid(part)
    placed.append(part)
    if spec.get('mirror'):
        twin = part.copy(); twin.data = part.data.copy(); twin.name = part.name + '_mirror'
        bpy.context.scene.collection.objects.link(twin)
        twin.data.transform(Matrix.Translation((mid, 0, 0)) @ Matrix.Scale(-1, 4, (1, 0, 0)) @ Matrix.Translation((-mid, 0, 0)))
        tb = bmesh.new(); tb.from_mesh(twin.data); bmesh.ops.reverse_faces(tb, faces=tb.faces[:]); tb.to_mesh(twin.data); tb.free()
        twin['dm_look'] = [-part['dm_look'][0], part['dm_look'][1], part['dm_look'][2]]
        if spec.get('rigid'):
            make_rigid(twin)                                                # its own piece: each plate on its own shoulder
        mlo, mhi = lump(1 - x1, z0, 1 - x0, z1)                               # the box across the middle (mid is the body box's middle)
        info['mirror'] = place(twin, mlo, mhi, spec)
        placed.append(twin)
    rep['parts'].append(info)

# ---- the body's own version of each part goes: its surface inside the part, just outside it (within SKIN of the part's size; a little
# bigger or smaller, it would show through the part in patches) and just over it on the side its picture saw (within FRONT: a hood's brim
# standing over the new face), then the bits of the body that leaves loose round the parts (under 1% of the body: a hood's old tip)
SKIN = float(cfg.get('skin', 0.08))
FRONT = float(cfg.get('front', 0.15))
bm = bmesh.new(); bm.from_mesh(body.data); bm.verts.ensure_lookup_table()
inside = np.zeros(len(bm.verts), bool)
for c in placed:
    tree = bvh(c)
    C = verts(c)
    size = float(np.linalg.norm(C.max(0) - C.min(0)))
    reach, ahead = SKIN * size, FRONT * size
    look = Vector(c['dm_look'])                                            # from the side the part's picture saw, into the part
    clo = np.minimum(C.min(0), C.min(0) - np.array(look) * ahead) - reach
    chi = np.maximum(C.max(0), C.max(0) - np.array(look) * ahead) + reach
    for v in bm.verts:
        p = v.co
        if not (clo[0] <= p.x <= chi[0] and clo[1] <= p.y <= chi[1] and clo[2] <= p.z <= chi[2]):
            continue
        if inside[v.index]:
            continue
        loc, n, _, d = tree.find_nearest(p)
        if loc is not None and ((p - loc).dot(n) < 0 or d < reach):
            inside[v.index] = True
        elif tree.ray_cast(p, look, ahead)[0] is not None:
            inside[v.index] = True
gone = [f for f in bm.faces if all(inside[v.index] for v in f.verts)]
rep['bodyTrisRemoved'] = sum(len(f.verts) - 2 for f in gone)
bmesh.ops.delete(bm, geom=gone, context='FACES')
bmesh.ops.delete(bm, geom=[v for v in bm.verts if not v.link_faces], context='VERTS')
bm.to_mesh(body.data); bm.free()
me = body.data
piece = pieces(me, np.ones(len(me.polygons), bool))
ids, size = np.unique(piece, return_counts=True)
fv = np.empty(len(me.loops), np.int64); me.loops.foreach_get('vertex_index', fv)
co = verts(body)
inbox = np.zeros(len(co), bool)
for c in placed:
    C = verts(c); g = 0.25 * (C.max(0) - C.min(0))
    inbox |= np.all((co >= C.min(0) - g) & (co <= C.max(0) + g), axis=1)
start = np.empty(len(me.polygons), np.int64); me.polygons.foreach_get('loop_start', start)
count = np.empty(len(me.polygons), np.int64); me.polygons.foreach_get('loop_total', count)
face_in = np.minimum.reduceat(inbox[fv].astype(np.int8), start).astype(bool)   # every corner of the face round a part
small = ids[size < 0.01 * len(me.polygons)]
loose = np.zeros(len(me.polygons), bool)
for k in small:
    m = piece == k
    if face_in[m].all():
        loose |= m
rep['bodyTrisLoose'] = int(loose.sum())
if loose.any():
    bm = bmesh.new(); bm.from_mesh(me); bm.faces.ensure_lookup_table()
    bmesh.ops.delete(bm, geom=[bm.faces[i] for i in np.flatnonzero(loose)], context='FACES')
    bmesh.ops.delete(bm, geom=[v for v in bm.verts if not v.link_faces], context='VERTS')
    bm.to_mesh(me); bm.free()

# ---- one object, a material per source (a mirrored copy shares its part's)
bpy.ops.object.select_all(action='DESELECT')
for o in [body, *placed]:
    o.select_set(True)
bpy.context.view_layer.objects.active = body
bpy.ops.object.join()
out = bpy.context.view_layer.objects.active
rep['tris'] = sum(len(p.vertices) - 2 for p in out.data.polygons)
rep['materials'] = len(out.data.materials)
bpy.ops.object.select_all(action='DESELECT')
out.select_set(True)
bpy.ops.export_scene.gltf(filepath=OUT, use_selection=True, export_format='GLB', export_yup=True, export_image_format='AUTO')
rep['seconds'] = round(time.time() - t0, 1)
print('PARTS', json.dumps(rep))
if REPORT:
    json.dump(rep, open(REPORT, 'w'), indent=1)
