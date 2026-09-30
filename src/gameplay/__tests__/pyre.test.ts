import { describe, expect, it } from 'vitest';
import { Nav } from '../nav';
import { WorldSim } from '../sim/WorldSim';
import { mulberry32 } from '../rng';
import type { SimEvent } from '../sim/types';
import { AREAS, DOORS } from '../../content/areas';
import { EMBER_BOLT, EMBER_DEATH, ENEMIES, SLAG_POOL } from '../../content/enemies';
import { CODEX_DEAD } from '../../content/codex';
import { BOSSES, REGENT, summonSpot } from '../../content/bosses';
import { Player } from '../Player';

const ALL = ['chapterhouse', 'graves', 'ossuary', 'nave', 'sanctum', 'cloister', 'pyre'] as const;

function world(level = 40, seed = 7) {
  const nav = new Nav();
  nav.setUnlocked([...ALL]);
  const sim = new WorldSim(nav, mulberry32(seed));
  sim.setPlayer({ id: 'p1', x: 90, z: -108, alive: true, area: 'pyre', level });
  sim.markVisited('pyre');
  return sim;
}
const run = (sim: WorldSim, s: number) => {
  const out: SimEvent[] = [];
  for (let t = 0; t < s; t += 0.05) out.push(...sim.step(0.05));
  return out;
};
const ember = (ev: SimEvent[]) => ev.filter((e): e is Extract<SimEvent, { t: 'zone' }> => e.t === 'zone' && e.zone.kind === 'ember' && !!e.zone.hostile);

describe('Cinder Pyre', () => {
  it('is a level-scaled area past the Cloister, joined by a door on its east wall', () => {
    const a = AREAS.pyre;
    expect(a.unlock?.area).toBe('cloister');
    expect(a.scaling!.minLevel).toBeGreaterThan(AREAS.cloister.scaling!.minLevel);
    const door = DOORS.find((d) => d.b === 'pyre')!;
    expect(door.a).toBe('cloister');
    expect(door.rect.x0).toBeLessThan(AREAS.cloister.rect.x1);
    expect(door.rect.x1).toBeGreaterThan(a.rect.x0);
    // No area overlaps it.
    for (const id of ALL) {
      if (id === 'pyre') continue;
      const r = AREAS[id].rect;
      expect(r.x1 <= a.rect.x0 || r.x0 >= a.rect.x1 || r.z1 <= a.rect.z0 || r.z0 >= a.rect.z1).toBe(true);
    }
    const sim = world(60);
    expect(sim.areaLevel('pyre')).toBe(60);
  });

  it('spawns only its own mobs, and every one has a Codex entry', () => {
    const roster = AREAS.pyre.enemies.map((e) => e.id);
    expect(roster).toEqual(['cinder_husk', 'pyre_priest', 'cinderhound', 'slag_brute']);
    for (const id of roster) expect(CODEX_DEAD[id].counter.length).toBeGreaterThan(30);
  });

  it("a pyre priest's coal leaves a hostile ember pool where it lands", () => {
    const sim = world(30);
    sim.spawnEnemy('pyre_priest', 'pyre', 90, -112, false, false);
    const ev = run(sim, 12);
    expect(ev.find((e) => e.t === 'telegraph' && e.kind === 'ember')).toBeDefined();
    const pool = ember(ev)[0];
    expect(pool).toBeDefined();
    expect(pool.zone.r).toBeCloseTo(EMBER_BOLT.radius);
  });

  it('a cinder husk leaves burning ground where it dies', () => {
    const sim = world(30);
    const e = sim.spawnEnemy('cinder_husk', 'pyre', 80, -120, false, false);
    e.hp = 0;
    const ev = sim.step(0.05);
    const pool = ember(ev)[0];
    expect(pool).toBeDefined();
    expect(pool.zone.r).toBeCloseTo(EMBER_DEATH.radius);
    expect(ev.some((x) => x.t === 'burst' && x.kind === 'ember')).toBe(true);
    expect(ENEMIES.cinder_husk.emberDeath).toBe(true);
  });

  it('a slag brute slam leaves its ring burning', () => {
    const sim = world(30);
    sim.spawnEnemy('slag_brute', 'pyre', 90, -112, false, false);
    const ev = run(sim, 10);
    expect(ev.find((e) => e.t === 'telegraph' && e.kind === 'slam')).toBeDefined();
    const pool = ember(ev)[0];
    expect(pool).toBeDefined();
    expect(pool.zone.r).toBeCloseTo(ENEMIES.slag_brute.slamRadius!);
    expect(pool.zone.until - pool.zone.bornAt).toBeCloseTo(SLAG_POOL.poolS);
  });

  it('cinderhounds arrive in packs', () => {
    const sim = world(30);
    const before = sim.enemies.size;
    sim.spawnEnemy('cinderhound', 'pyre', 90, -112, false, false);
    expect(ENEMIES.cinderhound.pack).toEqual([2, 3]);
    expect(sim.enemies.size).toBeGreaterThanOrEqual(before + 1);
  });

  it('standing in burning ground hurts with the ember source', () => {
    const sim = world(30);
    (sim as unknown as { emberPool(x: number, z: number, r: number, s: number, dps: number): unknown }).emberPool(90, -108, 2, 5, 3);
    const ev = run(sim, 2);
    expect(ev.some((e) => e.t === 'hurt' && e.from === 'burn')).toBe(true);
  });

  it('the Cinder Regent has a summon at its arena edge and a Codex entry', () => {
    const it = AREAS.pyre.interactables.find((i) => i.id === BOSSES.regent.summonId)!;
    const [x, z] = summonSpot('regent');
    expect(Math.hypot(it.x - x, it.z - z)).toBeLessThan(0.6);
    expect(CODEX_DEAD.regent.counter.length).toBeGreaterThan(30);
  });

  it('Conflagration burns everyone off the ash and spares whoever stands on it', () => {
    const sim = world(30);
    const a = BOSSES.regent.arena;
    sim.apply({ t: 'summonBoss', by: 'p1', boss: 'regent' });
    expect(sim.bossState.id).toBe('regent');
    const ash: [number, number] = [a.x + 4, a.z];
    sim.setPlayer({ id: 'p1', x: ash[0], z: ash[1], alive: true, area: 'pyre', level: 30 });
    sim.setPlayer({ id: 'p2', x: a.x - 6, z: a.z + 2, alive: true, area: 'pyre', level: 30 });
    const brain = sim.bosses.regent as unknown as { resolve(p: unknown, players: unknown[]): void };
    sim.step(0.001);
    brain.resolve({ kind: 'conflagration', at: 0, x: a.x, z: a.z, r: a.r, targets: [ash] }, [...sim.players.values()]);
    const ev = sim.step(0.001);
    const hurt = ev.filter((e): e is Extract<SimEvent, { t: 'hurt' }> => e.t === 'hurt' && e.from === 'ember');
    expect(hurt.map((h) => h.player)).toEqual(['p2']);
    expect(ev.some((e) => e.t === 'boss' && e.kind === 'conflagration')).toBe(true);
    expect(REGENT.conflagration.safe[2]).toBeLessThan(REGENT.conflagration.safe[0]);
  });

  it('the Regent telegraphs Conflagration with ash circles inside its arena, and coals leave burning ground', () => {
    const sim = world(30);
    const a = BOSSES.regent.arena;
    sim.apply({ t: 'summonBoss', by: 'p1', boss: 'regent' });
    sim.setPlayer({ id: 'p1', x: a.x, z: a.z + 5, alive: true, area: 'pyre', level: 30 });
    sim.bossState.hp = sim.bossState.maxHp;
    const ev: SimEvent[] = [];
    for (let t = 0; t < 40; t += 0.05) {
      sim.setPlayer({ id: 'p1', x: a.x, z: a.z + 5, alive: true, area: 'pyre', level: 30 });
      ev.push(...sim.step(0.05));
    }
    const tele = ev.find((e) => e.t === 'boss' && e.kind === 'conflagration' && (e.ms ?? 0) > 0) as Extract<SimEvent, { t: 'boss' }> | undefined;
    expect(tele).toBeDefined();
    expect(tele!.targets!.length).toBe(REGENT.conflagration.safe[0]);
    for (const [x, z] of tele!.targets!) expect(Math.hypot(x - a.x, z - a.z)).toBeLessThanOrEqual(a.r);
    expect(ember(ev).length).toBeGreaterThan(0);
  });

  it('burning ground reaches a Veilwalker mid-phase (like toxic pools), while a direct blow is phased through', () => {
    const stats = { level: 12, maxHp: 100, spellPower: 20, maxEssence: 150, essenceRegen: 5, moveSpeed: 5.4, thrallHp: 45, thrallDamage: 8, damageBonusPct: 0 };
    const veil = new Player(stats, new Nav(), 'veil');
    veil.resource.value = 30;
    veil.veilForm = true;
    expect(veil.takeDamage(20, 0, 1000, undefined, 'ember')).toBe(0);
    expect(veil.takeDamage(20, 0, 1000, undefined, 'burn')).toBeGreaterThan(0);
  });
});
