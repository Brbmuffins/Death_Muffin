# blender -b --python parts.py -- <detailed.glb> <out.glb> <parts.json> [--report <json>]
# Close-up parts fitted onto a detailed body. Pixal3D reads a whole figure at 512-1024 px, so a hero's face or the skull on a shoulder plate is ~25 px and
# comes out as a lump; the same part drawn large on its own (a Gemini close-up of the concept's crop) and made into its own detailed model has the
# detail. Each part model first loses Pixal3D's white fill (where its close-up had no subject: a neck fading out under a head) and the pieces that
# leaves loose, is turned so the side its picture saw faces where the picture looked from (facing: front, back, left, right: the subject's own left
# and right, or top), sized to its box (what both pictures show: a side-facing part's height) times `scale`, then turned `tilt` degrees about its
# middle (a part drawn in another pose than the body wears it: the Gravecaller's plate, drawn from outside the arm, lies over the shoulder at tilt 40,
# scale 1.3), centred on the box and moved along the depth until its front meets the body's there (rays from the picture's side, the median gap).
# A front part with its close-up (`picture`) is sized and placed where its close-up matches the concept instead (below), when one place stands out.
# A part joins as a piece (join: piece, the default): the body's own version of it goes (its surface inside the part, within `skin` of the part's
# size round it where it faces away from the picture, within `front` over it on the side its picture saw, and the bits that leaves loose; the
# surface beside a part facing the picture stays, and a cut that would open a hole keeps the body's surface there: below), and the part joins as
# its own material (finish.py moves every material's paint). Or it joins as the body's surface (join: surface, a head in its hood): the body keeps
# all of its surface and the part's face shows where the concept's labels mark skin (below). mirror: a copy placed on the other side, mirrored
# across the body's middle (one shoulder plate made, both worn). rigid: armour that moves as one piece (a shoulder plate, a gorget): its material
# is named dm_rigid_<n>, which finish.py turns into the rig's piece numbers.
# parts.json: {"parts": [{"file": <part model .glb>, "box": [x0, z0, x1, z1], "facing": "front", "tilt": 0, "scale": 1, "mirror": false, "rigid": false,
# "join": "piece", "picture": <its close-up .png>}, ...], "picture": <the concept .png>, "labels": <the concept's front label .png (materials.py)>,
# "skin": 0.08, "front": 0.15, "ease": 0.1, "poke": 0.04, "push": 0.05, "layer": 0.025}
# The box is where the part is on the body's picture: shares of the detailed body's own box as Pixal3D made it, which is the picture's frame (x the
# picture's left to right, z bottom to top; Pixal3D's model faces -y, the picture's camera). The picture never shows depth, so the body's own surface
# under the box gives it. The report's seeThrough (seethrough.py) counts the holes the step left against the body as Pixal3D made it.
import bpy, bmesh, sys, os, json, math, time
import numpy as np
from mathutils import Matrix, Vector
from mathutils.bvhtree import BVHTree

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from transfer import image_array
from seethrough import see_through, tree_of

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


# ---- a front part's close-up fitted onto the concept. The close-up was drawn anew (Gemini) and frames its subject its own way (a head with
# its hair to the ends, its hood a little smaller), so a part sized to its box sat up to a face's height off and a size off: two faces seen
# through each other on three of the four heroes, 2026-11-04. With its close-up (`picture`) the part goes where the close-up's grey matches
# the concept's best: the correlation over the close-up's figure, normalized, at sizes from 0.6 to 1.7 of the box's and every place whose
# middle lies within half the box of the box's. The model is its close-up's figure (Pixal3D fits the figure's longer side to the model's), so
# that places the model too. One size must stand out (its best match FIT_PEAK over the median size's best), or the part keeps its box: a
# close-up that matches nowhere well (a gorget drawn as another shape) would be pulled to a random place.
FIT_SIZES = np.geomspace(0.6, 1.7, 40)
FIT_PEAK = 0.1


def figure(path):
    """a picture (top row first), its figure (the pixels unlike the corner's grey) and the figure's box (x0, y0, x1, y1)"""
    im = bpy.data.images.load(path); w, h = im.size
    px = np.empty(w * h * 4, np.float32); im.pixels.foreach_get(px); a = px.reshape(h, w, 4)[::-1, :, :3].copy()
    bpy.data.images.remove(im)
    bg = a[:8, :8].reshape(-1, 3).mean(0)
    fig = np.abs(a - bg).sum(-1) > 0.15
    ys, xs = np.nonzero(fig)
    return a, fig, (int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max()))


PICTURE = figure(cfg['picture']) if cfg.get('picture') and os.path.exists(cfg['picture']) else None


def grey(a):
    return a @ np.array([0.299, 0.587, 0.114], np.float32)


def block(a, f):
    h, w = a.shape[0] // f * f, a.shape[1] // f * f
    return a[:h, :w].reshape(h // f, f, w // f, f).mean((1, 3))


def box_mean(a, r):
    """the mean over a (2r+1)-pixel square round each pixel"""
    if r < 1:
        return a
    c = np.pad(a, ((r + 1, r), (r + 1, r)), mode='edge').cumsum(0).cumsum(1)
    k = 2 * r + 1
    return (c[k:, k:] - c[:-k, k:] - c[k:, :-k] + c[:-k, :-k]) / (k * k)


def scaled(a, s, shape):
    """a at s pixels per pixel (shrunk: averaged first), cut to shape"""
    b = box_mean(a, int(round(0.5 / s)))
    r = np.clip(((np.arange(shape[0]) + 0.5) / s).astype(int), 0, a.shape[0] - 1)
    c = np.clip(((np.arange(shape[1]) + 0.5) / s).astype(int), 0, a.shape[1] - 1)
    return b[r][:, c]


def ncc_map(T, M, I):
    """the normalized correlation of T (where M) with I at every place T fits inside I (FFT)"""
    sh = (I.shape[0] + T.shape[0], I.shape[1] + T.shape[1])
    corr = lambda k, x: np.fft.irfft2(np.conj(np.fft.rfft2(k, sh)) * np.fft.rfft2(x, sh), sh)[:I.shape[0] - T.shape[0] + 1, :I.shape[1] - T.shape[1] + 1]
    n = M.sum(); A = (M * T).sum(); B = (M * T * T).sum()
    cI, cI2, cTI = corr(M, I), corr(M, I * I), corr(M * T, I)
    return (cTI - A * cI / n) / np.sqrt(np.maximum(B - A * A / n, 1e-12) * np.maximum(cI2 - cI * cI / n, 1e-12))


def fit(path, box):
    """where a front part's close-up lies on the concept: its figure's middle (concept pixels) and size (concept pixels per close-up pixel),
    with the match there and at the box; 'used' when one size stands out"""
    pic, _, (fx0, fy0, fx1, fy1) = PICTURE
    a, m, (gx0, gy0, gx1, gy1) = figure(path)
    g = grey(a[gy0:gy1 + 1, gx0:gx1 + 1]); m = m[gy0:gy1 + 1, gx0:gx1 + 1].astype(np.float32)
    del a
    x0, z0, x1, z1 = box
    bx0, bx1, by0, by1 = fx0 + x0 * (fx1 - fx0), fx0 + x1 * (fx1 - fx0), fy1 - z1 * (fy1 - fy0), fy1 - z0 * (fy1 - fy0)
    bw, bh, bcx, bcy = bx1 - bx0, by1 - by0, (bx0 + bx1) / 2, (by0 + by1) / 2
    s_box = min(bw / g.shape[1], bh / g.shape[0])                          # the close-up's figure in the box
    f = max(1, int(0.5 / (s_box * FIT_SIZES[-1])))                         # shrunk first to about twice the biggest size tried
    g, m = block(g, f), block(m, f)
    X0, Y0 = int(max(0, bx0 - bw)), int(max(0, by0 - bh))
    I = grey(pic[Y0:int(min(pic.shape[0], by1 + bh)), X0:int(min(pic.shape[1], bx1 + bw))])
    best, peaks, at_box = None, [], None
    for k in FIT_SIZES:
        s = s_box * f * k
        shape = (int(round(g.shape[0] * s)), int(round(g.shape[1] * s)))
        if min(shape) < 8 or shape[0] >= I.shape[0] or shape[1] >= I.shape[1]:
            continue
        T = scaled(g, s, shape); M = (scaled(m, s, shape) > 0.5).astype(np.float32)
        c = ncc_map(T, M, I)
        yy, xx = np.mgrid[:c.shape[0], :c.shape[1]]
        mx, my = X0 + xx + shape[1] / 2, Y0 + yy + shape[0] / 2
        if at_box is None or abs(np.log(k)) < abs(np.log(at_box[1])):
            at_box = (float(c[int(np.clip(round(bcy - Y0 - shape[0] / 2), 0, c.shape[0] - 1)), int(np.clip(round(bcx - X0 - shape[1] / 2), 0, c.shape[1] - 1))]), k)
        c[(np.abs(mx - bcx) > 0.5 * bw) | (np.abs(my - bcy) > 0.5 * bh)] = -2
        j = np.unravel_index(np.argmax(c), c.shape)
        peaks.append(float(c[j]))
        if best is None or c[j] > best['ncc']:
            best = {'ncc': float(c[j]), 'size': float(k), 'mid': (float(mx[j]), float(my[j])), 's': s / f}
    shift = ((best['mid'][0] - bcx) / bw, (bcy - best['mid'][1]) / bh)
    best['used'] = bool(FIT_SIZES[0] < best['size'] < FIT_SIZES[-1] and max(map(abs, shift)) < 0.49 and best['ncc'] - np.median(peaks) >= FIT_PEAK)
    best['report'] = {'ncc': round(best['ncc'], 3), 'nccBox': round(at_box[0], 3), 'standsOut': round(best['ncc'] - float(np.median(peaks)), 3),
                      'size': round(best['size'], 3), 'shift': [round(v, 3) for v in shift], 'used': best['used']}
    best['fig'] = (gx1 - gx0, gy1 - gy0)
    return best


placed = []
pieces_rigid = 0
mid = (blo[0] + bhi[0]) / 2
for spec in cfg['parts']:
    x0, z0, x1, z1 = (float(v) for v in spec['box'])
    lo, hi = lump(x0, z0, x1, z1)
    part = load(os.path.join(base_dir, spec['file']))
    part.name = os.path.splitext(os.path.basename(spec['file']))[0]
    R0 = verts(part); rlo, rhi = R0.min(0), R0.max(0)                     # the model as its close-up framed it, white fill and all
    white = unpainted(part)
    facing, tilt = spec.get('facing', 'front'), float(spec.get('tilt', 0))
    part.data.transform(turn_to(facing))
    P = verts(part)
    fitted = fit(spec['picture'], (x0, z0, x1, z1)) if facing == 'front' and spec.get('picture') and PICTURE is not None else None
    tilted = turn_to(facing, tilt) @ turn_to(facing).inverted()            # the tilt alone, about the part's middle: a pose, not a size
    if fitted and fitted['used']:
        _, _, (fx0, fy0, fx1, fy1) = PICTURE
        fw, fh = fitted['fig']
        per_px = (rhi[2] - rlo[2]) / fh if fh >= fw else (rhi[0] - rlo[0]) / fw   # model per close-up pixel, by the figure's longer side
        s0 = float(fitted['s'] * bsize[2] / (fy1 - fy0) / per_px)
        mx, my = fitted['mid']
        mid_at = Vector((blo[0] + (mx - fx0) / (fx1 - fx0) * bsize[0], (lo[1] + hi[1]) / 2, blo[2] + (fy1 - my) / (fy1 - fy0) * bsize[2]))
        part.data.transform(Matrix.Translation(mid_at) @ tilted @ Matrix.Scale(s0, 4) @ Matrix.Translation(Vector(-(rlo + rhi) / 2)))
        Q = verts(part); qlo, qhi = (Q.min(0) - blo) / bsize, (Q.max(0) - blo) / bsize
        x0, z0, x1, z1 = float(qlo[0]), float(qlo[2]), float(qhi[0]), float(qhi[2])   # its box now, for its depth and its mirror's
        lo, hi = lump(x0, z0, x1, z1)
    else:
        s0 = float(np.min(((hi - lo) / np.maximum(P.max(0) - P.min(0), 1e-9))[SEEN[facing]]))   # to what both pictures show of it, before any tilt
        s0 *= float(spec.get('scale', 1))                                  # a part drawn in another pose than the body wears it
        part.data.transform(Matrix.Translation(Vector((lo + hi) / 2)) @ tilted @ Matrix.Scale(s0, 4) @ Matrix.Translation(Vector(-(P.min(0) + P.max(0)) / 2)))
    info = {'file': spec['file'], 'facing': spec.get('facing', 'front'), 'boxScale': round(s0, 4), 'whiteCut': round(white, 3),
            **({'fit': fitted['report']} if fitted else {}), **place(part, lo, hi, spec)}
    part['dm_look'] = list(seen_from(facing, tilt))
    part['dm_join'] = spec.get('join', 'piece')
    if spec.get('rigid'):
        make_rigid(part)
    placed.append(part)
    if spec.get('mirror'):
        twin = part.copy(); twin.data = part.data.copy(); twin.name = part.name + '_mirror'
        bpy.context.scene.collection.objects.link(twin)
        twin.data.transform(Matrix.Translation((mid, 0, 0)) @ Matrix.Scale(-1, 4, (1, 0, 0)) @ Matrix.Translation((-mid, 0, 0)))
        tb = bmesh.new(); tb.from_mesh(twin.data); bmesh.ops.reverse_faces(tb, faces=tb.faces[:]); tb.to_mesh(twin.data); tb.free()
        twin['dm_look'] = [-part['dm_look'][0], part['dm_look'][1], part['dm_look'][2]]
        twin['dm_join'] = part['dm_join']
        if spec.get('rigid'):
            make_rigid(twin)                                                # its own piece: each plate on its own shoulder
        mlo, mhi = lump(1 - x1, z0, 1 - x0, z1)                               # the box across the middle (mid is the body box's middle)
        info['mirror'] = place(twin, mlo, mhi, spec)
        placed.append(twin)
    rep['parts'].append(info)

# ---- a part laid into the body's surface (join: surface: a head in its hood). Cutting the body's version away and setting the part in its
# place left the Ossuary's and the Mourner's hoods holed round the new head (the part's hood was smaller, another shape and another colour,
# and nothing joined the two); moving the body's surface onto the part's muddied the eyes (the two faces lie at other depths, so the body took
# the part's shape only in patches); telling face from hood by the concept's colours or by depth failed (the body, painted from the concept,
# matches its colours better nearly everywhere; its brim hangs over the part's eyes, so the part's face reaches its own hood behind it),
# 2026-11-04. Instead the body keeps all its surface, hood and all, and the part shows where the concept's labels (the front label picture
# of the record's materials step) mark skin: the face, as the face finder drew it. There, seen from the front, where the part faces the
# picture and lies in front of the body or less than POKE behind it (with the holes filled), its surface and what lies within LAYER behind it
# (the face under hair strands) are kept and the rest is cut off. It keeps its own shape and paint; toward the face's edge, where it stands in
# front of the body, it eases back over EASE of its size onto the body's surface (MARGIN in front of it). The body's surface standing in
# front of it (Pixal3D's face is a smooth lump under a low brim: the part's eyes lie up to 0.03 of the height behind it) is pushed back to
# just behind it, up to PUSH; what still stands in front of it (across the face's edge, or further in front than PUSH) goes, so no hole can
# open where only the part's face lies behind. A sheet of the part over its own face (its hood's brim) is left to the body's brim (brims);
# finish.py's inner-wall pass drops the body's surface left under the part.
EASE = float(cfg.get('ease', 0.1))
POKE = float(cfg.get('poke', 0.04))
PUSH = float(cfg.get('push', 0.05))
LAYER = float(cfg.get('layer', 0.025))
OVER, DEEP = 0.007, 0.08
MARGIN = 0.003
GRID = 256


def ramp(x, a, b):
    t = np.clip((x - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)


def blur(a, sigma):
    r = max(1, int(3 * sigma)); k = np.exp(-0.5 * (np.arange(-r, r + 1) / sigma) ** 2); k /= k.sum()
    p = np.apply_along_axis(np.convolve, 0, np.pad(a, r, mode='edge'), k, 'valid')
    return np.apply_along_axis(np.convolve, 1, p, k, 'valid')


def inset(mask, steps):
    """how many cells in from the mask's edge each of its cells lies, up to steps"""
    d = np.zeros(mask.shape); m = mask.copy()
    for _ in range(steps):
        d += m
        q = np.pad(m, 1, constant_values=False)
        m = m & q[:-2, 1:-1] & q[2:, 1:-1] & q[1:-1, :-2] & q[1:-1, 2:]
    return d


def islands(mask):
    """each cell's island number (4-neighbour; -1 off the mask) and the islands' sizes"""
    lab_ = np.full(mask.shape, -1); sizes = []
    for s in zip(*np.nonzero(mask)):
        if lab_[s] >= 0:
            continue
        stack, count = [s], 0
        lab_[s] = len(sizes)
        while stack:
            i, j = stack.pop(); count += 1
            for a_, b_ in ((i + 1, j), (i - 1, j), (i, j + 1), (i, j - 1)):
                if 0 <= a_ < mask.shape[0] and 0 <= b_ < mask.shape[1] and mask[a_, b_] and lab_[a_, b_] < 0:
                    lab_[a_, b_] = len(sizes); stack.append((a_, b_))
        sizes.append(count)
    return lab_, np.array(sizes, int)


def solid(mask):
    """the mask's islands, those under 2% of it dropped, with their holes filled"""
    lab_, sizes = islands(mask)
    m = np.isin(lab_, np.flatnonzero(sizes >= 0.02 * mask.sum()))
    out, _ = islands(~m)
    edge = np.unique(np.concatenate([out[0], out[-1], out[:, 0], out[:, -1]]))
    return m | ((out >= 0) & ~np.isin(out, edge))


SKIN_CLASS = 4                                                                  # skin's class number in a label picture (materials.py CLASSES)


def labels(path):
    """a label picture's class numbers (top row first) and its subject's box (x0, y0, x1, y1)"""
    im = bpy.data.images.load(path); im.colorspace_settings.name = 'Non-Color'
    lb = np.rint(image_array(im)[::-1, :, 0] * 255).astype(np.int16)
    bpy.data.images.remove(im)
    ys, xs = np.nonzero(lb)
    return lb, (int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max()))


LABELS = labels(cfg['labels']) if cfg.get('labels') else None


def next_front(tree, q, Lv, H):
    """how far behind q, a surface's first point along the look, the next surface facing the look lies (past OVER and within DEEP of the
    height: what a sheet hangs over); inf if none"""
    t = 0.0
    for _ in range(6):
        h = tree.ray_cast(q + Lv * 1e-5, Lv, DEEP * H - t)
        if h[0] is None:
            return np.inf
        t += h[3] + 1e-5; q = h[0]
        if -h[1].dot(Lv) > 0.15 and t > OVER * H:
            return t
    return np.inf


def brims(over, face, front, behind):
    """of the cells where a sheet hangs over a surface (over), the brims: islands that reach the face's edge (a brim hangs from outside it)
    and where the surface behind runs on into the face beside them (a hood's edge over the forehead), not the sheet's own front (a chin over
    the neck, the nose over a cheek: the face itself). Each island votes along its edge with the rest of the face; an island at the face's
    edge with no such edge is a brim"""
    lab_, sizes = islands(over)
    if not len(sizes):
        return over
    rest = face & ~over
    vote = np.zeros((len(sizes), 2))
    P = lambda a, fill: np.pad(a, 1, constant_values=fill)
    lp, rp, fp_, bp = P(lab_, -1), P(rest, False), P(front, np.inf), P(behind, np.inf)
    n0, n1 = over.shape
    for di, dj in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        nb = (slice(1 + di, 1 + di + n0), slice(1 + dj, 1 + dj + n1))
        at = over & rp[nb]
        if at.any():
            run_front = np.abs(front[at] - fp_[nb][at]); run_behind = np.abs(behind[at] - fp_[nb][at])
            np.add.at(vote, (lab_[at], (run_front <= run_behind).astype(int)), 1)
    out = np.pad(~face, 1, constant_values=True)
    edge = np.zeros(len(sizes), bool)
    for di, dj in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        at = over & out[1 + di:1 + di + n0, 1 + dj:1 + dj + n1]
        edge[np.unique(lab_[at])] = True
    return np.isin(lab_, np.flatnonzero(edge & (vote[:, 0] >= vote[:, 1])))


def relief(c):
    """the part's front against the body's, seen from the front on a grid over the part: M where the part shows (the concept's face), off
    how far along the look each point of it moves (onto the body toward the face's edge), dp how deep the part's front surface lies, under
    how deep the body may lie there once the part is in place"""
    H = float(bsize[2])
    L = np.array(c['dm_look'], float); L /= np.linalg.norm(L)
    u = np.cross(L, (0, 0, 1)) if abs(L[2]) < 0.9 else np.array((1.0, 0, 0)); u /= np.linalg.norm(u); v = np.cross(u, L)
    C = verts(c); size = float(np.linalg.norm(C.max(0) - C.min(0))); m = 0.1 * size
    u0, u1, v0, v1 = (C @ u).min() - m, (C @ u).max() + m, (C @ v).min() - m, (C @ v).max() + m
    cell = max(u1 - u0, v1 - v0) / GRID
    nu, nv = int((u1 - u0) / cell) + 2, int((v1 - v0) / cell) + 2
    s0 = float(min((C @ L).min(), (verts(body) @ L).min())) - 0.1 * size
    bt, pt, Lv = bvh(body), bvh(c), Vector(L)
    db, dp = np.full((nu, nv), np.inf), np.full((nu, nv), np.inf)
    fb, fp = np.zeros((nu, nv)), np.zeros((nu, nv))
    under_face = np.full((nu, nv), np.inf)                                      # a surface the part's front hangs over (below)
    for i in range(nu):
        for j in range(nv):
            o = Vector(u * (u0 + i * cell) + v * (v0 + j * cell) + L * s0)
            hb = bt.ray_cast(o, Lv)
            if hb[0] is not None:
                db[i, j], fb[i, j] = hb[3], -hb[1].dot(Lv)
            hp = pt.ray_cast(o, Lv)
            if hp[0] is not None:
                dp[i, j], fp[i, j] = hp[3], -hp[1].dot(Lv)
                under_face[i, j] = hp[3] + next_front(pt, hp[0], Lv, H)
    both = np.isfinite(db) & np.isfinite(dp)
    lb, (lx0, ly0, lx1, ly1) = LABELS
    G = np.stack(np.meshgrid(np.arange(nu), np.arange(nv), indexing='ij'), -1).reshape(-1, 2)
    Pw = u * (u0 + G[:, :1] * cell) + v * (v0 + G[:, 1:] * cell)
    px = np.clip(np.rint(lx0 + (Pw[:, 0] - blo[0]) / bsize[0] * (lx1 - lx0)).astype(int), 0, lb.shape[1] - 1)
    py = np.clip(np.rint(ly1 - (Pw[:, 2] - blo[2]) / bsize[2] * (ly1 - ly0)).astype(int), 0, lb.shape[0] - 1)
    face = (lb[py, px] == SKIN_CLASS).reshape(nu, nv)
    sheet = brims(face & np.isfinite(under_face), face & np.isfinite(dp), dp, under_face)   # its own brim: the body's stands there instead
    M = solid(both & face & ~sheet & (fp > 0.15) & (np.where(both, dp - db, np.inf) < POKE * H)) & both & ~sheet
    if os.environ.get('PARTS_DEBUG'):
        np.savez_compressed(os.environ['PARTS_DEBUG'] + '-%s.npz' % c.name, face=face, M=M, sheet=sheet, db=db, dp=dp, fb=fb, fp=fp,
                            under_face=under_face)
    F = max(2, int(round(EASE * size / cell)))
    e = ramp(inset(M, F), 0, F)
    target = np.where(both, db - MARGIN * H, 0)
    off = np.where(M, (1 - e) * np.maximum(target - dp, 0), 0)                 # where in front of the body, eased back onto it toward the edge
    n = blur(M * 1.0, 1.5)
    off = np.where(n > 1e-3, blur(off, 1.5) / np.maximum(n, 1e-3), 0)
    under = np.where(M, dp + off + MARGIN * H, -np.inf)
    ease_in = ramp(inset(M, 4), 0, 4)                                          # the push eased in over 4 cells from the edge: no step there
    return {'L': L, 'u': u, 'v': v, 'u0': u0, 'v0': v0, 'cell': cell, 's0': s0, 'M': M, 'off': off, 'dp': np.where(np.isfinite(dp), dp, np.inf),
            'under': under, 'easeIn': ease_in, 'front': np.where(M, dp + off, -np.inf),
            'cover': round(float(M.sum() / max(np.isfinite(dp).sum(), 1)), 3)}


def sample(R, P, key, nearest=False):
    A = R[key]; nu, nv = A.shape
    gu = (P @ R['u'] - R['u0']) / R['cell']; gv = (P @ R['v'] - R['v0']) / R['cell']
    inside = (gu >= 0) & (gu <= nu - 1) & (gv >= 0) & (gv <= nv - 1)
    if nearest:
        return np.where(inside, A[np.clip(np.rint(gu).astype(int), 0, nu - 1), np.clip(np.rint(gv).astype(int), 0, nv - 1)], 0)
    i0 = np.clip(np.floor(gu).astype(int), 0, nu - 2); j0 = np.clip(np.floor(gv).astype(int), 0, nv - 2)
    fu = np.clip(gu - i0, 0, 1); fv = np.clip(gv - j0, 0, 1)
    val = A[i0, j0] * (1 - fu) * (1 - fv) + A[i0 + 1, j0] * fu * (1 - fv) + A[i0, j0 + 1] * (1 - fu) * fv + A[i0 + 1, j0 + 1] * fu * fv
    return np.where(inside, val, 0.0)


def overlay(c):
    """the part cut to where it covers the body (M), and what lies within LAYER behind its front there, moved by off; the body's surface in
    front of it pushed back behind it"""
    R = relief(c)
    H = float(bsize[2])
    me = c.data
    bm = bmesh.new(); bm.from_mesh(me); bm.faces.ensure_lookup_table()
    n0 = len(bm.faces)
    cen = np.array([f.calc_center_median()[:] for f in bm.faces])
    nrm = np.array([f.normal[:] for f in bm.faces])
    covered = sample(R, cen, 'M', nearest=True) > 0
    behind = (cen @ R['L'] - R['s0']) - sample(R, cen, 'dp', nearest=True)
    keep = covered & (behind < LAYER * H) & (nrm @ -R['L'] > -0.2)           # its front, the face under hair strands; not its back
    bmesh.ops.delete(bm, geom=[bm.faces[i] for i in np.flatnonzero(~keep)], context='FACES')
    bmesh.ops.delete(bm, geom=[v for v in bm.verts if not v.link_faces], context='VERTS')
    bm.to_mesh(me); bm.free()
    piece = pieces(me, np.ones(len(me.polygons), bool))                      # crumbs the cut left (under 20 faces) go
    ids, size = np.unique(piece, return_counts=True)
    crumbs = np.isin(piece, ids[size < 20])
    if crumbs.any():
        bm = bmesh.new(); bm.from_mesh(me); bm.faces.ensure_lookup_table()
        bmesh.ops.delete(bm, geom=[bm.faces[i] for i in np.flatnonzero(crumbs)], context='FACES')
        bmesh.ops.delete(bm, geom=[v for v in bm.verts if not v.link_faces], context='VERTS')
        bm.to_mesh(me); bm.free()
    P = verts(c)
    off = sample(R, P, 'off')
    P = P + np.outer(off, R['L'])
    me.vertices.foreach_set('co', P.ravel()); me.update()
    B_ = verts(body)
    d = B_ @ R['L'] - R['s0']
    push = sample(R, B_, 'under', nearest=True) - d
    push = np.where((push > 0) & (push < PUSH * H), push, 0) * sample(R, B_, 'easeIn', nearest=True)
    B_ = B_ + np.outer(push, R['L'])
    body.data.vertices.foreach_set('co', B_.ravel()); body.data.update()
    # what of the body still stands in front of the face goes: faces across the face's edge, half pushed (stretched into spikes over the
    # Mourner's brow, 2026-11-04), and a brim further in front than the push reaches
    bm = bmesh.new(); bm.from_mesh(body.data); bm.faces.ensure_lookup_table()
    bc = np.array([f.calc_center_median()[:] for f in bm.faces])
    ahead = np.flatnonzero(bc @ R['L'] - R['s0'] < sample(R, bc, 'front', nearest=True))
    bmesh.ops.delete(bm, geom=[bm.faces[i] for i in ahead], context='FACES')
    bmesh.ops.delete(bm, geom=[v for v in bm.verts if not v.link_faces], context='VERTS')
    bm.to_mesh(body.data); bm.free()
    return {'cover': R['cover'], 'faces': len(me.polygons), 'cut': round(1 - len(me.polygons) / n0, 3),
            'moveMean': round(float(np.abs(off).mean() / H), 4), 'moveMax': round(float(np.abs(off).max() / H), 4),
            'pushed': int((push > 0).sum()), 'pushMax': round(float(push.max() / H), 4), 'inFront': len(ahead)}


if os.environ.get('PARTS_DEBUG'):                                          # each part as placed, to look at against the concept
    for c in placed:
        bpy.ops.object.select_all(action='DESELECT'); c.select_set(True)
        bpy.ops.export_scene.gltf(filepath=os.environ['PARTS_DEBUG'] + '-%s.glb' % c.name, use_selection=True, export_format='GLB', export_yup=True)
overlays = [c for c in placed if c['dm_join'] == 'surface']
if overlays and LABELS is None:
    sys.exit('parts: join surface lays a face in where the concept\'s labels mark skin: the cfg needs labels')
placed = [c for c in placed if c['dm_join'] != 'surface']
original = body.copy(); original.data = body.data.copy(); bpy.context.scene.collection.objects.link(original)   # the body as Pixal made it
rep['surface'] = [overlay(c) for c in overlays]


# ---- the body's own version of each part goes: its surface inside the part (the part round it on five of the six sides, a head open at
# the neck), just outside it where it faces away from the part's picture (within SKIN of the part's size; a little bigger, it would show
# through the part in patches), and just over it on the side its picture saw (within FRONT: a hood's brim standing over the new face), then
# the bits of the body that leaves loose round the parts (under 1% of the body: a hood's old tip). Surface facing the picture beside or
# behind a part stays: it is what shows between a ribcage's ribs, and under a part once the body moves. Cutting it too, and all a part's
# ring closed round, holed the Ossuary's chest behind its ribs and its robe from a belt to the thighs. A part over cloth that the body made
# of the cloth's own surface (a belt's column, pouch and medallion) cannot go cleanly: the body's version shows beside it or leaves a hole,
# so a part replaces what stands on its own (a head, a shoulder plate, a gorget, a ribcage)
SKIN = float(cfg.get('skin', 0.08))
FRONT = float(cfg.get('front', 0.15))
AXES = [Vector(r) for r in ((1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1))]   # closed round: 5 of 6 (a head's neck is open)
bm = bmesh.new(); bm.from_mesh(body.data); bm.verts.ensure_lookup_table(); bm.normal_update()
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
        if loc is None:
            continue
        if (p - loc).dot(n) >= 0:                                          # outside the part: gone where it stands over the part, and
            over = tree.ray_cast(p, look, ahead)[0] is not None            # near it unless it faces the picture
            inside[v.index] = over or (d < reach and v.normal.dot(-look) <= 0)
        else:                                                              # behind it: gone only where the part closes round it
            inside[v.index] = sum(tree.ray_cast(p, r)[0] is not None for r in AXES) >= 5
gone = np.array([all(inside[v.index] for v in f.verts) for f in bm.faces])
bm.free()
me = body.data
co = verts(body)
inbox = np.zeros(len(co), bool)
for c in placed:
    C = verts(c); g = 0.25 * (C.max(0) - C.min(0))
    inbox |= np.all((co >= C.min(0) - g) & (co <= C.max(0) + g), axis=1)
fv = np.empty(len(me.loops), np.int64); me.loops.foreach_get('vertex_index', fv)
start = np.empty(len(me.polygons), np.int64); me.polygons.foreach_get('loop_start', start)
face_in = np.minimum.reduceat(inbox[fv].astype(np.int8), start).astype(bool)   # every corner of the face round a part
cen = np.array([f.center[:] for f in me.polygons])


def loose_after(cut):
    """the bits of the body the cut leaves loose round the parts: pieces under 1% of what stays, every face round a part"""
    piece = pieces(me, ~cut)
    ids, size = np.unique(piece[~cut], return_counts=True)
    small = ids[size < 0.01 * (~cut).sum()]
    out = np.zeros(len(me.polygons), bool)
    for k in small:
        m = piece == k
        if face_in[m].all():
            out |= m
    return out


def tris(o):
    o.data.calc_loop_triangles()
    t = np.empty(len(o.data.loop_triangles) * 3, np.int64); o.data.loop_triangles.foreach_get('vertices', t)
    f = np.empty(len(o.data.loop_triangles), np.int64); o.data.loop_triangles.foreach_get('polygon_index', f)
    return verts(o), t.reshape(-1, 3), f


# a cut that opens a hole (seethrough.py: the ribcage's top under the cowl, seen from above, once the fitted ribcage grew) keeps the body's
# surface within HOLE of the height round it, in up to three rounds
HOLE = 0.03
ta, ca = tree_of(original.data)
BV, BT, BF = tris(body)
rest = [tris(o)[:2] for o in [*placed, *overlays]]
kept = np.zeros(len(me.polygons), bool)
for round_ in range(4):                                                     # the last round only looks
    cut = gone | loose_after(gone)
    V, T, n = [BV], [BT[~cut[BF]]], len(BV)
    for v, t in rest:
        V.append(v); T.append(t + n); n += len(v)
    pts = []
    seen = see_through(ta, BVHTree.FromPolygons(np.concatenate(V).tolist(), np.concatenate(T).tolist(), all_triangles=True), ca.min(0), ca.max(0), points=pts)
    near = np.zeros(len(me.polygons), bool)
    for q in pts:
        near |= gone & (np.linalg.norm(cen - np.array(q[:]), axis=1) < HOLE * float(bsize[2]))
    if round_ == 3 or not near.any():
        break
    gone &= ~near; kept |= near
rep['seeThrough'] = seen                                                    # holes the parts opened (seethrough.py)
rep['bodyTrisKept'] = int(kept.sum())
loose = loose_after(gone)
rep['bodyTrisRemoved'] = int(gone.sum()); rep['bodyTrisLoose'] = int(loose.sum())
bm = bmesh.new(); bm.from_mesh(me); bm.faces.ensure_lookup_table()
bmesh.ops.delete(bm, geom=[bm.faces[i] for i in np.flatnonzero(gone | loose)], context='FACES')
bmesh.ops.delete(bm, geom=[v for v in bm.verts if not v.link_faces], context='VERTS')
bm.to_mesh(me); bm.free()

# ---- one object, a material per source (a mirrored copy shares its part's)
bpy.ops.object.select_all(action='DESELECT')
for o in [body, *placed, *overlays]:
    o.select_set(True)
bpy.context.view_layer.objects.active = body
bpy.ops.object.join()
out = bpy.context.view_layer.objects.active
rep['tris'] = sum(len(p.vertices) - 2 for p in out.data.polygons)
rep['materials'] = len(out.data.materials)
bpy.data.objects.remove(original, do_unlink=True)
bpy.ops.object.select_all(action='DESELECT')
out.select_set(True)
bpy.ops.export_scene.gltf(filepath=OUT, use_selection=True, export_format='GLB', export_yup=True, export_image_format='AUTO')
rep['seconds'] = round(time.time() - t0, 1)
print('PARTS', json.dumps(rep))
if REPORT:
    json.dump(rep, open(REPORT, 'w'), indent=1)
