# The joints of a many-legged body from its shape (medial.py's branches): a spider's eight legs, or any number of legs around one body. Every long
# branch that ends on the floor is a leg (short ones near the front, a spider's pedipalps, stay with the head); legs are named by side and counted
# from the front (L1 is the front left leg). The body line runs from the rear end through the deepest point to the front end; the waist (the
# narrowest place between the leg roots and the abdomen) splits it into the Hip (the body the legs hang on, from the waist past the leg
# roots), the Head (on to the front end) and the Abdomen (Abdomen, Abdomen_End: back to the rear end). Each leg runs from where it leaves the
# body to its tip in three bones (Upper up to the knee, Lower down to the ankle, Foot to the tip) placed where the leg bends. A leg's side is the
# side its tip is on, its number counts the legs of that side by the way they point, front first.
# Body: Z up, standing on the floor, facing `fwd` (the game frame of that creature).
import numpy as np
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from solid import solid_grid, _dilate
from landmarks import depth_map
from medial import graph, paths_from, path, tips, fit_polyline, resample
UP = np.array([0.0, 0.0, 1.0])
LEG = [0.36, 0.34, 0.30]   # length shares of a leg's bones (root to knee, knee to ankle, ankle to tip), a spider's: the femur, the patella and tibia, the rest
FLOOR = 0.1                # a leg's tip lies within this share of the height of the floor
LEG_MIN = 0.5              # a floor branch is a leg when it is at least this share of the median of the longest ones (a pedipalp is shorter)


def smooth_line(p, k=2):
    if len(p) < 2 * k + 2:
        return p
    q = p.copy()
    for i in range(k, len(p) - k):
        q[i] = p[i - k:i + k + 1].mean(0)
    return q


def find_legs(co, tri, fwd=(0, 1, 0), cells=160, top_share=0.45, leg_margin=0.04):
    fwd = np.array(fwd, float)
    fwd[2] = 0
    fwd /= np.linalg.norm(fwd)
    lat = np.cross(UP, fwd)                                                         # the body's left
    solid, occ, lo, cell = solid_grid(co, tri, cells, 1)
    D = depth_map(solid)
    z0 = float(co[:, 2].min())
    H = float(co[:, 2].max()) - z0
    vox, idx, nb = graph(solid)
    P = lo + (vox + 0.5) * cell
    dep = D[tuple(vox.T)].astype(float)
    rep = {'H': round(H, 4), 'cell': round(float(cell), 5), 'nodes': len(vox), 'maxDepth': int(dep.max())}
    deep = np.where(dep >= dep.max() - 0.5)[0]
    src = int(deep[np.argmin(np.linalg.norm(P[deep] - P[deep].mean(0), axis=1))])
    _, pred = paths_from(nb, src, 1.0 / np.maximum(dep, 1.0) ** 2)
    dist_g, _ = paths_from(nb, src, np.ones(len(vox)))
    dist_g = dist_g * cell
    T = tips(vox, dep, dist_g, pred, min_branch=0.1 * H, start_share=0.05)
    c = P[src]
    cand = [dict(node=t, len=L, p=P[t], f=float((P[t] - c) @ fwd), l=float((P[t] - c) @ lat)) for t, L, j in T]
    rep['cand'] = [(round(t['len'], 3), np.round(t['p'], 3).tolist()) for t in cand]
    floor = sorted([t for t in cand if t['p'][2] <= z0 + FLOOR * H], key=lambda d: -d['len'])
    if len(floor) < 4:
        raise SystemExit('legs: %d branches reach the floor, need at least 4' % len(floor))
    ref = float(np.median([t['len'] for t in floor[:8]]))
    legs_ = [t for t in floor if t['len'] >= LEG_MIN * ref]
    rep['short'] = [round(t['len'], 3) for t in floor if t['len'] < LEG_MIN * ref]

    def depth_at(p):
        i = np.clip(np.floor((p - lo) / cell).astype(int), 0, np.array(D.shape) - 1)
        return D[i[..., 0], i[..., 1], i[..., 2]].astype(float)

    # ---- each leg: the deep path from the centre to its tip. Walking up from the tip, the leg ends where the depth first reaches its own
    # thickness (the 90th percentile over the tip-most 60% of the path: a spider's femur is thicker than its foot) plus 2 voxels and 1.4x it,
    # three voxels in a row, and stays there; never deeper than the body's share (top_share of the deepest point)
    tau = max(3.0, top_share * dep[src])
    found = []
    for t in legs_:
        nodes_ = path(pred, t['node'])
        lp = smooth_line(P[nodes_], 1)
        up_ = depth_at(lp)[::-1]                                                     # tip -> centre
        own = float(np.percentile(up_[:max(3, int(0.6 * len(up_)))], 90))
        need = min(tau, max(own + 2, 1.4 * own))
        deep_ = np.convolve(up_ >= need, np.ones(3), 'same') >= 3
        hit = np.where(deep_)[0]
        e = len(lp) - 1 - (int(hit[0]) - 1 if len(hit) else len(lp) // 2)
        e = int(np.clip(e, 0, len(lp) - 3))
        found.append(dict(t, nodes=nodes_[e:], line=resample(lp[e:], cell), entry=lp[e], ef=float((lp[e] - c) @ fwd), el=float((lp[e] - c) @ lat),
                          need=need))
    # sides and order seen from the middle of the leg roots (where the legs hang on the body, not the deepest point, which is often the
    # abdomen): a leg's side is where its tip lies, its place the way it points (front legs point forward)
    J, names = {}, {}
    hub = np.mean([g['entry'] for g in found], 0)
    for g in found:
        v = g['p'] - hub
        g['side'], g['angle'] = float(v @ lat), float(np.arctan2(v @ fwd, abs(v @ lat)))
    for side, sign in (('L', 1), ('R', -1)):
        mine = sorted([g for g in found if np.sign(g['side']) == sign], key=lambda g: -g['angle'])
        for i, g in enumerate(mine):
            k = '%s%d' % (side, i + 1)
            ji = fit_polyline(g['line'], 3, prior=LEG)
            for n_, (a_, b_) in zip(('Upper', 'Lower', 'Foot'), zip(ji[:-1], ji[1:])):
                J[k + '_' + n_] = (g['line'][a_], g['line'][b_])
            names[k] = g
            rep.setdefault('legs', {})[k] = {'len': round(g['len'], 3), 'need': round(g['need'], 1), 'entry': np.round(g['entry'], 3).tolist(), 'joints': [np.round(g['line'][i], 3).tolist() for i in ji]}
    rep['legCount'] = {'L': sum(1 for k in names if k[0] == 'L'), 'R': sum(1 for k in names if k[0] == 'R')}

    # ---- the body: every voxel whose way to the centre crosses no leg. Its line runs rear end -> centre -> front end (deep paths), the waist is
    # its narrowest place between the leg roots and the centre (or the deepest part, when that is ahead of the legs)
    lab = np.full(len(vox), -1, np.int64)
    keys = sorted(names)
    for i, k in enumerate(keys):
        lab[names[k]['nodes']] = i
    anc = np.where(pred >= 0, pred, np.arange(len(pred)))
    for _ in range(14):
        need_ = lab < 0
        lab[need_] = lab[anc[need_]]
        anc = anc[anc]
    # the body line's ends: its front-most and rear-most points near the midline, thin parts (a spider's pedipalps and fangs, which the Head carries)
    # left out
    body = np.where((lab < 0) & (dep >= max(3.0, 0.25 * dep.max())))[0]
    bf = (P[body] - c) @ fwd
    mid = np.abs((P[body] - c) @ lat) <= 0.15 * H
    front_n = int(body[mid][np.argmax(bf[mid])]) if mid.any() else int(body[np.argmax(bf)])
    rear_n = int(body[mid][np.argmin(bf[mid])]) if mid.any() else int(body[np.argmin(bf)])
    line = resample(np.concatenate([smooth_line(P[path(pred, rear_n)])[::-1], smooth_line(P[path(pred, front_n)])[1:]]), cell)
    lf = (line - c) @ fwd
    ld = depth_at(line)
    roots_f = float(np.mean([g['ef'] for g in names.values()]))
    i_root = int(np.argmin(np.abs(lf - roots_f)))
    i_c = int(np.argmin(np.abs(lf)))
    if i_c < i_root:                                                                # the deepest part (the abdomen) lies behind the leg roots
        win = slice(i_c, i_root + 1)
        i_waist = i_c + int(np.argmin(np.convolve(np.pad(ld[win], 1, mode='edge'), np.ones(3) / 3, 'valid')))
    else:
        i_waist = max(0, i_root - max(2, (i_root - 0) // 4))
    i_waist = int(np.clip(i_waist, 1, i_root - 1 if i_root > 1 else 1))
    end, i_head = len(line) - 1, i_root + max(1, (len(line) - 1 - i_root) // 3)
    i_ab = i_waist // 2
    J['Hip'] = (line[i_waist], line[i_head])
    J['Head'] = (line[i_head], line[end])
    J['Abdomen'] = (line[i_waist], line[i_ab])
    J['Abdomen_End'] = (line[i_ab], line[0])
    rep['body'] = {'waist': np.round(line[i_waist], 3).tolist(), 'roots': np.round(line[i_root], 3).tolist(), 'front': np.round(line[end], 3).tolist(),
                   'rear': np.round(line[0], 3).tolist(), 'waistDepth': int(ld[i_waist]), 'rootDepth': int(ld[i_root])}
    ax = line[end] - line[0]
    rep['body']['yawFix'] = round(-float(np.degrees(np.arctan2(ax @ lat, ax @ fwd))), 1)    # degrees to add to the frame's yaw so the body line faces fwd
    grow = max(1, int(round(leg_margin * H / cell)))
    regions = {}
    for i, k in enumerate(keys):
        m = np.zeros(solid.shape, bool)
        m[tuple(vox[lab == i].T)] = True
        for _ in range(grow):
            m = _dilate(m)
        regions[k] = m
        rep.setdefault('legShare', {})[k] = round(float((lab == i).mean()), 3)
    root = line[i_waist].copy()
    root[2] = z0
    J['Root'] = (root, root + fwd * 0.15 * H)
    parent = {'Root': None, 'Hip': 'Root', 'Head': 'Hip', 'Abdomen': 'Hip', 'Abdomen_End': 'Abdomen'}
    for k in keys:
        parent.update({k + '_Upper': 'Hip', k + '_Lower': k + '_Upper', k + '_Foot': k + '_Lower'})
    return J, parent, rep, dict(lo=lo, cell=cell, fwd=fwd, lat=lat, legRegion=regions, legs=keys)
