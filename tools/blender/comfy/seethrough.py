# Holes a step opened: rays from all round (26 directions, a grid of parallel rays each) against the surface a step started from and the one it made;
# a ray that met the first and goes on past it by more than <tol> of the height on the second (or meets nothing) sees through a hole the step opened.
# Pixal's double walls and a step's own shape changes stay under tol; a cut the parts never covered, or both walls of a sheet dropped, do not.
#   blender -b --python seethrough.py -- <before.glb> <after.glb> [--tol 0.02] [--grid 160]
# Prints SEETHROUGH {"share": rays through a hole / rays that met the first surface, "where": the holes' heights in tenths of the height, bottom up,
# "edge": rays past an outline the step moved (trimmed fringe: not holes)}. --mark <out.glb>: the second model with a red speck on each hole.
import sys, math
import numpy as np
from mathutils import Vector
from mathutils.bvhtree import BVHTree

DIRS = [Vector(d).normalized() for d in {(x, y, z) for x in (-1, 0, 1) for y in (-1, 0, 1) for z in (-1, 0, 1)} if any(d)]


def tree_of(me, matrix=None):
    """a BVH of a mesh's triangles (in world space with matrix)"""
    me.calc_loop_triangles()
    co = np.empty(len(me.vertices) * 3); me.vertices.foreach_get('co', co); co = co.reshape(-1, 3)
    if matrix is not None:
        m = np.array(matrix); co = co @ m[:3, :3].T + m[:3, 3]
    tri = np.empty(len(me.loop_triangles) * 3, np.int64); me.loop_triangles.foreach_get('vertices', tri)
    return BVHTree.FromPolygons(co.tolist(), tri.reshape(-1, 3).tolist(), all_triangles=True), co


def see_through(before, after, lo, hi, tol=0.02, grid=160, points=None):
    """before, after: BVH trees in one frame; lo, hi: the model's box. Returns {'share', 'rays', 'where', 'edge'}; points: a list that gets each
    hole's place on the first surface. A hole counts where the first surface runs on unbroken round the ray (its 8 neighbours meet it within
    tol/2 of the same depth); a ray at an outline (a strip's tattered edge the shrink trimmed, a thin bar it narrowed) counts as edge"""
    lo, hi = np.asarray(lo, float), np.asarray(hi, float)
    c = Vector(((lo + hi) / 2).tolist()); r = float(np.linalg.norm(hi - lo)) / 2; h = float(hi[2] - lo[2]); far = 4 * r
    met = holes = edge = 0
    where = np.zeros(10, int)
    ab = np.linspace(-r, r, grid)
    for d in DIRS:
        u = d.orthogonal().normalized(); v = d.cross(u)
        d0 = np.full((grid, grid), np.inf); d1 = np.full((grid, grid), np.inf); at = {}
        for i, a in enumerate(ab):
            for j, b in enumerate(ab):
                o = c - d * (2 * r) + u * a + v * b
                p0 = before.ray_cast(o, d, far)
                if p0[0] is None:
                    continue
                d0[i, j] = p0[3]; at[i, j] = p0[0]
                p1 = after.ray_cast(o, d, far)
                if p1[0] is not None:
                    d1[i, j] = p1[3]
        hit = np.isfinite(d0)
        through = hit & (d1 > d0 + tol * h)
        pad = np.pad(d0, 1, constant_values=np.inf)
        smooth = np.ones_like(hit)
        for di in (-1, 0, 1):
            for dj in (-1, 0, 1):
                nb = pad[1 + di:1 + di + grid, 1 + dj:1 + dj + grid]
                smooth &= np.isfinite(nb) & (np.abs(nb - d0) < 0.5 * tol * h)
        met += int(hit.sum()); edge += int((through & ~smooth).sum())
        for i, j in zip(*np.nonzero(through & smooth)):
            holes += 1
            where[min(9, max(0, int((at[i, j].z - lo[2]) / h * 10)))] += 1
            if points is not None:
                points.append(at[i, j])
    return {'share': round(holes / max(met, 1), 5), 'rays': met, 'where': where.tolist(), 'edge': round(edge / max(met, 1), 4)}


if __name__ == '__main__':
    import bpy, json
    a = sys.argv[sys.argv.index('--') + 1:]
    opt = lambda k, dv: float(a[a.index(k) + 1]) if k in a else dv
    trees = []
    for f in a[:2]:
        for o in list(bpy.data.objects):
            bpy.data.objects.remove(o, do_unlink=True)
        bpy.ops.import_scene.gltf(filepath=f)
        parts = [tree_of(o.data, o.matrix_world) for o in bpy.data.objects if o.type == 'MESH' and not o.name.startswith('Icosphere')]
        co = np.concatenate([p[1] for p in parts])
        if len(parts) > 1:                                                      # one tree over every mesh
            tris, base = [], 0
            for o in [o for o in bpy.data.objects if o.type == 'MESH' and not o.name.startswith('Icosphere')]:
                o.data.calc_loop_triangles()
                t = np.empty(len(o.data.loop_triangles) * 3, np.int64); o.data.loop_triangles.foreach_get('vertices', t)
                tris.append(t.reshape(-1, 3) + base); base += len(o.data.vertices)
            trees.append((BVHTree.FromPolygons(co.tolist(), np.concatenate(tris).tolist(), all_triangles=True), co))
        else:
            trees.append(parts[0])
    co = trees[0][1]
    pts = []
    print('SEETHROUGH', json.dumps(see_through(trees[0][0], trees[1][0], co.min(0), co.max(0), opt('--tol', 0.02), int(opt('--grid', 160)), pts)))
    if '--mark' in a and pts:                                                   # the second model with a red speck on each hole
        s = 0.004 * float(np.ptp(co[:, 2]))
        V, F = [], []
        for p in pts:
            b = len(V)
            V += [(p.x + dx * s, p.y + dy * s, p.z + dz * s) for dx, dy, dz in ((1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1))]
            F += [(b + i, b + j, b + k) for i, j, k in ((0, 2, 4), (2, 1, 4), (1, 3, 4), (3, 0, 4), (2, 0, 5), (1, 2, 5), (3, 1, 5), (0, 3, 5))]
        me = bpy.data.meshes.new('holes'); me.from_pydata(V, [], F)
        red = bpy.data.materials.new('holes'); red.use_nodes = True
        bsdf = red.node_tree.nodes['Principled BSDF']; bsdf.inputs['Base Color'].default_value = (1, 0, 0, 1)
        bsdf.inputs['Emission Color'].default_value = (1, 0, 0, 1); bsdf.inputs['Emission Strength'].default_value = 3
        me.materials.append(red)
        bpy.context.scene.collection.objects.link(bpy.data.objects.new('holes', me))
        bpy.ops.export_scene.gltf(filepath=a[a.index('--mark') + 1], export_format='GLB', export_yup=True)
