import { describe, expect, it } from 'vitest';
import { AREAS, AREA_ORDER, type AreaId } from '../../content/areas';
import { NODE_COLLIDER, PROPS, generateLayout } from '../../content/layout';
import { NODES } from '../gatheringRules';
import { Nav } from '../nav';
import { mulberry32 } from '../rng';

/** The live world's colliders, as WorldView registers them (walls, props, gathering nodes, ponds). */
function worldNav() {
  const layout = generateLayout();
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
      const cos = Math.abs(Math.cos(p.rot)), sin = Math.abs(Math.sin(p.rot));
      const hw = (c.hw * cos + c.hd * sin) * p.scale, hd = (c.hw * sin + c.hd * cos) * p.scale;
      nav.addObstacle({ kind: 'box', x0: p.x - hw, z0: p.z - hd, x1: p.x + hw, z1: p.z + hd });
    }
  }
  for (const n of layout.nodes) { const r = NODE_COLLIDER[NODES[n.type].kind]; if (r) nav.addObstacle({ kind: 'circle', x: n.x, z: n.z, r }); }
  for (const p of layout.ponds) nav.addObstacle({ kind: 'box', ...p });
  nav.setUnlocked(AREA_ORDER);
  return nav;
}

describe('click to move walks around what is in the way (owner, 2026-10-04)', () => {
  const nav = worldNav();
  const areas = AREA_ORDER.filter((a) => !AREAS[a].instance) as AreaId[];

  it('a click behind a prop or wall gets a route that is walkable end to end, in every area', () => {
    const rand = mulberry32(11);
    let blockedClicks = 0, routed = 0, worst = 0; const times: number[] = [];
    for (const a of areas) {
      const r = AREAS[a].rect;
      const pt = () => ({ x: r.x0 + 1 + rand() * (r.x1 - r.x0 - 2), z: r.z0 + 1 + rand() * (r.z1 - r.z0 - 2) });
      for (let n = 0; n < 60; n++) {
        const s = pt(), t = pt();
        if (nav.blocked(s.x, s.z, 0.45) || nav.blocked(t.x, t.z, 0.45)) continue;
        if (nav.clearLine(s.x, s.z, t.x, t.z, 0.45)) continue; // only the cases that used to get stuck
        blockedClicks++;
        const t0 = performance.now();
        const path = nav.findPath(s.x, s.z, t.x, t.z);
        const dt = performance.now() - t0; times.push(dt); if (times.length > 3) worst = Math.max(worst, dt); // the first plans include JIT warm-up
        let at = s, ok = true;
        for (const p of path) { if (!nav.clearLine(at.x, at.z, p.x, p.z, 0.4)) { ok = false; break; } at = p; }
        if (ok && Math.hypot(at.x - t.x, at.z - t.z) < 0.6) routed++;
      }
    }
    expect(blockedClicks).toBeGreaterThan(50);
    // A few clicks are unreachable on purpose (inside a walled-off pocket); nearly all must route cleanly.
    expect(routed / blockedClicks).toBeGreaterThan(0.98);
    // A* with a closed set: ~0.5 ms typical, a few ms for a 40 m cross-room route (it was up to ~40 ms before). Generous for slow CI.
    expect(worst, `worst plan ${worst.toFixed(1)} ms`).toBeLessThan(15);
    console.log(`click-pathing: ${routed}/${blockedClicks} blocked clicks routed around, worst plan ${worst.toFixed(1)} ms`);
  });
});
