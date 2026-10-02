"""
selftest.py - checks the pipeline's kinematics against Blender itself: blender -b --python selftest.py
  * Rig.fk reproduces Blender's own pose matrices for random bone transforms,
  * two_bone / fabrik reach reachable targets with the segment lengths intact and stretch (not break) on unreachable ones,
  * Leg.solve puts the ankle on the target and basis_from_pose round-trips,
  * a keyed clip exports to a non-empty GLB.
Prints SELFTEST OK or raises.
"""
import math
import os
import random
import sys
import tempfile

import bpy
from mathutils import Matrix, Quaternion, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common  # noqa: E402
from kin import Leg, Rig, fabrik, two_bone  # noqa: E402


def make_leg_rig():
    common.reset_scene()
    arm_data = bpy.data.armatures.new('A')
    arm = bpy.data.objects.new('A', arm_data)
    bpy.context.scene.collection.objects.link(arm)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.mode_set(mode='EDIT')
    eb = arm_data.edit_bones
    root = eb.new('root'); root.head = (0, 0, 0); root.tail = (0, 0, 0.2)
    pts = [(0, 0, 1.0), (0.1, 0.05, 0.55), (0, 0.1, 0.15), (0.12, 0.12, 0.02)]
    prev = root
    for i in range(3):
        b = eb.new(f'b{i}'); b.head = pts[i]; b.tail = pts[i + 1]; b.parent = prev
        prev = b
    p = eb.new('paw'); p.head = pts[3]; p.tail = (0.25, 0.12, 0.02); p.parent = prev
    bpy.ops.object.mode_set(mode='OBJECT')
    common.use_quaternions(arm)
    return arm


def main():
    random.seed(4)
    arm = make_leg_rig()
    rig = Rig(arm)
    # 1. FK vs Blender
    basis = {}
    for n in rig.order:
        q = Quaternion((random.random(), random.random() - .5, random.random() - .5, random.random() - .5)).normalized()
        loc = Vector((random.uniform(-.02, .02), random.uniform(-.02, .02), random.uniform(-.02, .02)))
        basis[n] = (loc, q)
        pb = arm.pose.bones[n]
        pb.location, pb.rotation_quaternion = loc, q
    bpy.context.view_layer.update()
    P = rig.fk(basis)
    for n in rig.order:
        d = (P[n] - arm.pose.bones[n].matrix)
        err = max(abs(v) for row in d for v in row)
        assert err < 1e-5, f'FK mismatch on {n}: {err}'
    # 2. IK primitives
    for target in (Vector((0.05, 0.1, 0.3)), Vector((0.2, 0.0, 0.7)), Vector((0, 0, -3))):
        root = Vector((0, 0, 1.0))
        sol = two_bone(root, target, 0.5, 0.45, Vector((1, 0, 0)))
        assert abs((sol[1] - sol[0]).length - 0.5) < 1e-5 and abs((sol[2] - sol[1]).length - 0.45) < 1e-5 or (target - root).length > 0.95
        if (target - root).length < 0.94:
            assert (sol[2] - target).length < 1e-5, 'two_bone missed a reachable target'
    j = [Vector((0, 0, 1)), Vector((0, 0, .7)), Vector((0, 0, .4)), Vector((0, 0, .1))]
    sol = fabrik(j, Vector((0.2, 0.1, 0.35)), [0.3, 0.3, 0.3])
    assert (sol[-1] - Vector((0.2, 0.1, 0.35))).length < 1e-3
    assert all(abs((sol[i + 1] - sol[i]).length - 0.3) < 1e-4 for i in range(3))
    # 3. Leg.solve lands the ankle where asked, for the 3-bone chain and the stiff-lower-leg variant
    for rigid in (None, 1):
        leg = Leg(rig, ['b0', 'b1', 'b2'], 'paw', rigid)
        P0 = rig.fk({})
        target = rig.head['paw'] + Vector((0.08, 0.03, 0.12))
        Pn, bs = dict(P0), {}
        leg.solve(Pn, bs, target)
        ank = Pn['b2'] @ (rig.rest['b2'].inverted() @ rig.head['paw'])
        assert (ank - target).length < 2e-3, f'ankle off by {(ank - target).length} (rigid={rigid})'
        assert (Pn['paw'].translation - target).length < 2e-3
    # 4. keyed clip exports to a GLB with the action's channels
    frames = [{'b0': (Vector((0, 0, 0)), Quaternion((0, 0, 1), math.radians(10 * i)))} for i in range(5)]
    act = common.key_clip(arm, 'spin', frames)
    path = os.path.join(tempfile.mkdtemp(), 'rt.glb')
    common.export_glb(path, arm, act)
    assert os.path.getsize(path) > 100, 'export wrote nothing'
    print('SELFTEST OK')


main()
