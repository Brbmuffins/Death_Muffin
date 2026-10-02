"""
cleanup.py - repair a clip in a GLB: blender -b --python cleanup.py -- <in.glb> <clip> <out.glb> [flags]

  --loop           make the last pose equal the first (the difference is spread over the last --window of the clip)
  --drift          remove residual root drift: the net horizontal and vertical travel of the root bone between the
                   first and last frame is subtracted as a ramp, so a walk does not creep and then snap back on loop
  --foot-lock      plant the feet. Contacts are found from ankle height and speed; during a contact the ankle is
                   forced onto a straight line at one constant speed (the clip's own median contact speed), at floor
                   height, with a short blend in and out. Legs are re-solved with IK and baked back to plain FK keys.
  --window 0.25    fraction of the clip used to close the loop
  --root NAME      the bone that carries root motion (default Hip, tripo::Root or hips)
  --legs "A,B,C;D,E,F"   leg chains "thigh,calf,foot" (default: detected for the Tripo biped / the Quaternius rig)
  --recipe file    take the legs from a procedural recipe (quadrupeds)
  --forward x,y    ground-plane forward of the body in armature space (default: from the left foot to its toe)
  --name n         name of the output clip

Prints `CLEANUP {...}` with the numbers it measured (seam gap before/after, drift removed, contact speed spread).
"""
import json
import math
import os
import sys

import bpy
from mathutils import Matrix, Quaternion, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common  # noqa: E402
from kin import Leg, Rig, T, smoothstep  # noqa: E402

UP = Vector((0, 0, 1))
DEFAULT_LEGS = [
    [['L_Thigh', 'L_Calf'], 'L_Foot'], [['R_Thigh', 'R_Calf'], 'R_Foot'],           # Tripo biped
    [['thigh_l', 'calf_l'], 'foot_l'], [['thigh_r', 'calf_r'], 'foot_r'],            # Quaternius UAL
]


def flag(a, name, default=None):
    return a[a.index(name) + 1] if name in a else default


def sample(arm, rig, act, n, t0=0.0):
    """Per-frame bases of every bone that has animation, read straight from the F-curves."""
    arm.animation_data_create()
    arm.animation_data.action = act
    frames = []
    f0 = act.frame_range[0]
    for i in range(n + 1):
        bpy.context.scene.frame_set(int(f0) + i)
        bpy.context.view_layer.update()
        fr = {}
        for nm in rig.order:
            pb = arm.pose.bones[nm]
            fr[nm] = (pb.location.copy(), pb.rotation_quaternion.copy())
        frames.append(fr)
    return frames


def fk_all(rig, frames):
    return [rig.fk(fr) for fr in frames]


def quat_diff_angle(a, b):
    return a.rotation_difference(b).angle


def seam_gap(rig, frames):
    """Largest bone-position jump (metres) between the last and first frame."""
    Pa, Pb = rig.fk(frames[0]), rig.fk(frames[-1])
    return max((Pa[n].translation - Pb[n].translation).length for n in rig.order)


def remove_drift(rig, frames, root):
    P = fk_all(rig, frames)
    n = len(frames) - 1
    d = P[-1][root].translation - P[0][root].translation
    for i, fr in enumerate(frames):
        s = i / n
        off = -d * s
        par = rig.parent[root]
        Pd = T(off) @ P[i][root]
        loc, rot = rig.basis_from_pose(root, P[i][par] if par else None, Pd)
        fr[root] = (loc, rot)
    return d


def close_loop(rig, frames, window):
    n = len(frames) - 1
    w = max(2, int(round(window * n)))
    first, last = frames[0], frames[-1]
    for nm in rig.order:
        l0, q0 = first[nm]
        l1, q1 = last[nm]
        dq = q0 @ q1.inverted()
        dl = l0 - l1
        for i in range(n - w, n + 1):
            s = smoothstep((i - (n - w)) / w)
            loc, rot = frames[i][nm]
            frames[i][nm] = (loc + dl * s, Quaternion((1, 0, 0, 0)).slerp(dq, s) @ rot)


def detect_legs(rig, a):
    if flag(a, '--legs'):
        out = []
        for part in flag(a, '--legs').split(';'):
            t, c, f = part.split(',')
            out.append(([t, c], f))
        return out
    if flag(a, '--recipe'):
        rec = common.load_json(flag(a, '--recipe'))
        return [(v['chain'], v['paw']) for v in rec['legs'].values()]
    return [(c, p) for c, p in DEFAULT_LEGS if all(x in rig.rest for x in c + [p])]


def contact_segments(flags, n):
    """Contiguous runs of True in a cyclic list of n flags (indices 0..n-1)."""
    if all(flags[:n]):
        return [list(range(n))]
    start = next(j for j in range(n) if not flags[j])
    segs, cur = [], None
    for step in range(1, n + 1):
        idx = (start + step) % n
        if flags[idx]:
            cur = (cur or []) + [idx]
        elif cur:
            segs.append(cur)
            cur = None
    if cur:
        segs.append(cur)
    return segs


def foot_lock(rig, frames, legs, forward):
    """
    Plant the feet of an in-place cyclic clip. For every foot: frames where the ankle is low and moving at roughly the
    clip's contact speed are contacts; inside a contact the ankle is placed on a straight line going backwards at one
    speed (the median contact speed of the whole clip), at the clip's floor height, blended in and out over three frames.
    The legs are then re-solved with IK so the keys stay plain FK. Returns (frames, info).
    """
    n = len(frames) - 1
    P = fk_all(rig, frames)
    legobjs = [Leg(rig, c, p) for c, p in legs]
    tracks = [[P[i][lg.paw].translation.copy() for i in range(n + 1)] for lg in legobjs]
    contacts, speeds = [], []
    for pts in tracks:
        z = [p.z for p in pts]
        zmin, zmax = min(z), max(z)
        low = [zz <= zmin + 0.22 * (zmax - zmin) for zz in z]
        u = [p.dot(forward) for p in pts]
        v = [abs(u[(i + 1) % n] - u[(i - 1) % n]) * common.FPS / 2 for i in range(n)]
        lowv = sorted(v[i] for i in range(n) if low[i])
        med = lowv[len(lowv) // 2] if lowv else 0.0
        c = [bool(low[i] and (med == 0 or 0.4 * med <= v[i] <= 1.8 * med)) for i in range(n)]
        c.append(c[0])
        contacts.append(c)
        speeds.extend(v[i] for i in range(n) if c[i])
    speeds.sort()
    vc = speeds[len(speeds) // 2] if speeds else 0.0
    floor = sorted(tracks[k][i].z for k in range(len(tracks)) for i in range(n) if contacts[k][i])
    gz = floor[int(len(floor) * 0.3)] if floor else min(p.z for t in tracks for p in t)
    out = [dict(fr) for fr in frames]
    report = []
    for k, lg in enumerate(legobjs):
        target, weight = [None] * (n + 1), [0.0] * (n + 1)
        segs = [s for s in contact_segments(contacts[k], n) if len(s) >= 3]
        if len(segs) > 2:
            # A cycle with several separate touch-downs per foot is not a gait this heuristic understands (Tripo's quadruped
            # presets shuffle like that); locking it would invent contacts. Leave the leg alone and say so.
            print('CLEANUP warning: leg', lg.chain[0], 'has', len(segs), 'contact segments per cycle, skipped (use a procedural gait)')
            report.append({'leg': lg.chain[0], 'contactSegments': len(segs), 'skipped': True})
            continue
        for seg in segs:
            m = len(seg)
            us = [tracks[k][i].dot(forward) for i in seg]
            um, tm = sum(us) / m, (m - 1) / 2
            mid = tracks[k][seg[m // 2]]
            lat = Vector((mid.x, mid.y, 0)) - forward * mid.dot(Vector((forward.x, forward.y, 0)))
            for q, i in enumerate(seg):
                p = lat + forward * (um - vc / common.FPS * (q - tm))
                p.z = gz
                target[i] = p
                weight[i] = smoothstep(min(1.0, (q + 1) / 3.0, (m - q) / 3.0))
        for i in range(n):
            if target[i] is None:
                continue
            ank = tracks[k][i].lerp(target[i], weight[i])
            basis = dict(out[i])
            Pi = rig.fk(out[i])
            lg.solve(Pi, basis, ank, paw_rot_world=Pi[lg.paw].to_3x3())
            for nm in lg.chain + [lg.paw]:
                out[i][nm] = basis[nm]
        report.append({'leg': lg.chain[0], 'contactSegments': len(segs)})
    for lg in legobjs:  # the last frame is the first again
        for nm in lg.chain + [lg.paw]:
            out[n][nm] = out[0][nm]
    return out, {'contactSpeed': round(vc, 4), 'floorZ': round(gz, 4), 'legs': report}


def main():
    a = common.script_args()
    src, clip, dst = a[0], a[1], a[2]
    common.reset_scene()
    arm, _ = common.import_glb(src)
    act = next((x for x in bpy.data.actions if x.name == clip), None) or (bpy.data.actions[0] if bpy.data.actions else None)
    if act is None:
        raise SystemExit(f'{src}: no animation')
    common.use_quaternions(arm)
    rig = Rig(arm)
    frames_count = int(round(act.frame_range[1] - act.frame_range[0]))
    frames = sample(arm, rig, act, frames_count)
    root = flag(a, '--root') or next((r for r in ('Hip', 'tripo::Root', 'pelvis', 'hips') if r in rig.rest), rig.order[0])
    rep = {'clip': clip, 'frames': frames_count + 1, 'seamBefore': round(seam_gap(rig, frames), 4)}
    if '--drift' in a:
        d = remove_drift(rig, frames, root)
        rep['driftRemoved'] = [round(d.x, 4), round(d.y, 4), round(d.z, 4)]
    if '--loop' in a:
        close_loop(rig, frames, float(flag(a, '--window', 0.25)))
    if '--foot-lock' in a:
        legs = detect_legs(rig, a)
        if not legs:
            raise SystemExit('no legs found; pass --legs or --recipe')
        fw = flag(a, '--forward')
        if fw:
            x, y = [float(v) for v in fw.split(',')]
            forward = Vector((x, y, 0)).normalized()
        else:
            P0 = rig.fk(frames[0])
            lg0 = Leg(rig, *legs[0])
            toe = [c for c in rig.children[lg0.paw]]
            tip = P0[toe[0]].translation if toe else P0[lg0.paw].translation + Vector((0, 0, 0))
            forward = Vector((tip.x - P0[lg0.paw].translation.x, tip.y - P0[lg0.paw].translation.y, 0)).normalized()
        frames, info = foot_lock(rig, frames, legs, forward)
        if '--loop' in a:
            close_loop(rig, frames, 0.1)  # the lock edits a few frames near the seam
        rep['footLock'] = info
        rep['forward'] = [round(forward.x, 3), round(forward.y, 3)]
    rep['seamAfter'] = round(seam_gap(rig, frames), 4)
    new_act = common.key_clip(arm, flag(a, '--name', clip), frames)
    common.export_glb(dst, arm, new_act)
    print('CLEANUP ' + json.dumps(rep))
    print('RESULT ' + json.dumps(rep))


main()
