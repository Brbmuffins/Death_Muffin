"""clip_strip.py - frame-strip contact sheet of clips (rows) for visual A/B checks.
  blender -b --python tools/blender/clip_strip.py -- out.jpg COLS "label|file.glb|clip" ["label|file.glb|clip" ...]
Each row imports the GLB, poses the armature at COLS evenly spaced times across the clip, renders with Cycles CPU (no GL needed) from a camera that follows the hip (so root motion does not walk the body out of frame)."""
import os, sys, math
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bpy, numpy as np
from mathutils import Vector
from common import script_args, reset_scene

args = script_args()
out, cols = args[0], int(args[1])
rows = [r.split('|') for r in args[2:]]
W, H = 150, 230
tmp = os.path.join(os.path.dirname(out) or '.', '_strip_tmp.png')
sheet = np.zeros((H * len(rows), W * cols, 4), dtype=np.float32)

def find_action(clip):
    for a in bpy.data.actions:
        if a.name == clip or a.name.endswith('|' + clip) or a.name.startswith(clip + '.'):
            return a
    return bpy.data.actions[0] if bpy.data.actions else None

for ri, (label, path, clip) in enumerate(rows):
    reset_scene()
    if path.endswith('.fbx'):
        bpy.ops.import_scene.fbx(filepath=path)
    else:
        bpy.ops.import_scene.gltf(filepath=path)
    arm = next(o for o in bpy.data.objects if o.type == 'ARMATURE')
    act = find_action(clip)
    arm.animation_data_create()
    for t in list(arm.animation_data.nla_tracks):
        arm.animation_data.nla_tracks.remove(t)
    arm.animation_data.action = act
    f0, f1 = act.frame_range
    sc = bpy.context.scene
    sc.render.engine = 'CYCLES'; sc.cycles.device = 'CPU'; sc.cycles.samples = 12; sc.cycles.use_denoising = False
    sun = bpy.data.objects.new('sun', bpy.data.lights.new('sun', 'SUN')); sc.collection.objects.link(sun)
    sun.data.energy = 3.0; sun.rotation_euler = (math.radians(55), 0, math.radians(-30))
    sc.render.film_transparent = False
    sc.world = bpy.data.worlds.new('w'); sc.world.use_nodes = True
    bg = sc.world.node_tree.nodes['Background']; bg.inputs[0].default_value = (0.35, 0.35, 0.4, 1); bg.inputs[1].default_value = 1.0
    sc.render.resolution_x, sc.render.resolution_y = W, H
    sc.render.image_settings.file_format = 'PNG'
    cam = bpy.data.objects.new('cam', bpy.data.cameras.new('cam')); sc.collection.objects.link(cam); sc.camera = cam
    cam.data.type = 'ORTHO'
    hipname = 'Hip' if 'Hip' in arm.pose.bones else arm.pose.bones[0].name
    sc.frame_set(int(f0)); bpy.context.view_layer.update()
    # body height from the bind mesh bounding box in world space
    zs = [(arm.matrix_world @ pb.head).z for pb in arm.pose.bones]
    height = (max(zs) - min(zs)) * 1.12  # bone heads stop short of the crown and soles
    zlo = min(zs) - height * 0.03
    cam.data.ortho_scale = height * 1.3
    cam.rotation_euler = (math.radians(90), 0, math.radians(180 + 25))  # front, slightly turned
    for ci in range(cols):
        fr = f0 + (f1 - f0) * ci / max(cols - 1, 1)
        sc.frame_set(int(round(fr))); bpy.context.view_layer.update()
        hip = (arm.matrix_world @ arm.pose.bones[hipname].head)
        dist = 6.0
        d = Vector((math.sin(math.radians(25)), -math.cos(math.radians(25)) * -1, 0))
        # camera sits in front (-Y side after Blender's Z-up import), looks at hip column
        look = Vector((hip.x, hip.y, zlo + height * 0.5))
        fwd = Vector((0, 1, 0)); fwd.rotate(__import__('mathutils').Euler((0, 0, math.radians(-25))))
        cam.location = look - fwd * dist
        cam.rotation_euler = (math.radians(90), 0, math.radians(-25))
        sc.render.filepath = tmp
        bpy.ops.render.render(write_still=True)
        img = bpy.data.images.load(tmp)
        px = np.array(img.pixels[:], dtype=np.float32).reshape(H, W, 4)
        bpy.data.images.remove(img)
        y0 = (len(rows) - 1 - ri) * H  # image origin is bottom-left
        sheet[y0:y0 + H, ci * W:(ci + 1) * W] = px
        print('ROW', ri, label, 'frame', ci, 'ok')
img = bpy.data.images.new('sheet', W * cols, H * len(rows), alpha=False)
img.pixels = sheet.ravel().tolist()
img.filepath_raw = out
img.file_format = 'JPEG'
sc = bpy.context.scene
sc.render.image_settings.quality = 82
img.save_render(out, scene=sc) if False else img.save()
os.remove(tmp)
print('WROTE', out)
