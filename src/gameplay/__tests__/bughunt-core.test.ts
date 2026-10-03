import { describe, expect, it } from 'vitest';
import { Nav } from '../nav';
import { WorldSim } from '../sim/WorldSim';
import { mulberry32 } from '../rng';
import { SURGE } from '../../content/enemies';

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
