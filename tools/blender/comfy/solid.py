# A solid rebuild of a detailed model: its surface into a voxel grid, pinholes closed (the outside grown back after the fill, so nothing gets fatter),
# everything the outside cannot reach filled, and a closed surface made from that. Thin skins (a building Pixal made hollow) become solid walls; noise tunnels close; real openings wider than a few voxels stay.
import bpy, bmesh, numpy as np


def _surface_voxels(co, tri, lo, cell, dims):
    occ = np.zeros(dims, bool)
    p = co[tri]
    edge = np.max(np.linalg.norm(p - np.roll(p, 1, axis=1), axis=2), axis=1)
    m = np.maximum(1, np.ceil(edge / (cell * 0.5))).astype(int)
    for k in np.unique(m):
        sel = p[m == k]
        ij = np.array([(i, j) for i in range(k + 1) for j in range(k + 1 - i)], dtype=np.float64) / k
        w = np.stack([1 - ij.sum(1), ij[:, 0], ij[:, 1]], 1)                     # lattice points on each triangle
        pts = np.einsum('pk,tkd->tpd', w, sel).reshape(-1, 3)
        idx = np.floor((pts - lo) / cell).astype(int)
        occ[idx[:, 0], idx[:, 1], idx[:, 2]] = True
    return occ


def _dilate(a):
    b = a.copy()
    b[1:, :, :] |= a[:-1, :, :]; b[:-1, :, :] |= a[1:, :, :]
    b[:, 1:, :] |= a[:, :-1, :]; b[:, :-1, :] |= a[:, 1:, :]
    b[:, :, 1:] |= a[:, :, :-1]; b[:, :, :-1] |= a[:, :, 1:]
    return b


def _outside(blocked):
    """cells the grid's border reaches through free cells (axis sweeps until nothing changes)"""
    out = np.zeros(blocked.shape, bool)
    out[0, :, :] = out[-1, :, :] = out[:, 0, :] = out[:, -1, :] = out[:, :, 0] = out[:, :, -1] = True
    out &= ~blocked
    for _ in range(64):
        before = out.sum()
        for ax in range(3):
            n = blocked.shape[ax]
            shape = [1, 1, 1]; shape[ax] = n
            idx = np.arange(n, dtype=np.int32).reshape(shape)
            for rev in (False, True):
                b = np.flip(blocked, ax) if rev else blocked
                o = np.flip(out, ax) if rev else out
                last_block = np.maximum.accumulate(np.where(b, idx, -1), axis=ax)
                last_out = np.maximum.accumulate(np.where(o, idx, -1), axis=ax)
                reach = (last_out > last_block) & ~b
                out |= np.flip(reach, ax) if rev else reach
        if out.sum() == before:
            break
    return out


def mesh_arrays(me):
    """a mesh's vertices and triangles as numpy arrays"""
    me.calc_loop_triangles()
    co = np.empty(len(me.vertices) * 3); me.vertices.foreach_get('co', co); co = co.reshape(-1, 3)
    tri = np.empty(len(me.loop_triangles) * 3, dtype=np.int64); me.loop_triangles.foreach_get('vertices', tri); tri = tri.reshape(-1, 3)
    return co, tri


def solid_grid(co, tri, cells=256, close=1):
    """the solid a surface encloses, as voxels: (solid, surface, lo corner, cell size); cells across the largest side"""
    size = (co.max(0) - co.min(0)).max()
    cell = size / cells
    pad = close + 2
    lo = co.min(0) - pad * cell
    dims = tuple((np.ceil((co.max(0) - lo) / cell).astype(int) + pad + 1).tolist())
    occ = _surface_voxels(co, tri, lo, cell, dims)
    blocked = occ
    for _ in range(close):
        blocked = _dilate(blocked)
    outside = _outside(blocked)
    for _ in range(close):                                                      # the closing's second half: back to the true surface
        outside = _dilate(outside) & ~occ
    return ~outside, occ, lo, cell


def solid_rebuild(o, cells=256, close=1):
    """o (applied transform) rebuilt as a solid at cells voxels across its largest side; returns stats"""
    co, tri = mesh_arrays(o.data)
    solid, occ, lo, cell = solid_grid(co, tri, cells, close)
    dims = solid.shape
    # the closed surface: a quad on every face between a solid and an empty cell
    quads = []
    for ax in range(3):
        a = solid
        d = np.diff(a.astype(np.int8), axis=ax)                                  # +1: empty -> solid going up the axis, -1: solid -> empty
        for sgn in (1, -1):
            c = np.argwhere(d == sgn)
            c[:, ax] += 1                                                           # the corner on the shared face
            u, v = [(1, 2), (2, 0), (0, 1)][ax]
            e_u = np.zeros(3, int); e_u[u] = 1
            e_v = np.zeros(3, int); e_v[v] = 1
            q = np.stack([c, c + e_u, c + e_u + e_v, c + e_v], 1)
            if sgn == 1:                                                            # outward = toward the empty side
                q = q[:, ::-1]
            quads.append(q)
    q = np.concatenate(quads)
    flat = (q[..., 0] * (dims[1] + 1) + q[..., 1]) * (dims[2] + 1) + q[..., 2]
    uniq, inv = np.unique(flat.ravel(), return_inverse=True)
    vx = np.stack([uniq // ((dims[1] + 1) * (dims[2] + 1)), (uniq // (dims[2] + 1)) % (dims[1] + 1), uniq % (dims[2] + 1)], 1) * cell + lo
    new = bpy.data.meshes.new('solid')
    new.vertices.add(len(vx)); new.vertices.foreach_set('co', vx.astype(np.float32).ravel())
    nq = len(q)
    new.loops.add(nq * 4); new.loops.foreach_set('vertex_index', inv.astype(np.int32))
    new.polygons.add(nq); new.polygons.foreach_set('loop_start', np.arange(0, nq * 4, 4, dtype=np.int32))
    new.update(); new.validate()
    old = o.data
    o.data = new
    bpy.data.meshes.remove(old)
    # the staircase into a smooth closed surface at the same voxel size
    m = o.modifiers.new('r', 'REMESH'); m.mode = 'VOXEL'; m.voxel_size = cell; m.use_smooth_shade = True
    bpy.context.view_layer.objects.active = o
    bpy.ops.object.modifier_apply(modifier='r')
    return {'cells': cells, 'surfaceVoxels': int(occ.sum()), 'solidShare': round(float(solid.mean()), 3), 'solidFaces': len(o.data.polygons)}
