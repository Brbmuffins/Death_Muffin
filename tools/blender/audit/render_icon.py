"""
render_icon.py - AUDIT PROOF OF CONCEPT: render a shipped prop GLB as a transparent inventory-icon sprite (Cycles CPU, no GPU needed).
  blender -b --python tools/blender/audit/render_icon.py -- <glb> <out.png> [size=256] [--tilt DEG] [--spin DEG] [--tint r,g,b]
Three-quarter view, warm key + cool rim light, ground-free, film transparent. Pipe the PNG through sharp to WebP for shipping.
"""
import math, sys
import bpy
from mathutils import Vector

a = sys.argv[sys.argv.index('--') + 1:]
src, out = a[0], a[1]
size = int(a[2]) if len(a) > 2 and a[2].isdigit() else 256
def opt(n, d): return float(a[a.index(n) + 1]) if n in a else d
tilt, spin = opt('--tilt', 25), opt('--spin', 35)
bpy.ops.wm.read_factory_settings(use_empty=True)
before = set(bpy.data.objects)
bpy.ops.import_scene.gltf(filepath=src)
objs = [o for o in bpy.data.objects if o not in before]
meshes = [o for o in objs if o.type == 'MESH']
for o in objs:
    if o.parent is None:
        o.rotation_euler.z += math.radians(spin)
bpy.context.view_layer.update()

def bounds():
    lo, hi = Vector((1e9,) * 3), Vector((-1e9,) * 3)
    for o in meshes:
        for c in o.bound_box:
            w = o.matrix_world @ Vector(c); lo = Vector(map(min, lo, w)); hi = Vector(map(max, hi, w))
    return lo, hi

lo, hi = bounds()
ext = hi - lo
# long thin items (staves, scythes) read better on the diagonal
roll = opt('--roll', 38 if max(ext) / max(1e-6, sorted(ext)[1]) > 2.4 else 0)
if roll:
    for o in objs:
        if o.parent is None:
            o.rotation_euler.rotate_axis('Y', math.radians(roll)) if False else None
    piv = bpy.data.objects.new('piv', None); bpy.context.scene.collection.objects.link(piv)
    for o in objs:
        if o.parent is None:
            o.parent = piv
    piv.rotation_euler = (0, math.radians(roll), 0)
    bpy.context.view_layer.update()
    lo, hi = bounds()
ctr, ext = (lo + hi) / 2, hi - lo
r = max(ext) * 0.5
sc = bpy.context.scene
sc.render.engine = 'CYCLES'; sc.cycles.device = 'CPU'; sc.cycles.samples = 48; sc.cycles.use_denoising = False
sc.render.film_transparent = True
sc.render.resolution_x = sc.render.resolution_y = size
sc.view_settings.view_transform = 'Standard'
sc.world = bpy.data.worlds.new('w'); sc.world.use_nodes = True
bg = sc.world.node_tree.nodes['Background']; bg.inputs[0].default_value = (0.30, 0.30, 0.36, 1); bg.inputs[1].default_value = 1.0
def light(name, kind, e, rot, col):
    L = bpy.data.lights.new(name, kind); L.energy = e; L.color = col
    o = bpy.data.objects.new(name, L); sc.collection.objects.link(o); o.rotation_euler = [math.radians(x) for x in rot]
light('key', 'SUN', 4.0, (50, 0, 30), (1.0, 0.86, 0.68))
light('rim', 'SUN', 2.5, (70, 0, 200), (0.55, 0.65, 1.0))
cd = bpy.data.cameras.new('c'); cd.type = 'ORTHO'
cam = bpy.data.objects.new('c', cd); sc.collection.objects.link(cam); sc.camera = cam
t = math.radians(tilt)
cam.rotation_euler = (math.radians(90) - t, 0, 0)
cam.location = ctr + Vector((0, -math.cos(t), math.sin(t))) * r * 8
bpy.context.view_layer.update()
inv = cam.matrix_world.inverted()
xs, ys = [], []
for o in meshes:
    for c in o.bound_box:
        q = inv @ (o.matrix_world @ Vector(c)); xs.append(q.x); ys.append(q.y)
cx, cy = (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2
cam.location += cam.matrix_world.to_3x3() @ Vector((cx, cy, 0))
cd.ortho_scale = max(max(xs) - min(xs), max(ys) - min(ys)) * 1.14
sc.render.image_settings.file_format = 'PNG'; sc.render.image_settings.color_mode = 'RGBA'
sc.render.filepath = out
bpy.ops.render.render(write_still=True)
print('ICON', src, out)
