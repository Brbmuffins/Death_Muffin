# Surface tools on plain arrays (V: corners Nx3, F: triangles Mx3), shared by clean.py (the detailed model) and finish.py (the rebuilt game mesh before
# its shrink): weld, bilateral normal denoising (Zheng et al. 2011), Taubin smoothing, plane snapping.
import math
import numpy as np


def weld(co, eps):
    """one id per position (the UV seams split corners): (ids per vertex, unique positions)"""
    key = np.round(co / eps).astype(np.int64)
    _, first, inv = np.unique(key, axis=0, return_index=True, return_inverse=True)
    return inv.ravel(), co[first]


def face_frame(V, F):
    p = V[F]
    c = p.mean(1)
    n = np.cross(p[:, 1] - p[:, 0], p[:, 2] - p[:, 0])
    ar = np.linalg.norm(n, axis=1)
    return c, n / np.maximum(ar, 1e-20)[:, None], 0.5 * ar


def ring_pairs(F, nv):
    """pairs of faces that share a corner (each pair once)"""
    v = F.ravel()
    f = np.repeat(np.arange(len(F)), 3)
    o = np.argsort(v, kind='stable')
    v, f = v[o], f[o]
    deg = np.bincount(v, minlength=nv)
    pa, pb = [], []
    for k in range(1, int(deg.max())):
        same = v[k:] == v[:-k]
        pa.append(f[:-k][same]); pb.append(f[k:][same])
    pa, pb = np.concatenate(pa), np.concatenate(pb)
    lo, hi = np.minimum(pa, pb), np.maximum(pa, pb)
    keep = lo != hi
    key = np.unique(lo[keep].astype(np.int64) * len(F) + hi[keep])
    return (key // len(F)).astype(np.int64), (key % len(F)).astype(np.int64)


def edge_pairs(F):
    """pairs of faces that share an edge (manifold edges only)"""
    e = np.sort(np.concatenate([F[:, [0, 1]], F[:, [1, 2]], F[:, [2, 0]]]), axis=1)
    f = np.tile(np.arange(len(F)), 3)
    key = e[:, 0].astype(np.int64) * (F.max() + 1) + e[:, 1]
    o = np.argsort(key, kind='stable')
    key, f = key[o], f[o]
    same = key[1:] == key[:-1]
    lone = np.ones(len(key), bool)
    lone[1:] &= ~same; lone[:-1] &= ~same
    return f[:-1][same], f[1:][same]


def denoise(V, F, rounds, sharp, settle):
    nv = len(V)
    A, B = ring_pairs(F, nv)
    vi = F.ravel()
    fi = np.repeat(np.arange(len(F)), 3)
    cnt = np.bincount(vi, minlength=nv).astype(np.float64)
    for _ in range(rounds):
        c, n, ar = face_frame(V, F)
        ss = np.mean(np.linalg.norm(c[A] - c[B], axis=1))             # the spatial scale: the mean distance between neighbouring faces
        ws = np.exp(-np.sum((c[A] - c[B]) ** 2, 1) / (2 * ss * ss))
        m = n.copy()
        for _ in range(3):                                            # a few normal passes per round, positions fixed
            wr = np.exp(-np.sum((m[A] - m[B]) ** 2, 1) / (2 * sharp * sharp))
            w = ws * wr
            acc = m * ar[:, None]
            for d in range(3):
                acc[:, d] += np.bincount(A, w * ar[B] * m[B, d], len(F)) + np.bincount(B, w * ar[A] * m[A, d], len(F))
            m = acc / np.maximum(np.linalg.norm(acc, axis=1), 1e-20)[:, None]
        for _ in range(settle):                                       # the corners onto the filtered normals
            c = V[F].mean(1)
            d = np.einsum('ij,ij->i', m[fi], c[fi] - V[vi])
            step = np.stack([np.bincount(vi, d * m[fi, k], nv) for k in range(3)], 1) / np.maximum(cnt, 1)[:, None]
            V = V + step
    return V


def taubin(V, F, rounds, lam=0.5, mu=-0.53):
    e = np.unique(np.sort(np.concatenate([F[:, [0, 1]], F[:, [1, 2]], F[:, [2, 0]]]), axis=1), axis=0)
    i, j = np.concatenate([e[:, 0], e[:, 1]]), np.concatenate([e[:, 1], e[:, 0]])
    deg = np.bincount(i, minlength=len(V)).astype(np.float64)
    # an open border's corners stay put (smoothing would pull the border in)
    ek = e[:, 0].astype(np.int64) * len(V) + e[:, 1]
    fe = np.sort(np.concatenate([F[:, [0, 1]], F[:, [1, 2]], F[:, [2, 0]]]), axis=1)
    _, cnt = np.unique(fe[:, 0].astype(np.int64) * len(V) + fe[:, 1], return_counts=True)
    border = np.zeros(len(V), bool)
    border[e[cnt == 1].ravel()] = True
    for _ in range(rounds):
        for f in (lam, mu):
            avg = np.stack([np.bincount(i, V[j, k], len(V)) for k in range(3)], 1) / np.maximum(deg, 1)[:, None]
            step = f * (avg - V)
            step[border] = 0
            V = V + step
    return V


def flatten(V, F, deg, min_share):
    c, n, ar = face_frame(V, F)
    A, B = edge_pairs(F)
    nbr = [[] for _ in range(len(F))]
    for x, y in zip(A.tolist(), B.tolist()):
        nbr[x].append(y); nbr[y].append(x)
    cos = math.cos(math.radians(deg))
    region = -np.ones(len(F), np.int64)
    order = np.argsort(-ar)                                           # big faces seed first
    planes = []
    total = ar.sum()
    rid = 0
    for s in order.tolist():
        if region[s] >= 0:
            continue
        acc = n[s] * ar[s]
        mean = n[s]
        stack, members = [s], [s]
        region[s] = rid
        while stack:
            x = stack.pop()
            for y in nbr[x]:
                if region[y] < 0 and float(n[y] @ mean) > cos:
                    region[y] = rid
                    members.append(y); stack.append(y)
                    acc = acc + n[y] * ar[y]
                    mean = acc / np.linalg.norm(acc)
        mem = np.array(members)
        if ar[mem].sum() >= min_share * total:
            w = ar[mem]
            p0 = (c[mem] * w[:, None]).sum(0) / w.sum()
            q = (c[mem] - p0) * np.sqrt(w)[:, None]
            nn = np.linalg.svd(q, full_matrices=False)[2][-1]
            nn = nn if nn @ mean > 0 else -nn
            planes.append((p0, nn))
        else:
            region[mem] = -2 - rid                                     # small: left as it is
        rid += 1
    # region ids of the planes kept, in order
    keep_ids = sorted(set(int(r) for r in region if r >= 0))
    pid = {r: k for k, r in enumerate(keep_ids)}
    fp = np.array([pid.get(int(r), -1) for r in region])
    # each corner: the planes of its faces (a corner touching a small region stays free)
    vi = F.ravel()
    fpl = np.repeat(fp, 3)
    order = np.lexsort((fpl, vi))
    vi_s, pl_s = vi[order], fpl[order]
    free = np.zeros(len(V), bool)
    free[vi_s[pl_s < 0]] = True
    sets = {}
    for v, p in zip(vi_s.tolist(), pl_s.tolist()):
        if p >= 0 and not free[v]:
            sets.setdefault(v, set()).add(p)
    moved = 0
    P = [(np.asarray(p0), np.asarray(nn)) for p0, nn in planes]
    for v, ps in sets.items():
        if len(ps) > 3:
            continue
        x = V[v].copy()
        for _ in range(12 if len(ps) > 1 else 1):                       # alternate projections: where the planes meet
            for p in ps:
                p0, nn = P[p]
                x = x - nn * float((x - p0) @ nn)
        V[v] = x
        moved += 1
    return V, {'planes': len(planes), 'planeShare': round(float(ar[fp >= 0].sum() / total), 3), 'cornersOnPlanes': round(moved / len(V), 3)}
