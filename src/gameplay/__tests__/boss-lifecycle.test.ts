import { describe, expect, it } from 'vitest';
import { Nav } from '../nav';
import { mulberry32 } from '../rng';
import { WorldSim } from '../sim/WorldSim';
import { Player } from '../Player';
import { CHILL } from '../../content/statuses';

function world() {
  const sim = new WorldSim(new Nav(), mulberry32(9));
  sim.setPlayer({ id: 'p1', x: 0, z: -110, alive: true, area: 'sanctum' });
  sim.apply({ t: 'summonBoss', by: 'p1' });
  sim.step(0.05);
  return sim;
}

describe('boss attempt lifecycle', () => {
  it('clears old Fracture and Withered when a boss is summoned after a wipe', () => {
    const sim = world();
    const boss = sim.bossState;
    boss.fracture = 4;
    boss.fractureT = 10;
    boss.withered = 6;
    boss.witheredT = 10;
    boss.witheredDps = 100;

    sim.setPlayer({ id: 'p1', x: 0, z: -110, alive: false, area: 'sanctum' });
    sim.step(0.05);
    expect(boss.active).toBe(false);

    sim.setPlayer({ id: 'p1', x: 0, z: -110, alive: true, area: 'sanctum' });
    sim.apply({ t: 'summonBoss', by: 'p1' });
    expect(boss).toMatchObject({ active: true, hp: boss.maxHp, fracture: 0, fractureT: 0, withered: 0, witheredT: 0, witheredDps: 0 });
    sim.step(0.05);
    expect(boss.hp).toBe(boss.maxHp);
  });

  it('removes phase summons when the fight ends, without turning them into kills', () => {
    const sim = world();
    const before = new Set(sim.enemies.keys());
    sim.apply({ t: 'hit', by: 'p1', ids: [], dmg: sim.bossState.maxHp * 0.5, boss: true });
    sim.step(0.05);
    const adds = [...sim.enemies.keys()].filter((id) => !before.has(id));
    expect(adds.length).toBe(4);

    sim.setPlayer({ id: 'p1', x: 0, z: -110, alive: false, area: 'sanctum' });
    const events = sim.step(0.05);
    expect(sim.bossState.active).toBe(false);
    expect(adds.every((id) => !sim.enemies.has(id))).toBe(true);
    expect(events.some((e) => e.t === 'death' && adds.includes(e.id))).toBe(false);
  });

  it('marks an uncovered Flood Hymn hit with two seconds of Chill', () => {
    const sim = new WorldSim(new Nav(), mulberry32(9));
    sim.setPlayer({ id: 'p1', x: 0, z: -67, alive: true, area: 'nave' });
    sim.apply({ t: 'summonBoss', by: 'p1', boss: 'congregation' });
    let hit = null as Extract<ReturnType<typeof sim.step>[number], { t: 'hurt' }> | null;
    for (let i = 0; i < 200 && !hit; i++) {
      for (const event of sim.step(0.05)) if (event.t === 'hurt' && event.chillMs) hit = event;
    }
    expect(hit).toMatchObject({ player: 'p1', from: 'boss', chillMs: 2000 });
  });

  it('judges Flood Hymn pew cover from the telegraphed origin', () => {
    const sim = new WorldSim(new Nav(), mulberry32(9));
    sim.setPlayer({ id: 'p1', x: 0, z: -67, alive: true, area: 'nave' });
    sim.setCover([{ x0: -0.5, z0: -65.5, x1: 0.5, z1: -65.2 }]);
    sim.apply({ t: 'summonBoss', by: 'p1', boss: 'congregation' });
    let telegraphed = false;
    let impact = false;
    let chilled = false;
    for (let i = 0; i < 220 && !impact; i++) {
      const events = sim.step(0.05);
      if (events.some((e) => e.t === 'boss' && e.kind === 'hymn' && (e.ms ?? 0) > 0)) {
        telegraphed = true;
        // The boss moves during the cast. The marked tide still starts where the tell appeared.
        sim.bossState.x = 3;
      }
      if (events.some((e) => e.t === 'boss' && e.kind === 'hymn' && e.ms === 0)) {
        impact = true;
        chilled = events.some((e) => e.t === 'hurt' && !!e.chillMs);
      }
    }
    expect(telegraphed).toBe(true);
    expect(impact).toBe(true);
    expect(chilled).toBe(false);
  });

  it('slows a Chilled player until the effect ends and clears it on revival', () => {
    const stats = { level: 10, maxHp: 100, spellPower: 20, maxEssence: 150, essenceRegen: 5,
      moveSpeed: 5.4, thrallHp: 45, thrallDamage: 8, damageBonusPct: 0 };
    const normal = new Player(stats, new Nav());
    const chilled = new Player(stats, new Nav());
    normal.teleport(0, 10);
    chilled.teleport(0, 10);
    chilled.chilledUntil = 2000;
    normal.update(0.1, 1000, { x: 1, z: 0 });
    chilled.update(0.1, 1000, { x: 1, z: 0 });
    expect(chilled.x).toBeCloseTo(normal.x * CHILL.moveMult, 5);
    chilled.alive = false;
    chilled.revive();
    expect(chilled.chilledUntil).toBe(0);
  });
});
