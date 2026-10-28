# Geodesic voxel binding (Dionne & de Lasa 2013, Maya's default automatic skinning): the body as voxels (its solid and its surface, so thin cloth
# is kept), each bone's distance to every voxel measured *through the model* (26-neighbour propagation, never through empty space), and each
# vertex weighted by those distances. A cloth layer therefore follows the part it is attached to (a sleeve its forearm, a robe its waist), not
# whatever bone is nearest through the air, and parts that touch but are not joined do not pull on each other.
import numpy as np
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from solid import solid_grid, _dilate

OFFS = [(dx, dy, dz) for dx in (-1, 0, 1) for dy in (-1, 0, 1) for dz in (-1, 0, 1) if (dx, dy, dz) != (0, 0, 0)]


def geodesic(domain, seeds, cell, reach, allowed=None):
    """distances (len(seeds), number of domain voxels) from each seed set through the domain (26 neighbours), up to reach (inf beyond);
    worked on the domain's voxels only (a neighbour table), so the cost follows the body, not its bounding box. Also returns the voxel -> row map."""
    shp = domain.shape
    idx = np.full(shp, -1, np.int64)
    pts = np.argwhere(domain)
    idx[tuple(pts.T)] = np.arange(len(pts))
    nbr, cost = [], []
    for o in OFFS:
        q = pts + o
        ok = np.all((q >= 0) & (q < shp), 1)
        n = np.full(len(pts), -1, np.int64)
        n[ok] = idx[tuple(q[ok].T)]
        keep = n >= 0
        nbr.append((np.flatnonzero(keep), n[keep]))
        cost.append(np.float32(cell * np.sqrt(sum(x * x for x in o))))
    D = np.full((len(seeds), len(pts)), np.inf, np.float32)
    for b, sm in enumerate(seeds):
        r = idx[sm]
        D[b, r[r >= 0]] = 0.0
    for it in range(int(np.ceil(reach / cell)) + 2):
        before = D.copy() if it % 8 == 7 else None
        for (dst, src), c in zip(nbr, cost):
            D[:, dst] = np.minimum(D[:, dst], D[:, src] + c)
        if allowed is not None:
            for b, ok in allowed.items():
                D[b, ~ok] = np.inf
        if before is not None and np.array_equal(before, D):
            break
    D[D > reach] = np.inf
    return D, idx


def weights(co, tri, verts, bones, cells=128, reach_share=0.45, power=4.0, influences=4, H=None, allow=None):
    """co/tri: the body surface; verts: the vertices to weight (n, 3); bones: [(name, head, tail)]. allow: {bone name: f(points (m, 3)) -> bool}, the
    space a bone may reach (a leg only its leg, so cloth hanging beside it stays with the body). Returns (W (n, len(bones)), stats)"""
    solid, occ, lo, cell = solid_grid(co, tri, cells, 1)
    H = H or float(co[:, 2].max() - co[:, 2].min())
    domain = solid | occ
    shp = np.array(domain.shape)
    seeds = []
    for name, h, t in bones:
        n = max(2, int(np.ceil(np.linalg.norm(t - h) / (0.5 * cell))) + 1)
        p = h[None] + (t - h)[None] * np.linspace(0, 1, n)[:, None]
        idx = np.clip(np.floor((p - lo) / cell).astype(int), 0, shp - 1)
        m = np.zeros(domain.shape, bool)
        m[idx[:, 0], idx[:, 1], idx[:, 2]] = True
        seeds.append(m)
    allseed = np.zeros(domain.shape, bool)
    for m in seeds:
        allseed |= m
    domain = domain | _dilate(allseed)                       # a bone a little outside its limb still reaches into it
    allowed = None
    if allow:
        pts = lo + (np.argwhere(domain) + 0.5) * cell
        allowed = {b: allow[name](pts) for b, (name, _, _) in enumerate(bones) if name in allow}
    D, row = geodesic(domain, seeds, cell, reach_share * H, allowed)
    D = np.concatenate([D, np.full((len(D), 1), np.inf, np.float32)], 1)    # row -1 (outside the domain) reads inf
    vi = np.clip(np.floor((verts - lo) / cell).astype(int), 0, shp - 1)
    d = D[:, row[vi[:, 0], vi[:, 1], vi[:, 2]]].T            # (n, B)
    bad = ~np.isfinite(d).any(1)
    if bad.any():                                            # a vertex whose voxel the flood missed: the best of its 3x3x3 neighbours
        for k in np.flatnonzero(bad):
            best = None
            for o in OFFS:
                j = np.clip(vi[k] + o, 0, shp - 1)
                dd = D[:, row[j[0], j[1], j[2]]]
                best = dd if best is None else np.minimum(best, dd)
            d[k] = best
    r = 0.5 * cell
    W = np.where(np.isfinite(d), 1.0 / np.maximum(d, r) ** power, 0.0)
    if influences:
        keep = np.argsort(-W, 1)[:, :influences]
        M = np.zeros_like(W, bool)
        np.put_along_axis(M, keep, True, 1)
        W = np.where(M, W, 0.0)
    s = W.sum(1, keepdims=True)
    unreached = int((s[:, 0] <= 0).sum())
    W = W / np.maximum(s, 1e-12)
    return W, {'cells': cells, 'cell': round(float(cell), 5), 'domain': int(domain.sum()), 'unreached': unreached, 'missedVoxel': int(bad.sum())}


def weld(co, tol=1e-5):
    """each vertex's index among the distinct positions: the copies a mesh keeps along its texture seams share one, so they get one set of
    weights (weighted apart, the copies drift apart in a pose and the seam opens)"""
    _, u = np.unique(np.round(np.asarray(co) / tol).astype(np.int64), axis=0, return_inverse=True)
    return u.ravel()


def _welded(W, edges, u):
    """weights averaged over each position's copies, and the edges between positions"""
    n = int(u.max()) + 1
    Wu = np.zeros((n, W.shape[1]))
    np.add.at(Wu, u, W)
    Wu /= np.bincount(u, minlength=n)[:, None]
    eu = u[edges]
    return Wu, eu[eu[:, 0] != eu[:, 1]]


def smooth(W, edges, rounds=2, lam=0.5, weld=None):
    """neighbour averaging along the mesh edges, then renormalised; with weld (weld()'s indices) on the welded mesh, so seam copies stay equal"""
    if weld is not None:
        Wu, eu = _welded(W, edges, weld)
        return smooth(Wu, eu, rounds, lam)[weld]
    n = len(W)
    for _ in range(rounds):
        acc = np.zeros_like(W); cnt = np.zeros(n)
        for i, j in ((0, 1), (1, 0)):
            np.add.at(acc, edges[:, j], W[edges[:, i]]); np.add.at(cnt, edges[:, j], 1)
        avg = acc / np.maximum(cnt, 1)[:, None]
        W = np.where(cnt[:, None] > 0, (1 - lam) * W + lam * avg, W)
    return W / np.maximum(W.sum(1, keepdims=True), 1e-12)


def fill_missing(W, edges, co, weld=None):
    """vertices with no weight take their weighted neighbours' average across the surface (a flood along the edges); a loose piece with no
    weighted vertex at all takes the nearest weighted vertex in space. Returns (W normalised, how many had none, how many were loose).
    weld: as in smooth (the copies of a position count once)"""
    if weld is not None:
        Wu, eu = _welded(W, edges, weld)
        cu = np.zeros((len(Wu), 3))
        cu[weld] = np.asarray(co)
        Wu, missing, loose = fill_missing(Wu, eu, cu)
        return Wu[weld], missing, loose
    from mathutils.kdtree import KDTree
    n = len(W)
    has = W.sum(1) > 1e-6
    missing = int((~has).sum())
    while not has.all():
        acc = np.zeros_like(W); cnt = np.zeros(n)
        for i, j in ((0, 1), (1, 0)):
            src, dst = edges[:, i], edges[:, j]
            ok = has[src] & ~has[dst]
            np.add.at(acc, dst[ok], W[src[ok]]); np.add.at(cnt, dst[ok], 1)
        new = cnt > 0
        if not new.any():
            break
        W[new] = acc[new] / cnt[new, None]
        has |= new
    loose = int((~has).sum())
    if loose:
        kd = KDTree(int(has.sum()))
        for i in np.flatnonzero(has):
            kd.insert(co[i], int(i))
        kd.balance()
        for i in np.flatnonzero(~has):
            W[i] = W[kd.find(co[i])[1]]
    return W / np.maximum(W.sum(1, keepdims=True), 1e-12), missing, loose
