import { describe, expect, it } from 'vitest';
import { AREAS, AREA_ORDER, DOORS, PLAYER_SPAWN, isAlwaysOpen } from '../../content/areas';
import { NODE_COLLIDER, NODE_REACH, PROPS, generateLayout } from '../../content/layout';
import { NODES, NODE_IDS } from '../gatheringRules';
import { Nav } from '../nav';
import { standSpot } from '../gatherPlan';

const layout = generateLayout();
const inside = (r: { x0: number; z0: number; x1: number; z1: number }, x: number, z: number, pad = 0) =>
  x >= r.x0 + pad && x <= r.x1 - pad && z >= r.z0 + pad && z <= r.z1 - pad;

function navFor() {
  const nav = new Nav();
  for (const w of layout.walls) {
    const horizontal = Math.abs(w.z1 - w.z0) < 1e-3;
    const len = horizontal ? w.x1 - w.x0 : w.z1 - w.z0;
    const hw = horizontal ? len / 2 : w.thickness / 2;
    const hd = horizontal ? w.thickness / 2 : len / 2;
    nav.addObstacle({ kind: 'box', x0: (w.x0 + w.x1) / 2 - hw, z0: (w.z0 + w.z1) / 2 - hd, x1: (w.x0 + w.x1) / 2 + hw, z1: (w.z0 + w.z1) / 2 + hd });
  }
  for (const p of layout.props) {
    const c = PROPS[p.prop].collider;
    if (c?.kind === 'circle') nav.addObstacle({ kind: 'circle', x: p.x, z: p.z, r: c.r * p.scale });
    else if (c?.kind === 'box') {
      const cos = Math.abs(Math.cos(p.rot));
      const sin = Math.abs(Math.sin(p.rot));
      const hw = (c.hw * cos + c.hd * sin) * p.scale;
      const hd = (c.hw * sin + c.hd * cos) * p.scale;
      nav.addObstacle({ kind: 'box', x0: p.x - hw, z0: p.z - hd, x1: p.x + hw, z1: p.z + hd });
    }
  }
  for (const n of layout.nodes) {
    const r = NODE_COLLIDER[NODES[n.type].kind];
    if (r) nav.addObstacle({ kind: 'circle', x: n.x, z: n.z, r });
  }
  for (const p of layout.ponds) nav.addObstacle({ kind: 'box', ...p });
  return nav;
}

describe("the Sexton's Acre", () => {
  it('is a safe, always-open area with no enemies, waves or breaches', () => {
    const a = AREAS.acre;
    expect(a.safe).toBe(true);
    expect(a.enemies).toEqual([]);
    expect(a.cap).toBe(0);
    expect(a.breaches).toEqual([]);
    expect(isAlwaysOpen('acre')).toBe(true);
    expect(AREA_ORDER).toContain('acre');
    expect(DOORS.find((d) => d.id === 'chapter_acre')).toMatchObject({ a: 'chapterhouse', b: 'acre', axis: 'x' });
  });

  it('does not overlap any other area', () => {
    for (const id of AREA_ORDER) {
      if (id === 'acre') continue;
      const r = AREAS[id].rect;
      const q = AREAS.acre.rect;
      expect(r.x1 <= q.x0 || r.x0 >= q.x1 || r.z1 <= q.z0 || r.z0 >= q.z1, id).toBe(true);
    }
  });

  it('holds every node type, each inside the area and off the lane, doors and stations', () => {
    const acre = layout.nodes.filter((n) => n.area === 'acre');
    for (const id of NODE_IDS) expect(acre.some((n) => n.type === id), id).toBe(true);
    for (const n of layout.nodes) {
      expect(inside(AREAS[n.area].rect, n.x, n.z, 0.5), n.id).toBe(true);
      for (const d of DOORS) expect(inside({ x0: d.rect.x0 - 1.5, z0: d.rect.z0 - 1.5, x1: d.rect.x1 + 1.5, z1: d.rect.z1 + 1.5 }, n.x, n.z), `${n.id} on ${d.id}`).toBe(false);
      for (const i of AREAS[n.area].interactables) expect(Math.hypot(i.x - n.x, i.z - n.z), `${n.id} vs ${i.id}`).toBeGreaterThan(2.5);
    }
    expect(acre.filter((n) => n.type === 'bone_elder')).toHaveLength(1);
    expect(new Set(layout.nodes.map((n) => n.id)).size).toBe(layout.nodes.length);
  });

  it('keeps nodes apart from each other and from colliding props', () => {
    const ns = layout.nodes;
    for (let i = 0; i < ns.length; i++)
      for (let j = i + 1; j < ns.length; j++) expect(Math.hypot(ns[i].x - ns[j].x, ns[i].z - ns[j].z), `${ns[i].id}/${ns[j].id}`).toBeGreaterThan(2.2);
    for (const n of ns)
      for (const p of layout.props) {
        if (p.area !== n.area || !PROPS[p.prop].collider) continue;
        expect(Math.hypot(p.x - n.x, p.z - n.z), `${n.id} vs ${p.prop}`).toBeGreaterThan(1.4);
      }
  });

  it('puts higher tiers further from the Chapterhouse door', () => {
    const door = { x: -20, z: 20 };
    const acre = layout.nodes.filter((n) => n.area === 'acre');
    const dist = (t: string) => Math.min(...acre.filter((n) => n.type === t).map((n) => Math.hypot(n.x - door.x, n.z - door.z)));
    expect(dist('coffin_oak')).toBeLessThan(dist('churchyard_yew'));
    expect(dist('churchyard_yew')).toBeLessThan(dist('bone_elder'));
    expect(dist('seam_copper')).toBeLessThan(dist('geode_moon'));
    expect(dist('grave_pauper')).toBeLessThan(dist('grave_barrow_king'));
  });

  it('gives each hunting ground 2–4 rich nodes', () => {
    for (const id of ['graves', 'ossuary', 'nave', 'sanctum'] as const) {
      const n = layout.nodes.filter((x) => x.area === id && x.rich).length;
      expect(n, id).toBeGreaterThanOrEqual(2);
      expect(n, id).toBeLessThanOrEqual(4);
    }
    expect(layout.nodes.filter((n) => n.area === 'acre' && n.rich)).toHaveLength(0);
  });

  it('is deterministic for a seed', () => {
    expect(generateLayout(1337).nodes).toEqual(layout.nodes);
  });

  it('every node can be reached on foot from the Chapterhouse spawn', () => {
    const nav = navFor();
    nav.setUnlocked(AREA_ORDER);
    // Walk like Player.update: follow nav.route with resolve(), dropping a stuck waypoint.
    const walk = (tx: number, tz: number) => {
      let [x, z] = nav.resolve(PLAYER_SPAWN.x, PLAYER_SPAWN.z, 0.45);
      const path = nav.findPath(x, z, tx, tz);
      for (let step = 0; step < 4000 && path.length; step++) {
        while (path.length && Math.hypot(path[0].x - x, path[0].z - z) < 0.2) path.shift();
        if (!path.length) break;
        const d = Math.hypot(path[0].x - x, path[0].z - z);
        const s = Math.min(d, 0.08);
        const [nx, nz] = nav.resolve(x + ((path[0].x - x) / d) * s, z + ((path[0].z - z) / d) * s, 0.45);
        if (Math.hypot(nx - x, nz - z) < s * 0.1) path.shift();
        x = nx;
        z = nz;
      }
      return [x, z];
    };
    for (const n of layout.nodes) {
      const reach = NODE_REACH[NODES[n.type].kind];
      const spot = standSpot(nav, n, -20, 20);
      expect(spot, `${n.id} has a free standing spot`).not.toBeNull();
      const [x, z] = walk(spot!.x, spot!.z);
      expect(Math.hypot(x - n.x, z - n.z), n.id).toBeLessThan(reach + 0.6);
    }
  });
});
