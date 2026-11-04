# The joints of a humanoid body found from its shape (no skeleton needed). The body becomes a solid in voxels, filled where the surface surrounds
# it on five of six sides (an open robe, sleeve or neck still reads as a body, not its skin), and each voxel gets its depth (the erosion steps it
# survives, i.e. its distance inside the surface). Limbs, spine and neck are then read along the depth ridge, the line of deepest voxels, which keeps
# to the body's middle front to back; a cape or a sleeve hanging free is a thin layer and never holds it. Proportions place what the shape cannot
# show (the elbow along the arm, the knee along the leg, the hand's length, the hip joints 0.048 of the height either side of the middle with the
# knee on the hip-ankle line, since a thigh's or robe's bulk is wider), the hip where a robe hides the legs (a crotch the shape puts outside 0.44
# to 0.56 of the height is a robe's slit or hem: the hip then sits at 0.555 of the height, the four Tripo-rigged heroes' 0.54 to 0.61), the
# shoulder joints 0.085 of the height out (sleeves and pauldrons hide where the arm meets the body), and the head where a hood or collar hides the
# neck. Mirrored pairs are made symmetric about the midline.
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
    solid, occ, lo, cell = solid_grid(co, tri, cells, 1, fill_open=True)
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
    # crotch: the lowest height (going up from the shins) where the midline holds depth comparable to a leg's for 0.02 of the height (one
    # voxel deeper on a robe's thin cloth is not one)
    def mid_holds(k):
        dl = max(leg_at(Z[k], 1)[1], leg_at(Z[k], -1)[1])
        dmid = D[:, jm - 1:jm + 2, k].max()
        return dl and dmid >= 0.6 * dl and dmid >= 3
    run = max(1, int(round(0.02 * H / cell)))
    zc = next((float(Z[k]) for k in range(zi(z0 + 0.2 * H), zi(z0 + 0.7 * H)) if all(mid_holds(k + i) for i in range(run))), None)
    rep['crotchFound'] = zc is not None and 0.44 * H <= zc - z0 <= 0.56 * H
    if zc is not None and not rep['crotchFound']:
        rep['crotchShape'] = round((zc - z0) / H, 3)                         # a robe's slit or a hem, not the legs
    if not rep['crotchFound']:
        zc = z0 + 0.49 * H
    rep['crotch'] = round((zc - z0) / H, 3)
    hipz = zc + 0.065 * H
    anklez = z0 + 0.045 * H
    kneez = anklez + 0.48 * (hipz - anklez)
    ahead = []                                                                  # each foot's share of its length ahead of the ankle
    rep['legEdge'] = {}
    sl = solid[:, :, :zi(z0 + 0.03 * H) + 1].any(2)                            # the soles' footprint (x, y)
    for side, p in ((1, 'L_'), (-1, 'R_')):
        # the hip joint sits 0.048 H out from the middle (Tripo's four heroes: 0.042-0.054); the lower body's side at that height (the
        # thigh's or the robe's, 0.12-0.2 H out on the four Pixal heroes), walked out from the half's ridge, bounds the leg's reach for the
        # weights (build_rig)
        top = leg_at(zc - 0.03 * H, side)[0]
        row = solid[:, :, zi(zc - 0.03 * H)].any(0)
        j = yi(top[1])
        while 0 <= j + side < ny and row[j + side]:
            j += side
        rep['legEdge'][p] = round(float(Y[j]), 4)
        half = Y > ymid if side > 0 else Y < ymid
        cnt = sl[:, half].sum(0)
        fy = float((cnt * Y[half]).sum() / cnt.sum()) if cnt.any() else float(leg_at(z0 + 0.09 * H, side)[0][1])
        # the foot: the soles' footprint round its middle; toe tip = most forward, ball = 72% from heel to toe, the ankle under the shin (the
        # leg's ridge from 0.1 to 0.3 of the height, its median; the ankle height's own ridge was a shoe's tip poking out under a hollow hem),
        # at least 0.12 of the foot ahead of the heel (Tripo's heroes: 0.12-0.38; a long robe's ridge put the Gravecaller's at the heel's back)
        sel = np.abs(Y - fy) < 0.05 * H
        xs = np.flatnonzero(sl[:, sel].any(1))
        heel, toe = X[xs.min()], X[xs.max()]
        shin = float(np.clip(np.median([leg_at(z0 + f * H, side)[0][0] for f in np.arange(0.1, 0.31, 0.02)]), heel + 0.12 * (toe - heel), toe))
        J[p + 'Thigh'] = np.array([top[0], ymid + side * 0.048 * H, hipz])
        J[p + 'Foot'] = np.array([shin, fy, anklez])
        J[p + 'Calf'] = leg_at(kneez, side)[0]
        ahead.append((toe - shin) / max(toe - heel, cell))
        J[p + 'Calf'][1] = J[p + 'Thigh'][1] + (hipz - kneez) / (hipz - anklez) * (fy - J[p + 'Thigh'][1])   # sideways on the hip-ankle line
        J[p + 'Calf'][2] = kneez
        J[p + 'ToeBase'] = np.array([heel + 0.72 * (toe - heel), fy, z0 + 0.018 * H])
        J[p + 'ToeEnd'] = np.array([toe, fy, z0 + 0.012 * H])

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
        # the shoulder joint sits 0.085 of the height out from the middle and 0.04 over the arm's line, the elbow halfway out on that line
        # (Tripo's four heroes: 0.077-0.093 out, 0.034-0.043 over the wrist found here, the elbow 0.45-0.53 of the way and level with the
        # wrist). The line is at the wrist's height: sleeves, pauldrons and a robed torso hide where the arm meets the body and move its ridge
        # up to 0.2 of the height up or down (where the ridge deepened put the shoulder 0.14-0.25 out on 7 of 8 heroes, at the elbow). An A
        # pose's wrist hangs far below, so the line is held at 0.76 of the height or more (Tripo's shoulders: 0.83; a hood makes a body taller)
        az = max(float(wr[2]), z0 + 0.76 * H)
        sh = on_line(ymid + side * 0.085 * H)
        sh[2] = az + 0.04 * H
        el = on_line(sh[1] + 0.5 * (wr[1] - sh[1]))
        el[2] = az + 0.5 * (wr[2] - az)
        arms[p] = {'points': len(line), 'line': round((az - z0) / H, 3)}
        tip = on_line(tip_y)
        J[p + 'Upperarm'], J[p + 'Forearm'], J[p + 'Hand'], J[p + 'HandEnd'] = sh, el, wr, tip
    rep['arms'] = arms

    # ---- spine, neck and head along the midline ridge
    def mid_ridge(z):
        k = zi(z)
        q, d = ridge_in(allx, slice(jm - 2, jm + 3), slice(max(0, k - 1), k + 2))
        return q, d
    shz = 0.5 * (J['L_Upperarm'][2] + J['R_Upperarm'][2]) - 0.04 * H                 # the arms' line
    neckz = shz + 0.025 * H                                                           # just under the shoulder joints (Tripo's: 0.01-0.02)
    # the neck: the shallowest midline ridge above the arms; the head pivots just above it
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
    top = float(Z[np.flatnonzero(D[:, jm - 3:jm + 4, :].max((0, 1)) >= 2).max()])
    # a hood, gorget or collar hides the neck, so the head is held between 0.17 of the height under the top and 0.06 over the arms' line
    # (the four Tripo-rigged heroes: 0.15 under the top, 0.02 over the shoulder joints)
    headz = min(max(neck_mid + 0.01 * H, neckz + 0.03 * H, top - 0.17 * H), shz + 0.06 * H)
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
    # Tripo's four heroes hold their joints 0.03 of the height ahead of the solid's middle (0.02-0.04: a cloak, hood or hair fills the back);
    # the feet are placed from the soles
    for k in J:
        if 'Foot' not in k and 'Toe' not in k:
            J[k][0] += 0.03 * H
    rep['feetAhead'] = round(float(np.mean(ahead)), 3)
    rep['neck'] = round((neck_mid - z0) / H, 3)
    rep['ymid'] = round(ymid, 4)
    return J, rep, dict(solid=solid, D=D, lo=lo, cell=cell)
