"""
kin.py - tiny skeleton kinematics for the Death Muffin Blender pipeline (runs inside Blender, uses mathutils only).

Why not Blender's IK constraints: the Tripo rigs have odd chains (hind legs parented to the tail, front legs that are
not bones at all on the cinderhound), and we want deterministic, scriptable foot placement that we can also measure.
So we do our own forward kinematics (same formula Blender uses) and a FABRIK solver, then write plain bone
location/rotation keys that export to glTF with no constraints or baking.

Pose matrix of a bone, armature space:   P[b] = P[parent] @ (Rest[parent]^-1 @ Rest[b]) @ Basis[b]
where Rest[b] = bone.matrix_local and Basis[b] = Translation(location) @ rotation @ Scale.
"""
import math
import bpy
from mathutils import Matrix, Quaternion, Vector


def T(v):
    return Matrix.Translation(v)


class Rig:
    """Rest data and FK for one armature object (armature space; the object transform is ignored)."""

    def __init__(self, arm_obj):
        self.obj = arm_obj
        bones = list(arm_obj.data.bones)
        self.rest = {b.name: b.matrix_local.copy() for b in bones}
        self.parent = {b.name: (b.parent.name if b.parent else None) for b in bones}
        self.children = {b.name: [c.name for c in b.children] for b in bones}
        # Parents first.
        self.order = []
        seen = set()

        def visit(n):
            if n in seen:
                return
            p = self.parent[n]
            if p:
                visit(p)
            seen.add(n)
            self.order.append(n)

        for b in bones:
            visit(b.name)
        self.rel = {n: (self.rest[self.parent[n]].inverted() @ self.rest[n]) if self.parent[n] else self.rest[n].copy() for n in self.order}
        self.head = {n: self.rest[n].translation.copy() for n in self.order}

    def names(self):
        return list(self.order)

    def descendants(self, name):
        out, stack = [], list(self.children[name])
        while stack:
            n = stack.pop()
            out.append(n)
            stack.extend(self.children[n])
        return out

    def chain_up(self, name):
        out = []
        while name:
            out.append(name)
            name = self.parent[name]
        return out

    def basis_matrix(self, loc=None, rot=None):
        m = Matrix.Identity(4)
        if rot is not None:
            m = rot.to_matrix().to_4x4()
        if loc is not None:
            m = T(loc) @ m
        return m

    def fk(self, basis):
        """basis: {name: (loc Vector|None, rot Quaternion|None)} -> {name: pose matrix}."""
        P = {}
        for n in self.order:
            loc, rot = basis.get(n, (None, None))
            local = self.rel[n] @ self.basis_matrix(loc, rot)
            P[n] = (P[self.parent[n]] @ local) if self.parent[n] else local
        return P

    def basis_from_pose(self, name, P_parent, P_des):
        """The (loc, rot) basis that puts `name` at pose matrix P_des given its parent's final pose."""
        inh = (P_parent @ self.rel[name]) if P_parent is not None else self.rel[name]
        B = inh.inverted() @ P_des
        # inh is rest-relative, so B is the basis in the bone's rest frame.
        loc, rot, _ = B.decompose()
        return loc, rot

    def inherited(self, name, P_parent):
        return (P_parent @ self.rel[name]) if P_parent is not None else self.rel[name].copy()


def arc(a, b):
    """Shortest rotation taking direction a to direction b (Quaternion)."""
    a = a.normalized()
    b = b.normalized()
    return a.rotation_difference(b)


def fabrik(joints, target, lengths, iterations=24, tol=1e-5):
    """FABRIK on a chain of joint positions (root fixed). Returns new joint positions. Unreachable targets stretch."""
    p = [j.copy() for j in joints]
    root = p[0].copy()
    total = sum(lengths)
    if (target - root).length >= total:
        d = (target - root).normalized()
        out = [root.copy()]
        for L in lengths:
            out.append(out[-1] + d * L)
        return out
    for _ in range(iterations):
        p[-1] = target.copy()
        for i in range(len(p) - 2, -1, -1):
            d = (p[i] - p[i + 1])
            d = d.normalized() if d.length > 1e-9 else Vector((0, 0, 1))
            p[i] = p[i + 1] + d * lengths[i]
        p[0] = root.copy()
        for i in range(1, len(p)):
            d = (p[i] - p[i - 1])
            d = d.normalized() if d.length > 1e-9 else Vector((0, 0, -1))
            p[i] = p[i - 1] + d * lengths[i - 1]
        if (p[-1] - target).length < tol:
            break
    return p


def two_bone(root, target, l1, l2, pole):
    """Analytic two-segment IK. `pole` is a direction the middle joint bends toward (any vector; its part across the
    root-target line is used), which keeps the bend on one side from frame to frame. Unreachable targets stretch straight."""
    d = target - root
    D = d.length
    if D < 1e-9:
        return [root.copy(), root + Vector((0, 0, -l1)), root + Vector((0, 0, -l1 - l2))]
    u = d / D
    reach = min(max(D, abs(l1 - l2) + 1e-6), l1 + l2 - 1e-6)
    a = (l1 * l1 - l2 * l2 + reach * reach) / (2 * reach)
    h = math.sqrt(max(0.0, l1 * l1 - a * a))
    perp = pole - u * pole.dot(u)
    if perp.length < 1e-9:
        perp = Vector((0, 0, 1)) - u * u.z
    perp.normalize()
    knee = root + u * a + perp * h
    end = root + u * D if D <= l1 + l2 - 1e-6 else root + u * (l1 + l2)
    return [root.copy(), knee, end]


class Leg:
    """IK leg: `chain` bones hip->...->last, `paw` is the child whose head is the ankle target."""

    def __init__(self, rig, chain, paw, rigid_from=None, hock=False):
        """
        rigid_from=k (k >= 1): bones chain[k:] are treated as one stiff piece from joint k to the ankle (the solver then
        has exactly two segments, so the answer is unique and smooth from frame to frame). A 3-bone chain solved with
        FABRIK has a free middle joint that can jump between frames; the stiff lower leg keeps the rest pose's hock angle.
        """
        self.rig = rig
        self.chain = chain
        self.paw = paw
        self.rigid_from = rigid_from
        self.hock = hock
        self.joint_rest = [rig.head[b] for b in chain] + [rig.head[paw]]
        self.lengths = [(self.joint_rest[i + 1] - self.joint_rest[i]).length for i in range(len(chain))]
        if hock:
            # thigh, shin, metatarsus: the first two are solved to the hock, the metatarsus then points at the ankle
            # along a direction the caller chooses (so the hock flexes instead of keeping the rest angle).
            assert len(chain) == 3, 'hock legs have exactly three chain bones'
            self.solve_joints_rest = self.joint_rest[:3]
            self.solve_lengths = self.lengths[:2]
            self.meta_len = self.lengths[2]
            self.meta_rest = (self.joint_rest[3] - self.joint_rest[2]).normalized()
        elif rigid_from:
            self.solve_joints_rest = self.joint_rest[:rigid_from + 1] + [self.joint_rest[-1]]
            self.solve_lengths = self.lengths[:rigid_from] + [(self.joint_rest[-1] - self.joint_rest[rigid_from]).length]
        else:
            self.solve_joints_rest = self.joint_rest
            self.solve_lengths = self.lengths
        self.reach = sum(self.solve_lengths)
        # Rest direction of each link, in the bone's own rest frame (so it survives any inherited rotation).
        self.local_dir = []
        for i, b in enumerate(chain):
            d0 = (self.joint_rest[i + 1] - self.joint_rest[i])
            self.local_dir.append(rig.rest[b].to_3x3().inverted() @ d0)

    def solve(self, P, basis, ankle, paw_rot_world=None, hint=None, meta_dir=None):
        """
        P: pose matrices already final for every bone above the chain (others ignored).
        Fills `basis` for the chain bones and the paw, and P for them. `ankle` is a world (armature) position.
        `paw_rot_world`: 3x3 world rotation for the paw bone (default: its rest world orientation).
        """
        rig = self.rig
        first = self.chain[0]
        par = rig.parent[first]
        inh0 = rig.inherited(first, P.get(par) if par else None)
        root = inh0.translation.copy()
        # Initial joint guess: rest-pose chain carried by the inherited transform, so the bend side is the rest side.
        rest0 = rig.rest[first]
        carry = inh0 @ rest0.inverted()
        joints = [carry @ j for j in self.solve_joints_rest]
        joints[0] = root
        if hint is not None:
            joints = [h.copy() for h in hint]
        if self.hock:
            md = (meta_dir if meta_dir is not None else self.meta_rest).normalized()
            hockpos = ankle - md * self.meta_len
            line = joints[2] - joints[0]
            pole = (joints[1] - joints[0]) - line * ((joints[1] - joints[0]).dot(line) / max(1e-9, line.dot(line)))
            s2 = two_bone(root, hockpos, self.solve_lengths[0], self.solve_lengths[1], pole)
            sol = [s2[0], s2[1], s2[2], s2[2] + md * self.meta_len]
        elif len(joints) == 3:
            # Two segments: closed form, with the rest pose's bend direction (carried by the body) as the pole.
            line = joints[2] - joints[0]
            pole = (joints[1] - joints[0]) - line * ((joints[1] - joints[0]).dot(line) / max(1e-9, line.dot(line)))
            sol = two_bone(root, ankle, self.solve_lengths[0], self.solve_lengths[1], pole)
        else:
            sol = fabrik(joints, ankle, self.solve_lengths)
        k = self.rigid_from
        # Rebuild bone rotations top-down from the solved joints.
        for i, b in enumerate(self.chain):
            if k and i > k:
                # inside the stiff lower leg: no extra rotation, FK carries it
                pp = P.get(rig.parent[b])
                basis[b] = (None, None)
                P[b] = pp @ rig.rel[b]
                continue
            pp = P.get(rig.parent[b]) if rig.parent[b] else None
            inh = rig.inherited(b, pp)
            if k and i == k:
                # the stiff piece points from joint k at the ankle
                local = rig.rest[b].to_3x3().inverted() @ (self.joint_rest[-1] - self.joint_rest[k])
                d_inh = (inh.to_3x3() @ local).normalized()
            else:
                d_inh = (inh.to_3x3() @ self.local_dir[i]).normalized()
            want = (sol[i + 1] - sol[i]).normalized()
            q = arc(d_inh, want)
            rot3 = q.to_matrix() @ inh.to_3x3()
            Pdes = T(inh.translation) @ rot3.to_4x4()
            loc, rot = rig.basis_from_pose(b, pp, Pdes)
            basis[b] = (loc, rot)
            P[b] = pp @ rig.rel[b] @ rig.basis_matrix(loc, rot) if pp is not None else rig.rel[b] @ rig.basis_matrix(loc, rot)
        # Paw sits on the solved ankle (= tail of the last chain bone).
        ppar = P[self.chain[-1]]
        pawM = rig.rest[self.paw].to_3x3() if paw_rot_world is None else paw_rot_world
        ank = P[self.chain[-1]] @ (rig.rest[self.chain[-1]].inverted() @ rig.head[self.paw])
        Pdes = T(ank) @ pawM.to_4x4()
        loc, rot = rig.basis_from_pose(self.paw, ppar, Pdes)
        basis[self.paw] = (loc, rot)
        P[self.paw] = ppar @ rig.rel[self.paw] @ rig.basis_matrix(loc, rot)
        return sol


def rot_about(axis, angle):
    return Quaternion(axis.normalized(), angle)


def pivot_rotate(P_inh, axis, angle):
    """Armature-space rotation by `angle` about `axis` through the bone's head, applied on top of the inherited pose."""
    c = P_inh.translation
    R = Matrix.Rotation(angle, 4, axis.normalized())
    return T(c) @ R @ T(-c) @ P_inh


def smoothstep(x):
    x = max(0.0, min(1.0, x))
    return x * x * (3 - 2 * x)
