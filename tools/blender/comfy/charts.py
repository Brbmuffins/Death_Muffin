# UVs the studio way for a game mesh: a few large charts instead of one island per triangle. Faces grow into charts while they face within <angle> of the
# chart's mean direction (cheapest first); charts under <min_faces> join the neighbour they face most like; seams go on chart borders; each chart is
# unwrapped (minimum stretch), scaled evenly and packed. A chart the solver cannot flatten (squashed to nothing, so it takes one texel's colour, or
# into a thin strip, so its paint streaks) is grown again into smaller charts at a tighter angle, or cut in two, and those are unwrapped the same way
# (an angle-based redo overlapped itself and smeared the paint in game; smart project shattered it into slivers). The charts are packed by xatlas
# (pylib/, its own charts cut the models into 3-4x more pieces for a few % more space, so only its packer is used): it fills about a quarter more of
# the texture than Blender's packer (helm 38 -> 47%, hound 29 -> 41%, mausoleum 46 -> 58% at 4 px apart on 1024), and Blender's is kept as the fallback.
import bpy, bmesh, heapq, math, os, sys, numpy as np

XATLAS = os.environ.get('DM_BLENDER_PYLIB') or os.path.join(os.path.dirname(os.path.realpath(bpy.app.binary_path)), 'pylib')   # tools/blender/comfy/setup.sh puts xatlas there


def squashed(o, chart, share=1e-3):
    """(edit mode) the charts whose UV area, for their surface area, is under <share> of the typical chart's"""
    bm = bmesh.from_edit_mesh(o.data); bm.faces.ensure_lookup_table()
    uvl = bm.loops.layers.uv.active
    nc = int(chart.max()) + 1
    a3, a2, nan = np.zeros(nc), np.zeros(nc), np.zeros(nc, bool)
    for f in bm.faces:
        c = chart[f.index]
        uv = np.array([l[uvl].uv[:] for l in f.loops])
        if not np.isfinite(uv).all():
            nan[c] = True; continue
        x, y = uv[:, 0], uv[:, 1]
        a2[c] += 0.5 * abs(np.dot(x, np.roll(y, -1)) - np.dot(y, np.roll(x, -1)))
        a3[c] += f.calc_area()
    used = a3 > 0
    ratio = np.where(used, a2 / np.maximum(a3, 1e-30), 0.0)
    typical = float(np.median(ratio[used])) if used.any() else 0.0
    return np.where(used & (nan | (ratio < share * typical)))[0]


def anisotropic(o, chart, limit=3.0, share=0.25):
    """(edit mode) the charts where more than <share> of the surface is stretched over <limit> x more one way than the other on the UVs (a chart
    flattened into a thin strip: the paint streaks)"""
    bm = bmesh.from_edit_mesh(o.data); bm.faces.ensure_lookup_table()
    uvl = bm.loops.layers.uv.active
    nc = int(chart.max()) + 1
    bad_a, tot_a = np.zeros(nc), np.zeros(nc)
    for f in bm.faces:
        ls = f.loops
        if len(ls) != 3:
            continue
        p0, p1, p2 = (np.array(l.vert.co[:]) for l in ls)
        e1, e2 = p1 - p0, p2 - p0
        n1 = np.linalg.norm(e1)
        area = 0.5 * np.linalg.norm(np.cross(e1, e2))
        if n1 < 1e-20 or area < 1e-20:
            continue
        x = e1 / n1; y = np.cross(np.cross(e1, e2), e1); y /= np.linalg.norm(y)
        P = np.array([[n1, e2 @ x], [0.0, e2 @ y]])                              # the triangle's edges in its own plane
        u0, u1, u2 = (np.array(l[uvl].uv[:]) for l in ls)
        U = np.stack([u1 - u0, u2 - u0], 1)
        try:
            J = U @ np.linalg.inv(P)
        except np.linalg.LinAlgError:
            continue
        sv = np.linalg.svd(J, compute_uv=False)
        c = chart[f.index]
        tot_a[c] += area
        if sv[1] <= 1e-12 * max(sv[0], 1e-30) or sv[0] / sv[1] > limit:
            bad_a[c] += area
    return np.where((tot_a > 0) & (bad_a > share * tot_a))[0]


def stretched(o, chart, which=None, mag=8.0, share=0.2):
    """(edit mode) the charts where more than <share> of the UV area sits on triangles blown up over <mag> x the typical UV-per-surface ratio
    (an angle-based unwrap of an awkward chart: a few triangles take most of its texture)"""
    bm = bmesh.from_edit_mesh(o.data); bm.faces.ensure_lookup_table()
    uvl = bm.loops.layers.uv.active
    nc = int(chart.max()) + 1
    fa2 = np.zeros(len(bm.faces)); fa3 = np.zeros(len(bm.faces))
    for f in bm.faces:
        uv = np.array([l[uvl].uv[:] for l in f.loops]); x, y = uv[:, 0], uv[:, 1]
        fa2[f.index] = 0.5 * abs(np.dot(x, np.roll(y, -1)) - np.dot(y, np.roll(x, -1)))
        fa3[f.index] = f.calc_area()
    tot2, tot3 = np.bincount(chart, fa2, nc), np.bincount(chart, fa3, nc)
    cr = tot2 / np.maximum(tot3, 1e-30)                                          # each chart's own ratio (its scale is its own until averaged)
    r = fa2 / np.maximum(fa3, 1e-30) / np.maximum(cr[chart], 1e-30)
    big = np.bincount(chart, fa2 * (r > mag), nc) / np.maximum(tot2, 1e-30)
    cand = np.arange(nc) if which is None else np.asarray(which)
    return cand[(tot3[cand] > 0) & (big[cand] > share)]


def select_charts(o, chart, which):
    bm = bmesh.from_edit_mesh(o.data); bm.faces.ensure_lookup_table()
    pick = np.isin(chart, which)
    for f in bm.faces:
        f.select_set(bool(pick[f.index]))
    bmesh.update_edit_mesh(o.data)


def grow(fn, fa, nbr, faces, angle, min_faces, first):
    """charts over <faces> (indices): grown while facing within <angle> of the chart's mean direction (cheapest first), neighbours only inside
    <faces>; charts under <min_faces> join the neighbour they face most like. Returns {face: label}, labels from <first>."""
    inside = set(int(f) for f in faces)
    lab = {}
    cos_lim = math.cos(math.radians(angle))
    sums = {}
    for seed in sorted(inside, key=lambda f: -fa[f]):
        if seed in lab:
            continue
        c = first + len(sums); lab[seed] = c; s = fn[seed] * fa[seed]
        heap = [(1 - fn[seed].dot(fn[j]), j) for j in nbr[seed] if j in inside and j not in lab]
        heapq.heapify(heap)
        while heap:
            _, j = heapq.heappop(heap)
            if j in lab:
                continue
            m = s / (np.linalg.norm(s) + 1e-12)
            if fn[j].dot(m) < cos_lim:
                continue
            lab[j] = c; s = s + fn[j] * fa[j]
            m = s / (np.linalg.norm(s) + 1e-12)
            for k in nbr[j]:
                if k in inside and k not in lab:
                    heapq.heappush(heap, (1 - fn[k].dot(m), k))
        sums[c] = s
    for _ in range(4):
        counts = {}
        for f, c in lab.items():
            counts[c] = counts.get(c, 0) + 1
        changed = False
        for c in [c for c, n in counts.items() if n < min_faces]:
            fs = [f for f, d in lab.items() if d == c]
            cand = {lab[k] for f in fs for k in nbr[f] if k in inside and lab[k] != c}
            if not cand:
                continue
            mc = sums[c] / (np.linalg.norm(sums[c]) + 1e-12)
            best = max(cand, key=lambda d: (sums[d] / (np.linalg.norm(sums[d]) + 1e-12)).dot(mc) + 1e-3 * counts.get(d, 0))
            for f in fs:
                lab[f] = best
            sums[best] = sums[best] + sums[c]; changed = True
        if not changed:
            break
    return lab


def halve(fc, fa, faces, first):
    """<faces> cut in two by the plane through their middle, across their longest spread"""
    p = fc[faces]; w = fa[faces]
    mid = (p * w[:, None]).sum(0) / max(w.sum(), 1e-30)
    axis = np.linalg.svd((p - mid) * np.sqrt(w)[:, None], full_matrices=False)[2][0]
    side = (p - mid) @ axis > 0
    return {int(f): first + int(sd) for f, sd in zip(faces, side)}


def set_seams(o, chart):
    bm = bmesh.from_edit_mesh(o.data)
    for e in bm.edges:
        lf = e.link_faces
        e.seam = len(lf) != 2 or chart[lf[0].index] != chart[lf[1].index]
    bmesh.update_edit_mesh(o.data)


def pack(o, size, padding):
    """(object mode) the UV charts packed by xatlas, rotated as needed, <padding> texels apart on a <size> texture, density kept. None if it could not"""
    if XATLAS not in sys.path:
        sys.path.insert(0, XATLAS)
    import xatlas
    me = o.data; me.calc_loop_triangles()
    lt = np.empty(len(me.loop_triangles) * 3, np.int64); me.loop_triangles.foreach_get('loops', lt); lt = lt.reshape(-1, 3)
    vi = np.empty(len(me.loops), np.int64); me.loops.foreach_get('vertex_index', vi)
    co = np.empty(len(me.vertices) * 3, np.float32); me.vertices.foreach_get('co', co); co = co.reshape(-1, 3)
    uvd = me.uv_layers.active.data
    uv = np.empty(len(uvd) * 2, np.float32); uvd.foreach_get('uv', uv); uv = uv.reshape(-1, 2)
    if not np.isfinite(uv).all():
        return None
    key = np.concatenate([vi[:, None], np.round(uv.astype(np.float64) * (1 << 24)).astype(np.int64)], 1)    # one corner per (vertex, uv)
    _, first, inv = np.unique(key, axis=0, return_index=True, return_inverse=True); inv = inv.ravel()
    at = xatlas.Atlas()
    at.add_mesh(co[vi[first]], inv[lt].astype(np.uint32), None, uv[first])
    c = xatlas.ChartOptions(); c.use_input_mesh_uvs = True
    p = xatlas.PackOptions(); p.resolution = size; p.padding = padding; p.bruteForce = True; p.rotate_charts = True; p.bilinear = True
    at.generate(c, p)
    vm, ind, out = (np.asarray(x) for x in at[0])
    ignored = np.asarray(at.get_mesh_vertex_assignment(0)[0]).astype(np.int64) >= at.atlas_count       # a face xatlas left out: atlas -1 (as uint32)
    if at.atlas_count != 1 or ind.size != lt.size or not np.isfinite(out).all() or ignored.any():
        return None
    new = np.empty_like(uv); new[lt.ravel()] = out[ind].reshape(-1, 2)
    uvd.foreach_set('uv', new.ravel())
    me.update()
    return {'packer': 'xatlas', 'used': round(float(at.utilization), 3), 'charts': int(at.chart_count)}


def make_charts(o, angle=60.0, min_faces=12, margin=0.005, report=None, levels=4, size=1024, padding=None):
    me = o.data
    bm = bmesh.new(); bm.from_mesh(me); bm.faces.ensure_lookup_table(); bm.edges.ensure_lookup_table()
    nf = len(bm.faces)
    fn = np.array([f.normal[:] for f in bm.faces]); fa = np.array([f.calc_area() for f in bm.faces])
    fc = np.array([f.calc_center_median()[:] for f in bm.faces])
    nbr = [[] for _ in range(nf)]
    for e in bm.edges:
        if len(e.link_faces) == 2:
            a, b = e.link_faces[0].index, e.link_faces[1].index
            nbr[a].append(b); nbr[b].append(a)
    bm.free()
    chart = np.full(nf, -1, dtype=np.int64)
    for f, c in grow(fn, fa, nbr, range(nf), angle, min_faces, 0).items():
        chart[f] = c
    bpy.ops.object.mode_set(mode='EDIT')
    # UV operators act on the UV selection, which is kept apart from the mesh's: after unwrapping only some charts the final pack would move only
    # those and leave the rest piled on top of each other. Synced, the mesh selection drives them
    bpy.context.scene.tool_settings.use_uv_select_sync = True
    set_seams(o, chart)
    bpy.ops.mesh.select_all(action='SELECT')
    bpy.ops.uv.unwrap(method='MINIMUM_STRETCH', fill_holes=True, correct_aspect=True, margin=0.0)
    refit = {'failed': 0, 'split': 0, 'smartProject': 0}
    bad = np.union1d(squashed(o, chart), anisotropic(o, chart))
    refit['failed'] = len(bad)
    refit['stretched'] = len(stretched(o, chart))                                # measured only: splitting those by smart project shattered the paint in game
    a = angle
    for level in range(levels):
        if not len(bad):
            break
        a *= 0.6
        new = []
        for c in bad:
            faces = np.where(chart == c)[0]
            first = int(chart.max()) + 1
            lab = grow(fn, fa, nbr, faces, a, max(2, min_faces // 3), first) if level < levels - 1 else {}
            if len(set(lab.values())) < 2:                                       # no tighter split by direction: cut it in two
                lab = halve(fc, fa, faces, first)
            for f, l in lab.items():
                chart[f] = l
            new += sorted(set(lab.values()))
            refit['split'] += 1
        set_seams(o, chart)
        select_charts(o, chart, np.array(new))
        bpy.ops.uv.unwrap(method='MINIMUM_STRETCH', fill_holes=True, correct_aspect=True, margin=0.0)
        bad = np.intersect1d(np.union1d(squashed(o, chart), anisotropic(o, chart)), np.array(new))
    sq = squashed(o, chart)
    if len(sq):                                                                  # last resort (squashed to nothing after every split), rare
        select_charts(o, chart, sq)
        bpy.ops.uv.smart_project(angle_limit=math.radians(66), island_margin=0.0, area_weight=0.0, correct_aspect=True, scale_to_bounds=False)
        refit['smartProject'] = len(sq)
    refit['stillSquashed'] = len(squashed(o, chart))
    refit['stillStreaky'] = len(anisotropic(o, chart))
    if report is not None:
        report['uvRefit'] = refit
    bpy.ops.mesh.select_all(action='SELECT')
    bpy.ops.uv.average_islands_scale()
    bpy.ops.object.mode_set(mode='OBJECT')
    if padding is None:                                                          # the gap between charts grows with the texture: the same mip
        padding = max(2, size // 256)                                            # level bleeds at every size (2 below 512, 4 at 1024)
    try:
        packed = pack(o, size, padding)
    except Exception as e:                                                       # a missing or failing xatlas: Blender packs instead
        packed = None; print('xatlas pack failed:', e)
    if packed is None:
        bpy.ops.object.mode_set(mode='EDIT')
        bpy.ops.mesh.select_all(action='SELECT')
        bpy.ops.uv.pack_islands(rotate=True, margin_method='FRACTION', margin=margin, shape_method='CONCAVE')
        bpy.ops.object.mode_set(mode='OBJECT')
        packed = {'packer': 'blender'}
    else:
        packed['padding'] = padding
    if report is not None:
        report['uvPack'] = packed
    return int(len(set(chart.tolist())))
