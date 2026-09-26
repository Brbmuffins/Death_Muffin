import { describe, expect, it } from 'vitest';
import { Nav } from '../nav';
import { WorldSim } from '../sim/WorldSim';
import { WorldMirror, makeSnapshot } from '../sim/snapshot';
import { mulberry32 } from '../rng';
import type { SimEvent } from '../sim/types';

function world(seed = 1) {
  const nav = new Nav();
  const sim = new WorldSim(nav, mulberry32(seed));
  sim.setPlayer({ id: 'p1', x: 0, z: -16, alive: true, area: 'graves' });
  return { nav, sim };
}

const exhume = (x: number, z: number, cap = 3) =>
  ({ t: 'exhume', by: 'p1', x, z, r: 1, kind: 'warrior', cap, hp: 50, damage: 5, attackSpeedMult: 1 }) as const;

describe('WorldSim', () => {
  it('opens an area with a wave when a player first enters it', () => {
    const { sim } = world();
    const ev = sim.step(0.016);
    expect(ev.some((e) => e.t === 'wave')).toBe(true);
    expect(sim.enemies.size).toBeGreaterThan(0);
    for (const e of sim.enemies.values()) expect(e.area).toBe('graves');
  });

  it('never spawns into the safe chapterhouse', () => {
    const { sim } = world();
    sim.setPlayer({ id: 'p1', x: 0, z: 20, alive: true, area: 'chapterhouse' });
    for (let i = 0; i < 300; i++) sim.step(0.05);
    expect(sim.enemies.size).toBe(0);
  });

  it('kills leave corpses; exhume consumes one and raises a thrall', () => {
    const { sim } = world();
    const e = sim.spawnEnemy('robber', 'graves', 2, -16, false, false);
    sim.apply({ t: 'hit', by: 'p1', ids: [e.id], dmg: 9999 });
    const ev = sim.step(0.016);
    const death = ev.find((x): x is Extract<SimEvent, { t: 'death' }> => x.t === 'death');
    expect(death?.killer).toBe('p1');
    expect(sim.corpses.size).toBe(1);
    const corpse = [...sim.corpses.values()][0];
    sim.apply(exhume(corpse.x, corpse.z));
    expect(sim.corpses.size).toBe(0);
    expect(sim.thralls.size).toBe(1);
  });

  it('the thrall cap crumbles the oldest thrall', () => {
    const { sim } = world();
    for (let i = 0; i < 4; i++) {
      sim.addCorpse(1 + i, -16, 'normal', 'robber', false, 0, 1, 'graves');
      sim.step(0.1);
      sim.apply(exhume(1 + i, -16, 3));
    }
    expect(sim.thralls.size).toBe(3);
  });

  it('fracture amplifies later hits', () => {
    const { sim } = world();
    const e = sim.spawnEnemy('sac', 'graves', 3, -16, false, false);
    const start = e.hp;
    sim.apply({ t: 'hit', by: 'p1', ids: [e.id], dmg: 10, fracture: 1 });
    const afterFirst = e.hp;
    sim.apply({ t: 'hit', by: 'p1', ids: [e.id], dmg: 10 });
    expect(start - afterFirst).toBeCloseTo(10);
    expect(afterFirst - e.hp).toBeCloseTo(11.5);
  });

  it('black litany consumes corpses in radius, sacrifices thralls and scales damage', () => {
    const { sim } = world();
    sim.clearArea('graves');
    const e = sim.spawnEnemy('sac', 'graves', 0, -19, false, false);
    const hp0 = e.hp;
    for (let i = 0; i < 4; i++) sim.addCorpse(i - 2, -15, 'normal', 'robber', false, 0, 1, 'graves');
    sim.addCorpse(10, -16, 'normal', 'robber', false, 0, 1, 'graves'); // outside radius
    sim.apply({ t: 'litany', by: 'p1', x: 0, z: -16, r: 7, spellPower: 10, leaveCorpses: false });
    const ev = sim.drain();
    const res = ev.find((x): x is Extract<SimEvent, { t: 'litanyResult' }> => x.t === 'litanyResult')!;
    expect(res.corpses).toBe(4);
    expect(sim.corpses.size).toBe(1);
    // 1.5 base + 0.6 × 4 corpses = 3.9 × spell power.
    expect(hp0 - e.hp).toBeCloseTo(39, 0);
  });

  it('toxic corpses rupture into a hostile zone that hurts players', () => {
    const { sim } = world();
    sim.clearArea('graves');
    sim.addCorpse(0, -16, 'toxic', 'sac', false, 0, 1, 'graves');
    let hurt = 0;
    for (let i = 0; i < 140; i++) for (const ev of sim.step(0.05)) if (ev.t === 'hurt' && ev.from === 'toxic') hurt++;
    expect(hurt).toBeGreaterThan(0);
  });

  it('deacons steal unclaimed corpses and raise Risen', () => {
    const { sim } = world();
    sim.clearArea('graves');
    sim.setPlayer({ id: 'p1', x: 15, z: -30, alive: true, area: 'graves' });
    sim.spawnEnemy('deacon', 'graves', -10, -10, false, false);
    sim.addCorpse(-8, -10, 'normal', 'robber', false, 0, 1, 'graves');
    let raised = false;
    for (let i = 0; i < 200 && !raised; i++) for (const ev of sim.step(0.05)) if (ev.t === 'corpseGone' && ev.reason === 'raised') raised = true;
    expect(raised).toBe(true);
    expect([...sim.enemies.values()].some((e) => e.def === 'risen')).toBe(true);
  });

  it('snapshots round-trip into a mirror and can seed a new host', () => {
    const { sim, nav } = world();
    for (let i = 0; i < 20; i++) sim.step(0.05);
    sim.addCorpse(1, -16, 'normal', 'robber', false, 0, 1, 'graves');
    const mirror = new WorldMirror();
    mirror.applySnapshot(makeSnapshot(sim, true));
    expect(mirror.enemies.size).toBe(sim.enemies.size);
    expect(mirror.corpses.size).toBe(sim.corpses.size);
    const next = new WorldSim(nav);
    mirror.seed(next);
    expect(next.enemies.size).toBe(sim.enemies.size);
    // New ids never collide with inherited ones.
    const maxInherited = Math.max(...next.enemies.keys(), ...next.corpses.keys());
    expect(next.id()).toBeGreaterThan(maxInherited);
  });

  it('the Prelate awakens, changes phase and can be defeated', () => {
    const { sim } = world();
    sim.setPlayer({ id: 'p1', x: 0, z: -110, alive: true, area: 'sanctum' });
    sim.apply({ t: 'summonBoss', by: 'p1' });
    expect(sim.bossState.active).toBe(true);
    sim.apply({ t: 'hit', by: 'p1', ids: [], dmg: sim.bossState.maxHp * 0.5, boss: true });
    sim.step(0.05);
    expect(sim.bossState.phase).toBe(2);
    sim.apply({ t: 'hit', by: 'p1', ids: [], dmg: sim.bossState.maxHp, boss: true });
    const ev = sim.step(0.05);
    expect(ev.some((e) => e.t === 'boss' && e.kind === 'defeated' && e.killer === 'p1')).toBe(true);
  });
});
