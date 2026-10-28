# The branches of any body, from its shape alone: the body as voxels, each voxel's depth (landmarks.depth_map), shortest paths from the deepest
# point that prefer deep voxels (so a path runs down the middle of a leg, tail or neck, not along its skin), and the tips (paws, snout, tail end,
# horns) as the far ends of branches long enough to matter. Body-type fitters (quad.py, ...) name the branches and place joints along them.
import numpy as np

OFFS = np.array([(dx, dy, dz) for dx in (-1, 0, 1) for dy in (-1, 0, 1) for dz in (-1, 0, 1) if (dx, dy, dz) != (0, 0, 0)])
LENS = np.linalg.norm(OFFS, axis=1)


def graph(solid):
    """solid voxels as a graph: (vox (N,3) indices, neighbour table (N,26), -1 = none)"""
    vox = np.argwhere(solid)
    idx = -np.ones(solid.shape, np.int64)
    idx[tuple(vox.T)] = np.arange(len(vox))
    nb = np.full((len(vox), 26), -1, np.int64)
    sh = np.array(solid.shape)
    for k, o in enumerate(OFFS):
        q = vox + o
        ok = np.all((q >= 0) & (q < sh), axis=1)
        nb[ok, k] = idx[tuple(q[ok].T)]
    return vox, idx, nb


def paths_from(nb, src, node_cost, most=4000):
    """shortest paths from node src: an edge into node v costs its length * node_cost[v]; (distance, predecessor)"""
    n = len(nb)
    d = np.full(n + 1, np.inf)                                                     # slot n: the 'no neighbour' sink
    d[src] = 0.0
    pred = np.full(n, -1, np.int64)
    cost = LENS[None, :] * node_cost[:, None]                                       # (n, 26): cost of reaching node i from its neighbour k
    for it in range(most):
        cand = d[np.where(nb >= 0, nb, n)] + cost                                   # arriving at i from each neighbour
        k = cand.argmin(1)
        best = cand[np.arange(n), k]
        better = best < d[:n] - 1e-9
        if not better.any():
            break
        d[:n][better] = best[better]
        pred[better] = nb[better, k[better]]
    return d[:n], pred


def path(pred, tip):
    """node indices from the source to tip"""
    out = [tip]
    while pred[out[-1]] >= 0:
        out.append(pred[out[-1]])
    return out[::-1]


def tips(vox, dep, dist, pred, min_branch, start_share=0.1, most=40):
    """far ends of branches: nodes taken in falling distance; each walks back toward the source until it reaches the space of a branch already
    kept, and is kept when that walk is at least min_branch long. A walk claims a tube around itself as thick as the body there (its depth + 2
    voxels), so a second path down the same leg or a spike on it never counts as a new branch. Returns [(node, branch length, junction node)]"""
    order = np.argsort(-dist)
    order = order[dist[order] > start_share * dist.max()]
    shape = tuple(vox.max(0) + 1)
    cl = np.zeros(shape, bool)
    out = []

    def stamp(nodes):
        S = np.array(shape)
        for q in nodes:
            r = int(dep[q]) + 2
            c = vox[q]
            lo_, hi_ = np.maximum(c - r, 0), np.minimum(c + r + 1, S)
            b0 = lo_ - (c - r)
            b1 = b0 + (hi_ - lo_)
            cl[lo_[0]:hi_[0], lo_[1]:hi_[1], lo_[2]:hi_[2]] |= _ball(r)[b0[0]:b1[0], b0[1]:b1[1], b0[2]:b1[2]]
    for t in order:
        if cl[tuple(vox[t])]:
            continue
        walk = []
        p = t
        while p >= 0 and not cl[tuple(vox[p])]:
            walk.append(p)
            p = pred[p]
        j = p if p >= 0 else walk[-1]
        length = dist[t] - dist[j]
        if length >= min_branch:
            out.append((int(t), float(length), int(j)))
        stamp(walk)                                                                 # claimed either way: a short spike's space is used up
        if len(out) >= most:
            break
    return out


_balls = {}


def _ball(r):
    if r not in _balls:
        g = np.arange(-r, r + 1)
        _balls[r] = (g[:, None, None] ** 2 + g[None, :, None] ** 2 + g[None, None, :] ** 2) <= r * r
    return _balls[r]


def fit_polyline(pts, k, prior=None, strength=0.03):
    """best k-segment polyline through ordered, evenly spaced points (ends fixed): indices of the k+1 joints. Cost: squared distance of the points to
    the chords, plus (with prior = k length shares) a pull toward those shares, so a straight stretch still splits where the body type's bones go.
    strength: how far (share of the line's length, every point) one 0.1 share off the prior weighs."""
    n = len(pts)
    if n <= k + 1:
        return list(np.linspace(0, n - 1, k + 1).round().astype(int))
    L = float(np.linalg.norm(np.diff(pts, axis=0), axis=1).sum())
    lam = n * (strength * L) ** 2 / 0.1 ** 2

    def err(i, j):
        if j <= i + 1:
            return 0.0
        a, b = pts[i], pts[j]
        ab = b - a
        Lab = np.linalg.norm(ab)
        q = pts[i + 1:j] - a
        if Lab < 1e-9:
            return float((q ** 2).sum())
        u = ab / Lab
        perp = q - np.outer(q @ u, u)
        return float((perp ** 2).sum())

    E = np.full((n, n), np.inf)
    for i in range(n):
        for j in range(i + 1, n):
            E[i, j] = err(i, j)
    share = (np.arange(n)[None, :] - np.arange(n)[:, None]) / (n - 1)               # share[i, j]: (j - i) of the whole
    best = np.full((k + 1, n), np.inf)
    arg = np.zeros((k + 1, n), int)
    best[0, 0] = 0.0
    for s in range(1, k + 1):
        pen = lam * (share - prior[s - 1]) ** 2 if prior is not None else 0.0
        for j in range(1, n):
            c = best[s - 1, :j] + E[:j, j] + (pen[:j, j] if prior is not None else 0.0)
            i = int(np.argmin(c))
            best[s, j], arg[s, j] = c[i], i
    out = [n - 1]
    for s in range(k, 0, -1):
        out.append(arg[s, out[-1]])
    return out[::-1]


def resample(pts, step):
    """an ordered point line at even spacing"""
    seg = np.linalg.norm(np.diff(pts, axis=0), axis=1)
    s = np.concatenate([[0], np.cumsum(seg)])
    m = max(2, int(np.ceil(s[-1] / step)) + 1)
    t = np.linspace(0, s[-1], m)
    return np.stack([np.interp(t, s, pts[:, i]) for i in range(3)], 1)
