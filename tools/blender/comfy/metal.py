# Which parts of a model are metal, decided per material instead of per texel. Pixal3D paints each material its own roughness (the fence: iron ~0.60,
# stone ~0.88; one helm: band 0.54, cloth 0.92; another: band spread 0.36-0.64, cloth 0.76-0.88), so the model splits into materials where its roughness
# histogram has a clear gap (_splits), each triangle then taking its texels' majority so specks go. A material is metal when Pixal's metal on it is high
# (median >= 0.5), its colour reads as metal, and Pixal is sure: the metal steady (middle half within 0.15) or the material smooth (roughness <= 0.7). On
# the fence's stone Pixal's metal swings 0.43-0.93 at roughness 0.89 (it half-thinks the grey stone is iron), so the old texel-by-texel decision made the
# pillars blotchy; real metal is steady (fence iron 0.91-0.99, a helm band 0.63-0.65) or smooth (the other helm's band, 0.6-0.82 at 0.53). A material
# whose metal is split two ways (leather and iron painted the same roughness: a quarter under 0.2, a quarter at `high` or more, the scythe's
# wood-and-iron 0.33 and 0.46 with its iron at 0.5-0.8) is split by metal first. When Pixal marks the whole model metal its map says
# nothing: metal then comes only from the asset's metal regions (by_regions), none without them.
import numpy as np
from transfer import grow


def _otsu(v, bins=200):
    lo, hi = float(v.min()), float(v.max())
    if hi - lo < 1e-3:
        return None
    h, e = np.histogram(v, bins=bins, range=(lo, hi))
    c = (e[:-1] + e[1:]) / 2
    w0 = np.cumsum(h); w1 = w0[-1] - w0
    m0 = np.cumsum(h * c) / np.maximum(w0, 1); m1 = (np.sum(h * c) - np.cumsum(h * c)) / np.maximum(w1, 1)
    return float(e[1:][np.argmax(w0 * w1 * (m0 - m1) ** 2)])


def _splits(v, n, min_share=0.02, gap=0.15, depth=3):
    """roughness values where the materials divide: Otsu's split (moved to the emptiest stretch within 0.1), kept when both sides are real materials (each at least min_share of all the texels,
    medians at least <gap> apart, and the split in an emptyish stretch: texels within 0.02 of it at most half as dense as on the thinner side), then each
    side split again"""
    t = _otsu(v) if depth and v.size else None
    if t is None:
        return []
    near = lambda t: ((v >= t - 0.02) & (v < t + 0.02)).sum()
    t = min(np.arange(t - 0.1, t + 0.1, 0.005), key=near)                       # Otsu's split, moved to the emptiest stretch next to it
    a, b = v[v < t], v[v >= t]
    if min(a.size, b.size) < min_share * n or np.median(b) - np.median(a) < gap:
        return []
    dens = lambda x: 0.8 * x.size / max(np.percentile(x, 90) - np.percentile(x, 10), 0.04)
    if near(t) / 0.04 > 0.5 * min(dens(a), dens(b)):
        return []
    return _splits(a, n, min_share, gap, depth - 1) + [t] + _splits(b, n, min_share, gap, depth - 1)


def _majority(grp, tri_of, filled, k, share=0.8):
    """each texel of a triangle that is at least <share> one group: that group"""
    t, g = tri_of[filled], grp[filled]
    T = int(t.max()) + 1
    cnt = np.bincount(t * k + g, minlength=T * k).reshape(T, k)
    maj, top = cnt.argmax(1), cnt.max(1) / np.maximum(cnt.sum(1), 1)
    out = grp.copy()
    sub = out[filled]
    ok = top[t] >= share
    sub[ok] = maj[t[ok]]
    out[filled] = sub
    return out


def metal_colour(rgb):
    mx, mn = rgb.max(-1), rgb.min(-1)
    sat = (mx - mn) / np.maximum(mx, 1e-4)
    hue_warm = (rgb[..., 0] >= rgb[..., 1]) & (rgb[..., 1] >= rgb[..., 2])                  # gold, brass, copper run red >= green >= blue
    return (sat < 0.22) | (hue_warm & (sat < 0.75) & (mx > 0.35))


def by_regions(orm, base, tri_of, cen, regions, pad):
    """Pixal marked the whole model metal, so its map says nothing (the hero: metal 1.0 and one roughness on robe and shoulder plates alike, and the
    robe's colour as grey as the plates'). Metal only inside the asset's metal regions (boxes, each a share of the model's size along x, y, z: its own
    axes, z up), on the triangles whose colour mostly reads as metal; their roughness at most regions['rough'] (default 0.5, worn iron). No regions:
    no metal. Gutters copy their nearest texel within pad."""
    filled = tri_of >= 0
    out = np.zeros(orm.shape[:2], np.float32)
    row = dict(pixalAll=True, regions=len(regions.get('boxes', [])) if regions else 0)
    if not row['regions']:
        return out, [row]
    n = (cen - cen.min(0)) / np.maximum(np.ptp(cen, 0), 1e-9)
    inside = np.zeros(len(cen), bool)
    for b in regions['boxes']:
        inside |= np.all((n >= np.array(b[:3])) & (n <= np.array(b[3:])), 1)
    t = tri_of[filled]
    share = np.bincount(t, metal_colour(base[..., :3])[filled], len(cen)) / np.maximum(np.bincount(t, None, len(cen)), 1)
    m = np.zeros(out.shape, bool)
    m[filled] = (inside & (share >= 0.5))[t]
    src = grow(filled, pad).ravel()
    gut = ~filled.ravel() & (src >= 0)
    mf = m.ravel(); mf[gut] = mf[src[gut]]; m = mf.reshape(m.shape)
    out[m] = 1.0
    orm[..., 1][m] = np.minimum(orm[..., 1][m], regions.get('rough', 0.5))
    row['share'] = round(float(m[filled].mean()), 3)
    return out, [row]


def metal_by_material(orm, base, tri_of, cen=None, regions=None, pad=16, high=0.5, steady=0.15, smooth=0.7, colour=0.5):
    """orm, base: HxWx4 maps; tri_of: each texel's triangle (-1 = gutter); cen: the triangles' centres. The new metal channel and a report row per
    material (orm's roughness changes only inside metal regions)."""
    filled = tri_of >= 0
    rough, metal = orm[..., 1], orm[..., 2]
    if (metal[filled] >= 0.9).mean() >= 0.9:
        return by_regions(orm, base, tri_of, cen, regions, pad)
    cuts = _splits(rough[filled], filled.sum())
    k = len(cuts) + 1
    grp = _majority(np.digitize(rough, cuts), tri_of, filled, k)
    for g in range(len(cuts) + 1):                                                  # leather and iron at one roughness: split by metal
        m = filled & (grp == g)
        v = metal[m]
        if v.size and (v < 0.2).mean() >= 0.25 and (v >= high).mean() >= 0.25:
            grp[(grp == g) & (metal >= high)] = k
            k += 1
    grp = _majority(grp, tri_of, filled, k)
    col = metal_colour(base[..., :3])
    out = np.zeros_like(metal)
    rows = []
    for g in range(k):
        m = filled & (grp == g)
        if not m.any():
            continue
        q1, med, q3 = np.percentile(metal[m], [25, 50, 75])
        cs = float(col[m].mean())
        is_metal = med >= high and (q3 - q1 <= steady or np.median(rough[m]) <= smooth) and cs >= colour
        if is_metal:
            w = grp == g                                                         # gutters too
            out[w] = np.maximum(metal[w], 0.85)
        rows.append(dict(rough=round(float(np.median(rough[m])), 2), share=round(float(m.mean() / filled.mean()), 3), metalMid=round(float(med), 2),
                         metalSpread=round(float(q3 - q1), 2), colour=round(cs, 2), metal=bool(is_metal)))
    return out, rows
