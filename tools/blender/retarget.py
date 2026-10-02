"""
retarget.py - put a clip from a CC0 library rig onto a Tripo biped:
  blender -b --python retarget.py -- <source.glb|fbx> <target_rig.glb> <clip-map.json> <out_dir> [--only name,name]

The clip map (tools/blender/maps/*.json) says which source bone drives which target bone and how:
  "delta"  the bone's rotation away from its own rest pose is carried over (in armature space, turned to the target's
           forward axis). Right for spine, head, hands, feet: whatever the rest pose, the same *change* happens.
  "aim"    as delta, then the bone is swung so that it points exactly where the source bone points (toward `aim`'s
           child). Right for upper arms and legs: the source rig stands in a T-pose with level arms, the Tripo rig has
           arms a little below level, and a pure delta would drive the arms into the torso. Twist stays from delta.
Hip translation is carried over scaled by the ratio of the two rigs' hip heights; "inPlace" drops its ground-plane part.
Unmapped target bones (twist bones, Pelvis, ...) keep their rest pose. Nothing about the target's rest pose changes, so
the clip can be copied onto the Tripo skeleton by joint name exactly like Tripo's own clips.
"""
import json
import math
import os
import sys

import bpy
from mathutils import Matrix, Quaternion, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common  # noqa: E402
from kin import Rig, T, arc  # noqa: E402

UP = Vector((0, 0, 1))


def horizontal(v):
    return Vector((v.x, v.y, 0)).normalized()


def yaw_between(a, b):
    a, b = horizontal(a), horizontal(b)
    return Matrix.Rotation(math.atan2(a.cross(b).z, a.dot(b)), 3, 'Z')


def import_any(path):
    if path.lower().endswith('.fbx'):
        before = set(bpy.data.objects)
        bpy.ops.import_scene.fbx(filepath=path)
        new = [o for o in bpy.data.objects if o not in before]
        return [o for o in new if o.type == 'ARMATURE'][0], [o for o in new if o.type == 'MESH']
    return common.import_glb(path)


def main():
    a = common.script_args()
    src_path, tgt_path, map_path, out_dir = a[0], a[1], a[2], a[3]
    only = a[a.index('--only') + 1].split(',') if '--only' in a else None
    cmap = common.load_json(map_path)
    common.reset_scene()

    src, _ = import_any(src_path)
    src_actions = {act.name: act for act in bpy.data.actions}
    for o in list(bpy.data.objects):  # the library's mesh is not needed
        if o.type == 'MESH':
            bpy.data.objects.remove(o)
    tgt, _ = common.import_glb(tgt_path)
    # glTF import of the target brings its own actions: remove those only (the source ones stay).
    for act in list(bpy.data.actions):
        if act.name not in src_actions:
            bpy.data.actions.remove(act)
    if tgt.animation_data:
        tgt.animation_data.action = None
    common.use_quaternions(tgt)
    for o in (src, tgt):
        m3 = o.matrix_world.to_3x3()
        if max(abs(m3[i][j] - (1 if i == j else 0)) for i in range(3) for j in range(3)) > 1e-3:
            raise SystemExit(f'{o.name}: armature object has a rotation/scale; apply it first (this script works in armature space)')

    srig, trig = Rig(src), Rig(tgt)
    F = yaw_between(Vector(cmap['source_forward']), Vector(cmap['target_forward']))
    bones = cmap['bones']
    for b in bones:
        for k in ('src', 'dst'):
            if (b[k] not in (srig.rest if k == 'src' else trig.rest)):
                raise SystemExit(f"map bone {b[k]!r} ({k}) not found in the {'source' if k == 'src' else 'target'} rig")
    by_dst = {b['dst']: b for b in bones}
    hip = cmap['hip']
    s_hip, t_hip = hip['src'], hip['dst']
    scale = cmap.get('scale')
    if scale in (None, 'auto'):
        scale = (trig.head[t_hip].z - min(h.z for h in (trig.head[n] for n in cmap.get('ground_bones', []))) if cmap.get('ground_bones') else trig.head[t_hip].z) / \
                (srig.head[s_hip].z - min(h.z for h in (srig.head[n] for n in cmap.get('source_ground_bones', []))) if cmap.get('source_ground_bones') else srig.head[s_hip].z)
    print('RETARGET hip scale', round(scale, 3))

    results = []
    scene = bpy.context.scene

    def pose_frames(act, spec):
        """Target bases for every frame of one source action (optionally trimmed / retimed)."""
        src.animation_data_create()
        src.animation_data.action = act
        f0, f1 = act.frame_range
        trim = spec.get('trim', [0, (f1 - f0) / common.FPS])
        t0, t1, speed = trim[0], trim[1], spec.get('speed', 1.0)
        n = max(2, int(round((t1 - t0) / speed * common.FPS)))
        out = []
        for i in range(n + 1):
            t = t0 + (t1 - t0) * i / n
            fr = f0 + t * common.FPS
            scene.frame_set(int(math.floor(fr)), subframe=fr % 1.0)
            bpy.context.view_layer.update()
            Ps = {nm: src.pose.bones[nm].matrix.copy() for nm in srig.order}
            P, basis = {}, {}
            for nm in trig.order:
                par = trig.parent[nm]
                inh = trig.inherited(nm, P.get(par) if par else None)
                m = by_dst.get(nm)
                if nm == t_hip:
                    disp = Ps[s_hip].translation - srig.head[s_hip]
                    if spec.get('inPlace', True):
                        disp = Vector((0, 0, disp.z))
                    pos = trig.head[t_hip] + (F @ disp) * scale
                elif m is None:
                    P[nm] = inh
                    continue
                else:
                    pos = inh.translation
                sp = Ps[m['src']].to_3x3()
                delta = sp @ srig.rest[m['src']].to_3x3().inverted()
                rot = (F @ delta @ F.inverted()) @ trig.rest[nm].to_3x3()
                if m.get('mode') == 'aim':
                    am = m['aim']
                    d_src = (F @ (Ps[am['src']].translation - Ps[m['src']].translation)).normalized()
                    d_rest = trig.head[am['dst']] - trig.head[nm]
                    d_cur = (rot @ (trig.rest[nm].to_3x3().inverted() @ d_rest)).normalized()
                    rot = arc(d_cur, d_src).to_matrix() @ rot
                Pd = T(pos) @ rot.to_4x4()
                loc, q = trig.basis_from_pose(nm, P.get(par) if par else None, Pd)
                basis[nm] = (loc, q)
                P[nm] = Pd
            out.append(basis)
        return out

    for clip_name, spec in cmap['clips'].items():
        if only and spec['name'] not in only:
            continue
        # "sequence": several source actions played back to back (e.g. Spell_Simple_Enter + _Shoot + _Exit)
        names = spec.get('sequence', [clip_name])
        frames = []
        for nm in names:
            act = src_actions.get(nm)
            if act is None:
                raise SystemExit(f'source has no action {nm!r}; has: {sorted(src_actions)}')
            part = pose_frames(act, spec)
            frames.extend(part if not frames else part[1:])
        n = len(frames) - 1
        if spec.get('loop'):
            for nm in frames[0]:
                if nm in frames[-1]:
                    frames[-1][nm] = frames[0][nm]
        act2 = common.key_clip(tgt, spec['name'], frames)
        out = os.path.join(out_dir, f"anim_{spec['name']}.glb")
        common.export_glb(out, tgt, act2)
        bpy.data.actions.remove(act2)
        tgt.animation_data.action = None
        results.append({'clip': spec['name'], 'source': '+'.join(names), 'seconds': round(n / common.FPS, 3), 'file': out})
        print('RETARGET', spec['name'], '<-', '+'.join(names), f'{n / common.FPS:.2f}s')
    print('RESULT ' + json.dumps(results))


main()
