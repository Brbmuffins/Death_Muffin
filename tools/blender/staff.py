"""
staff.py - staff-aware re-bake of a hero's right arm (docs/BLENDER-PIPELINE.md "staff").

  blender -b --python staff.py -- <character.glb> <recipe.json> <out_dir> <height_m> <length_m> <grip_t> [clip ...]
                                  [--sheets <staff_prop.glb>] [--sheet-clips clip,clip]

Reads the hero the client loads (client/assets/slice/models/<slug>/character.glb), prepares the clips as
DmCreature.prep_clips does for a hero, and for every recipe clip re-solves R_Upperarm / R_Forearm / R_Hand so the staff
held the way DmCreature.attach_held holds it sits where the recipe says: the grip point (metres from the shoulder) and the
staff's long axis (tilt and azimuth). Every other channel is the clip's own, untouched. Writes anim_<clip>_staff.glb.

The grip is the game's: the prop's origin on the palm centre (the mean of the vertices skinned > 0.5 to the hand, in the
hand's bind space: DmCreature.palm_of), its +Y along the hand's knuckle line leaned `lean` degrees toward the fingers. The
original clips are read with the game's current lean (recipe gameLean); the re-baked ones are made for recipe lean, a fist
grip, because with the current one (the staff laid back along the forearm) a raised staff needs a wrist folded past 150 deg.

Solver: with a straight wrist the hand's +Y is the forearm direction, so a staff axis fixes the forearm on a cone around it
(angle 90 - lean). Of the directions on that cone the upper arm can reach, keep the one nearest the previous frame's; the
wrist may bend within recipe wrist (degrees of effective lean) when the relaxed grip cannot reach, and 70 % of the hand's
twist about the forearm goes to the forearm (pronation lives there). A target out of reach lands as close as the arm allows;
the miss is reported per clip.

--sheets renders the original clip (game grip) above the re-bake at the recipe's sample times, with the staff model in
hand, into <out_dir>/sheets/sheet_<clip>.png (every re-baked clip, or those --sheet-clips names), with the job previews'
render (preview.scene); a sheet that fails is reported as sheetError and the clips are still written.
"""
import json
import math
import os
import struct
import sys

import bpy
import numpy as np
from mathutils import Matrix, Quaternion, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common  # noqa: E402
import preview  # noqa: E402

G2B = Matrix(((1, 0, 0, 0), (0, 0, -1, 0), (0, 1, 0, 0), (0, 0, 0, 1)))  # glTF Y-up -> Blender Z-up
UP, FWD, RIGHT = Vector((0, 0, 1)), Vector((1, 0, 0)), Vector((0, -1, 0))  # the hero faces +X, right hand on -Y
ARM = ('R_Upperarm', 'R_Forearm', 'R_Hand')
COMBAT = ('slam', 'sweep', 'flick', 'channel', 'summon')  # DmCreature.COMBAT


# ----------------------------------------------------------------------------------------------------------- glTF data

def read_glb(path):
    data = open(path, 'rb').read()
    jl, _ = struct.unpack_from('<II', data, 12)
    js = json.loads(data[20:20 + jl])
    off = 20 + jl
    bl, _ = struct.unpack_from('<II', data, off)
    return js, data[off + 8:off + 8 + bl]


def accessor(js, bin_, idx):
    """Accessor as float rows; normalized integers (KHR_mesh_quantization positions, uint8 weights) are scaled like the spec."""
    a = js['accessors'][idx]
    bv = js['bufferViews'][a['bufferView']]
    dt = {5126: np.float32, 5125: np.uint32, 5123: np.uint16, 5122: np.int16, 5121: np.uint8, 5120: np.int8}[a['componentType']]
    n = {'SCALAR': 1, 'VEC2': 2, 'VEC3': 3, 'VEC4': 4, 'MAT4': 16}[a['type']]
    start = bv.get('byteOffset', 0) + a.get('byteOffset', 0)
    size = np.dtype(dt).itemsize
    stride = bv.get('byteStride') or n * size
    raw = np.frombuffer(bin_, dtype=np.uint8, count=a['count'] * stride, offset=start).reshape(a['count'], stride)
    out = np.frombuffer(raw[:, :n * size].tobytes(), dtype=dt).reshape(a['count'], n).astype(np.float64)
    if a.get('normalized'):
        out = {5121: out / 255.0, 5123: out / 65535.0, 5120: np.maximum(out / 127.0, -1.0), 5122: np.maximum(out / 32767.0, -1.0)}.get(a['componentType'], out)
    return out


def node_world(js, name):
    """The node's rest transform in glTF scene space (TRS chain to the root)."""
    parent = {c: i for i, n in enumerate(js['nodes']) for c in n.get('children', [])}
    i = next(k for k, n in enumerate(js['nodes']) if n.get('name') == name)
    m = Matrix.Identity(4)
    while i is not None:
        n = js['nodes'][i]
        r = n.get('rotation', [0, 0, 0, 1])
        s = n.get('scale', [1, 1, 1])
        m = (Matrix.Translation(n.get('translation', [0, 0, 0])) @ Quaternion((r[3], r[0], r[1], r[2])).to_matrix().to_4x4()
             @ Matrix.Diagonal((s[0], s[1], s[2], 1))) @ m
        i = parent.get(i)
    return m


def palm_of(js, bin_, bone):
    """DmCreature.palm_of: mean bind-space position (bone-local) of the vertices weighted > 0.5 to `bone`."""
    skin = js['skins'][0]
    joints = [js['nodes'][j]['name'] for j in skin['joints']]
    bi = joints.index(bone)
    ibm = Matrix(accessor(js, bin_, skin['inverseBindMatrices'])[bi].reshape(4, 4).T.tolist())
    acc = np.zeros(3); n = 0
    for mesh in js['meshes']:
        for p in mesh['primitives']:
            at = p['attributes']
            if 'JOINTS_0' not in at:
                continue
            pos = accessor(js, bin_, at['POSITION'])
            w = (accessor(js, bin_, at['WEIGHTS_0']) * (accessor(js, bin_, at['JOINTS_0']) == bi)).sum(axis=1)
            sel = pos[w > 0.5]
            acc += sel.sum(axis=0); n += len(sel)
    if n <= 20:
        raise SystemExit(f'{bone}: only {n} vertices weighted to it')
    return ibm @ Vector(acc / n)


def hip_tracks(js, bin_):
    hip = next(i for i, n in enumerate(js['nodes']) if n.get('name') == 'Hip')
    out = {}
    for an in js.get('animations', []):
        for ch in an['channels']:
            if ch['target'].get('node') == hip and ch['target']['path'] == 'translation':
                out[an['name']] = accessor(js, bin_, an['samplers'][ch['sampler']]['output'])
    return out


# ----------------------------------------------------------------------------------------------------------- actions

def fcurves(act):
    """The action's F-curves: Blender 4.4+ slotted actions (layer 0, strip 0, slot 0), else the legacy accessor."""
    try:
        return act.layers[0].strips[0].channelbag(act.slots[0]).fcurves
    except (AttributeError, IndexError):
        return act.fcurves


def assign(arm, act):
    for pb in arm.pose.bones:  # a channel the clip does not key sits at rest, as in Godot, not at the last clip's value
        pb.location = (0, 0, 0); pb.rotation_quaternion = (1, 0, 0, 0); pb.scale = (1, 1, 1)
    arm.animation_data.action = act
    if hasattr(act, 'slots') and len(act.slots) and hasattr(arm.animation_data, 'action_slot'):
        arm.animation_data.action_slot = act.slots[0]
    sc = bpy.context.scene
    sc.frame_start, sc.frame_end = int(round(act.frame_range[0])), int(round(act.frame_range[1]))


def prep_clips(arm, js, bin_):
    """DmCreature.prep_clips for a hero (in_place): Root tracks dropped; combat clips' Hip pinned to idle's first Hip
    position plus their own vertical; other clips (not death) lose the Hip position track. Returns the max error of the
    fitted glTF -> Blender Hip location map (the importer's map is affine; fitted from every clip's keys)."""
    gl = hip_tracks(js, bin_)
    path = 'pose.bones["Hip"].location'
    X, Y = [], []
    for name, vals in gl.items():
        act = bpy.data.actions.get(name)
        fcs = sorted([f for f in fcurves(act) if f.data_path == path], key=lambda f: f.array_index) if act else []
        if len(fcs) != 3 or len(fcs[0].keyframe_points) != len(vals):
            continue
        for k, v in enumerate(vals):
            X.append(list(v) + [1.0]); Y.append([fcs[i].keyframe_points[k].co[1] for i in range(3)])
    X, Y = np.array(X), np.array(Y)
    A = np.linalg.lstsq(X, Y, rcond=None)[0]
    err = float(np.abs(X @ A - Y).max())
    anchor = gl['idle'][0]
    for name in list(gl.keys()) + [a.name for a in bpy.data.actions if a.name not in gl]:
        act = bpy.data.actions.get(name)
        if act is None or name.endswith('__raw'):
            continue
        fc = fcurves(act)
        for f in [f for f in fc if f.data_path.startswith('pose.bones["Root"]')]:
            fc.remove(f)
        if name.rstrip('0123456789') == 'death':
            continue
        fcs = sorted([f for f in fc if f.data_path == path], key=lambda f: f.array_index)
        if not fcs:
            continue
        if name in COMBAT and name in gl and len(fcs[0].keyframe_points) == len(gl[name]):
            for k, v in enumerate(gl[name]):
                t = np.array([anchor[0], anchor[1], anchor[2] + v[2], 1.0]) @ A
                for i in range(3):
                    kp = fcs[i].keyframe_points[k]
                    kp.co[1] = kp.handle_left[1] = kp.handle_right[1] = t[i]
            for f in fcs:
                f.update()
        elif name not in COMBAT:
            for f in fcs:
                fc.remove(f)
    return err


# ----------------------------------------------------------------------------------------------------------- the hero

class Hero:
    def __init__(self, glb, height, recipe):
        self.recipe = recipe
        self.js, self.bin = read_glb(glb)
        self.arm, meshes = common.import_glb(glb)
        # skinned meshes only: the importer also brings an Icosphere it uses as the bones' display shape
        self.meshes = [o for o in meshes if any(m.type == 'ARMATURE' for m in o.modifiers)]
        common.use_quaternions(self.arm)
        for a in [a for a in bpy.data.actions if a.name.endswith('_staff')]:  # an earlier re-bake: made again from its clip
            bpy.data.actions.remove(a)
        for a in bpy.data.actions:  # keep the clips as shipped: the re-bakes copy every channel but the arm from these
            raw = a.copy(); raw.name = a.name + '__raw'; raw.use_fake_user = True
        self.prep_err = prep_clips(self.arm, self.js, self.bin)
        self.bone = recipe.get('hand', 'R_Hand')
        # game scale: the rest pose normalised to the hero's height (heroModels.height)
        self.arm.data.pose_position = 'REST'
        bpy.context.view_layer.update()
        dg = bpy.context.evaluated_depsgraph_get()
        zs = []
        for o in self.meshes:
            me = o.evaluated_get(dg).to_mesh()
            zs += [(o.matrix_world @ v.co).z for v in me.vertices]
            o.evaluated_get(dg).to_mesh_clear()
        self.arm.data.pose_position = 'POSE'
        self.scale = height / (max(zs) - min(zs))
        self.arm.scale = (self.scale,) * 3
        bpy.context.view_layer.update()
        # the hand's Godot (glTF node) frame relative to Blender's bone frame
        self.C = self.arm.data.bones[self.bone].matrix_local.inverted() @ G2B @ node_world(self.js, self.bone)
        self.palm = palm_of(self.js, self.bin, self.bone)
        self.fs = self.frame().to_scale().x
        self.use_lean(recipe['gameLean'])

    def frame(self):
        """The hand's frame as Godot's BoneAttachment3D sees it (world)."""
        pb = self.arm.pose.bones[self.bone]
        return self.arm.matrix_world @ pb.matrix @ self.C

    def use_lean(self, lean):
        """DmCreature._seat_held with {lean, roll 0, hold 0}: bone-local transform of the prop (origin = grip)."""
        self.lean = math.radians(lean)
        up = Vector((math.cos(self.lean), math.sin(self.lean), 0)).normalized()
        self.seat = Matrix.Translation(self.palm) @ Vector((0, 1, 0)).rotation_difference(up).to_matrix().to_4x4()

    def grip(self):
        g = self.frame() @ self.seat
        return g.to_translation(), (g.to_3x3() @ Vector((0, 1, 0))).normalized()

    def play(self, name):
        assign(self.arm, bpy.data.actions[name])

    def sample(self, name):
        self.play(name)
        sc = bpy.context.scene; W = self.arm.matrix_world; pbs = self.arm.pose.bones
        rows = []
        for f in range(sc.frame_start, sc.frame_end + 1):
            sc.frame_set(f)
            g, a = self.grip()
            rows.append({'f': f, 'grip': g, 'axis': a, 'sh': W @ pbs[ARM[0]].head})
        n = max(len(rows) - 1, 1)
        for i, r in enumerate(rows):
            r['u'] = i / n
        return rows


# ----------------------------------------------------------------------------------------------------------- targets

def hero_vec(v):
    """[forward, right, up] -> world."""
    return FWD * v[0] + RIGHT * v[1] + UP * v[2]


def dir_of(tilt, az):
    t, a = math.radians(tilt), math.radians(az)
    return (UP * math.cos(t) + (FWD * math.cos(a) + RIGHT * math.sin(a)) * math.sin(t)).normalized()


def smooth(t):
    t = min(max(t, 0.0), 1.0)
    return t * t * (3 - 2 * t)


def carry(spec, rest):
    """idle / walk / run: the hand at `rest` from the shoulder, plus the original hand's fore-aft swing scaled by `swing`;
    the staff upright, leaning forward by `tilt` plus `tiltSwing` as the hand comes forward, `out` degrees to the side."""
    base = hero_vec(rest) + hero_vec(spec.get('offset', [0, 0, 0]))

    def fn(r, rows):
        mean = sum(((x['grip'] - x['sh']).x for x in rows), 0.0) / len(rows)
        dx = (r['grip'] - r['sh']).x - mean
        sw = max(-1.0, min(1.0, dx / 0.25))
        g = r['sh'] + base + Vector((dx * spec['swing'], 0, abs(dx) * spec['swing'] * 0.25))
        tilt = math.radians(spec['tilt'] + spec.get('tiltSwing', 0) * sw)
        o = math.radians(spec.get('out', 0))
        return g, (UP * math.cos(tilt) + FWD * math.sin(tilt) + RIGHT * math.sin(o)).normalized()
    return fn


def gesture(spec, rest, length, grip_t):
    """Keys [u, pos, [tilt, az]]: pos [forward, right, up] from the shoulder, "rest", or {"plant": [forward, right]} (the
    staff's foot on the floor there, measured from the shoulder at that key's time, and fixed in the world)."""
    keys = spec['keys']

    def world(key, r, rows):
        u, pos, (tl, az) = key
        ax = dir_of(tl, az)
        if isinstance(pos, dict):
            sh = min(rows, key=lambda x: abs(x['u'] - u))['sh']
            fx, rt = pos['plant']
            foot = sh + hero_vec([fx, rt, 0]); foot.z = 0.004
            return foot + ax * (length * grip_t), ax
        return r['sh'] + hero_vec(rest if pos == 'rest' else pos), ax

    def fn(r, rows):
        u = r['u']
        if u <= keys[0][0]:
            return world(keys[0], r, rows)
        for k0, k1 in zip(keys, keys[1:]):
            if u <= k1[0]:
                s = smooth((u - k0[0]) / max(k1[0] - k0[0], 1e-6))
                (p0, a0), (p1, a1) = world(k0, r, rows), world(k1, r, rows)
                return p0.lerp(p1, s), a0.lerp(a1, s).normalized()
        return world(keys[-1], r, rows)
    return fn


# ----------------------------------------------------------------------------------------------------------- solver

def _set(pb, m):
    pb.matrix = m
    bpy.context.view_layer.update()


def _turn(pb, pivot, q):
    _set(pb, Matrix.Translation(pivot) @ q.to_matrix().to_4x4() @ Matrix.Translation(-pivot) @ pb.matrix)


def _twist(q, axis):
    p = Vector((q.x, q.y, q.z)).project(axis)
    tw = Quaternion((q.w, p.x, p.y, p.z)).normalized()
    ang = tw.angle if tw.axis.dot(axis) >= 0 else -tw.angle
    return (ang + math.pi) % (2 * math.pi) - math.pi


def hand_rot(a, y, lean):
    """Hand rotation (Godot frame) whose +Y is `y` and that holds the staff along `a` at `lean`."""
    x = (a - y * math.sin(lean)) / math.cos(lean)
    x = (x - y * x.dot(y)).normalized()
    return Matrix((x, y, x.cross(y).normalized())).transposed()


class Solver:
    def __init__(self, hero):
        self.h = hero
        r = hero.recipe
        base = r['lean']
        lo, hi = r['wrist']
        self.leans = sorted({float(base)} | {lo + 5.0 * i for i in range(int((hi - lo) / 5) + 1)}, key=lambda l: abs(l - base))
        self.twist = r.get('twistToForearm', 0.7)

    def frame(self, grip_d, axis_d, prev):
        """Pose the arm; returns (forearm direction, miss in metres, wrist lean used)."""
        h = self.h; arm = h.arm; pbs = arm.pose.bones
        Wm = arm.matrix_world; Wi = Wm.inverted()
        up, fo, ha = (pbs[n] for n in ARM)
        S, E0, W0 = Wm @ up.head, Wm @ fo.head, Wm @ ha.head
        L1, L2 = (E0 - S).length, (W0 - E0).length
        a = axis_d.normalized()
        u = a.orthogonal().normalized(); v = a.cross(u).normalized()
        palm = h.palm * h.fs
        D = L2 + palm.y
        q = grip_d - S; qa = q.dot(a); qp = q - a * qa; R = max(qp.length, 1e-6)
        th0 = math.atan2(qp.dot(v), qp.dot(u))
        c = (q.length_squared + D * D - L1 * L1) / (2 * D)
        ref = prev if prev is not None else (W0 - E0).normalized()
        best = None
        for le in self.leans:
            Le = math.radians(le)
            k = (c - math.sin(Le) * qa) / (math.cos(Le) * R)
            fd = lambda th: (a * math.sin(Le) + (u * math.cos(th) + v * math.sin(th)) * math.cos(Le)).normalized()
            cands = [fd(th0 + math.acos(k)), fd(th0 - math.acos(k))] if abs(k) <= 1.0 else [fd(th0 if k > 0 else th0 + math.pi)]
            fdir = max(cands, key=lambda d: d.dot(ref))
            w = (fdir - a * fdir.dot(a)).normalized()
            y = (a * math.sin(h.lean) + w * math.cos(h.lean)).normalized()  # the hand keeps the grip; the wrist bends
            H = hand_rot(a, y, h.lean)
            miss = abs((grip_d - H @ palm - fdir * L2 - S).length - L1)
            score = miss + 0.02 * (1.0 - fdir.dot(ref)) * (prev is not None) + 0.0008 * abs(le - self.leans[0])
            if best is None or score < best[0]:
                best = (score, fdir, H, le)
        _, fdir, H, le = best
        Wt = grip_d - H @ palm
        E_ideal = Wt - fdir * L2
        E = S + (E_ideal - S).normalized() * L1
        shift = E - E_ideal
        Wt = Wt + shift
        _turn(up, up.head.copy(), (fo.head - up.head).rotation_difference(Wi @ E - Wi @ S))
        E1, W1 = fo.head.copy(), ha.head.copy()
        _turn(fo, E1, (W1 - E1).rotation_difference(Wi @ Wt - E1))
        hand = Wi @ Matrix.Translation(Wm @ ha.head) @ H.to_4x4() @ Matrix.Scale(h.fs, 4) @ h.C.inverted()
        rel = fo.matrix.to_quaternion().inverted() @ hand.to_quaternion()
        rest = fo.bone.matrix_local.to_quaternion().inverted() @ ha.bone.matrix_local.to_quaternion()
        tw = _twist(rest.inverted() @ rel, Vector((0, 1, 0)))
        if abs(tw) > 1e-3:
            _turn(fo, E1, Quaternion((fo.tail - fo.head).normalized(), tw * self.twist))
        _set(ha, Wi @ Matrix.Translation(Wm @ ha.head) @ H.to_4x4() @ Matrix.Scale(h.fs, 4) @ h.C.inverted())
        return fdir, shift.length, le


def write_action(hero, clip, rows, poses):
    """The prepared clip (the body as the game poses it) with the arm's channels replaced by the solved keys: what the
    checks and sheets play. The export swaps the body channels back to the shipped ones (main)."""
    act = bpy.data.actions[clip].copy(); act.name = clip + '_staff'
    fc = fcurves(act)
    for f in [f for f in fc if any(f'pose.bones["{b}"]' in f.data_path for b in ARM)]:
        fc.remove(f)
    arm = hero.arm
    arm.animation_data.action = act
    if hasattr(act, 'slots') and len(act.slots):
        arm.animation_data.action_slot = act.slots[0]
    for r, pose in zip(rows, poses):
        for b, (loc, rot) in pose.items():
            pb = arm.pose.bones[b]
            pb.location, pb.rotation_quaternion = loc, rot
            pb.keyframe_insert('location', frame=r['f'])
            pb.keyframe_insert('rotation_quaternion', frame=r['f'])
    fc = fcurves(act)
    for b in ARM:  # same hemisphere across keys, so interpolation takes the short way round
        comp = sorted([f for f in fc if f.data_path == f'pose.bones["{b}"].rotation_quaternion'], key=lambda f: f.array_index)
        prev = None
        for k in range(len(comp[0].keyframe_points)):
            qv = [comp[i].keyframe_points[k].co[1] for i in range(4)]
            if prev is not None and sum(x * y for x, y in zip(qv, prev)) < 0:
                qv = [-x for x in qv]
                for i in range(4):
                    comp[i].keyframe_points[k].co[1] = qv[i]
            prev = qv
        for f in comp:
            for kp in f.keyframe_points:
                kp.interpolation = 'LINEAR'
            f.update()
    return act


def bake(hero, solver, clip, spec, length, grip_t):
    rest = hero.recipe['rest']
    target = carry(spec, rest) if spec['type'] == 'carry' else gesture(spec, rest, length, grip_t)
    hero.use_lean(hero.recipe['gameLean'])  # read the clip as the game shows it today
    rows = hero.sample(clip)
    hero.use_lean(hero.recipe['lean'])
    hero.play(clip)
    sc = bpy.context.scene
    poses, misses, leans, prev = [], [], [], None
    for r in rows:
        sc.frame_set(r['f'])
        prev, miss, le = solver.frame(*target(r, rows), prev)
        misses.append(miss); leans.append(le)
        poses.append({b: (hero.arm.pose.bones[b].location.copy(), hero.arm.pose.bones[b].rotation_quaternion.copy()) for b in ARM})
    act = write_action(hero, clip, rows, poses)
    return act, {'miss': round(max(misses), 3), 'wristLean': [min(leans), max(leans)]}


def quality(hero, name, length, grip_t):
    """Staff tilt range, the wrist's bend / twist against the forearm (from the rest relation), and the staff foot's lowest point."""
    hero.play(name)
    sc = bpy.context.scene; pbs = hero.arm.pose.bones
    fo, ha = pbs['R_Forearm'], pbs['R_Hand']
    rest = fo.bone.matrix_local.to_quaternion().inverted() @ ha.bone.matrix_local.to_quaternion()
    tilt, bend, twist, foot = [], [], [], []
    for f in range(sc.frame_start, sc.frame_end + 1):
        sc.frame_set(f)
        g, a = hero.grip()
        tilt.append(math.degrees(a.angle(UP)))
        foot.append((g - a * length * grip_t).z)
        d = rest.inverted() @ (fo.matrix.to_quaternion().inverted() @ ha.matrix.to_quaternion())
        yax = Vector((0, 1, 0))
        bend.append(math.degrees((d @ yax).angle(yax)))
        twist.append(abs(math.degrees(_twist(d, yax))))
    return {'tilt': [round(min(tilt)), round(max(tilt))], 'wristBend': round(max(bend)), 'wristTwist': round(max(twist)),
            'footMin': round(min(foot), 3)}


# ----------------------------------------------------------------------------------------------------------- sheets

TILE_W, TILE_H = 360, 450


def sheet_setup(prop_glb, length, grip_t):
    sc, _ = preview.scene((TILE_W, TILE_H))   # the job previews' render: Cycles on a few CPU threads, what the VPS can spare
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=prop_glb)
    new = [o for o in bpy.data.objects if o not in before]
    prop = next(o for o in new if o.type == 'MESH')
    for o in new:
        if o is not prop:
            bpy.data.objects.remove(o, do_unlink=True)
    prop.parent = None
    vs = [v.co.copy() for v in prop.data.vertices]
    z0 = min(v.z for v in vs); size = max(v.z for v in vs) - z0
    zt = z0 + grip_t * size
    band = [v for v in vs if abs(v.z - zt) < 0.03 * size] or vs
    shaft = sum((Vector((v.x, v.y, zt)) for v in band), Vector()) / len(band)
    # prop local (Blender axes) -> grip frame: shaft point at the origin, scaled to length_m (DmGearModels.weapon)
    to_grip = Matrix.Scale(length / size, 4) @ Matrix.Translation(-(G2B.inverted() @ shaft)) @ G2B.inverted()
    bpy.ops.mesh.primitive_plane_add(size=6)
    cam = bpy.data.objects.new('SheetCam', bpy.data.cameras.new('SheetCam'))
    sc.collection.objects.link(cam)
    cam.data.type = 'ORTHO'; cam.data.ortho_scale = 3.1
    return prop, to_grip, cam


def sheet_render(hero, prop, to_grip, cam, clip, us, out_dir):
    sc = bpy.context.scene
    sc.camera = cam
    rows = []
    for suffix, lean, tag in (('', hero.recipe['gameLean'], 'original'), ('_staff', hero.recipe['lean'], 'staff re-bake')):
        hero.use_lean(lean)
        hero.play(clip + suffix)
        f0, f1 = sc.frame_start, sc.frame_end
        tiles = []
        for u in us:
            f = int(round(f0 + u * (f1 - f0)))
            sc.frame_set(f)
            if not tiles:  # frame the hero once per row: the shoulder at the first sample
                sh0 = hero.arm.matrix_world @ hero.arm.pose.bones[ARM[0]].head
                target = Vector((sh0.x + 0.2, sh0.y + 0.1, 1.32))
                cam.location = target + Vector((0.85, -0.75, 0.18)).normalized() * 6.0
                cam.rotation_euler = (target - cam.location).to_track_quat('-Z', 'Y').to_euler()
            prop.matrix_world = hero.frame() @ hero.seat @ Matrix.Scale(1.0 / hero.fs, 4) @ to_grip
            path = os.path.join(out_dir, f'{clip}{suffix or "_orig"}_{f:03d}.png')
            sc.render.filepath = path
            bpy.ops.render.render(write_still=True)
            tiles.append(path)
        rows.append(tiles)
    return compose(rows, os.path.join(out_dir, f'sheet_{clip}.png'))


def compose(rows, out):
    lines = []
    for row in rows:
        imgs = []
        for p in row:
            im = bpy.data.images.load(p, check_existing=False)
            imgs.append(np.array(im.pixels[:], dtype=np.float32).reshape(im.size[1], im.size[0], 4))
            bpy.data.images.remove(im)
            os.remove(p)
        gap = np.full((imgs[0].shape[0], 4, 4), 0.2, dtype=np.float32)
        parts = []
        for k, a in enumerate(imgs):
            parts += [a] + ([gap] if k < len(imgs) - 1 else [])
        lines.append(np.concatenate(parts, axis=1))
    sep = np.ones((6, lines[0].shape[1], 4), dtype=np.float32) * np.array([0.9, 0.7, 0.25, 1.0], dtype=np.float32)
    stack = []
    for k, t in enumerate(reversed(lines)):  # image rows are stored bottom-up: the first row goes last
        stack += [t] + ([sep] if k < len(lines) - 1 else [])
    big = np.concatenate(stack, axis=0)
    img = bpy.data.images.new('sheet', big.shape[1], big.shape[0], alpha=True)
    img.pixels[:] = big.ravel()
    img.filepath_raw = out; img.file_format = 'PNG'
    img.save()
    bpy.data.images.remove(img)
    return out


# ----------------------------------------------------------------------------------------------------------- main

def main():
    a = common.script_args()
    sheets_prop, sheet_clips = None, None
    if '--sheets' in a:
        i = a.index('--sheets'); sheets_prop = a[i + 1]; del a[i:i + 2]
    if '--sheet-clips' in a:
        i = a.index('--sheet-clips'); sheet_clips = a[i + 1].split(','); del a[i:i + 2]
    glb, recipe_path, out_dir = a[0], a[1], a[2]
    height, length, grip_t = float(a[3]), float(a[4]), float(a[5])
    only = a[6:]
    recipe = common.load_json(recipe_path)
    common.reset_scene()
    hero = Hero(glb, height, recipe)
    print(f'STAFF scale {hero.scale:.4f}, palm {tuple(round(x, 4) for x in hero.palm)}, hip map fit {hero.prep_err:.2e}')
    solver = Solver(hero)
    results = []
    baked = []
    for clip, spec in recipe['clips'].items():
        if only and clip not in only or clip not in bpy.data.actions:
            continue
        act, res = bake(hero, solver, clip, spec, length, grip_t)
        hero.use_lean(recipe['gameLean']); res['before'] = quality(hero, clip, length, grip_t)
        hero.use_lean(recipe['lean']); res['after'] = quality(hero, act.name, length, grip_t)
        hero.arm.scale = (1, 1, 1)
        out = os.path.join(out_dir, f'anim_{act.name}.glb')
        # export the shipped channels (Root, Hip as built), not the prepped ones the solve read
        exp = bpy.data.actions[clip + '__raw'].copy()
        for f in [f for f in fcurves(exp) if any(f'pose.bones["{b}"]' in f.data_path for b in ARM)]:
            fcurves(exp).remove(f)
        src = fcurves(act)
        dst = fcurves(exp)
        for f in src:
            if any(f'pose.bones["{b}"]' in f.data_path for b in ARM):
                g = dst.new(f.data_path, index=f.array_index)
                g.keyframe_points.add(len(f.keyframe_points))
                for i, kp in enumerate(f.keyframe_points):
                    g.keyframe_points[i].co = kp.co
                    g.keyframe_points[i].interpolation = 'LINEAR'
                g.update()
        exp.name = act.name + '__export'
        hero.arm.animation_data.action = exp
        if hasattr(exp, 'slots') and len(exp.slots):
            hero.arm.animation_data.action_slot = exp.slots[0]
        common.export_glb(out, hero.arm, exp)
        assign(hero.arm, act)
        bpy.data.actions.remove(exp)
        hero.arm.scale = (hero.scale,) * 3
        bpy.context.view_layer.update()
        res.update(clip=act.name, file=out)
        print('STAFF', json.dumps(res))
        results.append(res)
        baked.append(clip)
    sheets, sheet_error = [], None
    if sheets_prop:
        try:  # a picture that cannot be made costs only the picture: the clips above are written
            sdir = os.path.join(out_dir, 'sheets')
            os.makedirs(sdir, exist_ok=True)
            prop, to_grip, cam = sheet_setup(sheets_prop, length, grip_t)
            for clip in [c for c in (sheet_clips or baked) if c in baked]:
                us = recipe.get('sheets', {}).get(clip, [0, 0.2, 0.4, 0.6, 0.8, 1])
                sheets.append(sheet_render(hero, prop, to_grip, cam, clip, us, sdir))
                print('STAFF sheet', sheets[-1])
        except Exception as e:  # noqa: BLE001
            sheet_error = f'{type(e).__name__}: {e}'
            print('STAFF sheet failed:', sheet_error)
    print('RESULT ' + json.dumps({'clips': results, 'sheets': sheets, 'sheetError': sheet_error}))


main()
