"""
decimate_trial.py - READ-ONLY audit trial (never touches public/models). Imports a shipped GLB twice, decimates the right copy
(collapse, UV seams kept), reports triangle counts and renders original | decimated side by side with Workbench.

  blender -b --python tools/blender/audit/decimate_trial.py -- <glb> <ratio> <out_prefix> [tex|wire] [--yaw DEG] [--right other.glb] [--out-glb file]
  --right: render this GLB (e.g. a meshopt-simplified copy from simplify_trial.mjs) on the right instead of Blender-decimating

Writes <out_prefix>_<mode>.png and prints a JSON line: {"glb","orig_tris","dec_tris","ratio"}.
Skinned models are decimated in rest pose with the Decimate modifier first in the stack (vertex-group weights are interpolated by
the collapse), so the result must still be judged in motion before shipping.
"""
import json, math, os, sys
import bpy
from mathutils import Vector

argv = sys.argv[sys.argv.index('--') + 1:]
path, ratio, prefix = argv[0], float(argv[1]), argv[2]
mode = 'wire' if 'wire' in argv else 'tex'
yaw = float(argv[argv.index('--yaw') + 1]) if '--yaw' in argv else 0.0
right = argv[argv.index('--right') + 1] if '--right' in argv else None
out_glb = argv[argv.index('--out-glb') + 1] if '--out-glb' in argv else None

bpy.ops.wm.read_factory_settings(use_empty=True)


def import_one(src=None):
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=src or path)
    new = [o for o in bpy.data.objects if o not in before]
    keep = []
    for o in new:  # the importer adds an 80-face 'Icosphere' bone-shape helper; it is not part of the model
        if o.type == 'MESH' and o.name.startswith('Icosphere'):
            bpy.data.objects.remove(o, do_unlink=True)
        else:
            keep.append(o)
    return keep


def tri_count(objs):
    dg = bpy.context.evaluated_depsgraph_get()
    n = 0
    for o in objs:
        if o.type != 'MESH':
            continue
        m = o.evaluated_get(dg).to_mesh()
        m.calc_loop_triangles()
        n += len(m.loop_triangles)
        o.evaluated_get(dg).to_mesh_clear()
    return n


def bbox(objs):
    """World-space bounds from evaluated vertices (bound_box lies for skinned meshes)."""
    lo, hi = Vector((1e9,) * 3), Vector((-1e9,) * 3)
    dg = bpy.context.evaluated_depsgraph_get()
    for o in objs:
        if o.type != 'MESH':
            continue
        e = o.evaluated_get(dg); m = e.to_mesh()
        for v in m.vertices:
            w = e.matrix_world @ v.co
            lo = Vector(map(min, lo, w)); hi = Vector(map(max, hi, w))
        e.to_mesh_clear()
    return lo, hi


def rest_pose():
    for o in bpy.data.objects:
        if o.type == 'ARMATURE':
            o.data.pose_position = 'REST'


orig = import_one()
dec = import_one(right)
rest_pose()
bpy.context.view_layer.update()
lo, hi = bbox([o for o in orig])
size = hi - lo
span = max(size.x, size.y, size.z)
# the right-hand copy: shift every root object along +X by 1.25 * width
roots_dec = [o for o in dec if o.parent is None]
dx = max(size.x, size.y) * 1.25
for r in roots_dec:
    r.location.x += dx
roots_orig = [o for o in orig if o.parent is None]
for r in roots_orig + roots_dec:
    r.rotation_mode = 'XYZ'
    r.rotation_euler.z += math.radians(yaw)
bpy.context.view_layer.update()

lo2, hi2 = bbox([o for o in dec])
lo = Vector(map(min, lo, lo2)); hi = Vector(map(max, hi, hi2))
meshes_dec = [o for o in dec if o.type == 'MESH']
before_tris = tri_count([o for o in orig if o.type == 'MESH'])
for o in ([] if right else meshes_dec):
    bpy.context.view_layer.objects.active = o
    md = o.modifiers.new('Dec', 'DECIMATE')
    md.decimate_type = 'COLLAPSE'
    md.ratio = ratio
    md.use_collapse_triangulate = True
    md.delimit = {'UV'}
    # decimate runs before the armature so it works on the rest mesh
    with bpy.context.temp_override(object=o, active_object=o):
        bpy.ops.object.modifier_move_to_index(modifier='Dec', index=0)
        bpy.ops.object.modifier_apply(modifier='Dec')
bpy.context.view_layer.update()
after_tris = tri_count(meshes_dec)

if out_glb:
    for o in bpy.data.objects:
        o.select_set(o in dec)
    bpy.ops.export_scene.gltf(filepath=out_glb, use_selection=True, export_format='GLB')

# ---- render
scene = bpy.context.scene
# No GPU/EGL on the VPS: Cycles on the CPU with a handful of samples (flat, bright, readable lighting).
scene.render.engine = 'CYCLES'
scene.cycles.device = 'CPU'
scene.cycles.samples = 24
scene.cycles.use_denoising = False
scene.render.film_transparent = False
scene.view_settings.view_transform = 'Standard'
scene.world = bpy.data.worlds.new('w'); scene.world.use_nodes = True
bg = scene.world.node_tree.nodes['Background']; bg.inputs[0].default_value = (0.20, 0.19, 0.23, 1); bg.inputs[1].default_value = 1.6
sun = bpy.data.lights.new('sun', 'SUN'); sun.energy = 3.0
so = bpy.data.objects.new('sun', sun); scene.collection.objects.link(so); so.rotation_euler = (math.radians(55), 0, math.radians(-30))

if mode == 'wire':
    def flat(name, rgb):
        m = bpy.data.materials.new(name); m.use_nodes = True
        nt = m.node_tree; nt.nodes.clear()
        e = nt.nodes.new('ShaderNodeEmission'); e.inputs[0].default_value = rgb + (1,)
        o = nt.nodes.new('ShaderNodeOutputMaterial'); nt.links.new(e.outputs[0], o.inputs[0]); return m
    grey = flat('grey', (0.45, 0.45, 0.5)); blk = flat('blk', (0.01, 0.01, 0.01))
    for o in [o for o in bpy.data.objects if o.type == 'MESH']:
        o.data.materials.clear(); o.data.materials.append(grey); o.data.materials.append(blk)
        for p in o.data.polygons:
            p.material_index = 0
        w = o.modifiers.new('Wire', 'WIREFRAME')
        w.thickness = span * 0.0018; w.use_replace = False; w.material_offset = 1; w.use_boundary = True

cam_d = bpy.data.cameras.new('cam'); cam_d.type = 'ORTHO'
cam = bpy.data.objects.new('cam', cam_d); scene.collection.objects.link(cam); scene.camera = cam
total_w = size.x + dx
cx = (lo.x + hi.x) / 2
cz = (lo.z + hi.z) / 2
cam.location = Vector((cx, lo.y - span * 3, cz)); cam.rotation_euler = (math.radians(90), 0, 0)
W, H = 1200, 640
cam_d.ortho_scale = max((hi.x - lo.x) * 1.08, (hi.z - lo.z) * 1.12 * W / H)
scene.render.resolution_x, scene.render.resolution_y = W, H
scene.render.image_settings.file_format = 'PNG'
scene.render.filepath = f'{prefix}_{mode}.png'
bpy.ops.render.render(write_still=True)
print('RESULT ' + json.dumps({'glb': os.path.basename(os.path.dirname(path)) + '/' + os.path.basename(path), 'orig_tris': before_tris, 'dec_tris': after_tris, 'ratio': ratio}))
