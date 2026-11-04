# blender -b --python finish.py -- <detailed.glb> <out.glb> <triangles> [--method solid|meshopt] [--metal none|mixed|all|keep] [--hard] [--angle 40]
#   [--part-scale 1.5] [--part-tris 0.3] [--tex 1024] [--bake N] [--reach 0.03] [--cells 256] [--calm N] [--metal-regions <json>] [--keep-regions <json>] [--report <json>]
# The game version of a detailed model (a Pixal3D model at ~200k faces), the studio way: a new mesh at <triangles>, fresh UVs in a few large charts, and the
# detailed model's paint, shine and surface detail moved onto it (transfer.py). --method:
#   solid     (default) the detailed surface into voxels (<cells> across), pinholes closed, everything the outside cannot reach filled (solid.py): hollow
#             skins become walls and noise tunnels close, so the shrink can reach the budget; then edge collapse, and each corner within 2 voxels of the
#             detailed surface moved onto it
#   meshopt   the welded detailed surface itself cut down by meshoptimizer (shrink.mjs: edge collapse that refuses folds and moves the kept corners to
#             where they hold the shape best); a hero's face and skulls keep their shape at 20k triangles where Blender's collapse folded them into
#             spikes (Gravecaller, 2026-11-03). Each group shrinks to its own share: the keep boxes and the rest, or a body's close-up parts and the body
# The shrink spends triangles where removing them would change the shape most, so Pixal's wobble on flat walls costs triangles the ornaments need, and a thin
# bar costs little to flatten (its error is small because it is thin). --calm N: the rebuilt surface's wobble calmed first (N rounds of bilateral normal
# filtering, real edges kept: surface.py denoise), default 4: on the fence, hound, helm and mausoleum masters (2026-10-27) 4 rounds gave the closest outline
# and paint at the same triangles, 8 and 16 less; 0 turns it off. Protecting thin parts and sharp bends from the shrink (a decimate vertex group) gained nothing
# at any strength: the shrink's own error measure already keeps them.
# --metal (the asset's material decides): none = stone, bone, wood, cloth, flesh (no metal); mixed = metal decided per material (metal.py: Pixal paints each
# material its own roughness; a material is metal where Pixal's metal on it is high and sure and its colour reads as metal), so the fence's stone is never
# patchy iron; all = by colour alone (grey, or gold/brass); keep = as Pixal made it. --metal-regions: where the metal is when Pixal marks the whole model
# metal ({"boxes": [[x0, y0, z0, x1, y1, z1], ...], "rough": 0.5}, shares of the model's size; metal.py by_regions); without it such a model gets none. --hard: sharp edges kept (smooth by angle, --angle degrees). --reach: how far the transfer looks, share of the height.
# --keep-regions: parts the shrink takes last (or, holding more than their share after a plain cut, first), so they keep that share of the triangles (a creature's open jaw and teeth): {"boxes": [[x0, y0, z0, x1, y1, z1],
# ...], "frame": "<xform.json>", "share": 0.3}; boxes are shares of the detailed model's size in the frame its xform.json moves it to (the game's placement,
# so one box fits every version of a creature), or its own frame without "frame"; share = the boxes' share of the finished triangles. Blender's decimate
# vertex group (0.05 on the side kept, 1 on the other; never 0, which Blender never shrinks at all) with its strength searched until the boxes hold that share (within
# 0.02): the same strength gives the hound's head 15% of the triangles on a 256 rebuild and 8% on a 512 one, so a fixed strength means nothing.
# A detailed model of several materials (a body with close-up parts joined on, parts.py): every material's paint is moved, no chart crosses from the
# body onto a part, and the parts' charts are drawn --part-scale (default 1.5) times larger, so the face and the skulls keep the detail their close-ups
# carry (2.25x the texels, the body packed a little smaller), and the cut leaves the parts --part-tris (default 0.3) of the triangles (0: the cut decides;
# keep boxes, when given, decide instead). A rigid part's corners (armour, parts.py) are numbered by piece in the _DM_RIGID attribute for the rig.
# --tex: the texture size. The paint is moved at up to 4x that (at most 2048) and averaged down, so a 512 texture is each 4x4 block's mean, not one
# point's colour (the UV gutters are packed for the final size; 2048 over 1024 gave visibly cleaner edges on a 512 hound, ~50 s more). --bake: the size
# it is moved at instead (a whole multiple of --tex).
import bpy, bmesh, sys, os, math, json, time, tempfile, shutil, subprocess
import numpy as np
from mathutils import Vector
from mathutils.bvhtree import BVHTree

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from solid import solid_rebuild
from charts import make_charts
from transfer import transfer, image_array, _loops, _raster
from metal import metal_by_material, metal_colour
from surface import denoise

a = sys.argv[sys.argv.index('--') + 1:]
HI, OUT, TARGET = a[0], a[1], int(a[2])


def opt(name, default, cast=float):
    return cast(a[a.index(name) + 1]) if name in a else default


METHOD = opt('--method', 'solid', str)
METAL = opt('--metal', 'mixed', str)
HARD = '--hard' in a
ANGLE = opt('--angle', 40.0)
TEX = opt('--tex', 1024, int)
BAKE = opt('--bake', max(TEX, min(TEX * 4, 2048)), int)
if BAKE < TEX or BAKE % TEX:
    sys.exit('--bake must be a whole multiple of --tex')
REACH = opt('--reach', 0.03)
CELLS = opt('--cells', 256, int)
REPORT = opt('--report', '', str)
CALM = opt('--calm', 4, int)
REGIONS = opt('--metal-regions', '', str)
PART_SCALE = opt('--part-scale', 1.5)
PART_TRIS = opt('--part-tris', 0.3)
KEEP = json.load(open(opt('--keep-regions', '', str))) if '--keep-regions' in a else None
t0 = time.time()
rep = {'method': METHOD, 'target': TARGET, 'hard': HARD, 'tex': TEX, 'bake': BAKE, 'metal': METAL, 'calm': CALM}

for o in list(bpy.data.objects):
    bpy.data.objects.remove(o, do_unlink=True)


def select_only(*objs, active=None):
    bpy.ops.object.select_all(action='DESELECT')
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = active or objs[0]


def tris(o):
    return sum(len(p.vertices) - 2 for p in o.data.polygons)


def apply_mod(o, **kw):
    m = o.modifiers.new('m', kw.pop('kind'))
    for k, v in kw.items():
        setattr(m, k, v)
    select_only(o)
    bpy.ops.object.modifier_apply(modifier=m.name)


def collapse_to(o, n):
    t = tris(o)
    if t > n:
        apply_mod(o, kind='DECIMATE', decimate_type='COLLAPSE', ratio=n / t, use_collapse_triangulate=True)


def arrays(o):
    """(corners Nx3, triangles Mx3) of a mesh"""
    me = o.data
    V = np.empty(len(me.vertices) * 3); me.vertices.foreach_get('co', V)
    me.calc_loop_triangles()
    F = np.empty(len(me.loop_triangles) * 3, np.int64); me.loop_triangles.foreach_get('vertices', F)
    return V.reshape(-1, 3), F.reshape(-1, 3)


def calm(o, rounds, size):
    """the rebuilt surface's wobble calmed (bilateral normal filtering; real edges stay), so the shrink sees flat walls as flat"""
    V, F = arrays(o)
    W = denoise(V, F, rounds, 0.35, 20)
    o.data.vertices.foreach_set('co', W.astype(np.float32).ravel()); o.data.update()
    mv = np.linalg.norm(W - V, axis=1) / size
    return {'rounds': rounds, 'movedMean': round(float(mv.mean()), 5), 'movedP99': round(float(np.percentile(mv, 99)), 5)}


def in_regions(P, regions, ref):
    """which of the points P are inside the regions' boxes (shares of the reference points' size, both in the regions' frame)"""
    X = np.array(json.load(open(regions['frame']))['matrix']) if regions.get('frame') else np.eye(4)
    P, ref = P @ X[:3, :3].T + X[:3, 3], ref @ X[:3, :3].T + X[:3, 3]
    lo, sz = ref.min(0), np.maximum(ref.max(0) - ref.min(0), 1e-9)
    S = (P - lo) / sz
    inside = np.zeros(len(P), bool)
    for b in regions['boxes']:
        inside |= np.all((S >= b[:3]) & (S <= b[3:]), axis=1)
    return inside


def collapse_keeping(o, n, want, within, tol=0.02, tries=10):
    """edge collapse to <n> triangles with <want> of them on the corners `within` (points -> bool) takes: a plain cut first; when it leaves them
    fewer, their corners are taken last (a creature's jaw, a hero's face), when more, the rest's are (close-up parts denser than the body); the
    vertex group's strength searched (doubling, then halving the gap in log steps) until the share is within <tol>; the closest try is kept"""
    V, F = arrays(o)
    if len(F) <= n:
        return {}
    inside = within(V)
    src, log = o.data, []

    def attempt(f):
        t = bpy.data.objects.new('try', src.copy())
        bpy.context.scene.collection.objects.link(t)                    # the mesh's copy carries the vertex group (Blender keeps their names on it)
        kw = dict(vertex_group='keep', vertex_group_factor=f) if f else {}
        apply_mod(t, kind='DECIMATE', decimate_type='COLLAPSE', ratio=n / len(F), use_collapse_triangulate=True, **kw)
        Vt, Ft = arrays(t)
        got = float(within(Vt[Ft].mean(1)).mean())
        log.append([round(f, 3), round(got, 3)])
        return t, got

    best = attempt(0.0)
    plain = best[1]
    if abs(plain - want) > tol:
        keep_in = want > plain                                          # the side whose corners go last
        g = o.vertex_groups.new(name='keep')
        g.add(np.nonzero(~inside if keep_in else inside)[0].tolist(), 1.0, 'REPLACE')
        g.add(np.nonzero(inside if keep_in else ~inside)[0].tolist(), 0.05, 'REPLACE')
        lo_f, hi_f, f = None, None, 1.0
        for _ in range(tries - 1):
            t, got = attempt(f)
            if abs(got - want) < abs(best[1] - want):
                bpy.data.objects.remove(best[0], do_unlink=True)
                best = (t, got)
            else:
                bpy.data.objects.remove(t, do_unlink=True)
            if abs(got - want) <= tol:
                break
            if (got < want) == keep_in:                                 # not far enough: stronger
                lo_f = f
            else:
                hi_f = f
            f = math.sqrt(lo_f * hi_f) if lo_f is not None and hi_f is not None else (f * 8 if hi_f is None else f / 8)
            if f > 1000:                                                # Blender's limit
                break
    old = o.data
    o.data = best[0].data
    bpy.data.objects.remove(best[0], do_unlink=True)
    bpy.data.meshes.remove(old)
    for vg in list(o.vertex_groups):
        o.vertex_groups.remove(vg)
    return {'share': want, 'plain': round(plain, 3), 'cornersIn': round(float(inside.mean()), 3), 'tries': log}


def drop_specks(o, share=1e-4, float_share=0.02, gap=0.015):
    """loose pieces under <share> of the whole surface (single triangles the rebuild leaves floating): invisible, but each would get a full-size
    UV island (no area to scale it by) and take ~5% of the texture. Also floaters: pieces under <float_share> of the surface whose nearest point is
    more than <gap> of the model's size from everything else (a scrap Pixal leaves hanging in the air beside a helm; eyes in their sockets stay)"""
    bm = bmesh.new(); bm.from_mesh(o.data); bm.faces.ensure_lookup_table()
    seen, parts = set(), []
    for f in bm.faces:
        if f.index in seen:
            continue
        stack, mem = [f], []
        seen.add(f.index)
        while stack:
            g = stack.pop(); mem.append(g)
            for e in g.edges:
                for h in e.link_faces:
                    if h.index not in seen:
                        seen.add(h.index); stack.append(h)
        parts.append(mem)
    total = sum(f.calc_area() for f in bm.faces)
    area = [sum(f.calc_area() for f in p) for p in parts]
    gone = [f for p, a in zip(parts, area) if a < share * total for f in p]
    vs = [v.co for v in bm.verts]
    size = (Vector([max(c[i] for c in vs) for i in range(3)]) - Vector([min(c[i] for c in vs) for i in range(3)])).length if vs else 0
    for i, (p, a) in enumerate(zip(parts, area)):
        if share * total <= a < float_share * total and len(parts) > 1:
            mine = {f.index for f in p}
            rest = [f for f in bm.faces if f.index not in mine]
            tree = BVHTree.FromPolygons([v.co for v in bm.verts], [[v.index for v in f.verts] for f in rest])
            near = min((tree.find_nearest(v.co)[3] for f in p for v in f.verts), default=0)
            if near is not None and near > gap * size:
                gone += p
    if gone:
        bmesh.ops.delete(bm, geom=gone, context='FACES')
    bm.to_mesh(o.data); bm.free()
    return len(gone)


def fix_degenerate(o, size, q_min=0.01, passes=4):
    """triangles with (almost) no area: the corner snap can stack corners or put three in a line. The unwrap blows such a triangle up over its
    neighbours' UVs and the paint pass gives it one point's colour, which then shows on the neighbours as a flat patch. A needle (one edge far
    shorter than the others) loses that edge; a cap (three corners in a line) has its long edge turned, which keeps the shape exactly."""
    bm = bmesh.new(); bm.from_mesh(o.data)
    bmesh.ops.dissolve_degenerate(bm, dist=size * 1e-4, edges=bm.edges[:])
    bmesh.ops.triangulate(bm, faces=bm.faces[:])
    fixed = 0
    for _ in range(passes):
        bad = []
        for f in bm.faces:
            es = sorted(f.edges, key=lambda e: e.calc_length())
            ss = sum(e.calc_length() ** 2 for e in es)
            if ss > 0 and 4 * math.sqrt(3) * f.calc_area() / ss < q_min:
                bad.append((f, es))
        if not bad:
            break
        for f, es in bad:
            if not f.is_valid or any(not e.is_valid for e in es):
                continue
            if es[0].calc_length() < 0.05 * es[2].calc_length():
                bmesh.ops.collapse(bm, edges=[es[0]])
                fixed += 1
            elif len(es[2].link_faces) == 2 and bmesh.utils.edge_rotate(es[2], True) is not None:
                fixed += 1
        bmesh.ops.dissolve_degenerate(bm, dist=size * 1e-4, edges=bm.edges[:])
        bmesh.ops.triangulate(bm, faces=bm.faces[:])
    left = 0
    for f in bm.faces:
        ss = sum(e.calc_length() ** 2 for e in f.edges)
        left += ss > 0 and 4 * math.sqrt(3) * f.calc_area() / ss < q_min
    bm.to_mesh(o.data); bm.free()
    return {'fixed': fixed, 'left': int(left)}


# ---- the detailed model, one object
bpy.ops.import_scene.gltf(filepath=HI)
meshes = [o for o in bpy.data.objects if o.type == 'MESH']
if len(meshes) > 1:
    select_only(*meshes)
    bpy.ops.object.join()
hi = [o for o in bpy.data.objects if o.type == 'MESH'][0]
for o in list(bpy.data.objects):
    if o is not hi and o.type != 'MESH':
        bpy.data.objects.remove(o, do_unlink=True)
select_only(hi)
bpy.ops.object.parent_clear(type='CLEAR_KEEP_TRANSFORM')
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
co = np.empty(len(hi.data.vertices) * 3)
hi.data.vertices.foreach_get('co', co)
co = co.reshape(-1, 3)
height = float(co[:, 2].max() - co[:, 2].min())
rep['hiTris'] = tris(hi)
part_of = None
if len(hi.data.materials) > 1:                                                   # a body with close-up parts (parts.py): a point is on a part when its
    hm = hi.data                                                                 # nearest detailed surface is a part's (a material past the body's)
    hb_parts = BVHTree.FromPolygons([v.co[:] for v in hm.vertices], [p.vertices[:] for p in hm.polygons])
    hmat = np.array([p.material_index for p in hm.polygons])
    part_of = lambda P: np.array([hmat[hb_parts.find_nearest(Vector(p))[2]] > 0 for p in P], dtype=bool)
    rigid_mat = np.array([int(m.name.split('dm_rigid_')[1].split('.')[0]) if m and 'dm_rigid_' in m.name else 0 for m in hm.materials])

# ---- the game mesh
lo = hi.copy()
lo.data = hi.data.copy()
lo.name = 'game'
bpy.context.scene.collection.objects.link(lo)
mi = np.empty(len(lo.data.polygons), np.int32)
lo.data.polygons.foreach_get('material_index', mi)
lo.data.attributes.new('dm_part', 'INT', 'FACE').data.foreach_set('value', mi)   # clearing the materials zeroes their indices; meshopt groups by it
lo.data.materials.clear()
for uv in list(lo.data.uv_layers):
    lo.data.uv_layers.remove(uv)
bm = bmesh.new()
bm.from_mesh(lo.data)
bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=height * 1e-5)   # the UV seams split the vertices; one surface again
bm.to_mesh(lo.data)
bm.free()
select_only(lo)
bpy.ops.mesh.customdata_custom_splitnormals_clear()                 # the import's stored normals do not survive a rebuild: the game mesh gets its own

def shrink(o):
    """to the budget: the keep boxes, or else a body's close-up parts, held to their share of the triangles"""
    if KEEP:
        rep['keep'] = collapse_keeping(o, TARGET, KEEP['share'], lambda P: in_regions(P, KEEP, co))
    elif part_of is not None and PART_TRIS > 0:
        rep['partTris'] = collapse_keeping(o, TARGET, PART_TRIS, part_of)
    else:
        collapse_to(o, TARGET)


def meshopt_shrink(o):
    """to the budget with meshoptimizer (shrink.mjs), each group to its share: the keep boxes and the rest, or a body's close-up parts and the body"""
    V, F = arrays(o)
    if len(F) <= TARGET:
        return {}
    me = o.data
    if KEEP:
        g, shares = in_regions(V[F].mean(1), KEEP, co).astype(int), [1 - KEEP['share'], KEEP['share']]
    elif part_of is not None and PART_TRIS > 0:
        part = np.empty(len(me.polygons), np.int32); me.attributes['dm_part'].data.foreach_get('value', part)
        poly = np.empty(len(me.loop_triangles), np.int64); me.loop_triangles.foreach_get('polygon_index', poly)
        g, shares = (part[poly] > 0).astype(int), [1 - PART_TRIS, PART_TRIS]
    else:
        g, shares = np.zeros(len(F), int), [1.0]
    d = tempfile.mkdtemp(prefix='dm-shrink-')
    try:
        V.astype(np.float32).tofile(os.path.join(d, 'pos.f32'))
        for k in range(len(shares)):
            F[g == k].astype(np.uint32).tofile(os.path.join(d, 'idx-%d.u32' % k))
        json.dump({'targets': [int(round(s * TARGET)) for s in shares]}, open(os.path.join(d, 'job.json'), 'w'))
        run = subprocess.run(['node', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'shrink.mjs'), d], capture_output=True, text=True)
        if run.returncode:
            raise SystemExit('shrink.mjs failed: ' + run.stderr[-2000:])
        P = np.fromfile(os.path.join(d, 'pos.out.f32'), np.float32).reshape(-1, 3)
        T = np.fromfile(os.path.join(d, 'idx.out.u32'), np.uint32).reshape(-1, 3)
    finally:
        shutil.rmtree(d, ignore_errors=True)
    used, T = np.unique(T, return_inverse=True)
    new = bpy.data.meshes.new('game')
    new.from_pydata(P[used].tolist(), [], T.reshape(-1, 3).tolist())
    o.data = new
    bpy.data.meshes.remove(me)
    return json.loads(run.stdout.strip().splitlines()[-1])


if METHOD == 'solid':
    rep['solid'] = solid_rebuild(lo, CELLS)
    if CALM:
        apply_mod(lo, kind='TRIANGULATE')
        rep['calmed'] = calm(lo, CALM, max(lo.dimensions))
    shrink(lo)
    hm = hi.data
    hm.calc_loop_triangles()
    hb = BVHTree.FromPolygons([v.co[:] for v in hm.vertices], [t.vertices[:] for t in hm.loop_triangles], all_triangles=True)
    lim = 2.0 * max(lo.dimensions) / CELLS
    moved = 0
    for v in lo.data.vertices:
        loc = hb.find_nearest(v.co, lim)[0]
        if loc is not None:
            v.co = loc
            moved += 1
    rep['snapped'] = round(moved / max(1, len(lo.data.vertices)), 3)
elif METHOD == 'meshopt':
    rep['meshopt'] = meshopt_shrink(lo)
else:
    raise SystemExit('unknown method ' + METHOD)
apply_mod(lo, kind='TRIANGULATE', quad_method='BEAUTY', ngon_method='BEAUTY')
rep['specks'] = drop_specks(lo)
rep['degenerate'] = fix_degenerate(lo, height)
rep['tris'] = tris(lo)
if KEEP:
    V, F = arrays(lo)
    rep['keep']['trisIn'] = round(float(in_regions(V[F].mean(1), KEEP, co).mean()), 3)
rep['meshS'] = round(time.time() - t0, 1)


def rigid_pieces(o):
    """the parts that move as one piece (parts.py's rigid: armour), as each corner's piece number (0 none) in _DM_RIGID, which the next steps carry
    and the rig reads (every corner of a piece gets the same bone weights); each loose piece of the game mesh takes its corners' majority"""
    me = o.data
    V, F = arrays(o)
    near = np.array([rigid_mat[hmat[hb_parts.find_nearest(Vector(p))[2]]] for p in V])
    parent = np.arange(len(V))
    def root(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]; i = parent[i]
        return i
    for t in F:
        for a_, b_ in ((t[0], t[1]), (t[1], t[2])):
            ra, rb = root(a_), root(b_)
            if ra != rb:
                parent[ra] = rb
    comp = np.array([root(i) for i in range(len(V))])
    piece = np.zeros(len(V), int)
    for c in np.unique(comp):
        m = comp == c
        ids, n = np.unique(near[m], return_counts=True)
        piece[m] = ids[n.argmax()]
    me.attributes.new('_DM_RIGID', 'FLOAT', 'POINT').data.foreach_set('value', piece.astype(np.float32))
    return {int(k): int((piece == k).sum()) for k in np.unique(piece) if k}


if part_of is not None and rigid_mat.any():
    rep['rigid'] = rigid_pieces(lo)

# ---- shading and UVs
for p in lo.data.polygons:
    p.use_smooth = True
select_only(lo)
if HARD:
    bpy.ops.object.shade_smooth_by_angle(angle=math.radians(ANGLE), keep_sharp_edges=True)
lo.data.uv_layers.new(name='UVMap')
groups = None
if part_of is not None:
    groups = part_of([p.center for p in lo.data.polygons]).astype(int)
    rep['partShare'] = round(float(groups.mean()), 3)
rep['charts'] = make_charts(lo, report=rep, size=TEX, groups=groups, group_scale=PART_SCALE)
rep['uvS'] = round(time.time() - t0, 1)

# ---- the detailed model's maps (base colour, ORM: R occlusion G roughness B metal, normal) onto the game mesh; a model of several materials (a body
# with parts joined on) moves each part's own paint


def src_image_node(sock):
    while sock.is_linked:
        n = sock.links[0].from_node
        if n.type == 'TEX_IMAGE':
            return n
        sock = next((i for i in n.inputs if i.is_linked), None)
        if sock is None:
            return None
    return None


def material_maps(mat):
    bsdf = next((n for n in mat.node_tree.nodes if n.type == 'BSDF_PRINCIPLED'), None) if mat and mat.use_nodes else None
    out = {}
    for key, sock in (('base', 'Base Color'), ('orm', 'Roughness'), ('normal', 'Normal')):
        n = bsdf and (src_image_node(bsdf.inputs[sock]) or (src_image_node(bsdf.inputs['Metallic']) if key == 'orm' else None))
        if n:
            out[key] = image_array(n.image)
    return out


hi_maps = [material_maps(m) for m in hi.data.materials] or [{}]
rep['hiMaterials'] = len(hi_maps)
maps, st = transfer(hi, lo, hi_maps, BAKE, REACH * height, margin=16 * (BAKE // TEX))   # edge padding 16 texels of the final size at any bake size
rep.update({'xfer_' + k: v for k, v in st.items()})

img = {}
for key, cs in (('base', 'sRGB'), ('orm', 'Non-Color'), ('normal', 'Non-Color')):
    if key in maps:
        img[key] = bpy.data.images.new(key, TEX, TEX, alpha=False, float_buffer=False)
        img[key].colorspace_settings.name = cs

if os.environ.get('FINISH_DUMP'):                                                # diag: the moved maps before the metal step, texel -> triangle
    L = _loops(lo.data); tri_of, _ = _raster(L, BAKE)
    P = L['pos'][L['tri']]
    np.savez_compressed(os.environ['FINISH_DUMP'], tri_of=tri_of, cen=P.mean(1), area=0.5 * np.linalg.norm(np.cross(P[:, 1] - P[:, 0], P[:, 2] - P[:, 0]), axis=1),
                        **{k: v for k, v in maps.items()})

# ---- metal by the asset's material
if 'orm' in maps:
    orm, base = maps['orm'], maps['base']
    metal = orm[..., 2]
    metal_px = metal > 0.6
    rep['metalSharePixal'] = round(float(metal_px.mean()), 3)
    if METAL == 'none':
        orm[..., 2] = 0.0
    elif METAL == 'mixed':
        L = _loops(lo.data)
        orm[..., 2], rep['materials'] = metal_by_material(orm, base, _raster(L, BAKE)[0], L['pos'][L['tri']].mean(1),
                                                          json.load(open(REGIONS)) if REGIONS else None, pad=16 * (BAKE // TEX))
    elif METAL == 'all':
        orm[..., 2] = np.where(metal_colour(base[..., :3]), np.maximum(metal, 0.85), 0.0)
    rep['metalShare'] = round(float((orm[..., 2] > 0.5).mean()), 3)
if BAKE != TEX:                                                                  # each f x f block's mean (normals: their mean direction)
    f = BAKE // TEX
    for key in list(maps):
        m = maps[key].reshape(TEX, f, TEX, f, -1).mean((1, 3))
        if key == 'normal':
            v = m[..., :3] * 2 - 1
            v /= np.maximum(np.linalg.norm(v, axis=-1, keepdims=True), 1e-6)
            m[..., :3] = v * 0.5 + 0.5
        maps[key] = m.astype(np.float32)
for key, im in img.items():
    im.pixels.foreach_set(maps[key].ravel())
    im.pack()

# ---- the game material (glTF: base, metal-roughness + occlusion from the ORM, normal)
gm = bpy.data.materials.new('game')
gm.use_nodes = True
lo.data.materials.append(gm)
nt = gm.node_tree
gb = next(n for n in nt.nodes if n.type == 'BSDF_PRINCIPLED')
tex = {}
for key, im in img.items():
    tex[key] = nt.nodes.new('ShaderNodeTexImage')
    tex[key].image = im
nt.links.new(tex['base'].outputs['Color'], gb.inputs['Base Color'])
if 'orm' in tex:
    sep = nt.nodes.new('ShaderNodeSeparateColor')
    nt.links.new(tex['orm'].outputs['Color'], sep.inputs['Color'])
    nt.links.new(sep.outputs['Green'], gb.inputs['Roughness'])
    nt.links.new(sep.outputs['Blue'], gb.inputs['Metallic'])
    grp = bpy.data.node_groups.get('glTF Material Output')
    if grp is None:
        grp = bpy.data.node_groups.new('glTF Material Output', 'ShaderNodeTree')
        grp.interface.new_socket('Occlusion', in_out='INPUT', socket_type='NodeSocketFloat')
    gn = nt.nodes.new('ShaderNodeGroup')
    gn.node_tree = grp
    nt.links.new(sep.outputs['Red'], gn.inputs['Occlusion'])
if 'normal' in tex:
    nm = nt.nodes.new('ShaderNodeNormalMap')
    nt.links.new(tex['normal'].outputs['Color'], nm.inputs['Color'])
    nt.links.new(nm.outputs['Normal'], gb.inputs['Normal'])

bpy.data.objects.remove(hi, do_unlink=True)
select_only(lo)
bpy.ops.export_scene.gltf(filepath=OUT, use_selection=True, export_format='GLB', export_yup=True, export_tangents=True, export_image_format='AUTO',
                          export_attributes=True)                                # _DM_RIGID, when there are rigid parts
rep['totalS'] = round(time.time() - t0, 1)
print('FINISH', json.dumps(rep))
if REPORT:
    json.dump(rep, open(REPORT, 'w'))
