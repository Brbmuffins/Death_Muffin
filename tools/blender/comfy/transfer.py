# The detailed model's paint, shine and surface detail onto the game mesh's UVs. For every texel of the game mesh: a ray out and a ray in along its normal;
# the nearer hit on a surface facing the same way wins (a thin bone next door never does). The ray out goes on through up to three surfaces facing away
# (a texel between a cloth and the ribs under it meets the cloth's underside first; stopping there gave the ribs' paint to the cloth: bone-white blotches). If neither finds one within reach: the same rays
# out to 3x reach, then the nearest surface facing the same way seen from points stepped out (then in) along the normal; a texel near only
# surfaces facing away (Pixal's inner wall, dark paint) takes the paint of the nearest texel (in 3D) that found the right wall, and a
# flat normal.
# Texture space on both sides is MikkTSpace (Blender's, glTF's and Godot's), so the normal map reads the same in game.
import bpy, numpy as np, time
from mathutils import Vector
from mathutils.bvhtree import BVHTree


def _loops(me, uvname=None):
    me.calc_loop_triangles()
    me.calc_tangents(uvmap=uvname or me.uv_layers.active.name)
    nl = len(me.loops)
    g = lambda attr, w: (lambda b: (me.loops.foreach_get(attr, b), b.reshape(nl, w) if w > 1 else b)[1])(np.empty(nl * w, dtype=np.float64))
    lt = np.empty(len(me.loop_triangles) * 3, dtype=np.int64)
    me.loop_triangles.foreach_get('loops', lt)
    uv = np.empty(nl * 2)
    (me.uv_layers[uvname] if uvname else me.uv_layers.active).data.foreach_get('uv', uv)
    vi = np.empty(nl, dtype=np.int64)
    me.loops.foreach_get('vertex_index', vi)
    co = np.empty(len(me.vertices) * 3)
    me.vertices.foreach_get('co', co)
    return dict(tri=lt.reshape(-1, 3), uv=uv.reshape(nl, 2), pos=co.reshape(-1, 3)[vi], n=g('normal', 3), t=g('tangent', 3), s=g('bitangent_sign', 1))


def _frame(L, tri, bary):
    """interpolated position, normal, tangent, bitangent at (triangle, barycentric) rows"""
    ids = L['tri'][tri]
    lerp = lambda a: np.einsum('ij,ijk->ik', bary, a[ids])
    n = lerp(L['n']); t = lerp(L['t'])
    s = np.sign(np.einsum('ij,ij->i', bary, L['s'][ids]) + 1e-9)
    n /= np.linalg.norm(n, axis=1, keepdims=True) + 1e-12
    t -= n * np.einsum('ij,ij->i', t, n)[:, None]
    t /= np.linalg.norm(t, axis=1, keepdims=True) + 1e-12
    return lerp(L['pos']), n, t, s[:, None] * np.cross(n, t)


def _raster(L, size):
    """each texel the game mesh's UVs cover: its triangle and barycentric (texels up to 0.75 px outside an edge count, clamped onto it)"""
    best = np.full((size, size), -1e9)
    tri_of = np.full((size, size), -1, dtype=np.int64)
    bary = np.zeros((size, size, 3))
    uvp = L['uv'][L['tri']] * size - 0.5
    for i, (a, b, c) in enumerate(uvp):
        x0, y0 = np.floor(np.minimum(np.minimum(a, b), c)).astype(int) - 1
        x1, y1 = np.ceil(np.maximum(np.maximum(a, b), c)).astype(int) + 1
        x0, y0, x1, y1 = max(x0, 0), max(y0, 0), min(x1, size - 1), min(y1, size - 1)
        if x1 < x0 or y1 < y0:
            continue
        X, Y = np.meshgrid(np.arange(x0, x1 + 1), np.arange(y0, y1 + 1))
        area = (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])
        if abs(area) < 1e-12:
            continue
        e = lambda p, q: ((q[0] - p[0]) * (Y - p[1]) - (q[1] - p[1]) * (X - p[0])) / area
        w = np.stack([e(b, c), e(c, a), e(a, b)], -1)
        lens = np.array([np.hypot(*(c - b)), np.hypot(*(a - c)), np.hypot(*(b - a))])
        d = (w * abs(area) / np.maximum(lens, 1e-9)).min(-1)                    # signed distance to the nearest edge, px
        sub = best[y0:y1 + 1, x0:x1 + 1]
        m = (d > -0.75) & (d > sub)
        if not m.any():
            continue
        w = np.clip(w, 0, None)
        w /= w.sum(-1, keepdims=True)
        sub[m] = d[m]
        tri_of[y0:y1 + 1, x0:x1 + 1][m] = i
        bary[y0:y1 + 1, x0:x1 + 1][m] = w[m]
    return tri_of, bary


def _sample(img, uv):
    """bilinear, clamped; uv rows -> RGBA rows"""
    h, w = img.shape[:2]
    x = np.clip(uv[:, 0] * w - 0.5, 0, w - 1); y = np.clip(uv[:, 1] * h - 0.5, 0, h - 1)
    x0 = np.floor(x).astype(int); y0 = np.floor(y).astype(int)
    x1 = np.minimum(x0 + 1, w - 1); y1 = np.minimum(y0 + 1, h - 1)
    fx = (x - x0)[:, None]; fy = (y - y0)[:, None]
    return (img[y0, x0] * (1 - fx) + img[y0, x1] * fx) * (1 - fy) + (img[y1, x0] * (1 - fx) + img[y1, x1] * fx) * fy


def image_array(im):
    w, h = im.size
    p = np.empty(w * h * 4, dtype=np.float32)
    im.pixels.foreach_get(p)
    return p.reshape(h, w, 4)


def grow(filled, px):
    """for each texel within px of a filled one: the flat index of a filled texel to copy (edge padding); -1 elsewhere"""
    h, w = filled.shape
    src = np.where(filled, np.arange(h * w).reshape(h, w), -1)
    for _ in range(px):
        new = src.copy()
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)):
            r = np.roll(np.roll(src, dy, 0), dx, 1)
            m = (new < 0) & (r >= 0)
            new[m] = r[m]
        if (new == src).all():
            break
        src = new
    return src


def transfer(hi, lo, hi_maps, size, reach, margin=16):
    """hi_maps: {'base': HxWx4, 'orm': ..., 'normal': ...} on the detailed model's UVs. Returns the same keys at size x size on the game mesh's UVs, and stats."""
    t0 = time.time()
    H = _loops(hi.data, hi.data.uv_layers.active.name)
    L = _loops(lo.data)
    tri_of, bary = _raster(L, size)
    cov = tri_of >= 0
    P, N, T, B = _frame(L, tri_of[cov], bary[cov])
    st = {'texels': int(cov.sum()), 'rasterS': round(time.time() - t0, 1)}

    hv = hi.data.vertices
    co = np.empty(len(hv) * 3); hv.foreach_get('co', co); co = co.reshape(-1, 3)
    hvi = np.empty(len(hi.data.loops), dtype=np.int64); hi.data.loops.foreach_get('vertex_index', hvi)
    htri_v = hvi[H['tri']]
    bvh = BVHTree.FromPolygons([tuple(v) for v in co], [tuple(t) for t in htri_v.tolist()], all_triangles=True)
    eps = reach * 0.002
    hit_tri = np.full(len(P), -1, dtype=np.int64); hit_loc = np.zeros((len(P), 3))
    kinds = np.zeros(3, dtype=np.int64)
    facing = np.ones(len(P), bool)
    how = np.zeros(len(P), dtype=np.uint8)                                     # 0 ray within reach, 1 ray within 3x reach, 2 nearest, 3 lost
    rc, fn = bvh.ray_cast, bvh.find_nearest
    steps = [reach * f for f in (0.25, 0.5, 1.0, 2.0, -0.25, -0.5, -1.0)]       # out along the normal first, then in
    far = reach * 3
    def out_ray(p, n, r):
        """the first surface facing out along the normal within <r>, through up to three facing away: (distance, location, index) or None"""
        o = p - n * eps; left = r
        for _ in range(4):
            loc, hn, idx, d = rc(o, n, left)
            if loc is None:
                return None
            if hn.dot(n) > 0:
                return ((loc - p).length, loc, idx)
            o = loc + n * eps; left -= d + eps
            if left <= 0:
                return None
        return None
    def ray_pair(p, n, r):
        best = out_ray(p, n, r)                                                # inside the detailed surface: it is outward
        loc, hn, idx, d = rc(p + n * eps, -n, r)                               # outside it: it is inward
        if loc is not None and hn.dot(n) > 0 and (best is None or d < best[0]):
            best = (d, loc, idx)
        return best
    for k in range(len(P)):
        p = Vector(P[k]); n = Vector(N[k])
        best = ray_pair(p, n, reach)
        if best is not None:
            kinds[0] += 1
        else:
            # Pixal's walls are double: the nearest surface may be the inside wall (facing away, dark paint). Look further along
            # the normal, then for a nearest surface that faces the same way; failing both, the texel copies a good neighbour's hit
            best = ray_pair(p, n, far)
            how[k] = 1
            if best is None:
                how[k] = 2
                for off in (0.0, 0.5, 1.0, 2.0):                               # the nearest surface seen from a little outside
                    loc, hn, idx, d = fn(p + n * (reach * off), far)
                    if loc is not None and hn.dot(n) > 0:
                        best = ((loc - p).length, loc, idx)
                        break
                if best is None:
                    facing[k] = False
                    how[k] = 3
                    kinds[1] += 1
                    continue
            kinds[2] += 1
        hit_tri[k] = best[2]; hit_loc[k] = best[1]
    if __import__('os').environ.get('XFER_DEBUG'):                            # debug: each texel's game triangle, position, normal, kind
        np.savez(__import__('os').environ['XFER_DEBUG'], tri=tri_of[cov], P=P, N=N, facing=facing, how=how, cov=cov, hit=hit_tri, loc=hit_loc, tpos=L['pos'][L['tri']], tuv=L['uv'][L['tri']], tn=L['n'][L['tri']])
    lost = (hit_tri < 0) & ~facing                                             # only an away-facing wall was near: the paint of the
    good = np.nonzero(hit_tri >= 0)[0]                                         # nearest texel that found the right wall, in 3D
    if lost.any() and len(good):
        from mathutils.kdtree import KDTree
        kd = KDTree(len(good))
        for i, g in enumerate(good):
            kd.insert(P[g], i)
        kd.balance()
        for k in np.nonzero(lost)[0]:
            g = good[kd.find(P[k])[1]]
            hit_tri[k] = hit_tri[g]; hit_loc[k] = hit_loc[g]
    st['rayS'] = round(time.time() - t0, 1)
    ok = hit_tri >= 0
    st['nearestShare'] = round(float(kinds[2] / max(1, len(P))), 3)
    st['missShare'] = round(float((~ok).mean()), 3)
    st['backShare'] = round(float((~facing).mean()), 3)                      # texels only an away-facing wall was near
    if st['backShare'] > 0.05:
        st['warning'] = f"backShare {st['backShare']}: much of the game mesh found only the detailed model's inside wall; check the paint"

    # barycentric of each hit on the detailed triangle -> its UV, normal frame
    tv = co[htri_v[hit_tri[ok]]]
    v0, v1, v2 = tv[:, 0], tv[:, 1], tv[:, 2]
    e0, e1, ep = v1 - v0, v2 - v0, hit_loc[ok] - v0
    d00 = (e0 * e0).sum(1); d01 = (e0 * e1).sum(1); d11 = (e1 * e1).sum(1); d20 = (ep * e0).sum(1); d21 = (ep * e1).sum(1)
    den = d00 * d11 - d01 * d01 + 1e-30
    bv = (d11 * d20 - d01 * d21) / den; bw = (d00 * d21 - d01 * d20) / den
    hb = np.clip(np.stack([1 - bv - bw, bv, bw], 1), 0, 1); hb /= hb.sum(1, keepdims=True)
    huv = np.einsum('ij,ijk->ik', hb, H['uv'][H['tri'][hit_tri[ok]]])
    _, hn, ht, hbt = _frame(H, hit_tri[ok], hb)

    idx = np.argwhere(cov)[ok]
    flat = idx[:, 0] * size + idx[:, 1]
    fill = np.zeros(size * size, bool); fill[flat] = True
    src = grow(fill.reshape(size, size), margin)
    out = {}
    for key, img in hi_maps.items():
        s = _sample(img, huv)
        if key == 'normal':
            m = s[:, :3] * 2 - 1
            w = m[:, :1] * ht + m[:, 1:2] * hbt + m[:, 2:3] * hn                 # the detailed surface's shading normal, model space
            w /= np.linalg.norm(w, axis=1, keepdims=True) + 1e-12
            n, t, b = N[ok], T[ok], B[ok]
            ts = np.stack([(w * t).sum(1), (w * b).sum(1), (w * n).sum(1)], 1)
            ts[~facing[ok]] = (0, 0, 1)
            low = ts[:, 2] < 0.26
            ts[low, 2] = 0.26
            ts[low, :2] *= (np.sqrt(1 - 0.26 ** 2) / (np.linalg.norm(ts[low, :2], axis=1, keepdims=True) + 1e-12))
            st['steepShare'] = round(float(low.mean()), 3)
            s = np.concatenate([ts * 0.5 + 0.5, np.ones((len(w), 1))], 1)
        arr = np.zeros((size * size, 4), dtype=np.float32)
        arr[flat] = s
        bg = np.array([0.5, 0.5, 1.0, 1.0] if key == 'normal' else [0, 0, 0, 1], dtype=np.float32)
        arr = np.where((src >= 0).ravel()[:, None], arr[np.maximum(src, 0).ravel()], bg).reshape(size, size, 4)
        arr[..., 3] = 1
        out[key] = arr
    st['totalS'] = round(time.time() - t0, 1)
    return out, st
