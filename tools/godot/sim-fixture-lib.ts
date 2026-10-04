/** Shared helpers of the sim fixture generators (fixtures-sim.ts, fixtures-sim-run.ts). Not a generator itself. */
import { mkdirSync, writeFileSync, readFileSync } from 'node:fs';
import { exactStringify, exactParse } from './exact-json';
export { exactStringify };
import { mulberry32 } from '../../src/gameplay/rng';
import { Nav } from '../../src/gameplay/nav';
import { AREAS, AREA_ORDER, type AreaId } from '../../src/content/areas';

export const OUT = 'godot/tests/sim/fixtures';
mkdirSync(OUT, { recursive: true });
export const counts: Record<string, number> = {};
export const w = (fn: string, cases: { in: unknown; out: unknown }[]) => {
  writeFileSync(`${OUT}/${fn}.json`, exactStringify({ fn, cases }) + '\n');
  counts[fn] = cases.length;
};
export const J = <T>(x: T): T => JSON.parse(JSON.stringify(x));

export const rand = mulberry32(20261005);
export const R = (n: number) => Math.floor(rand() * n);
export const pick = <T>(a: readonly T[]): T => a[R(a.length)];
export const chance = (p: number) => rand() < p;
export const range = (lo: number, hi: number) => lo + R(hi - lo + 1);

/** The world's nav, built from the exported layout exactly like WorldView/WorldScene do (godot/data/sim/world.json). */
export const WORLD = exactParse(readFileSync('godot/data/sim/world.json', 'utf8')) as {
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

