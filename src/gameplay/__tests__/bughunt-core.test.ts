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
