# The joints of a four-legged body from its shape (medial.py's branches): four paws on the floor, the snout and the tail end as the far tips, the
# spine as the deep path from the tail end to the snout, each leg as the deep path from the body down to its paw. Joints sit where the shape bends
# (a best-fit polyline on each leg: front leg 3 parts, hind leg 4 with the hock) and where the depth changes (the body ends, the neck narrows).
# Body: Z up, standing on the floor, facing `fwd` (the game frame of that creature).
import numpy as np
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from solid import solid_grid, _dilate
from landmarks import depth_map
from medial import graph, paths_from, path, tips, fit_polyline, resample

UP = np.array([0.0, 0.0, 1.0])
# length shares of the leg bones (top joint to toe tip), from a hand-placed hound skeleton: front shoulder-elbow, elbow-wrist, wrist-toe;
# hind hip-knee, knee-hock, hock-ball of the foot, ball-toe
FRONT = [0.43, 0.31, 0.26]
HIND = [0.34, 0.29, 0.20, 0.17]
HEAD_SHARE = 0.45


LEG_CLIMB_R = 0.1    # --leg-top over 0.5: a leg's region climbs at most this share of the height sideways from where it met the body
PELVIS_BACK = 0.15   # the pelvis reaches at most this share of the hips-to-shoulders span behind the hip joints (as the tailless fallback places it)


def find_quad(co, tri, fwd=(0, 1, 0), cells=160, top_share=0.45, leg_margin=0.06, leg_top=0.5):
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

    # the centre: the deepest voxels' middle, snapped to the nearest deepest voxel
    deep = np.where(dep >= dep.max() - 0.5)[0]
    src = int(deep[np.argmin(np.linalg.norm(P[deep] - P[deep].mean(0), axis=1))])
    dist_w, pred = paths_from(nb, src, 1.0 / np.maximum(dep, 1.0) ** 2)
    dist_g, _ = paths_from(nb, src, np.ones(len(vox)))
    dist_g = dist_g * cell                                                          # metres
    # branch lengths measured along the deep paths
    T = tips(vox, dep, dist_g, pred, min_branch=0.1 * H, start_share=0.1)
    rep['tips'] = len(T)

    def pts(node):
        return P[path(pred, node)]

    c = P[src]
    cand = [dict(node=t, len=L, p=P[t], f=float((P[t] - c) @ fwd), l=float((P[t] - c) @ lat)) for t, L, j in T]
    # ---- paws: the longest branch ending on the floor in each quarter (front/hind x left/right). Front and hind split half-way between the
    # foremost and hindmost floor tips, not at the centre: on a body whose deepest part is a big skull or collar the centre sits over the front legs
    floor = [t for t in cand if t['p'][2] <= z0 + 0.08 * H]
    mid = (max(t['f'] for t in floor) + min(t['f'] for t in floor)) / 2 if floor else 0.0
    rep['pawSplit'] = round(mid, 4)
    legs = {}
    for t in sorted(floor, key=lambda d: -d['len']):
        key = ('F' if t['f'] > mid else 'H') + ('L' if t['l'] > 0 else 'R')
        if key not in legs:
            legs[key] = t
    rep['cand'] = [(round(t['len'], 3), np.round(t['p'], 3).tolist(), round(t['f'], 3), round(t['l'], 3)) for t in cand]
    if len(legs) != 4:
        print('QCAND', rep['cand'], 'centre', np.round(c, 3).tolist(), 'z0', z0, 'H', H)
        raise SystemExit('quad: found paws %s, need FL FR HL HR' % sorted(legs))
    rest = [t for t in cand if all(t['node'] != v['node'] for v in legs.values())]
    head = max(rest, key=lambda d: d['f'])
    tails = [t for t in rest if t['f'] < 0 and t['len'] > 0.15 * H and t['node'] != head['node']]
    tail = min(tails, key=lambda d: d['f']) if tails else None
    rep['legsLen'] = {k: round(v['len'], 3) for k, v in legs.items()}
    rep['headLen'] = round(head['len'], 3)
    rep['tailLen'] = round(tail['len'], 3) if tail else None

    def smooth_line(p, k=2):
        if len(p) < 2 * k + 2:
            return p
        q = p.copy()
        for i in range(k, len(p) - k):
            q[i] = p[i - k:i + k + 1].mean(0)
        return q

    def depth_at(p):
        i = np.clip(np.floor((p - lo) / cell).astype(int), 0, np.array(D.shape) - 1)
        return D[i[..., 0], i[..., 1], i[..., 2]].astype(float)

    J = {}
    # ---- the spine line, tail end -> centre -> snout
    front = smooth_line(pts(head['node']))
    back = smooth_line(pts(tail['node']))[::-1] if tail else c[None]
    spine = resample(np.concatenate([back, front[1:]]), cell)
    sf = (spine - c) @ fwd
    sd = depth_at(spine)

    def spine_at(f):
        return spine[int(np.argmin(np.abs(sf - f)))]

    # ---- legs: deep path from the centre to the paw. Walking up from the paw, the leg ends where the depth first reaches 1.5x the leg's own
    # (its median over the lower half) and the body's share, and stays there. The leg's top joint sits halfway from there up to the spine line.
    tau = max(2.0, top_share * dep[src])
    tops, legnodes = {}, {}
    for k, t in legs.items():
        nodes_ = path(pred, t['node'])
        lp = smooth_line(P[nodes_], 1)
        d = depth_at(lp)
        rep.setdefault('legProf', {})[k] = [(round(float(z_), 3), int(d_)) for z_, d_ in zip(lp[::-3, 2], d[::-3])]
        up_ = d[::-1]                                                                 # paw -> centre
        zt = lp[::-1, 2]
        low = up_[zt < z0 + 0.5 * (zt.max() - z0)]
        need = max(tau, 1.5 * float(np.median(low)) if len(low) else tau)
        deep_ = np.convolve(up_ >= need, np.ones(3), 'same') >= 3                       # three in a row
        hit = np.where(deep_)[0]
        e = len(lp) - 1 - (int(hit[0]) - 1 if len(hit) else len(lp) // 2)
        e = int(np.clip(e, 0, len(lp) - 3))
        entry = lp[e]
        s = spine_at(float((entry - c) @ fwd))
        top = entry.copy()
        top[2] = entry[2] + leg_top * max(0.0, s[2] - entry[2])
        # leg_top over 0.5 (cloth hanging beside the legs or a hollow ribcage meets them low): the leg and its region start where its path
        # climbs to the top joint's height, so the upper thigh moves with the leg; only straight up the leg (within LEG_CLIMB_R of the height
        # above the entry), never along the path's turn into the body
        while leg_top > 0.5 and e > 0 and lp[e - 1, 2] <= top[2] and np.linalg.norm((lp[e - 1] - entry)[:2]) <= LEG_CLIMB_R * H:
            e -= 1
        rep.setdefault('legTopShare', {})[k] = round(float((top[2] - z0) / max(1e-6, s[2] - z0)), 3)
        line = resample(np.concatenate([top[None], lp[e:]]), cell)
        front_ = k[0] == 'F'
        ji = fit_polyline(line, 3 if front_ else 4, prior=FRONT if front_ else HIND)
        tops[k] = (entry, top)
        legnodes[k] = nodes_[e:]
        names = (['Upper', 'Lower', 'Paw'] if front_ else ['Thigh', 'Shin', 'Meta', 'Paw'])
        for n_, (a_, b_) in zip(names, zip(ji[:-1], ji[1:])):
            J[k + '_' + n_] = (line[a_], line[b_])
        rep.setdefault('legs', {})[k] = {'need': round(need, 1), 'entry': np.round(entry, 3).tolist(), 'joints': [np.round(line[i], 3).tolist() for i in ji]}

    # ---- body: hip joints and shoulder joints split the spine line; the pelvis starts where the tail leaves the body
    fh = float(np.mean([(tops[k][1] - c) @ fwd for k in ('HL', 'HR')]))
    fs = float(np.mean([(tops[k][1] - c) @ fwd for k in ('FL', 'FR')]))
    ih, i_s = int(np.argmin(np.abs(sf - fh))), int(np.argmin(np.abs(sf - fs)))
    if tail:
        it = next((i for i in range(ih - 1, -1, -1) if sd[i] < 0.5 * sd[ih]), max(0, ih - 1))
    else:
        it = int(np.argmin(np.abs(sf - (fh - 0.15 * (fs - fh)))))
    ip = max(0, min(it, ih - 1))
    # never further back than PELVIS_BACK of the hips-to-shoulders span behind the hip joints: a tail that hangs down as thick as a thin
    # (ribcage) body never halves the depth, and the pelvis would run down the tail
    back_f = fh - PELVIS_BACK * (fs - fh)
    ip = next((i for i in range(ip, ih) if sf[i] >= back_f), ip)
    rep['pelvisCapped'] = bool(ip > max(0, min(it, ih - 1)))
    # neck and head: a narrowing between the shoulders and the snout (depth falls, then rises again by 2 or more) marks the head joint;
    # without one (a mane, a thick neck), the head joint sits at HEAD_SHARE of the way from the shoulders to the snout
    end = len(spine) - 1
    prof = np.convolve(np.pad(sd, 2, mode='edge'), np.ones(5) / 5, 'valid')
    ihd = None
    lo_i, hi_i = i_s + int(0.25 * (end - i_s)), i_s + int(0.75 * (end - i_s))
    for i in range(max(i_s + 2, lo_i), min(end - 2, hi_i)):
        after = prof[i + 1:end].max()
        if prof[i] <= prof[i - 1] and prof[i] < prof[i + 1] and after >= max(prof[i] + 2, 1.25 * prof[i]):
            ihd = i
            break
    rep['headBy'] = 'narrowing' if ihd else 'share'
    if ihd is None:
        ihd = i_s + int(round(HEAD_SHARE * (end - i_s)))
    i_n2 = (i_s + ihd) // 2
    q1, q2, q3 = [ip + int(round(f * (i_s - ip))) for f in (0.25, 0.5, 0.75)]
    chain = [('Hip', ip, q1), ('Spine1', q1, q2), ('Spine2', q2, q3), ('Chest', q3, i_s), ('Neck1', i_s, i_n2), ('Neck2', i_n2, ihd), ('Head', ihd, end)]
    for n_, a_, b_ in chain:
        J[n_] = (spine[a_], spine[b_])
    rep['spineDepth'] = {'pelvis': int(sd[ip]), 'hips': int(sd[ih]), 'shoulders': int(sd[i_s]), 'head': int(sd[ihd])}
    # tail: four even parts from the pelvis start to the end
    if tail:
        tl = spine[:ip + 1][::-1]
        seg = np.linalg.norm(np.diff(tl, axis=0), axis=1)
        s_ = np.concatenate([[0], np.cumsum(seg)])
        cut = [int(np.argmin(np.abs(s_ - s_[-1] * q))) for q in (0, 0.25, 0.5, 0.75, 1.0)]
        for n_, a_, b_ in zip(['Tail_A', 'Tail_B', 'Tail_C', 'Tail_D'], cut[:-1], cut[1:]):
            J[n_] = (tl[a_], tl[b_])
    lab = np.full(len(vox), -1, np.int64)
    keys = sorted(legnodes)
    for i, k in enumerate(keys):
        lab[legnodes[k]] = i
    anc = np.where(pred >= 0, pred, np.arange(len(pred)))
    for _ in range(14):                                                            # pointer jumping: the first labelled node on the way to the centre
        need = lab < 0
        lab[need] = lab[anc[need]]
        anc = anc[anc]
    grow = max(1, int(round(leg_margin * H / cell)))
    regions = {}
    for i, k in enumerate(keys):
        m = np.zeros(solid.shape, bool)
        m[tuple(vox[lab == i].T)] = True
        for _ in range(grow):
            m = _dilate(m)
        regions[k] = m
        rep.setdefault('legShare', {})[k] = round(float((lab == i).mean()), 3)
    root = spine[ip].copy()
    root[2] = z0
    J['Root'] = (root, root + fwd * 0.15 * H)
    return J, rep, dict(solid=solid, D=D, lo=lo, cell=cell, spine=spine, fwd=fwd, lat=lat, src=P[src], legRegion=regions)
