import { describe, expect, it } from 'vitest';
import { Nav } from '../nav';
import { WorldSim } from '../sim/WorldSim';
import { mulberry32 } from '../rng';
import { SURGE } from '../../content/enemies';
import { BOSSES } from '../../content/bosses';

function world(seed = 1) {
  const nav = new Nav();
  const sim = new WorldSim(nav, mulberry32(seed));
  sim.setPlayer({ id: 'p1', x: 0, z: -16, alive: true, area: 'graves' });
  return { nav, sim };
}

describe('core bug hunt: surge', () => {
  it('a surge abandoned with the area (everyone left) restarts the surge clock instead of leaving it expired', () => {
    const { sim } = world();
    sim.step(0.05);
    sim.startSurge('graves');
    expect(sim.surge).not.toBeNull();
    sim.surgeIn = -1; // the clock that opened it has long lapsed
    // the hero walks home; the hunting ground crumbles after its vacancy delay
    sim.setPlayer({ id: 'p1', x: 0, z: 20, alive: true, area: 'chapterhouse' });
    for (let i = 0; i < 200; i++) sim.step(0.05);
    expect(sim.surge).toBeNull();
    expect(sim.surgeIn).toBeGreaterThanOrEqual(SURGE.minIntervalS * 0.5);
  });
});

describe('core bug hunt: burrowed ghoul', () => {
  it('Withered and bleed damage over time cannot reach a ghoul that is underground', () => {
    const { sim } = world();
    const g = sim.spawnEnemy('ghoul', 'graves', 7, -16, false);
    expect(g.state).toBe('burrow');
    const hp = g.hp;
    g.withered = 5;
    g.witheredT = 5;
    g.witheredDps = 1e6;
    g.bleedT = 5;
    g.bleedDps = 1e6;
    for (let i = 0; i < 5; i++) sim.step(0.05);
    expect(g.state).toBe('burrow');
    expect(g.hp).toBe(hp);
  });
});

describe('core bug hunt: Mire Mother under the water', () => {
  it('Withered rot cannot hurt her while she is sunk', () => {
    const { sim } = world(60);
    const a = BOSSES.mire.arena;
    const keep = () => sim.setPlayer({ id: 'p1', x: a.x + 8, z: a.z + 6, alive: true, area: 'fen', level: 60 });
    keep();
    sim.apply({ t: 'summonBoss', by: 'p1', boss: 'mire' });
    let sunk = false;
    for (let t = 0; t < 25 && !sunk; t += 0.05) {
      keep();
      sim.step(0.05);
      sunk = sim.bossState.state === 'sunk';
    }
    expect(sunk).toBe(true);
    const b = sim.bossState;
    const hp = b.hp;
    b.withered = 5;
    b.witheredT = 5;
    b.witheredDps = 1000;
    keep();
    sim.step(0.05);
    expect(b.state).toBe('sunk');
    expect(b.hp).toBe(hp);
  });
});

describe('core bug hunt: socket id change (join / rejoin)', () => {
  it('retagPlayer hands the legion, rites and credit to the new id instead of crumbling them', () => {
    const { sim } = world();
    sim.setPlayer({ id: 'old', x: 0, z: -16, alive: true, area: 'graves' });
    sim.addCorpse(1, -16, 'normal', 'robber', false, 0, 1, 'graves');
    const c = [...sim.corpses.values()][0];
    sim.apply({ t: 'exhume', by: 'old', x: c.x, z: c.z, r: 1, kind: 'warrior', cap: 3, hp: 50, damage: 5, attackSpeedMult: 1 });
    sim.apply({ t: 'miasma', by: 'old', x: 0, z: -16, r: 3, dps: 5, durationMs: 6000, witheredCap: 5, bloom: false });
    expect(sim.thralls.size).toBe(1);
    sim.retagPlayer('old', 'new');
    sim.setPlayer({ id: 'new', x: 0, z: -16, alive: true, area: 'graves' });
    sim.step(0.05);
    expect(sim.thralls.size).toBe(1);
    expect([...sim.thralls.values()][0].owner).toBe('new');
    expect([...sim.zones.values()].every((z) => z.owner !== 'old')).toBe(true);
    expect(sim.players.has('old')).toBe(false);
  });
});
