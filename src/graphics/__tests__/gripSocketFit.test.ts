/**
 * Offline fit of the necromancer grip sockets (docs/GEAR-VISUALS-PLAN.md, Phase 1): `npm run qa:grip-fit` searches, per hero and prop
 * kind, a small lean / outward-shift / follow adjustment that keeps the prop out of the body in every clip (never worse than the
 * committed baseline's pen, within the guard's tolerance), preferring the original aim and a prop that rides the wrist. It writes
 * tools/grip-fit.json; `node tools/gen-grip-sockets.mjs` turns that into src/graphics/gripSockets.generated.ts. Skipped in `npm test`.
 */
import { describe, expect, it, vi } from 'vitest';
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import * as THREE from 'three';
import type { ModelTemplate } from '../AssetCache';
import { HEROES, MAINS, OFFS, clipNames, measureConfig } from './gearClipHarness';
// @ts-expect-error plain JS helper shared with the generator
import { loadRig, readGrips, socket } from '../../../tools/lib/gripSocket.mjs';

const store = vi.hoisted(() => ({ models: new Map<string, ModelTemplate>(), props: new Map<string, string>() }));
vi.mock('../AssetCache', () => ({
  assets: {
    model: async (url: string, height: number) => {
      const prop = [...store.props].find(([k]) => url.endsWith(k));
      if (prop) return (await import('./propHarness')).propTemplate(prop[1], height);
      return store.models.get(url);
    },
  },
}));
vi.mock('../fxTextures', async () => {
  const THREE = await import('three');
  return { fx: new Proxy({}, { get: () => () => new THREE.Texture() }) };
});

const { NecromancerAvatar } = await import('../Avatars');
const { GRIP_SOCKETS, GRIP_CLIP_FOLLOW } = await import('../gripSockets.generated');
for (const f of [...MAINS, ...OFFS]) store.props.set(`gear_${f}.glb`, `public/models/props/gear_${f}.glb`);

interface Fit { out: number; fwd: number; shift: number; follow: number }
const FOLLOWS = [1, 0.9, 0.8];
const CONFIGS: [string, string][] = [['staff', 'skull_focus'], ['scythe', 'mourning_bell'], ['wand', 'grimoire'], ['sickle', 'skull_focus']];
const KIND_CONFIG: Record<string, number> = { staff: 0, skull_focus: 0, scythe: 1, mourning_bell: 1, wand: 2, grimoire: 2, sickle: 3 };
const KINDS: [string, 'R_Hand' | 'L_Hand', number][] = [...MAINS.map((k) => [k, 'R_Hand', -1] as [string, 'R_Hand', number]), ...OFFS.map((k) => [k, 'L_Hand', 1] as [string, 'L_Hand', number])];
const MOVES: Partial<Fit>[] = [{ out: 0.1 }, { out: -0.1 }, { fwd: 0.1 }, { fwd: -0.1 }, { shift: 0.02 }, { shift: -0.02 }, { follow: -1 }, { follow: 1 }];
const SKIP = !process.env.GRIP_FIT;
// GRIP_FIT=orient: stage 1 only; GRIP_FIT=clips: stage 2 only; GRIP_FIT=1: both.

const STAGE = process.env.GRIP_FIT;
describe.skipIf(SKIP)('grip socket fit', () => {
  it.skipIf(STAGE === 'clips')('fits sockets', async () => {
    let seed = 12345;
    vi.spyOn(Math, 'random').mockImplementation(() => { seed = (seed + 0x6d2b79f5) | 0; let t = Math.imul(seed ^ (seed >>> 15), 1 | seed); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; });
    const base = (JSON.parse(readFileSync('docs/gear-clip/baseline.json', 'utf8')) as { cells: Record<string, [number, number]> }).cells;
    const grips = readGrips();
    const prior = existsSync('tools/grip-fit.json') ? JSON.parse(readFileSync('tools/grip-fit.json', 'utf8')) : {};
    const result: Record<string, Record<string, Fit>> = {};
    const mutSockets = GRIP_SOCKETS as unknown as Record<string, Record<string, number[]>>;
    const mutFollow = GRIP_CLIP_FOLLOW as unknown as Record<string, Record<string, Record<string, number>>>;
    const only = process.env.GRIP_FIT_HERO;
    for (const hero of HEROES) {
      if (only && hero !== only) { result[hero] = prior[hero] ?? {}; continue; }
      const rig = await loadRig(hero);
      const clips = clipNames(hero);
      const apply = (kind: string, bone: string, side: number, f: Fit) => {
        const s = socket(rig, bone, side, grips[kind], f);
        mutSockets[hero][kind] = [...(s.pos as THREE.Vector3).toArray(), ...(s.q as THREE.Quaternion).toArray()];
        mutFollow[hero][kind] = {}; // stage 1 fits the orientation with the stabiliser at `follow` in every clip
        for (const c of clips) mutFollow[hero][kind][c] = f.follow;
      };
      const score = (kind: string, f: Fit, cells: Record<string, { worst: number; p95: number }>) => {
        let v = 0;
        for (const clip of clips) {
          const c = cells[`${kind}|${clip}|pen`];
          const b = base[`${hero}|${kind}|${clip}|pen`];
          if (!c || !b) continue;
          v += Math.max(0, c.worst - (b[0] + Math.max(0.004, b[0] * 0.1) - 0.002)) * 100;
          v += Math.max(0, c.p95 - (b[1] + Math.max(0.004, b[1] * 0.1) - 0.002)) * 100;
        }
        return v + 20 * (Math.abs(f.out) + Math.abs(f.fwd)) + 100 * Math.abs(f.shift) + 15 * (1 - f.follow);
      };
      const evaluate = async (fits: Record<string, Fit>) => {
        for (const [kind, bone, side] of KINDS) apply(kind, bone, side, fits[kind]);
        const per: Record<string, Record<string, { worst: number; p95: number }>> = {};
        const cfgCells: Record<string, { worst: number; p95: number }>[] = [];
        for (const [m, o] of CONFIGS) cfgCells.push((await measureConfig(NecromancerAvatar, hero, m, o, clips, store)).cells);
        for (const [kind] of KINDS) per[kind] = cfgCells[KIND_CONFIG[kind]];
        return Object.fromEntries(KINDS.map(([kind]) => [kind, score(kind, fits[kind], per[kind])]));
      };
      const best: Record<string, Fit> = Object.fromEntries(KINDS.map(([k]) => [k, { out: 0, fwd: 0, shift: 0, follow: 1, ...(prior[hero]?.[k] ?? {}) }]));
      let bestScore = await evaluate(best);
      console.log(hero, 'start', JSON.stringify(bestScore));
      for (let round = 0; round < 6; round++) {
        let improved = false;
        for (const mv of MOVES) {
          const trial: Record<string, Fit> = {};
          for (const [k] of KINDS) {
            const b = best[k];
            const fi = FOLLOWS.indexOf(b.follow);
            trial[k] = {
              out: b.out + (mv.out ?? 0), fwd: b.fwd + (mv.fwd ?? 0), shift: Math.max(0, Math.min(0.08, b.shift + (mv.shift ?? 0))),
              follow: mv.follow ? FOLLOWS[Math.max(0, Math.min(FOLLOWS.length - 1, fi + mv.follow))] : b.follow,
            };
          }
          const sc = await evaluate(trial);
          for (const [k] of KINDS) if (sc[k] < bestScore[k] - 0.05) { best[k] = trial[k]; bestScore[k] = sc[k]; improved = true; }
        }
        console.log(hero, 'round', round, JSON.stringify(bestScore));
        if (!improved) break;
      }
      result[hero] = Object.fromEntries(Object.entries(best).map(([k, f]) => [k, { out: +f.out.toFixed(3), fwd: +f.fwd.toFixed(3), shift: +f.shift.toFixed(3), follow: f.follow }]));
      writeFileSync('tools/grip-fit.json', JSON.stringify(result, null, 1) + '\n');
    }
    expect(Object.keys(result).length).toBe(4);
  }, 3_000_000);

  // Stage 2: with the orientations fixed and every prop riding the wrist, pick per clip the highest follow whose penetration
  // stays within the baseline (worst and p95, the guard's tolerance); a clip where nothing fits takes the least-bad level.
  it.skipIf(STAGE === 'orient')('fits per-clip follow', async () => {
    let seed = 12345;
    vi.spyOn(Math, 'random').mockImplementation(() => { seed = (seed + 0x6d2b79f5) | 0; let t = Math.imul(seed ^ (seed >>> 15), 1 | seed); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; });
    const base = (JSON.parse(readFileSync('docs/gear-clip/baseline.json', 'utf8')) as { cells: Record<string, [number, number]> }).cells;
    const grips = readGrips();
    const fit = JSON.parse(readFileSync('tools/grip-fit.json', 'utf8')) as Record<string, Record<string, Fit & { clips?: Record<string, number> }>>;
    const mutSockets = GRIP_SOCKETS as unknown as Record<string, Record<string, number[]>>;
    const mutFollow = GRIP_CLIP_FOLLOW as unknown as Record<string, Record<string, Record<string, number>>>;
    const LEVELS = [1, 0.9, 0.8, 0.65, 0.5, 0.35, 0.2];
    const only = process.env.GRIP_FIT_HERO;
    for (const hero of HEROES) {
      if (only && hero !== only) continue;
      const rig = await loadRig(hero);
      const clips = clipNames(hero);
      for (const [kind, bone, side] of KINDS) {
        const s = socket(rig, bone, side, grips[kind], fit[hero][kind]);
        mutSockets[hero][kind] = [...(s.pos as THREE.Vector3).toArray(), ...(s.q as THREE.Quaternion).toArray()];
        fit[hero][kind].clips = {};
      }
      const chosen: Record<string, Record<string, { level: number; excess: number }>> = {};
      for (const level of LEVELS) {
        for (const [kind] of KINDS) mutFollow[hero][kind] = Object.fromEntries(clips.map((c) => [c, level]));
        const cfg: Record<string, { worst: number; p95: number }>[] = [];
        for (const [m, o] of CONFIGS) cfg.push((await measureConfig(NecromancerAvatar, hero, m, o, clips, store)).cells);
        for (const [kind] of KINDS) {
          for (const clip of clips) {
            const c = cfg[KIND_CONFIG[kind]][`${kind}|${clip}|pen`];
            const b = base[`${hero}|${kind}|${clip}|pen`];
            if (!c || !b) continue;
            const excess = Math.max(c.worst - (b[0] + Math.max(0.004, b[0] * 0.1) - 0.002), c.p95 - (b[1] + Math.max(0.004, b[1] * 0.1) - 0.002));
            const cur = ((chosen[kind] ??= {})[clip]);
            if (!cur || (cur.excess > 0 && excess < cur.excess - 1e-4)) chosen[kind][clip] = { level, excess };
          }
        }
        console.log(hero, 'level', level);
      }
      for (const [kind] of KINDS) {
        const clipsOut: Record<string, number> = {};
        for (const [clip, v] of Object.entries(chosen[kind] ?? {})) if (v.level < 1) clipsOut[clip] = v.level;
        fit[hero][kind].clips = clipsOut;
        fit[hero][kind].follow = 1;
        console.log(hero, kind, JSON.stringify(clipsOut), 'unresolved', Object.entries(chosen[kind] ?? {}).filter(([, v]) => v.excess > 0).map(([c]) => c).join(','));
      }
      writeFileSync('tools/grip-fit.json', JSON.stringify(fit, null, 1) + '\n');
    }
  }, 3_000_000);
});
