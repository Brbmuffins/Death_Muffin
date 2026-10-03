import { describe, expect, it, vi } from 'vitest';
import { mkdirSync, readFileSync, writeFileSync, existsSync } from 'node:fs';
import type { ModelTemplate } from '../AssetCache';
import {
  GUARD_CLIPS, GUARD_CONFIGS, HEROES, MAINS, OFFS, clipNames, measureConfig, merge,
  type Matrix, type Support,
} from './gearClipHarness';
import { renderReport } from './gearClipReport';

const store = vi.hoisted(() => ({ models: new Map<string, ModelTemplate>(), props: new Map<string, string>() }));
vi.mock('../AssetCache', () => ({
  assets: {
    model: async (url: string, height: number) => {
      const prop = [...store.props].find(([k]) => url.endsWith(k));
      if (prop) {
        const h = await import('./propHarness');
        return h.propTemplate(prop[1], height);
      }
      return store.models.get(url);
    },
  },
}));
vi.mock('../fxTextures', async () => {
  const THREE = await import('three');
  return { fx: new Proxy({}, { get: () => () => new THREE.Texture() }) };
});

const { NecromancerAvatar } = await import('../Avatars');

for (const f of ['staff', 'scythe', 'wand', 'sickle', 'skull_focus', 'grimoire', 'mourning_bell']) store.props.set(`gear_${f}.glb`, `public/models/props/gear_${f}.glb`);

const FULL = !!process.env.GEAR_CLIP_FULL;
const BASELINE = 'docs/gear-clip/baseline.json';
/** A pair may get worse than its committed baseline by this much (absolute metres, or 10 %), whichever is larger. */
const TOLERANCE_M = 0.004;
const TOLERANCE_REL = 0.1;

async function run(clipFilter: string[] | null, configs: [string, string][]) {
  const matrix: Matrix = {};
  const support: Record<string, Support> = {};
  for (const hero of HEROES) {
    const clips = clipNames(hero).filter((c) => !clipFilter || clipFilter.includes(c));
    for (const [main, off] of configs) {
      const r = await measureConfig(NecromancerAvatar, hero, main, off, clips, store);
      merge(matrix, hero, r.cells);
      for (const [k, v] of Object.entries(r.support)) support[`${hero}|${k}`] = v;
    }
  }
  return { matrix, support };
}

const round = (v: number) => Math.round(v * 10000) / 10000;

describe(FULL ? 'gear x clip matrix (full run, writes docs/gear-clip)' : 'gear x clip guard (subset vs docs/gear-clip/baseline.json)', () => {
  it('measures', async () => {
    // Seeded, not constant: three derives clip and object UUIDs from Math.random (a constant would merge every clip's action).
    let seed = 12345;
    vi.spyOn(Math, 'random').mockImplementation(() => {
      seed = (seed + 0x6d2b79f5) | 0;
      let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
      t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    });
    if (FULL) {
      const configs = MAINS.flatMap((m) => OFFS.map((o) => [m, o] as [string, string]));
      const { matrix, support } = await run(null, configs);
      mkdirSync('docs/gear-clip', { recursive: true });
      const out: Record<string, [number, number]> = {};
      for (const k of Object.keys(matrix).sort()) out[k] = [round(matrix[k].worst), round(matrix[k].p95)];
      const sup: Record<string, [number, number]> = {};
      for (const k of Object.keys(support).sort()) sup[k] = [round(support[k].min), round(support[k].med)];
      writeFileSync(BASELINE, JSON.stringify({ version: 1, unit: 'metres', cells: out, support: sup }, null, 1) + '\n');
      writeFileSync('docs/gear-clip/report.md', renderReport(matrix, support));
      expect(Object.keys(matrix).length).toBeGreaterThan(100);
      return;
    }
    expect(existsSync(BASELINE), 'run `npm run qa:gear-clip` to create docs/gear-clip/baseline.json').toBe(true);
    const base = (JSON.parse(readFileSync(BASELINE, 'utf8')) as { cells: Record<string, [number, number]> }).cells;
    const { matrix } = await run(GUARD_CLIPS, GUARD_CONFIGS);
    const worse: string[] = [];
    let compared = 0;
    for (const [k, cell] of Object.entries(matrix)) {
      const b = base[k];
      if (!b) { worse.push(`${k}: not in baseline (rerun npm run qa:gear-clip)`); continue; }
      compared++;
      for (const [i, label] of [[0, 'worst'], [1, 'p95']] as const) {
        const now = i === 0 ? cell.worst : cell.p95;
        if (now > b[i] + Math.max(TOLERANCE_M, b[i] * TOLERANCE_REL)) worse.push(`${k} ${label}: ${now.toFixed(3)} m, baseline ${b[i].toFixed(3)} m`);
      }
    }
    expect(compared).toBeGreaterThan(100);
    expect(worse, `Gear clearance got worse than docs/gear-clip/baseline.json:\n${worse.join('\n')}`).toEqual([]);
  }, 600_000);
});
