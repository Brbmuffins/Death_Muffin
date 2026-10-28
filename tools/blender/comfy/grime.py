# blender -b --python grime.py -- <in.glb> <out.glb> [--amount 1] [--film 0.25] [--crevice 1] [--stain 1] [--ground 1] [--top 0.5] [--age 0.5] [--reach 0.06] [--seed 0]
#   [--report <json>]
# Dirt painted into a game model's colour texture (and its roughness), for models that come out of Pixal too clean (the hound from a washed 3D-style
# picture: bright clean bones, "a Halloween decoration"). Five kinds, each 0..1 and all scaled by --amount:
#   film     a thin layer everywhere, so no part reads brand new
#   crevice  dark grime where the surface is shut in (Cycles ambient-occlusion bake on the game mesh, looking --reach of the height around)
#   stain    uneven patches and small specks over the surface (3D noise, so no seams at UV edges; --seed picks the pattern)
#   ground   mud rising from the feet (lowest third of the height, strongest at the ground)
#   top      dust settled on the up-facing surfaces (the spine and skull top, which the game's overhead light makes the brightest)
# --age: old-bone yellowing of the light, colourless parts (0 = none). Dirt multiplies the colour towards dark grey grave soil with a hint of mould green
# (any warm brown, and strong yellowing, reads as flesh-pink under the game's purple light: red is all that survives a dark warm colour there), so it darkens light and dark parts alike and never lightens; dirty parts get rougher; painted glows stay clean. The model's up is Blender's +Z after import (the game file's up), so run it on game-placed models.
import bpy, sys, os, json, math
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from transfer import _loops, _raster, _frame, image_array, grow

a = sys.argv[sys.argv.index('--') + 1:]
IN, OUT = a[0], a[1]


def opt(name, default, cast=float):
    return cast(a[a.index(name) + 1]) if name in a else default


AMOUNT, FILM, CREV, STAIN, GROUND, TOP = opt('--amount', 1.0), opt('--film', 0.25), opt('--crevice', 1.0), opt('--stain', 1.0), opt('--ground', 1.0), opt('--top', 0.5)
AGE, REACH, SEED, REPORT = opt('--age', 0.5), opt('--reach', 0.06), opt('--seed', 0, int), opt('--report', '', str)
DIRT = np.array([0.34, 0.36, 0.33])          # what full grime multiplies the colour by (sRGB): dark grey soil, a hint of mould green
OLD = np.array([1.0, 0.96, 0.87])            # old bone: yellowed ivory

for o in list(bpy.data.objects):
    bpy.data.objects.remove(o, do_unlink=True)
bpy.ops.import_scene.gltf(filepath=IN)
meshes = [o for o in bpy.data.objects if o.type == 'MESH']
lo = max(meshes, key=lambda o: len(o.data.polygons))
pts = np.array([lo.matrix_world @ v.co for v in lo.data.vertices])
zmin, height = pts[:, 2].min(), np.ptp(pts[:, 2])
sc = bpy.context.scene
rep = dict(input=IN, height=round(float(height), 3))


def src_image_node(sock):
    while sock.is_linked:
        n = sock.links[0].from_node
        if n.type == 'TEX_IMAGE':
            return n
        sock = next((i for i in n.inputs if i.is_linked), None)
        if sock is None:
            return None
    return None


mat = lo.active_material
nt = mat.node_tree
bsdf = next(n for n in nt.nodes if n.type == 'BSDF_PRINCIPLED')
base_img = src_image_node(bsdf.inputs['Base Color']).image
orm_node = src_image_node(bsdf.inputs['Roughness'])
W, H = base_img.size

# ---- crevices: ambient occlusion baked on the game mesh
sc.render.engine = 'CYCLES'; sc.cycles.device = 'CPU'; sc.cycles.samples = 64
sc.render.threads_mode = 'FIXED'; sc.render.threads = 4
if sc.world is None:
    sc.world = bpy.data.worlds.new('w')
sc.world.light_settings.distance = REACH * height
ao_img = bpy.data.images.new('ao', W, H, alpha=False, float_buffer=True)
ao_img.colorspace_settings.name = 'Non-Color'
tn = nt.nodes.new('ShaderNodeTexImage'); tn.image = ao_img; nt.nodes.active = tn
for o in bpy.data.objects:
    o.select_set(o == lo)
bpy.context.view_layer.objects.active = lo
bpy.ops.object.bake(type='AO', margin=4, margin_type='EXTEND', use_clear=True)   # past the chart edges: their edge texels count as filled
ao = image_array(ao_img)[..., 0]
nt.nodes.remove(tn)

# ---- each texel's place on the model (for the stains and the ground)
L = _loops(lo.data, lo.data.uv_layers.active.name)
tri_of, bary = _raster(L, W)
filled = tri_of >= 0
pos, nrm, _, _ = _frame(L, tri_of[filled], bary[filled])
M = np.array(lo.matrix_world)
pos = pos @ M[:3, :3].T + M[:3, 3]
nrm = nrm @ np.linalg.inv(M[:3, :3])
nrm /= np.linalg.norm(nrm, axis=1, keepdims=True) + 1e-12


def value_noise(p, cells, seed):
    """smooth 3D value noise in 0..1 on a lattice of <cells> per model height"""
    rng = np.random.default_rng(seed)
    g = rng.random((cells + 2,) * 3)
    q = (p - pts.min(0)) / height * cells
    q = np.clip(q, 0, cells - 1e-6)
    i = np.floor(q).astype(int); f = q - i
    f = f * f * (3 - 2 * f)
    out = 0.0
    for dx in (0, 1):
        for dy in (0, 1):
            for dz in (0, 1):
                w = (f[:, 0] if dx else 1 - f[:, 0]) * (f[:, 1] if dy else 1 - f[:, 1]) * (f[:, 2] if dz else 1 - f[:, 2])
                out = out + w * g[i[:, 0] + dx, i[:, 1] + dy, i[:, 2] + dz]
    return out


fbm = 0.55 * value_noise(pos, 6, SEED) + 0.3 * value_noise(pos, 14, SEED + 1) + 0.15 * value_noise(pos, 32, SEED + 2)
stain = np.maximum(np.clip((fbm - 0.45) / 0.3, 0, 1), 0.7 * np.clip((value_noise(pos, 70, SEED + 3) - 0.62) / 0.15, 0, 1))
ground = np.clip(1 - (pos[:, 2] - zmin) / (0.3 * height), 0, 1) ** 1.5
crev = np.clip((1 - ao[filled] - 0.08) / 0.55, 0, 1) ** 0.8
top = np.clip(nrm[:, 2], 0, 1) ** 2 * np.clip((fbm - 0.25) / 0.3, 0, 1)            # broken up by the stain noise, so it is not a flat cap
g = 1 - (1 - FILM) * (1 - CREV * crev) * (1 - 0.75 * STAIN * stain) * (1 - 0.7 * GROUND * ground) * (1 - 0.6 * TOP * top)
g = np.clip(AMOUNT * g, 0, 0.9)

# ---- into the colour and the roughness; gutters copy their nearest texel
base = image_array(base_img)
rgb = base[..., :3][filled]
mx, mn = rgb.max(-1), rgb.min(-1)
sat = (mx - mn) / np.maximum(mx, 1e-4)
old = AGE * np.clip((mx - 0.45) / 0.3, 0, 1) * (1 - np.clip(sat / 0.3, 0, 1))
g = g * (1 - np.clip((sat - 0.45) / 0.2, 0, 1) * np.clip((mx - 0.45) / 0.2, 0, 1))      # painted glows (bright, strongly coloured: the hound's eyes) stay clean
rgb = rgb * (1 - old[:, None] * (1 - OLD))
rgb = rgb * (1 - g[:, None] * (1 - DIRT))
src = grow(filled, 8).ravel()
gut = (~filled.ravel()) & (src >= 0)


def put(img, arr, idx, vals):
    flat = arr.reshape(-1, arr.shape[-1])
    sub = flat[filled.ravel()]
    sub[:, idx] = vals
    flat[filled.ravel()] = sub
    flat[gut] = flat[src[gut]]
    img.pixels.foreach_set(flat.ravel())
    img.pack()


put(base_img, base, slice(0, 3), rgb)
rep['grime'] = dict(mean=round(float(g.mean()), 3), over_half=round(float((g > 0.5).mean()), 3), crevice=round(float(crev.mean()), 3),
                    stain=round(float(stain.mean()), 3), ground=round(float(ground.mean()), 3), top=round(float(top.mean()), 3), aged=round(float((old > 0.1).mean()), 3))
if orm_node is not None and orm_node.image is not None and orm_node.image != base_img:
    orm_img = orm_node.image
    orm = image_array(orm_img)
    if orm.shape[:2] == (H, W):
        r = orm[..., 1][filled]
        put(orm_img, orm, 1, r + (0.95 - r) * 0.6 * g)
        rep['rough'] = True

bpy.ops.object.select_all(action='SELECT')
bpy.ops.export_scene.gltf(filepath=OUT, use_selection=True, export_format='GLB', export_yup=True, export_tangents=True, export_image_format='AUTO')
if REPORT:
    json.dump(rep, open(REPORT, 'w'), indent=1)
print('GRIME', json.dumps(rep))
