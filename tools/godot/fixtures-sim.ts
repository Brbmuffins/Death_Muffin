/**
 * Golden fixtures for godot/sim (run: npx vite-node tools/godot/fixtures-sim.ts; also run by gen-fixtures.sh).
 * Everything is produced by the REAL TS modules (Nav, depthsFloor, WorldSim, BossBrain via WorldSim). Part A: nav + Depths floors.
 * Part B (further down): whole-sim scenario replays. Format per file: { fn, cases: [{ in, out }] }; tests/sim/run.gd maps fn -> handler.
 */
import { mkdirSync, writeFileSync, readFileSync } from 'node:fs';
import { mulberry32 } from '../../src/gameplay/rng';
import { Nav } from '../../src/gameplay/nav';
import { AREAS, AREA_ORDER, type AreaId } from '../../src/content/areas';
import { floorHop, floorHops, floorPath, floorProblems, floorSeed, generateFloor, roomAt, floorObstacles, floorSightBoxes } from '../../src/gameplay/depthsFloor';

export const OUT = 'godot/tests/sim/fixtures';
mkdirSync(OUT, { recursive: true });
export const counts: Record<string, number> = {};
export const w = (fn: string, cases: { in: unknown; out: unknown }[]) => {
  writeFileSync(`${OUT}/${fn}.json`, JSON.stringify({ fn, cases }) + '\n');
  counts[fn] = cases.length;
};
export const J = <T>(x: T): T => JSON.parse(JSON.stringify(x));

export const rand = mulberry32(20261005);
export const R = (n: number) => Math.floor(rand() * n);
export const pick = <T>(a: readonly T[]): T => a[R(a.length)];
export const chance = (p: number) => rand() < p;
export const range = (lo: number, hi: number) => lo + R(hi - lo + 1);

/** The world's nav, built from the exported layout exactly like WorldView/WorldScene do (godot/data/sim/world.json). */
export const WORLD = JSON.parse(readFileSync('godot/data/sim/world.json', 'utf8')) as {
  obstacles: any[]; sightBlockers: any[]; crypts: { area: AreaId; x: number; z: number }[]; nodes: any[]; cover: any[];
};
export function worldNav(unlocked?: AreaId[]): Nav {
  const nav = new Nav();
  for (const o of WORLD.obstacles) nav.addObstacle(o);
  for (const s of WORLD.sightBlockers) nav.addSightBlocker(s);
  if (unlocked) nav.setUnlocked(unlocked);
  return nav;
}
export const ALL_OPEN = AREA_ORDER.filter((a) => a !== 'depths');

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
