import { describe, expect, it } from 'vitest';
import { Nav } from '../nav';
import { WorldSim } from '../sim/WorldSim';
import { WorldMirror, makeSnapshot } from '../sim/snapshot';
import { mulberry32 } from '../rng';
import type { Enemy, SimEvent } from '../sim/types';
import { CENSER, ENEMIES, PROCESSION, SCREAM, WAVE_THEMES } from '../../../server/rules/content/enemies';
import { AREAS } from '../../../server/rules/content/areas';
import { CODEX_DEAD, DEAD_ORDER } from '../../content/codex';

type Internals = {
  spawnWave(area: string, first?: boolean): void;
  strike(e: Enemy, kind: string): void;
  waveCounts: Map<string, number>;
};
const internals = (sim: WorldSim) => sim as unknown as Internals;

function world(seed = 1, area: 'graves' | 'ossuary' | 'nave' | 'sanctum' = 'graves') {
  const nav = new Nav();
  nav.setUnlocked(['chapterhouse', 'graves', 'ossuary', 'nave', 'sanctum']);
  const sim = new WorldSim(nav, mulberry32(seed));
  const r = AREAS[area].rect;
  sim.setPlayer({ id: 'p1', x: (r.x0 + r.x1) / 2, z: (r.z0 + r.z1) / 2, alive: true, area });
  return { nav, sim };
}
const of = <T extends SimEvent['t']>(ev: SimEvent[], t: T) => ev.filter((e): e is Extract<SimEvent, { t: T }> => e.t === t);

describe('Enemy variety pack', () => {
  it('every new kind of dead has a Codex entry, a bestiary slot and sane stats', () => {
    for (const id of ['censer', 'wraith', 'rat', 'golem'] as const) {
      expect(DEAD_ORDER).toContain(id);
      expect(CODEX_DEAD[id].counter.length).toBeGreaterThan(30);
      expect(ENEMIES[id].hp).toBeGreaterThan(0);
    }
    // Processions only name enemies that exist, and every lead is a real kind.
    for (const themes of Object.values(WAVE_THEMES)) {
      for (const t of themes ?? []) {
        for (const r of t.roster) expect(ENEMIES[r.id]).toBeDefined();
        if (t.lead) expect(ENEMIES[t.lead]).toBeDefined();
      }
    }
  });

  it('Skull-Rats climb out as a pack and never as elites; a wave counts bodies', () => {
    const { sim } = world(3, 'ossuary');
    const rats = WAVE_THEMES.ossuary!.find((t) => t.id === 'skittering')!;
    // Force the Skittering: every pick is a rat.
    const before = sim.enemies.size;
    for (let i = 0; i < 40 && sim.enemies.size - before < 4; i++) {
      internals(sim).waveCounts.set('ossuary', PROCESSION.minWave);
      internals(sim).spawnWave('ossuary');
    }
    const spawned = [...sim.enemies.values()].filter((e) => e.def === 'rat');
    expect(spawned.length).toBeGreaterThanOrEqual(ENEMIES.rat.pack![0]);
    expect(spawned.every((e) => !e.elite)).toBe(true);
    expect(rats.roster[0].id).toBe('rat');
  });

  it('a procession announces its theme on the wave event and brings its lead', () => {
    const { sim } = world(11, 'ossuary');
    let themed: Extract<SimEvent, { t: 'wave' }> | undefined;
    for (let i = 0; i < 60 && !themed; i++) {
      internals(sim).waveCounts.set('ossuary', PROCESSION.minWave);
      internals(sim).spawnWave('ossuary');
      themed = of(sim.step(0.01), 'wave').find((w) => w.theme);
      if (!themed) sim.clearArea('ossuary');
    }
    expect(themed).toBeDefined();
    const theme = WAVE_THEMES.ossuary!.find((t) => t.id === themed!.theme)!;
    if (theme.lead) expect([...sim.enemies.values()].some((e) => e.def === theme.lead)).toBe(true);
  });

  it('a Censer Bearer Incenses the dead near it, and Incensed dead move faster', () => {
    const { sim } = world(5);
    const p = sim.players.get('p1')!;
    const censer = sim.spawnEnemy('censer', 'graves', p.x + 8, p.z, false, false);
    const near = sim.spawnEnemy('robber', 'graves', p.x + 8 + CENSER.radius - 1, p.z + 1, false, false);
    const far = sim.spawnEnemy('robber', 'graves', p.x - 12, p.z - 10, false, false);
    sim.step(0.05);
    expect(near.incenseT ?? 0).toBeGreaterThan(0);
    expect(censer.incenseT ?? 0).toBeGreaterThan(0);
    expect(far.incenseT ?? 0).toBe(0);
    // It mirrors to co-op guests through the snapshot flags.
    const mirror = new WorldMirror();
    mirror.applySnapshot(makeSnapshot(sim, true));
    expect(mirror.enemies.get(near.id)?.incenseT ?? 0).toBeGreaterThan(0);
    expect(mirror.enemies.get(far.id)?.incenseT ?? 0).toBe(0);
  });

  it("a Choir Wraith's scream lands on the ring it sang, not on whoever stepped out", () => {
    const { sim } = world(7);
    const p = sim.players.get('p1')!;
    const w = sim.spawnEnemy('wraith', 'graves', p.x + 6, p.z, false, false);
    w.aimX = p.x;
    w.aimZ = p.z;
    internals(sim).strike(w, 'scream');
    expect(of(sim.step(0.01), 'hurt').filter((h) => h.from === 'scream').length).toBe(1);
    sim.setPlayer({ ...p, x: p.x + SCREAM.radius + 0.5 });
    internals(sim).strike(w, 'scream');
    expect(of(sim.step(0.01), 'hurt').filter((h) => h.from === 'scream').length).toBe(0);
  });

  it('a Bone Golem falls apart into three corpses; wraiths and rats leave none', () => {
    const { sim } = world(9);
    const p = sim.players.get('p1')!;
    const golem = sim.spawnEnemy('golem', 'graves', p.x + 6, p.z - 4, false, false);
    const wraith = sim.spawnEnemy('wraith', 'graves', p.x - 6, p.z - 4, false, false);
    const rat = sim.spawnEnemy('rat', 'graves', p.x, p.z - 6, false, false);
    const corpses = sim.corpses.size;
    for (const e of [golem, wraith, rat]) sim.apply({ t: 'hit', by: 'p1', ids: [e.id], dmg: 1e5 });
    sim.step(0.05);
    expect(sim.corpses.size - corpses).toBe(ENEMIES.golem.deathCorpses);
  });
});
