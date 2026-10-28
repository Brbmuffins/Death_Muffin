# The joints of a humanoid body found from its shape (no skeleton needed). The body becomes a solid in voxels, and each voxel gets its depth (the
# erosion steps it survives, i.e. its distance inside the surface). Limbs, spine and neck are then read along the depth ridge, the line of deepest
# voxels: a sleeve, robe, cape or hood is a thin layer and never holds the ridge, so cloth does not pull the joints. Proportions place what the
# shape cannot show (the elbow along the arm, the knee along the leg, the hand's length). Mirrored pairs are made symmetric about the midline.
# Body: Z up, +X forward, +Y its left, feet on the floor (the caller straightens it). T or A pose.
import numpy as np
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from solid import solid_grid, _dilate


def depth_map(solid, most=60):
    """erosion steps each voxel survives (0 outside)"""
    d = np.zeros(solid.shape, np.int16)
    cur = solid.copy()
    for _ in range(most):
        d += cur
        cur = cur & ~_dilate(~cur)
        if not cur.any():
            break
    return d


def find(co, tri, cells=192):
    solid, occ, lo, cell = solid_grid(co, tri, cells, 1)
    D = depth_map(solid)
    z0 = float(co[:, 2].min())
    H = float(co[:, 2].max()) - z0
    nx, ny, nz = solid.shape
    X = lo[0] + (np.arange(nx) + 0.5) * cell
    Y = lo[1] + (np.arange(ny) + 0.5) * cell
    Z = lo[2] + (np.arange(nz) + 0.5) * cell
    zi = lambda z: int(np.clip(round((z - lo[2]) / cell - 0.5), 0, nz - 1))
    yi = lambda y: int(np.clip(round((y - lo[1]) / cell - 0.5), 0, ny - 1))
    rep = {'H': round(H, 4), 'cell': round(float(cell), 5)}
    J = {}

    # midline: depth-weighted mean y of the torso band
    band = (Z > z0 + 0.45 * H) & (Z < z0 + 0.75 * H)
    w = D[:, :, band].astype(float).sum((0, 2))
    ymid = float((w * Y).sum() / w.sum())
    jm = yi(ymid)

    def ridge_in(xs, ys, zs, frac=0.85):
        """mean position of the deepest voxels (>= frac of the max) in a box of index slices; (point, max depth)"""
        sub = D[xs, ys, zs]
        mx = sub.max()
        if mx <= 0:
            return None, 0
        idx = np.argwhere(sub >= max(1, frac * mx))
        p = np.array([X[xs][idx[:, 0]].mean(), Y[ys][idx[:, 1]].mean(), Z[zs][idx[:, 2]].mean()])
        return p, int(mx)

    allx = slice(0, nx)
    # ---- legs: per side and height, the ridge in that half
    def leg_at(z, side):
        k = zi(z)
        ys = slice(jm + 1, ny) if side > 0 else slice(0, jm)
        return ridge_in(allx, ys, slice(k, k + 1))
    # crotch: the lowest height (going up from the shins) where the midline holds depth comparable to a leg's
    zc = None
    for k in range(zi(z0 + 0.2 * H), zi(z0 + 0.7 * H)):
        dl = max(leg_at(Z[k], 1)[1], leg_at(Z[k], -1)[1])
        dmid = D[:, jm - 1:jm + 2, k].max()
        if dl and dmid >= 0.6 * dl and dmid >= 3:
            zc = float(Z[k])
            break
    rep['crotchFound'] = zc is not None
    if zc is None:
        zc = z0 + 0.46 * H
    rep['crotch'] = round((zc - z0) / H, 3)
    hipz = zc + 0.065 * H
    anklez = z0 + 0.045 * H
    kneez = anklez + 0.48 * (hipz - anklez)
    ahead = []                                                                  # each foot's share of its length ahead of the ankle
    for side, p in ((1, 'L_'), (-1, 'R_')):
        top = leg_at(zc - 0.03 * H, side)[0]
        J[p + 'Thigh'] = np.array([top[0], top[1], hipz])
        J[p + 'Calf'] = leg_at(kneez, side)[0]
        J[p + 'Calf'][2] = kneez
        an = leg_at(z0 + 0.09 * H, side)[0]
        J[p + 'Foot'] = np.array([an[0], an[1], anklez])
        # the foot: the solid's lowest 3% near the ankle; toe tip = most forward, ball = 72% from heel to toe
        sl = solid[:, :, :zi(z0 + 0.03 * H) + 1].any(2)
        sel = np.abs(Y - an[1]) < 0.05 * H
        xs = np.flatnonzero(sl[:, sel].any(1))
        heel, toe = X[xs.min()], X[xs.max()]
        ahead.append((toe - an[0]) / max(toe - heel, cell))
        J[p + 'ToeBase'] = np.array([heel + 0.72 * (toe - heel), an[1], z0 + 0.018 * H])
        J[p + 'ToeEnd'] = np.array([toe, an[1], z0 + 0.012 * H])

    # ---- arms: the depth ridge followed from the hand's end inward, one column of y at a time, staying within reach of the last point
    arms = {}
    for side, p in ((1, 'L_'), (-1, 'R_')):
        cols = [j for j in (range(ny - 1, jm, -1) if side > 0 else range(0, jm)) if D[:, j, zi(z0 + 0.4 * H):].max() > 0]
        cols = [j for j in cols if side * (Y[j] - ymid) > 0.1 * H]
        # start: over the outer 15% of the span, the height holding the most depth
        span = abs(Y[cols[0]] - ymid)
        outer = [j for j in cols if abs(Y[j] - ymid) > 0.8 * span]
        prof = D[:, outer, :].sum((0, 1)).astype(float)
        prof[:zi(z0 + 0.4 * H)] = 0
        zprev = float(Z[int(np.argmax(prof))])
        line = []
        for j in cols:
            ks = slice(zi(zprev - 0.035 * H), zi(zprev + 0.035 * H) + 1)
            q, d = ridge_in(allx, slice(j, j + 1), ks, 0.9)
            if q is None:
                continue
            line.append((q[0], q[1], q[2], d))
            zprev = q[2]
        line = np.array(line)                    # x, y, z, depth; from the hand end inward
        n = len(line)
        lat = np.abs(line[:, 1] - ymid)
        tipl = lat.max()
        mid = (lat > 0.35 * tipl) & (lat < 0.6 * tipl)
        da = float(np.median(line[mid, 3])) if mid.any() else float(np.median(line[:, 3]))
        k_e = next((i for i in range(n) if line[i, 3] >= 1.45 * da and lat[i] < 0.6 * tipl), n - 1)
        edge = line[k_e]
        sh = edge[:3].copy(); sh[1] -= side * 0.5 * da * cell
        # the hand's tip: the farthest solid near the line's end
        end = line[0]
        ks = slice(zi(end[2] - 0.05 * H), zi(end[2] + 0.05 * H) + 1)
        reach = np.flatnonzero(solid[:, :, ks].any((0, 2)))
        tip_y = Y[reach.max()] if side > 0 else Y[reach.min()]
        def on_line(y):
            i = int(np.argmin(np.abs(line[:, 1] - y)))
            return np.array([line[i, 0], y, line[i, 2]])
        hand_len = 0.10 * H
        wr = on_line(tip_y - side * hand_len)
        el = on_line(sh[1] + 0.55 * (wr[1] - sh[1]))
        tip = on_line(tip_y)
        J[p + 'Upperarm'], J[p + 'Forearm'], J[p + 'Hand'], J[p + 'HandEnd'] = sh, el, wr, tip
        arms[p] = {'armDepth': da, 'points': n, 'shoulderEdge': round(float(edge[1]), 4)}
    rep['arms'] = arms

    # ---- spine, neck and head along the midline ridge
    def mid_ridge(z):
        k = zi(z)
        q, d = ridge_in(allx, slice(jm - 2, jm + 3), slice(max(0, k - 1), k + 2))
        return q, d
    shz = 0.5 * (J['L_Upperarm'][2] + J['R_Upperarm'][2])
    neckz = shz - 0.015 * H
    # the neck: the shallowest midline ridge above the shoulders; the head pivots just above it
    zs = np.arange(shz + 0.02 * H, shz + 0.15 * H, cell)
    prof = np.array([mid_ridge(z)[1] for z in zs], float)
    sm = np.convolve(np.pad(prof, 1, mode='edge'), np.ones(3) / 3, 'valid')
    neck_mid = shz + 0.05 * H                                            # proportions, if the shape shows no neck
    for i in range(1, len(sm) - 3):                                      # the first narrowing going up that the next three steps climb out of
        if sm[i] <= sm[:i].min() and sm[i + 1:i + 4].min() > sm[i] and sm[i + 3] >= sm[i] + 0.6:
            plateau = np.flatnonzero(np.abs(sm[:i + 1] - sm[i]) < 0.34)
            neck_mid = float(zs[plateau].mean())
            break
    rep['neckProf'] = [int(d) for d in prof]
    headz = max(neck_mid + 0.01 * H, neckz + 0.03 * H)
    top = float(Z[np.flatnonzero(D[:, jm - 3:jm + 4, :].max((0, 1)) >= 2).max()])
    for name, z in (('Hip', hipz), ('Spine01', hipz + 0.21 * (neckz - hipz)), ('Spine02', hipz + 0.63 * (neckz - hipz)),
                    ('NeckTwist01', neckz), ('NeckTwist02', neckz + 0.7 * (headz - neckz)), ('Head', headz), ('HeadEnd', top)):
        q = mid_ridge(z)[0]
        J[name] = np.array([q[0], ymid, z])
    J['Hip'][0] = 0.5 * (J['L_Thigh'][0] + J['R_Thigh'][0])
    for side, p in ((1, 'L_'), (-1, 'R_')):
        J[p + 'Clavicle'] = np.array([J['NeckTwist01'][0], ymid + side * 0.02 * H, neckz])

    # ---- mirror pairs onto one shape (same height, depth and distance from the midline)
    for k in [k for k in J if k.startswith('L_')]:
        l, r = J[k], J['R_' + k[2:]]
        x, z = 0.5 * (l[0] + r[0]), 0.5 * (l[2] + r[2])
        off = 0.5 * ((l[1] - ymid) + (ymid - r[1]))
        J[k] = np.array([x, ymid + off, z])
        J['R_' + k[2:]] = np.array([x, ymid - off, z])
    rep['feetAhead'] = round(float(np.mean(ahead)), 3)
    rep['neck'] = round((neck_mid - z0) / H, 3)
    rep['ymid'] = round(ymid, 4)
    return J, rep, dict(solid=solid, D=D, lo=lo, cell=cell)
