import { describe, expect, it } from 'vitest';
import { Nav } from '../nav';
import { WorldSim } from '../sim/WorldSim';
import { WorldMirror, makeSnapshot } from '../sim/snapshot';
import { mulberry32 } from '../rng';
import type { Enemy, SimEvent } from '../sim/types';
import { DUST, ENEMIES, WARD, WAVE_THEMES, type EnemyId } from '../../content/enemies';
import { AREAS } from '../../content/areas';
import { CODEX_DEAD, DEAD_ORDER } from '../../content/codex';

type Internals = { strike(e: Enemy, kind: string): void };
const internals = (sim: WorldSim) => sim as unknown as Internals;

function world(seed = 1, area: 'graves' | 'nave' | 'sanctum' = 'graves') {
  const nav = new Nav();
  nav.setUnlocked(['chapterhouse', 'graves', 'ossuary', 'nave', 'sanctum']);
  const sim = new WorldSim(nav, mulberry32(seed));
  const r = AREAS[area].rect;
  sim.setPlayer({ id: 'p1', x: (r.x0 + r.x1) / 2, z: (r.z0 + r.z1) / 2, alive: true, area });
  return { nav, sim };
}
const of = <T extends SimEvent['t']>(ev: SimEvent[], t: T) => ev.filter((e): e is Extract<SimEvent, { t: T }> => e.t === t);
const FLYERS: EnemyId[] = ['gargoyle', 'moth', 'bat', 'seraph'];

describe('Flying pack', () => {
  it('every flyer has a Codex entry, a hover height, a model and a place to spawn', () => {
    const rostered = new Set(Object.values(AREAS).flatMap((a) => a.enemies.map((e) => e.id)));
    for (const id of FLYERS) {
      expect(DEAD_ORDER).toContain(id);
      expect(CODEX_DEAD[id].counter.length).toBeGreaterThan(30);
      expect(ENEMIES[id].flying).toBeGreaterThan(0);
      expect(ENEMIES[id].modelSlug).toBeTruthy();
      expect(rostered.has(id)).toBe(true);
    }
    for (const themes of Object.values(WAVE_THEMES)) for (const t of themes ?? []) for (const r of t.roster) expect(ENEMIES[r.id]).toBeDefined();
  });

  it('a Belfry Gargoyle marks a spot, dives onto it, hits what stayed, then sits grounded', () => {
    const { sim } = world(4);
    const p = sim.players.get('p1')!;
    const g = sim.spawnEnemy('gargoyle', 'graves', p.x + 6, p.z, false, false);
    g.attackCd = 0;
    const tele = of(sim.step(0.05), 'telegraph').find((t) => t.id === g.id);
    expect(tele?.kind).toBe('dive');
    expect(g.diving).toBe(true);
    // Mid-dive it mirrors to co-op guests (flag bit 19).
    sim.step((ENEMIES.gargoyle.windupMs / 1000) * 0.6);
    const mirror = new WorldMirror();
    mirror.applySnapshot(makeSnapshot(sim, true));
    expect(mirror.enemies.get(g.id)?.diving).toBe(true);
    const hurts: SimEvent[] = [];
    for (let i = 0; i < 20 && g.diving; i++) hurts.push(...sim.step(0.05));
    expect(g.diving).toBe(false);
    expect(Math.hypot(g.x - p.x, g.z - p.z)).toBeLessThan(1.2);
    expect(of(hurts, 'hurt').some((h) => h.player === 'p1')).toBe(true);
    // Grounded: still recovering well past the usual 0.3s.
    sim.step(0.3 + ENEMIES.gargoyle.dive!.groundedS * 0.7);
    expect(g.state).toBe('recover');
    sim.step(ENEMIES.gargoyle.dive!.groundedS * 0.5);
    expect(g.state).not.toBe('recover');
  });

  it('a dive misses a player who walked out of the mark', () => {
    const { sim } = world(6);
    const p = sim.players.get('p1')!;
    const g = sim.spawnEnemy('gargoyle', 'graves', p.x + 6, p.z, false, false);
    g.attackCd = 0;
    sim.step(0.05);
    expect(g.diving).toBe(true);
    sim.setPlayer({ ...p, x: p.x - ENEMIES.gargoyle.dive!.radius - 1.5 });
    const ev: SimEvent[] = [];
    for (let i = 0; i < 20 && g.diving; i++) ev.push(...sim.step(0.05));
    expect(of(ev, 'hurt').filter((h) => h.player === 'p1').length).toBe(0);
  });

  it("a Shroud Moth's dust bursts on the ring, then its cloud keeps choking", () => {
    const { sim } = world(7);
    const p = sim.players.get('p1')!;
    const m = sim.spawnEnemy('moth', 'graves', p.x + 5, p.z, false, false);
    m.aimX = p.x;
    m.aimZ = p.z;
    internals(sim).strike(m, 'dust');
    const burst = sim.step(0.01);
    expect(of(burst, 'hurt').filter((h) => h.from === 'dust').length).toBe(1);
    const cloud = [...sim.zones.values()].find((z) => z.kind === 'dust');
    expect(cloud?.hostile).toBe(true);
    expect(cloud?.r).toBe(DUST.radius);
    expect(of(sim.step(1.05), 'hurt').length).toBeGreaterThan(0);
    sim.step(DUST.cloudS);
    expect([...sim.zones.values()].some((z) => z.kind === 'dust')).toBe(false);
  });

  it('a Tithe Bat flits away after it bites', () => {
    const { sim } = world(8);
    const p = sim.players.get('p1')!;
    const b = sim.spawnEnemy('bat', 'graves', p.x + 0.8, p.z, false, false);
    b.attackCd = 0;
    for (let i = 0; i < 20 && !(b.fleeT ?? 0); i++) sim.step(0.05);
    expect(b.fleeT ?? 0).toBeGreaterThan(0);
    const d0 = Math.hypot(b.x - p.x, b.z - p.z);
    // Recover (0.3s) first, then it flies off before circling back.
    for (let i = 0; i < 14; i++) sim.step(0.05);
    expect(Math.hypot(b.x - p.x, b.z - p.z)).toBeGreaterThan(d0 + 1);
  });

  it('a Weeping Seraph blesses every ally near it at once and never raises corpses', () => {
    const { sim } = world(9);
    const p = sim.players.get('p1')!;
    const s = sim.spawnEnemy('seraph', 'graves', p.x + 8, p.z, false, false);
    s.attackCd = 0;
    const allies = [0, 1, 2].map((i) => sim.spawnEnemy('robber', 'graves', s.x + 1 + i * 0.8, s.z + 1.2, false, false));
    const far = sim.spawnEnemy('robber', 'graves', s.x - WARD.range - 4, s.z - 4, false, false);
    sim.addCorpse(s.x - 1, s.z, 'normal', 'robber', false, 0, 1, 'graves');
    const ev = sim.step(0.05);
    expect(of(ev, 'sanctify').length).toBe(3);
    expect(allies.every((a) => (a.sanctT ?? 0) > 0)).toBe(true);
    expect(far.sanctT ?? 0).toBe(0);
    sim.step(2);
    expect([...sim.enemies.values()].some((e) => e.def === 'risen')).toBe(false);
  });
});
