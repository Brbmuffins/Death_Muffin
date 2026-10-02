"""
procedural.py - author clips from code: blender -b --python procedural.py -- <rig.glb> <recipe.json> <out_dir> [clip ...]

Clip types in a recipe (see tools/blender/recipes/*.json and docs/BLENDER-PIPELINE.md):
  gait   a quadruped (or any multi-legged) gait: each foot follows a stance line (constant speed, so it cannot slide)
         and a swing arc, solved with IK from the hip; the body bobs, pitches and sways around it.
  idle   feet planted, body breathes, head and tail drift.

Everything is expressed in armature space of the imported rig (Blender Z up). `forward` is the horizontal direction
the body faces (default: from the root toward the head bone). Angles are degrees in the recipe.
"""
import math
import os
import sys

import bpy
from mathutils import Matrix, Quaternion, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common  # noqa: E402
from kin import Leg, Rig, T, pivot_rotate, smoothstep  # noqa: E402

UP = Vector((0, 0, 1))


def horizontal(v):
    return Vector((v.x, v.y, 0)).normalized()


class Gait:
    def level_feet(self, meshes):
        """
        Rigs are rarely symmetric: one paw's lowest vertex can sit a few centimetres above its partner's. Lower each leg's
        ankle target by that difference so every foot's mesh actually touches the same floor in stance.
        """
        arm_inv = self.rig.obj.matrix_world.inverted()
        low = {}
        for k, lg in self.legs.items():
            names = set(lg.chain) | {lg.paw} | set(self.rig.descendants(lg.paw))
            lo = None
            for m in meshes:
                if not m.vertex_groups:
                    continue
                gname = {g.index: g.name for g in m.vertex_groups}
                for v in m.data.vertices:
                    if not v.groups:
                        continue
                    top = max(v.groups, key=lambda g: g.weight)
                    if gname[top.group] in names:
                        z = (arm_inv @ (m.matrix_world @ v.co)).z
                        lo = z if lo is None else min(lo, z)
            low[k] = lo
        floor = min(z for z in low.values() if z is not None)
        for k, z in low.items():
            if z is not None:
                self.A0[k].z -= (z - floor)
        self.foot_offsets = {k: round(z - floor, 4) for k, z in low.items() if z is not None}

    def __init__(self, rig, recipe):
        self.rig = rig
        self.r = recipe
        r = recipe
        head = r.get('headBone')
        self.root = r['root']
        if 'forward' in r:
            self.fwd = horizontal(Vector(r['forward']))
        else:
            self.fwd = horizontal(rig.head[head] - rig.head[self.root])
        self.lat = UP.cross(self.fwd).normalized()  # body's left
        self.min_reach = {k: v.get('minReach', 0.0) for k, v in r['legs'].items()}
        self.legs = {k: Leg(rig, v['chain'], v['paw'], v.get('rigidFrom'), bool(v.get('hock'))) for k, v in r['legs'].items()}
        self.side = {k: (1 if (rig.head[v['paw']] - rig.head[self.root]).dot(self.lat) >= 0 else -1) for k, v in r['legs'].items()}
        self.leg_bones = set()
        for lg in self.legs.values():
            self.leg_bones.update(lg.chain)
            self.leg_bones.add(lg.paw)
        self.first_of = {lg.chain[0]: k for k, lg in self.legs.items()}
        self.A0 = {k: rig.head[lg.paw].copy() for k, lg in self.legs.items()}

    # --- foot path -------------------------------------------------------------------------------
    def foot(self, key, phase, g):
        duty = g['duty']
        v = (phase - g['phase'][key]) % 1.0
        stride = g['stride'] * g.get('legScale', {}).get(key, 1.0)
        center = g.get('center', {}).get(key, 0.0) if isinstance(g.get('center'), dict) else g.get('center', 0.0)
        lift = g['lift'] * g.get('legLift', {}).get(key, 1.0)
        if v < duty:
            s = v / duty
            x, z = center + stride * (0.5 - s), 0.0
        else:
            s = (v - duty) / (1 - duty)
            e = smoothstep(s)
            x = center + stride * (-0.5 + e)
            z = lift * math.sin(math.pi * s) ** g.get('arc', 0.85)
        return self.A0[key] + self.fwd * x + UP * z, (1.0 if v < duty else 0.0)

    # --- body modulators -------------------------------------------------------------------------
    def mods_for(self, bone, t, mods):
        """Return (translation, [(axis, angle)]) accumulated for a bone from the clip's modulators at loop time t (0..1)."""
        tr = Vector((0, 0, 0))
        rots = []
        for m in mods:
            bones = m['bones']
            if bone not in bones:
                continue
            i = bones.index(bone)
            ph = m.get('phase', 0.0) + i * m.get('lag', 0.0)
            w = math.sin(2 * math.pi * (m.get('cycles', 1) * t + ph))
            if m.get('abs'):
                w = abs(w) * 2 - 1
            amp = m['amp'] * m.get('falloff', 1.0) ** i
            k = m['kind']
            if k == 'lift':
                tr += UP * amp * w
            elif k == 'sway':
                tr += self.lat * amp * w
            elif k == 'surge':
                tr += self.fwd * amp * w
            else:
                ang = math.radians(amp) * w + math.radians(m.get('offset', 0.0))
                axis = {'pitch': self.lat, 'yaw': UP, 'roll': self.fwd}[k]
                rots.append((axis, ang))
        return tr, rots

    # --- one frame ---------------------------------------------------------------------------------
    def pose(self, t, clip, drop=0.0):
        rig = self.rig
        mods = clip.get('mods', [])
        g = clip.get('gait')
        P, basis = {}, {}
        info = {'stretch': 0.0, 'contact': {}}
        for n in rig.order:
            if n in self.leg_bones and n not in self.first_of:
                continue
            par = rig.parent[n]
            if n in self.first_of:
                key = self.first_of[n]
                lg = self.legs[key]
                ph = t
                if g:
                    ankle, contact = self.foot(key, ph, g)
                else:
                    ankle, contact = self.A0[key].copy(), 1.0
                # pitch the paw a little with the stride (heel-off late in stance, toe-down in swing)
                pawrot = None
                pr = clip.get('paw')
                if pr and g:
                    v = (ph - g['phase'][key]) % 1.0
                    ang = math.radians(pr['stance'] * (v / g['duty'] - 0.5) if v < g['duty'] else pr['swing'] * math.sin(math.pi * (v - g['duty']) / (1 - g['duty'])))
                    R = Matrix.Rotation(ang, 3, self.lat)
                    pawrot = R @ rig.rest[lg.paw].to_3x3()
                inh = rig.inherited(n, P.get(par) if par else None)
                md = None
                hk = clip.get('hock')
                if lg.hock:
                    # rotate the rest metatarsus direction about the body's lateral axis (positive folds the foot back)
                    ang = 0.0
                    if hk and g:
                        v = (ph - g['phase'][key]) % 1.0
                        ang = math.radians(hk['stance'] * (v / g['duty'] - 0.5) if v < g['duty'] else hk['swing'] * math.sin(math.pi * (v - g['duty']) / (1 - g['duty'])))
                    ang += math.radians(hk.get('offset', 0.0)) if hk else 0.0
                    md = Matrix.Rotation(ang, 3, self.lat) @ lg.meta_rest
                    dist = (ankle - md * lg.meta_len - inh.translation).length
                else:
                    dist = (ankle - inh.translation).length
                    mr = self.min_reach[key] * lg.reach
                    if mr and g and 1e-6 < dist < mr:
                        # a tightly folded leg turns the thin forearm into a fin that rises past the spine: open the fold
                        # in mid-swing (weight 0 at lift-off and touch-down, so the foot never pops)
                        v = (ph - g['phase'][key]) % 1.0
                        w = math.sin(math.pi * (v - g['duty']) / (1 - g['duty'])) if v >= g['duty'] else 0.0
                        if w > 0:
                            nd = dist + (mr - dist) * w
                            ankle = inh.translation + (ankle - inh.translation) * (nd / dist)
                            dist = nd
                info['stretch'] = max(info['stretch'], dist / lg.reach)
                info.setdefault('ratio', {})[key] = dist / lg.reach
                info['contact'][key] = contact
                sol = lg.solve(P, basis, ankle, paw_rot_world=pawrot, meta_dir=md)
                info.setdefault('sol', {})[key] = sol
                continue
            inh = rig.inherited(n, P.get(par) if par else None)
            X = Matrix.Identity(4)
            tr, rots = self.mods_for(n, t, mods)
            if n == self.root:
                tr = tr + Vector((0, 0, -drop))
            Pd = inh
            for axis, ang in rots:
                Pd = pivot_rotate(Pd, axis, ang)
            if tr.length > 0:
                Pd = T(tr) @ Pd
            if Pd is not inh:
                loc, rot = rig.basis_from_pose(n, P.get(par) if par else None, Pd)
                basis[n] = (loc, rot)
                P[n] = Pd
            else:
                P[n] = inh
        return basis, P, info

    def build(self, name, clip):
        dur = clip['duration']
        n = int(round(dur * common.FPS))
        # Lowest root drop that keeps every leg within reach (auto) or the recipe's number.
        crouch = clip.get('crouch', 'auto')
        if crouch == 'auto':
            d = clip.get('crouchMin', 0.0)
            limit = clip.get('reach', 0.985)
            while d < 0.25:
                worst = max(self.pose(i / n, clip, d)[2]['stretch'] for i in range(n))
                if worst <= limit:
                    break
                d += 0.002
            crouch = d
        frames, stretch, contacts, lows = [], 0.0, [], {}
        for i in range(n + 1):  # frame n == frame 0 so the loop closes
            b, P, info = self.pose((i % n) / n, clip, crouch)
            frames.append(b)
            if os.environ.get('PROC_DEBUG'):
                print('DBG', i, {k: [tuple(round(c, 3) for c in j) for j in v] for k, v in info.get('sol', {}).items() if k in os.environ['PROC_DEBUG'].split(',')})
            stretch = max(stretch, info['stretch'])
            for k_, r_ in info.get('ratio', {}).items():
                lows[k_] = min(lows.get(k_, 9), r_)
            contacts.append(info['contact'])
        g = clip.get('gait')
        res = {'clip': name, 'duration': dur, 'frames': n + 1, 'crouch': round(crouch, 4), 'maxStretch': round(stretch, 3), 'minReach': {k_: round(v_, 2) for k_, v_ in lows.items()}}
        if g:
            res['stanceSpeed'] = round(g['stride'] / (g['duty'] * dur), 4)
        return frames, res


def main():
    a = common.script_args()
    rig_glb, recipe_path, out_dir = a[0], a[1], a[2]
    only = a[3:]
    recipe = common.load_json(recipe_path)
    common.reset_scene()
    arm, meshes = common.import_glb(rig_glb)
    common.clear_actions(arm)
    common.use_quaternions(arm)
    rig = Rig(arm)
    gait = Gait(rig, recipe)
    if recipe.get('levelFeet', True):
        gait.level_feet(meshes)
        print('PROCEDURAL foot offsets (m)', gait.foot_offsets)
    results = []
    for name, clip in recipe['clips'].items():
        if only and name not in only:
            continue
        frames, res = gait.build(name, clip)
        act = common.key_clip(arm, name, frames)
        out = os.path.join(out_dir, f'anim_{name}.glb')
        common.export_glb(out, arm, act)
        bpy.data.actions.remove(act)
        arm.animation_data.action = None
        res['file'] = out
        results.append(res)
        print('PROCEDURAL', name, res)
    import json
    print('RESULT ' + json.dumps(results))


main()
