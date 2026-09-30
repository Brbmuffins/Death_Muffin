import { describe, expect, it } from 'vitest';
import { OMENS, OMEN_ORDER, omenEnds, omenFor, omenLeft, omenWeek } from '../../content/omens';
import { Nav } from '../nav';
import { WorldSim } from '../sim/WorldSim';
import { mulberry32 } from '../rng';

const MON = Date.UTC(2026, 8, 28, 0, 0, 0); // Monday 2026-09-28 00:00 UTC
const DAY = 24 * 3600 * 1000;

describe('weekly Omens', () => {
  it('changes on Monday 00:00 UTC and cycles through every omen in order', () => {
    expect(omenFor(MON).id).toBe(omenFor(MON + 6 * DAY + 23 * 3600 * 1000).id);
    expect(omenFor(MON + 7 * DAY).id).not.toBe(omenFor(MON).id);
    expect(omenFor(MON - 1).id).not.toBe(omenFor(MON).id);
    const seen = [0, 1, 2].map((w) => omenFor(MON + w * 7 * DAY).id);
    expect([...seen].sort()).toEqual([...OMEN_ORDER].sort());
    expect(omenFor(MON + 3 * 7 * DAY).id).toBe(omenFor(MON).id);
    expect(omenWeek(MON + 7 * DAY)).toBe(omenWeek(MON) + 1);
  });

  it('every omen is modest, has art and a rule, and the countdown reads sensibly', () => {
    for (const o of Object.values(OMENS)) {
      expect(o.rewardMult).toBeLessThanOrEqual(1.25);
      expect(o.waveSizeMult).toBeLessThanOrEqual(1.3);
      expect(o.eliteBonus).toBeLessThanOrEqual(0.08);
      expect(o.blurb.length).toBeGreaterThan(30);
      expect(o.icon.startsWith('art/omens/')).toBe(true);
    }
    expect(omenEnds(MON + 2 * DAY)).toBe(MON + 7 * DAY);
    expect(omenLeft(MON + 2 * DAY)).toBe('5 days');
    expect(omenLeft(MON + 7 * DAY - 2 * 3600 * 1000)).toBe('2 hours');
  });
});

/** Fight 60 waves in the Graves and total what arrived. */
function harvest(omenId: keyof typeof OMENS | null, seed = 11) {
  const nav = new Nav();
  const sim = new WorldSim(nav, mulberry32(seed));
  sim.omen = omenId ? OMENS[omenId] : null;
  sim.setPlayer({ id: 'p1', x: 0, z: -12, alive: true, area: 'graves', level: 5 });
  sim.markVisited('graves');
  let bodies = 0;
  let elites = 0;
  let tolled = 0;
  const spawn = sim as unknown as { spawnWave(area: string, first?: boolean): void };
  for (let i = 0; i < 60; i++) {
    sim.clearArea('graves');
    spawn.spawnWave('graves');
    for (const e of sim.enemies.values()) {
      bodies++;
      if (e.elite) {
        elites++;
        if (e.affix === 'bellTolled') tolled++;
      }
    }
  }
  return { bodies, elites, tolled };
}

describe('Omen effects in the sim', () => {
  it('Blood Moon brings more elites, Drowned Week bigger waves, the Tolling Bell-Tolled elites', () => {
    const base = harvest(null);
    const moon = harvest('blood_moon');
    const drowned = harvest('drowned_week');
    const toll = harvest('tolling');
    expect(moon.elites).toBeGreaterThan(base.elites * 1.5);
    expect(drowned.bodies).toBeGreaterThan(base.bodies * 1.15);
    expect(toll.elites).toBeGreaterThan(0);
    expect(toll.tolled).toBe(toll.elites);
    expect(base.tolled).toBeLessThan(base.elites);
  });
});
