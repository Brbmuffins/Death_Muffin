# blender -b --python materials.py -- <game.glb> <out.glb> <materials.json> [--report <json>] [--classes <png>]
# What each part of a finished model is made of, and the shine that goes with it. Pixal3D paints one roughness over a whole figure (the Gravecaller:
# 0.88 everywhere, no metal) and bakes deep occlusion, so iron, leather and cloth read the same flat dull grey; a game artist gives each material its
# own response. Here the materials come from label pictures (each pixel a class number, 0 unknown; made from the concept and its views, the same
# framing as the pictures the model was made from): every texel the picture's camera sees takes its pixel's class; an unseen texel takes the vote of
# the 8 nearest seen ones within NEAR of the height, weighed by how alike their colours are (the inside of a sleeve is the sleeve's cloth), and what is
# left the class whose colours it matches (each class's colour spread, learnt from the seen texels), then a few rounds of majority among neighbours.
# Per class: a base roughness and metal (CLASSES, overridable), varied by the paint's own light and dark (scratches shine, grime dulls); metal is
# lifted to METAL_LIGHT where it is not grimy (Pixal3D paints iron near black, which reads as lacquer once it shines), and gets worn bright edges
# and dark crevices from the surface's bumps (the normal map) and folds (the mesh); the occlusion is lightened to `occlusion` of its depth.
# materials.json: {"labels": [{"file": <png>, "view": "front"|"back"}], "occlusion": 0.4, "wear": 1.0}; a label pixel's red is 1 + the class's place in
# CLASSES (1 metal, 2 leather, 3 cloth, 4 skin, 5 hair, 6 bone, 7 wood, 8 stone, 9 gem).
# The model is in the picture's frame (before place): x the picture's left to right, z up, the front facing -y; a label picture's subject spans the
# model's box (its non-zero pixels' box), the back view mirrored.
import bpy, sys, os, json, math, time
import numpy as np
from mathutils import Vector
from mathutils.bvhtree import BVHTree

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from transfer import _loops, _raster, _frame, image_array, grow

a = sys.argv[sys.argv.index('--') + 1:]
SRC, OUT, CFG = a[0], a[1], a[2]
REPORT = a[a.index('--report') + 1] if '--report' in a else ''
SEE = a[a.index('--classes') + 1] if '--classes' in a else ''            # the class map in the texture's layout, coloured, to put on the model and look at
cfg = json.load(open(CFG))
t0 = time.time()
rep = {}

# base roughness and metal per class (PBR reference values for worn game assets), and how much the paint's light/dark moves the roughness
CLASSES = {
    'metal': {'rough': 0.5, 'metal': 0.9, 'vary': 0.25},
    'leather': {'rough': 0.62, 'metal': 0.0, 'vary': 0.15},
    'cloth': {'rough': 0.9, 'metal': 0.0, 'vary': 0.05},
    'skin': {'rough': 0.55, 'metal': 0.0, 'vary': 0.08},
    'hair': {'rough': 0.5, 'metal': 0.0, 'vary': 0.1},
    'bone': {'rough': 0.66, 'metal': 0.0, 'vary': 0.15},
    'wood': {'rough': 0.72, 'metal': 0.0, 'vary': 0.12},
    'stone': {'rough': 0.82, 'metal': 0.0, 'vary': 0.1},
    'gem': {'rough': 0.25, 'metal': 0.0, 'vary': 0.05},
}
OCC = float(cfg.get('occlusion', 0.4))
WEAR = float(cfg.get('wear', 1.0))
METAL_LIGHT = 0.32                                                       # clean metal's usual colour value (stored, sRGB): worn iron
NEAR = 0.03                                                              # how far an unseen texel looks for seen ones, share of the height

# ---- the model and its maps
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=SRC)
o = next(x for x in bpy.data.objects if x.type == 'MESH')
bpy.ops.object.select_all(action='DESELECT')
o.select_set(True)
bpy.context.view_layer.objects.active = o
bpy.ops.object.parent_clear(type='CLEAR_KEEP_TRANSFORM')
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
me = o.data
mat = me.materials[0]
nodes = mat.node_tree.nodes
bsdf = next(n for n in nodes if n.type == 'BSDF_PRINCIPLED')


def image_of(sock):
    while sock.is_linked:
        n = sock.links[0].from_node
        if n.type == 'TEX_IMAGE':
            return n.image
        sock = next((i for i in n.inputs if i.is_linked), None)
        if sock is None:
            return None
    return None


img = {'base': image_of(bsdf.inputs['Base Color']), 'orm': image_of(bsdf.inputs['Roughness']) or image_of(bsdf.inputs['Metallic']),
       'normal': image_of(bsdf.inputs['Normal'])}
occ_img = None
for n in nodes:
    if n.type == 'GROUP' and n.node_tree and 'Occlusion' in n.inputs and n.inputs['Occlusion'].is_linked:
        occ_img = image_of(n.inputs['Occlusion'])
arr = {k: image_array(v) for k, v in img.items() if v is not None}
TEX = arr['base'].shape[0]
L = _loops(me)
tri_of, bary = _raster(L, TEX)
cov = tri_of >= 0
P, N, T, Bt = _frame(L, tri_of[cov], bary[cov])
rows, cols = np.nonzero(cov)
co = np.empty(len(me.vertices) * 3); me.vertices.foreach_get('co', co); co = co.reshape(-1, 3)
blo, bhi = co.min(0), co.max(0)
me.calc_loop_triangles()
tree = BVHTree.FromPolygons([tuple(v) for v in co], [tuple(t.vertices) for t in me.loop_triangles], all_triangles=True)
rep['texels'] = int(cov.sum())

# ---- classes from the label pictures, where their camera sees the surface
names = list(CLASSES)
lab = np.zeros(len(P), dtype=np.int16)                                  # 0 unknown, else 1 + index into names
for spec in cfg.get('labels', []):
    li = bpy.data.images.load(spec['file'])
    li.colorspace_settings.name = 'Non-Color'
    im = np.rint(image_array(li)[::-1, :, 0] * 255).astype(np.int16)   # top row first, like the picture; the class number in red
    ys, xs = np.nonzero(im)
    x0, x1, y0, y1 = xs.min(), xs.max() + 1, ys.min(), ys.max() + 1
    view = spec.get('view', 'front')
    d = np.array([0, -1, 0] if view == 'front' else [0, 1, 0], dtype=float)
    u = (P[:, 0] - blo[0]) / (bhi[0] - blo[0])
    if view == 'back':
        u = 1 - u
    v = (bhi[2] - P[:, 2]) / (bhi[2] - blo[2])
    px = np.clip((x0 + u * (x1 - x0)).astype(int), 0, im.shape[1] - 1)
    py = np.clip((y0 + v * (y1 - y0)).astype(int), 0, im.shape[0] - 1)
    facing = (N @ d) > 0.2
    seen = 0
    eps = float(np.linalg.norm(bhi - blo)) * 1e-4
    dv = Vector(d)
    for k in np.flatnonzero(facing & (lab == 0)):
        if tree.ray_cast(Vector(P[k]) + dv * eps * 4, dv)[0] is not None:
            continue
        c = int(im[py[k], px[k]])
        if 0 < c <= len(names):
            lab[k] = c
            seen += 1
    rep.setdefault('seen', {})[view] = round(seen / len(P), 3)

# ---- the rest by colour: each class's mean and spread in Lab, learnt from the seen texels
base = arr['base'][rows, cols, :3]


def to_lab(rgb):
    c = np.where(rgb > 0.04045, ((np.clip(rgb, 0, 1) + 0.055) / 1.055) ** 2.4, rgb / 12.92)     # Blender holds a byte image's stored (sRGB) values
    M = np.array([[0.4124, 0.3576, 0.1805], [0.2126, 0.7152, 0.0722], [0.0193, 0.1192, 0.9505]])
    xyz = c @ M.T / np.array([0.9505, 1.0, 1.089])
    f = np.where(xyz > 0.008856, np.cbrt(xyz), 7.787 * xyz + 16 / 116)
    return np.stack([116 * f[:, 1] - 16, 500 * (f[:, 0] - f[:, 1]), 200 * (f[:, 1] - f[:, 2])], 1)


F = np.concatenate([to_lab(base), (P[:, 2:3] - blo[2]) / (bhi[2] - blo[2]) * 20], 1)   # colour, and height a little (hair high, boots low)
known = lab > 0
# an unseen texel (inside the hood, under a sleeve) takes the class of the seen surface near it in space, its votes weighted by how alike their colours
# are: colour alone took the Gravecaller's dark cloth for iron (18% metal against the concept's 6%)
near_share = 0.0
seen_lab = lab.copy()
if known.any() and (~known).any():
    from mathutils.kdtree import KDTree
    ks = np.flatnonzero(known)
    ks = ks[np.random.default_rng(1).permutation(len(ks))[:80000]]
    kd = KDTree(len(ks))
    for i, k in enumerate(ks):
        kd.insert(Vector(P[k]), i)
    kd.balance()
    R = float(bhi[2] - blo[2]) * NEAR
    Lab = F[:, :3]
    un = np.flatnonzero(~known)
    K = 8
    nb = np.full((len(un), K), -1, np.int64); nd = np.full((len(un), K), np.inf)
    for r, k in enumerate(un):                                          # the K nearest seen texels
        for c, (_, i, dist) in enumerate(kd.find_n(Vector(P[k]), K)):
            nb[r, c] = ks[i]; nd[r, c] = dist
    ok = (nb >= 0) & (nd <= R)
    dc = Lab[np.where(ok, nb, 0)] - Lab[un][:, None, :]
    w = np.where(ok, np.exp(-(dc ** 2).sum(2) / (2 * 12.0 ** 2) - (np.minimum(nd, R) / R) ** 2 * 2), 0.0)
    votes = np.zeros((len(un), len(names)))
    for c in range(K):
        np.add.at(votes, (np.arange(len(un)), np.clip(lab[np.where(ok[:, c], nb[:, c], 0)] - 1, 0, None)), w[:, c])
    take = votes.max(1) > 0.05
    lab[un[take]] = votes[take].argmax(1) + 1
    near_share = float((lab[un] > 0).mean())
rep['nearShare'] = round(near_share, 3)
known = lab > 0
if known.any() and (~known).any():
    score = np.full(((~known).sum(), len(names)), -np.inf)
    for ci in range(len(names)):
        m = seen_lab == ci + 1                                          # learnt from what the pictures saw
        if m.sum() < 50:
            continue
        mu = F[m].mean(0)
        cv = np.cov(F[m].T) + np.eye(F.shape[1]) * 1.0
        ic = np.linalg.inv(cv)
        dd = F[~known] - mu
        score[:, ci] = -0.5 * np.einsum('ij,jk,ik->i', dd, ic, dd) - 0.5 * np.linalg.slogdet(cv)[1] + np.log(m.mean())
    lab[~known] = score.argmax(1) + 1
rep['classShare'] = {n: round(float((lab == i + 1).mean()), 3) for i, n in enumerate(names) if (lab == i + 1).any()}

# ---- a few rounds of majority among texel neighbours (in the texture: within a chart), so no salt and pepper
grid = np.zeros((TEX, TEX), dtype=np.int16); grid[rows, cols] = lab
for _ in range(2):
    votes = np.zeros((len(names) + 1, TEX, TEX), dtype=np.int16)
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            r = np.roll(np.roll(grid, dy, 0), dx, 1)
            for ci in range(1, len(names) + 1):
                votes[ci] += r == ci
    best = votes[1:].argmax(0) + 1
    grid = np.where(cov & (votes[1:].max(0) >= 5), best, grid).astype(np.int16)
lab = grid[rows, cols]
if SEE:
    pal = np.array([[0, 0, 0], [0.1, 0.8, 1], [1, 0.5, 0.05], [0.6, 0.3, 1], [1, 0.35, 0.6], [0.15, 0.9, 0.35], [1, 0.9, 0.2], [0.5, 0.3, 0.1],
                    [0.6, 0.6, 0.6], [1, 0.1, 0.1]])
    si = bpy.data.images.new('classes', TEX, TEX)
    px = np.ones((TEX, TEX, 4)); px[..., :3] = pal[grid]
    si.pixels.foreach_set(px.astype(np.float32).ravel()); si.filepath_raw = SEE; si.file_format = 'PNG'; si.save()

# ---- the surface's bumps (convex +, concave -): the normal map's divergence, plus the mesh's own folds at its corners
conv = np.zeros(len(P))
if 'normal' in arr:
    n = arr['normal'][..., :3] * 2 - 1
    div = (np.roll(n[..., 0], -1, 1) - np.roll(n[..., 0], 1, 1)) + (np.roll(n[..., 1], -1, 0) - np.roll(n[..., 1], 1, 0))
    conv += np.clip(div[rows, cols] * 2.0, -1, 1)
vn = np.empty(len(me.vertices) * 3); me.vertices.foreach_get('normal', vn); vn = vn.reshape(-1, 3)
fold = np.zeros(len(me.vertices)); cnt = np.zeros(len(me.vertices))
ev = np.empty(len(me.edges) * 2, dtype=np.int64); me.edges.foreach_get('vertices', ev); ev = ev.reshape(-1, 2)
dvec = co[ev[:, 1]] - co[ev[:, 0]]
ln = np.linalg.norm(dvec, axis=1) + 1e-12
k = ((vn[ev[:, 1]] - vn[ev[:, 0]]) * dvec).sum(1) / ln                 # >0 where the surface turns away (convex: the normals spread along the edge)
np.add.at(fold, ev[:, 0], k); np.add.at(fold, ev[:, 1], k); np.add.at(cnt, ev[:, 0], 1); np.add.at(cnt, ev[:, 1], 1)
fold /= np.maximum(cnt, 1)
vi = np.empty(len(me.loops), dtype=np.int64); me.loops.foreach_get('vertex_index', vi)
tv = vi[L['tri'][tri_of[cov]]]
conv += np.clip(np.einsum('ij,ij->i', bary[cov], fold[tv]) * 3.0, -1, 1)
conv = np.clip(conv, -1, 1)

# ---- roughness, metal, worn edges and dark crevices per class; the occlusion lightened
orm = arr['orm'][rows, cols].copy() if 'orm' in arr else np.tile([1.0, 0.8, 0.0, 1.0], (len(P), 1))
lum = base @ np.array([0.2126, 0.7152, 0.0722])
col = arr['base'][rows, cols].copy()
for ci, name in enumerate(names):
    m = lab == ci + 1
    if not m.any():
        continue
    c = CLASSES[name]
    rel = (lum[m] - np.median(lum[m])) / (np.std(lum[m]) + 1e-6)          # brighter than the class's usual: worn shine; darker: grime
    rough = c['rough'] - c['vary'] * np.clip(rel, -2, 2) * 0.5
    metal = np.full(m.sum(), c['metal'])
    if c['metal'] > 0.5:
        # Pixal paints iron nearly black (the light it saw baked in); a metal's colour is its reflection, so a black one is a dark mirror that reads as
        # wet lacquer: the clean metal is lifted to METAL_LIGHT, the paint's darker spots stay dark as grime, rougher and less metal
        grime = np.clip(-rel, 0, 2) / 2
        lift = min(max(METAL_LIGHT / max(float(np.median(lum[m])), 1e-3), 1.0), 4.0)
        col[m, :3] = np.clip(col[m, :3] * (1 + (lift - 1) * (1 - grime))[:, None], 0, 1)
        rough = rough + 0.25 * grime
        metal = metal * (1 - 0.5 * grime)
        edge = np.clip(conv[m], 0, 1) * WEAR
        pit = np.clip(-conv[m], 0, 1) * WEAR
        col[m, :3] = col[m, :3] * (1 - 0.45 * edge[:, None]) + np.array([0.55, 0.54, 0.52]) * 0.45 * edge[:, None]
        col[m, :3] *= (1 - 0.35 * pit)[:, None]
        rough = rough - 0.18 * edge + 0.2 * pit
        metal = metal * (1 - 0.6 * pit) * np.clip(0.5 + lum[m] * 4, 0.5, 1)  # black grime in the dents is not bare metal
    else:
        pit = np.clip(-conv[m], 0, 1) * WEAR
        col[m, :3] *= (1 - 0.2 * pit)[:, None]
        rough = rough + 0.08 * pit
    orm[m, 1] = np.clip(rough, 0.05, 1)
    orm[m, 2] = np.clip(metal, 0, 1)
orm[:, 0] = 1 - OCC * (1 - orm[:, 0])
rep['roughP'] = [round(float(x), 2) for x in np.quantile(orm[:, 1], [0.05, 0.5, 0.95])]
rep['metalShare'] = round(float((orm[:, 2] > 0.5).mean()), 3)

# ---- back into the images (the UV gutters copy their nearest texel), export
src = grow(cov, 16).ravel()
for key, vals in (('base', col), ('orm', orm)):
    out = arr[key].reshape(-1, 4).copy() if key in arr else np.tile([1.0, 0.8, 0.0, 1.0], (TEX * TEX, 1)).astype(np.float32)
    flat = np.full((TEX * TEX, 4), np.nan, dtype=np.float32)
    flat[rows * TEX + cols] = vals
    has = src >= 0
    out[has] = flat[src[has]]
    target = img.get(key)
    if target is None:
        continue
    target.pixels.foreach_set(out.ravel())
    target.pack()
if occ_img is not None and occ_img is not img['orm']:
    rep['note'] = 'the occlusion is its own image: left as it was'
bpy.ops.object.select_all(action='DESELECT')
o.select_set(True)
bpy.ops.export_scene.gltf(filepath=OUT, use_selection=True, export_format='GLB', export_yup=True, export_tangents=True, export_image_format='AUTO',
                          export_attributes=True)   # _DM_RIGID (finish.py) for the rig
rep['seconds'] = round(time.time() - t0, 1)
print('MATERIALS', json.dumps(rep))
if REPORT:
    json.dump(rep, open(REPORT, 'w'), indent=1)
