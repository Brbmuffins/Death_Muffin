"""
common.py - shared helpers for the Death Muffin Blender scripts (run with: blender -b --python <script> -- <args>).

Conventions
  * Clips are sampled at FPS (30) and exported as glTF seconds starting at 0.
  * Import never changes a rig's rest pose: node TRS round-trips exactly through Blender's glTF import/export
    (checked on the skull rat and the biped heroes), so a clip exported from one file can be copied onto the Tripo
    skeleton by joint name, exactly as tools/build-characters.mjs does for Tripo's own clips.
"""
import json
import os
import sys

import bpy
from mathutils import Quaternion, Vector

FPS = 30
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)


def script_args():
    argv = sys.argv
    return argv[argv.index('--') + 1:] if '--' in argv else []


def load_json(path):
    with open(path) as f:
        return json.load(f)


def reset_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.context.scene.render.fps = FPS


def import_glb(path):
    """Import a GLB; returns (armature object, [mesh objects]). Existing actions in the file are removed."""
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=path)
    new = [o for o in bpy.data.objects if o not in before]  # several files may be imported into one scene
    arms = [o for o in new if o.type == 'ARMATURE']
    if not arms:
        raise SystemExit(f'{path}: no armature')
    return arms[0], [o for o in new if o.type == 'MESH']


def clear_actions(arm):
    if arm.animation_data:
        arm.animation_data.action = None
    for a in list(bpy.data.actions):
        bpy.data.actions.remove(a)


def use_quaternions(arm):
    for pb in arm.pose.bones:
        pb.rotation_mode = 'QUATERNION'


def key_clip(arm, name, frames, eps=1e-5):
    """
    frames: list (one per frame, frame i at time i/FPS) of {bone: (loc|None, rot|None)}.
    Bones that never leave the identity basis are not keyed. Returns the action.
    """
    use_quaternions(arm)
    for pb in arm.pose.bones:
        pb.location = Vector((0, 0, 0))
        pb.rotation_quaternion = Quaternion((1, 0, 0, 0))
        pb.scale = Vector((1, 1, 1))
    act = bpy.data.actions.new(name)
    if arm.animation_data is None:
        arm.animation_data_create()
    arm.animation_data.action = act
    bones = set()
    for fr in frames:
        bones.update(fr.keys())
    moving = set()
    ident = Quaternion((1, 0, 0, 0))
    for b in bones:
        for fr in frames:
            loc, rot = fr.get(b, (None, None))
            if (loc is not None and loc.length > eps) or (rot is not None and rot.rotation_difference(ident).angle > eps):
                moving.add(b)
                break
    for i, fr in enumerate(frames):
        f = i
        for b in moving:
            pb = arm.pose.bones[b]
            loc, rot = fr.get(b, (None, None))
            pb.location = loc if loc is not None else Vector((0, 0, 0))
            q = rot if rot is not None else Quaternion((1, 0, 0, 0))
            pb.rotation_quaternion = q
            pb.keyframe_insert('location', frame=f)
            pb.keyframe_insert('rotation_quaternion', frame=f)
    # Same hemisphere across keys so interpolation takes the short way round.
    fix_hemispheres(act)
    act.frame_start = 0
    act.frame_end = len(frames) - 1
    for fc in act.fcurves:
        for kp in fc.keyframe_points:
            kp.interpolation = 'LINEAR'
    return act


def fix_hemispheres(act):
    groups = {}
    for fc in act.fcurves:
        if fc.data_path.endswith('rotation_quaternion'):
            groups.setdefault(fc.data_path, {})[fc.array_index] = fc
    for _, comp in groups.items():
        if len(comp) != 4:
            continue
        n = len(comp[0].keyframe_points)
        prev = None
        for i in range(n):
            q = [comp[k].keyframe_points[i].co[1] for k in range(4)]
            if prev is not None and sum(a * b for a, b in zip(q, prev)) < 0:
                q = [-v for v in q]
                for k in range(4):
                    comp[k].keyframe_points[i].co[1] = q[k]
            prev = q


def export_glb(path, arm, action, skins=True):
    """Export armature + meshes + the given action as a GLB."""
    arm.animation_data.action = action
    bpy.context.scene.frame_start = int(action.frame_range[0])
    bpy.context.scene.frame_end = int(action.frame_range[1])
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    kw = dict(
        filepath=path, export_format='GLB', export_yup=True, export_animations=True,
        export_animation_mode='ACTIVE_ACTIONS', export_force_sampling=True, export_frame_range=True,
        export_optimize_animation_size=False, export_skins=skins, export_def_bones=False,
        export_apply=False, export_lights=False, export_cameras=False, export_reset_pose_bones=False,
    )
    try:
        bpy.ops.export_scene.gltf(**kw)
    except TypeError:
        for k in ('export_animation_mode', 'export_reset_pose_bones'):
            kw.pop(k, None)
        bpy.ops.export_scene.gltf(**kw)


def export_static(path):
    """Export the scene with no animation (rig-fixed base mesh)."""
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    bpy.ops.export_scene.gltf(filepath=path, export_format='GLB', export_yup=True, export_animations=False, export_skins=True, export_def_bones=False, export_apply=False)
