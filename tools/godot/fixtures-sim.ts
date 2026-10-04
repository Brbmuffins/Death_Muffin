/**
 * Golden fixtures for godot/sim (run: npx vite-node tools/godot/fixtures-sim.ts; also run by gen-fixtures.sh).
 * Everything is produced by the REAL TS modules (Nav, depthsFloor). Part A: nav + Depths floors. Whole-sim scenario replays: fixtures-sim-run.ts.
 * Format per file: { fn, cases: [{ in, out }] }; tests/sim/run.gd maps fn -> handler.
 */
import { AREAS, AREA_ORDER } from '../../src/content/areas';
import { floorHop, floorHops, floorPath, floorProblems, floorSeed, generateFloor, roomAt, floorObstacles, floorSightBoxes } from '../../src/gameplay/depthsFloor';
import { w, J, rand, R, pick, chance, worldNav, ALL_OPEN, counts } from './sim-fixture-lib';

// ---------------------------------------------------------------------------------------------------------------------
// A. Nav
// ---------------------------------------------------------------------------------------------------------------------
{
  const navs = [worldNav(), worldNav(ALL_OPEN), worldNav(['ossuary', 'nave'])];
  const xs = AREA_ORDER.map((a) => AREAS[a].rect);
  const minX = Math.min(...xs.map((r) => r.x0)) - 6, maxX = Math.max(...xs.map((r) => r.x1)) + 6;
  const minZ = Math.min(...xs.map((r) => r.z0)) - 6, maxZ = Math.max(...xs.map((r) => r.z1)) + 6;
  // Mostly points inside areas (so obstacles matter), some anywhere.
  const pt = () => {
    if (chance(0.15)) return { x: minX + rand() * (maxX - minX), z: minZ + rand() * (maxZ - minZ) };
    const r = AREAS[pick(AREA_ORDER)].rect;
    return { x: r.x0 + rand() * (r.x1 - r.x0), z: r.z0 + rand() * (r.z1 - r.z0) };
  };
  const cases: { in: unknown; out: unknown }[] = [];
  for (let i = 0; i < 1500; i++) {
    const ni = R(navs.length), nav = navs[ni], p = pt(), r = pick([0.4, 0.45, 0.5, 0.9]);
    const area = pick(AREA_ORDER), q = pt();
    cases.push({
      in: { ni, x: p.x, z: p.z, r, area, qx: q.x, qz: q.z },
      out: J({
        resolve: nav.resolve(p.x, p.z, r), inArea: nav.resolveInArea(area, p.x, p.z, r), pushOut: nav.pushOut(p.x, p.z, r), areaAt: nav.areaAt(p.x, p.z),
        blocked: nav.blocked(p.x, p.z, r), clearLine: nav.clearLine(p.x, p.z, q.x, q.z, r), sight: nav.sightBlocked(p.x, p.z, q.x, q.z), nearest: nav.nearestArea(p.x, p.z),
        unlocked: nav.isUnlocked(area), route: nav.route(p.x, p.z, q.x, q.z),
      }),
    });
  }
  w('nav_basic', cases);
  const paths: { in: unknown; out: unknown }[] = [];
  for (let i = 0; i < 400; i++) {
    const ni = R(navs.length), nav = navs[ni];
    // A* is slow-ish: same area pairs mostly, some cross-area.
    const a = pick(AREA_ORDER), ra = AREAS[a].rect;
    const p = { x: ra.x0 + 1 + rand() * (ra.x1 - ra.x0 - 2), z: ra.z0 + 1 + rand() * (ra.z1 - ra.z0 - 2) };
    const q = chance(0.8) ? { x: ra.x0 + 1 + rand() * (ra.x1 - ra.x0 - 2), z: ra.z0 + 1 + rand() * (ra.z1 - ra.z0 - 2) } : pt();
    const r = pick([0.4, 0.45]);
    paths.push({ in: { ni, x: p.x, z: p.z, qx: q.x, qz: q.z, r }, out: J({ path: nav.findPath(p.x, p.z, q.x, q.z, r) }) });
  }
  w('nav_paths', paths);
}

// ---------------------------------------------------------------------------------------------------------------------
// B. Depths floors
// ---------------------------------------------------------------------------------------------------------------------
{
  const cases: { in: unknown; out: unknown }[] = [];
  for (let i = 0; i < 70; i++) {
    const runSeed = chance(0.2) ? R(1e9) * 3 : R(2 ** 32);
    const depth = pick([1, 1, 2, 3, 4, 5, 5, 10, 15, 20, 25, 40]);
    const fs = floorSeed(runSeed, depth);
    const f = generateFloor(fs, depth, { chestEvery: 5 });
    const probes = [], pts = [];
    for (let k = 0; k < 20; k++) {
      const r = f.rect;
      const a = { x: r.x0 + rand() * (r.x1 - r.x0), z: r.z0 + rand() * (r.z1 - r.z0) }, b = { x: r.x0 + rand() * (r.x1 - r.x0), z: r.z0 + rand() * (r.z1 - r.z0) };
      const ra = roomAt(f, a.x, a.z), rb = roomAt(f, b.x, b.z);
      pts.push({ a, b });
      probes.push({ rooms: [ra, rb], hop: floorHop(f, a.x, a.z, b.x, b.z), hops: floorHops(f, ra, rb), path: floorPath(f, a.x, a.z, b.x, b.z) });
    }
    cases.push({ in: { runSeed, depth, pts }, out: J({ floorSeed: fs, floor: f, problems: floorProblems(f), obstacles: floorObstacles(f).length, sight: floorSightBoxes(f).length, probes }) });
  }
  w('depths_floor', cases);
}

// ---------------------------------------------------------------------------------------------------------------------
// C. V8's Math.sin / cos / atan2 (godot/sim/fdlibm.gd must match bit for bit; compared with ==)
// ---------------------------------------------------------------------------------------------------------------------
{
  const cases: { in: unknown; out: unknown }[] = [];
  const edge = [0, -0, 1e-10, -1e-10, 1e-8, 0.25, 0.5, 0.78, Math.PI / 4, Math.PI / 2, Math.PI, 2 * Math.PI, -Math.PI, 3 * Math.PI / 4, 100 * Math.PI, 1e5, 1e6, 5e5, -3, 6.283185307179586, 1.5707963267948966, 0.4375, 0.6875, 1.1875, 2.4375, 12345.678];
  for (const x of edge) cases.push({ in: { x }, out: { sin: Math.sin(x), cos: Math.cos(x) } });
  for (let i = 0; i < 12000; i++) {
    const sc = pick([0.5, 3, 8, 40, 400, 20000]);
    const x = (rand() - 0.5) * sc;
    cases.push({ in: { x }, out: { sin: Math.sin(x), cos: Math.cos(x) } });
  }
  w('trig_sincos', cases);
  const a2: { in: unknown; out: unknown }[] = [];
  const pts = [0, -0, 1, -1, 0.5, 1e-300, 1e300, 3, -3, 7.5, 1e-10, 2 ** 60, 2 ** -60];
  for (const y of pts) for (const x of pts) a2.push({ in: { y, x }, out: { r: Math.atan2(y, x), t: Math.atan(y) } });
  for (let i = 0; i < 12000; i++) {
    const sc = pick([1, 10, 100, 1e4]);
    const y = (rand() - 0.5) * sc, x = chance(0.1) ? 0 : (rand() - 0.5) * sc;
    a2.push({ in: { y, x }, out: { r: Math.atan2(y, x), t: Math.atan(y) } });
  }
  w('trig_atan2', a2);
}

console.log('sim fixtures written', counts);
