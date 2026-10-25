"""
preview.py - the pictures a Blender job posts in the thread (tools/blender/jobs.mjs, DECISIONS B74):
  blender -b --factory-startup --python preview.py -- clips <out_dir> <model.glb> <frames> <clip> [<clip> ...]
      <out_dir>/clip_<n>_<f>.png: <frames> moments of each clip, evenly over its length, from a three-quarter view with a floor line
  blender -b --factory-startup --python preview.py -- views <out_dir> <before.glb> <after.glb>
      <out_dir>/<before|after>_<front|side|back>.png: the model before and after an edit, in its first clip's first frame
Cycles on the CPU, a few threads, few samples (the VPS runs live game servers); jobs.mjs composes the sheet. One camera per clip, framed on
every frame's bounds, so the body moves through a still picture.
"""
import math
import os
import sys

import bpy
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common  # noqa: E402

CLIP_SIZE = (300, 300)
VIEW_SIZE = (320, 400)
VIEWS = [('front', 30.0), ('side', 90.0), ('back', 180.0)]
LOOPS = {'idle', 'walk', 'run', 'fly'}


def scene(size):
    sc = bpy.context.scene
    sc.render.engine = 'CYCLES'
    sc.cycles.device = 'CPU'
    sc.cycles.samples = 12
    sc.cycles.use_denoising = True
    sc.render.threads_mode = 'FIXED'
    sc.render.threads = 4
    sc.render.resolution_x, sc.render.resolution_y = size
    sc.render.fps = common.FPS
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
    cam.data.lens = 60
    sc.collection.objects.link(cam)
    sc.camera = cam
    return sc, cam


def load(path):
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=path)
    objs = [o for o in bpy.data.objects if o not in before]
    shapes = {pb.custom_shape for o in objs if o.type == 'ARMATURE' for pb in o.pose.bones if pb.custom_shape}
    for o in shapes:
        o.hide_render = True
    return [o for o in objs if o not in shapes]


def bounds(objs):
    dg = bpy.context.evaluated_depsgraph_get()
    pts = []
    for o in objs:
        if o.type != 'MESH' or o.hide_render:
            continue
        ev = o.evaluated_get(dg)
        me = ev.to_mesh()
        pts += [o.matrix_world @ me.vertices[i].co for i in range(0, len(me.vertices), 7)]
        ev.to_mesh_clear()
    if not pts:
        return Vector((0, 0, 0)), Vector((1, 1, 1))
    return Vector((min(p[i] for p in pts) for i in range(3))), Vector((max(p[i] for p in pts) for i in range(3)))


def aim(cam, lo, hi, yaw, lift=0.28):
    ctr = (lo + hi) / 2
    radius = max((hi - lo).length / 2, 0.01)
    dist = radius / math.tan(cam.data.angle / 2) * 1.08
    a = math.radians(yaw)
    d = Vector((math.sin(a), -math.cos(a), lift)).normalized()
    cam.location = ctr + d * dist
    cam.rotation_euler = (-d).to_track_quat('-Z', 'Y').to_euler()


def floor(z, size):
    bpy.ops.mesh.primitive_plane_add(size=size, location=(0, 0, z))
    pl = bpy.context.active_object
    m = bpy.data.materials.new('floor')
    m.use_nodes = True
    m.node_tree.nodes['Principled BSDF'].inputs['Base Color'].default_value = (0.16, 0.15, 0.17, 1)
    pl.data.materials.append(m)


def render(sc, path):
    sc.render.filepath = path
    bpy.ops.render.render(write_still=True)


def clips(out, glb, frames, names):
    common.reset_scene()
    sc, cam = scene(CLIP_SIZE)
    objs = load(glb)
    arm = next((o for o in objs if o.type == 'ARMATURE'), None)
    if arm is None:
        raise SystemExit('the model has no skeleton')
    if arm.animation_data is None:
        arm.animation_data_create()
    acts = {a.name: a for a in bpy.data.actions}
    for n, name in enumerate(names):
        act = acts.get(name) or next((a for a in acts.values() if a.name.split('_')[0] == name), None)
        if act is None:
            raise SystemExit(f'no clip {name} in the model (has: {", ".join(sorted(acts))})')
        arm.animation_data.action = act
        if hasattr(act, 'slots') and len(act.slots) and hasattr(arm.animation_data, 'action_slot'):
            arm.animation_data.action_slot = act.slots[0]
        f0, f1 = int(round(act.frame_range[0])), int(round(act.frame_range[1]))
        steps = frames if name in LOOPS else max(1, frames - 1)   # a loop's last frame is its first again; a one-shot shows its end
        at = [f0 + round(i * (f1 - f0) / steps) for i in range(frames)]
        lo, hi = None, None
        for f in at:
            sc.frame_set(f)
            a, b = bounds(objs)
            lo = a if lo is None else Vector(map(min, lo, a))
            hi = b if hi is None else Vector(map(max, hi, b))
        if n == 0:   # the floor at the first clip's lowest point
            floor(lo.z, max((hi - lo).length * 40, 40))
        aim(cam, lo, hi, 55.0, 0.22)
        for i, f in enumerate(at):
            sc.frame_set(f)
            render(sc, os.path.join(out, f'clip_{n}_{i}.png'))
        print(f'RENDERED clip {name} frames {at}', flush=True)


def views(out, before, after):
    def posed(glb, size):
        common.reset_scene()
        sc, cam = scene(size)
        objs = load(glb)
        for o in objs:
            if o.animation_data and o.animation_data.action:
                sc.frame_set(int(o.animation_data.action.frame_range[0]))
        bpy.context.view_layer.update()
        return sc, cam, objs
    box = []
    for glb in (before, after):   # one framing for both, so a change of size shows
        _, _, objs = posed(glb, VIEW_SIZE)
        box.append(bounds(objs))
    lo = Vector(map(min, box[0][0], box[1][0]))
    hi = Vector(map(max, box[0][1], box[1][1]))
    for label, glb in (('before', before), ('after', after)):
        sc, cam, _ = posed(glb, VIEW_SIZE)
        for view, yaw in VIEWS:
            aim(cam, lo, hi, yaw)
            render(sc, os.path.join(out, f'{label}_{view}.png'))
        print(f'RENDERED {label}', flush=True)


def main():
    a = common.script_args()
    os.makedirs(a[1], exist_ok=True)
    if a[0] == 'clips':
        clips(a[1], a[2], int(a[3]), a[4:])
    elif a[0] == 'views':
        views(a[1], a[2], a[3])
    else:
        raise SystemExit(f'unknown preview {a[0]}')


if __name__ == '__main__':   # staff.py imports scene() for its sheets
    main()
