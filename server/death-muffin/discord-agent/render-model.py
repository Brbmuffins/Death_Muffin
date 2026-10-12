"""
render-model.py - review renders of built models for the Discord agent (render-model.sh runs it inside the sandbox):
  blender -b --factory-startup --python render-model.py -- <out_dir> <label>=<file.glb> [<label>=<file.glb> ...]
Writes <out_dir>/<n>_<view>.png for each model (n = 0-based index, views front / side / back), textured, Cycles on the CPU with a few
threads and low samples (the VPS runs live game servers). Characters are shown in their first animation frame (rest pose when there is none).
Composed into one sheet by render-model.sh afterwards.
"""
import math
import os
import sys

import bpy
from mathutils import Vector

SIZE = (420, 520)
VIEWS = [('front', 30.0), ('side', 90.0), ('back', 180.0)]


def args():
    a = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else []
    return a[0], [x.split('=', 1) for x in a[1:]]


def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def bounds(objs):
    pts = []
    dg = bpy.context.evaluated_depsgraph_get()
    for o in objs:
        if o.type != 'MESH':
            continue
        ev = o.evaluated_get(dg)
        me = ev.to_mesh()
        mw = o.matrix_world
        pts += [mw @ v.co for v in me.vertices]
        ev.to_mesh_clear()
    if not pts:
        return Vector((0, 0, 0)), Vector((1, 1, 1))
    lo = Vector((min(p[i] for p in pts) for i in range(3)))
    hi = Vector((max(p[i] for p in pts) for i in range(3)))
    return lo, hi


def setup_scene():
    sc = bpy.context.scene
    sc.render.engine = 'CYCLES'
    sc.cycles.device = 'CPU'
    sc.cycles.samples = 24
    sc.cycles.use_denoising = True
    sc.render.threads_mode = 'FIXED'
    sc.render.threads = 4
    sc.render.resolution_x, sc.render.resolution_y = SIZE
    sc.render.film_transparent = False
    sc.view_settings.view_transform = 'Standard'
    w = bpy.data.worlds.new('w')
    w.use_nodes = True
    w.node_tree.nodes['Background'].inputs[0].default_value = (0.32, 0.31, 0.34, 1)
    w.node_tree.nodes['Background'].inputs[1].default_value = 0.9
    sc.world = w
    for name, energy, rot in (('key', 3.2, (50, 0, 35)), ('rim', 2.0, (60, 0, 200))):
        lt = bpy.data.objects.new(name, bpy.data.lights.new(name, 'SUN'))
        lt.data.energy = energy
        lt.rotation_euler = [math.radians(r) for r in rot]
        sc.collection.objects.link(lt)
    cam = bpy.data.objects.new('cam', bpy.data.cameras.new('cam'))
    cam.data.lens = 70
    sc.collection.objects.link(cam)
    sc.camera = cam
    return sc, cam


def main():
    out, models = args()
    os.makedirs(out, exist_ok=True)
    for n, (label, glb) in enumerate(models):
        reset()
        sc, cam = setup_scene()
        before = set(bpy.data.objects)
        bpy.ops.import_scene.gltf(filepath=glb)
        objs = [o for o in bpy.data.objects if o not in before]
        shapes = {pb.custom_shape for o in objs if o.type == 'ARMATURE' for pb in o.pose.bones if pb.custom_shape}
        for o in objs:   # the importer's bone display shapes (an Icosphere) are not part of the model
            if o in shapes:
                o.hide_render = True
        objs = [o for o in objs if o not in shapes and not o.hide_render]
        for o in objs:
            if o.animation_data and o.animation_data.action:
                sc.frame_set(int(o.animation_data.action.frame_range[0]))
        bpy.context.view_layer.update()
        lo, hi = bounds(objs)
        ctr = (lo + hi) / 2
        size = hi - lo
        radius = max(size.length / 2, 0.01)
        dist = radius / math.tan(cam.data.angle / 2) * 1.08
        # glTF +Z (forward) imports as Blender -Y; Tripo props face +X in the game table, characters face glTF +Z
        for view, yaw in VIEWS:
            a = math.radians(yaw)
            d = Vector((math.sin(a), -math.cos(a), 0.28)).normalized()
            cam.location = ctr + d * dist
            cam.rotation_euler = (-d).to_track_quat('-Z', 'Y').to_euler()
            sc.render.filepath = os.path.join(out, f'{n}_{view}.png')
            bpy.ops.render.render(write_still=True)
        print(f'RENDERED {n} {label}', flush=True)


main()
