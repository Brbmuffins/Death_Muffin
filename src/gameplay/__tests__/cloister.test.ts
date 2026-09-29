import { describe, expect, it } from 'vitest';
import { Nav } from '../nav';
import { WorldSim } from '../sim/WorldSim';
import { mulberry32 } from '../rng';
import type { SimEvent } from '../sim/types';
import { SaintBrain } from '../sim/BossBrain';
import { BOSSES, SAINT, summonSpot } from '../../content/bosses';
import { AREAS } from '../../content/areas';
import { FRENZY, PLAGUE_FLASK } from '../../content/enemies';
import { CODEX_DEAD } from '../../content/codex';

function world(level = 49, seed = 5) {
  const nav = new Nav();
  nav.setUnlocked(['chapterhouse', 'graves', 'ossuary', 'nave', 'sanctum', 'cloister']);
  const sim = new WorldSim(nav, mulberry32(seed));
  const a = BOSSES.saint.arena;
  sim.setPlayer({ id: 'p1', x: a.x, z: a.z + 6, alive: true, area: 'cloister', level });
  sim.markVisited('cloister');
  return sim;
}
const run = (sim: WorldSim, s: number) => {
  const out: SimEvent[] = [];
  for (let t = 0; t < s; t += 0.05) out.push(...sim.step(0.05));
  return out;
};

describe('Plague Cloister', () => {
  it('scales enemy level to the highest player in it, never below its floor', () => {
    const sim = world(49);
    expect(sim.areaLevel('cloister')).toBe(49);
    expect(sim.areaLevel('graves')).toBe(AREAS.graves.level);
    sim.setPlayer({ id: 'p1', x: 44, z: -115, alive: true, area: 'cloister', level: 3 });
    expect(sim.areaLevel('cloister')).toBe(AREAS.cloister.scaling!.minLevel);
    // A higher-level partner elsewhere doesn't count.
    sim.setPlayer({ id: 'p2', x: 0, z: 0, alive: true, area: 'chapterhouse', level: 80 });
    expect(sim.areaLevel('cloister')).toBe(AREAS.cloister.scaling!.minLevel);
    const lo = sim.spawnEnemy('flagellant', 'cloister', 44, -115, false, false);
    sim.setPlayer({ id: 'p1', x: 44, z: -115, alive: true, area: 'cloister', level: 60 });
    const hi = sim.spawnEnemy('flagellant', 'cloister', 44, -115, false, false);
    expect(hi.maxHp).toBeGreaterThan(lo.maxHp);
  });

  it("a plague doctor's flask leaves a hostile rot pool where it lands", () => {
    const sim = world(20);
    sim.spawnEnemy('plague_doctor', 'cloister', 44, -110, false, false);
    const ev = run(sim, 12);
    const tele = ev.find((e) => e.t === 'telegraph' && e.kind === 'flask');
    expect(tele).toBeDefined();
    const pool = ev.find((e): e is Extract<SimEvent, { t: 'zone' }> => e.t === 'zone' && !!e.zone.hostile);
    expect(pool).toBeDefined();
    expect(pool!.zone.r).toBeCloseTo(PLAGUE_FLASK.radius);
  });

  it('flagellants frenzy below half health', () => {
    const sim = world(20);
    const e = sim.spawnEnemy('flagellant', 'cloister', 44, -125, false, false);
    const frenzied = () => (sim as unknown as { frenzied(e: unknown): boolean }).frenzied(e);
    expect(frenzied()).toBe(false);
    e.hp = e.maxHp * (FRENZY.atFrac - 0.01);
    expect(frenzied()).toBe(true);
  });

  it('the Plague Saint has a summon at her arena edge and a Codex entry', () => {
    const it = AREAS.cloister.interactables.find((i) => i.id === BOSSES.saint.summonId)!;
    const [x, z] = summonSpot('saint');
    expect(Math.hypot(it.x - x, it.z - z)).toBeLessThan(0.6);
    expect(CODEX_DEAD.saint.counter.length).toBeGreaterThan(30);
  });

  it('Rot Rain leaves pools, and she heals only while standing in one', () => {
    const sim = world(30);
    sim.apply({ t: 'summonBoss', by: 'p1', boss: 'saint' });
    expect(sim.bossState.id).toBe('saint');
    const b = sim.bossState;
    const ev = run(sim, 12);
    const rain = ev.filter((e) => e.t === 'boss' && e.kind === 'rotRain' && (e.ms ?? 0) === 0);
    expect(rain.length).toBeGreaterThan(0);
    const pools = ev.filter((e) => e.t === 'zone' && e.zone.hostile && e.zone.r === SAINT.rain.r);
    expect(pools.length).toBeGreaterThanOrEqual(SAINT.rain.circles[0]);
    // Clear the rot and stand her on clean ground: no healing.
    sim.zones.clear();
    b.hp = b.maxHp * 0.7;
    const brain = sim.bosses.saint as SaintBrain;
    (brain as unknown as { tick(dt: number): void }).tick(1);
    expect(b.hp).toBeCloseTo(b.maxHp * 0.7);
    // Now a pool under her: she heals.
    sim.addHostilePool(b.x, b.z, 2, 1, 5);
    (brain as unknown as { tick(dt: number): void }).tick(1);
    expect(b.hp).toBeGreaterThan(b.maxHp * 0.7);
  });
});
