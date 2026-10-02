import { describe, expect, it } from 'vitest';
import { AREAS, type AreaId } from '../../content/areas';
import { DISCIPLINES } from '../../content/disciplines';
import { densityTier, waveModifiers } from '../../content/upgrades';
import { runBalance, type BalanceResult } from '../balance/harness';
import { Nav } from '../nav';
import { mulberry32 } from '../rng';
import { WorldSim } from '../sim/WorldSim';

/**
 * Necromancer balance guards from the 2026-10-02 pass (BALANCE.md). The sim is deterministic per seed, so these
 * use three seeds and wide margins: they catch a regression of the shape ("Max Wave Speed is a trap again"),
 * not a tenth of a death. Targets are the bot's, which never dodges telegraphs.
 */
const SEEDS = [42, 43, 44];
const mean = (xs: number[]) => xs.reduce((a, b) => a + b, 0) / xs.length;

function band(area: AreaId, classIndex: number, kind: 'intended' | 'max') {
  const lvl = AREAS[area].level;
  const runs: BalanceResult[] = SEEDS.map((seed) =>
    runBalance({ area, classIndex, level: lvl, damageTier: Math.round(lvl * 0.6), gearStats: Math.round(lvl * 0.8), waveTier: kind === 'max' ? 8 : 0, minutes: 3, seed }),
  );
  return {
    kills: mean(runs.map((r) => r.killsPerMin)),
    gold: mean(runs.map((r) => r.goldPerMin)),
    xp: mean(runs.map((r) => r.xpPerMin)),
    deaths: mean(runs.map((r) => r.deaths)),
    /** Median seed's first death (a seed that never died counts as the whole run). */
    firstDeath: runs.map((r) => (r.firstDeathSec < 0 ? 180 : r.firstDeathSec)).sort((a, b) => a - b)[1],
  };
}

describe('Wave Speed curve', () => {
  it('density levels off after tier 3 while every reward keeps climbing', () => {
    expect(densityTier(3)).toBe(3);
    expect(densityTier(8) - densityTier(3)).toBeLessThan(3);
    for (let t = 1; t <= 8; t++) {
      const a = waveModifiers(t - 1);
      const b = waveModifiers(t);
      expect(b.rewardMult).toBeGreaterThan(a.rewardMult);
      expect(b.xpMult).toBeGreaterThan(a.xpMult);
      expect(b.capMult).toBeGreaterThanOrEqual(a.capMult);
      expect(b.enemyDamageMult).toBeGreaterThan(a.enemyDamageMult);
    }
    // The old curve piled tier 8 up to 4.6x pressure; per-enemy terms are now gentle.
    expect(waveModifiers(8).enemyHpMult).toBeLessThan(1.2);
    expect(waveModifiers(8).enemyDamageMult).toBeLessThan(1.3);
  });
});

describe('Wave Speed arrival and vacancy rules', () => {
  function world(tier: number) {
    const sim = new WorldSim(new Nav(), mulberry32(7));
    sim.waveTier = tier;
    sim.setPlayer({ id: 'p1', x: 0, z: -16, alive: true, area: 'graves' });
    return sim;
  }
  const alive = (sim: WorldSim) => [...sim.enemies.values()].filter((e) => e.state !== 'dead');

  it('builds pressure over the first seconds of a visit: the greeting wave ignores the dial', () => {
    const calm = world(0);
    const dial = world(8);
    calm.step(0.05);
    dial.step(0.05);
    const first = (s: WorldSim) => alive(s).map((e) => e.damage / (1 + 0.15 * (e.level - 1)));
    // Same seed, same wave: the damage of the greeting wave matches the base game at any dial.
    expect(mean(first(dial))).toBeCloseTo(mean(first(calm)), 5);
    expect(alive(dial).length).toBe(alive(calm).length);
  });

  it('an area nobody is in sinks back into its graves and greets the next arrival', () => {
    const sim = world(0);
    sim.step(0.05);
    expect(alive(sim).length).toBeGreaterThan(0);
    // The only player dies / leaves: nobody is in the graves any more.
    sim.setPlayer({ id: 'p1', x: 0, z: -16, alive: false, area: null });
    for (let t = 0; t < 7; t += 0.05) sim.step(0.05);
    expect(sim.enemies.size).toBeGreaterThan(0);
    for (let t = 0; t < 3; t += 0.05) sim.step(0.05);
    expect(sim.enemies.size).toBe(0);
    // Back in: a fresh opening wave rather than a leftover mob.
    sim.setPlayer({ id: 'p1', x: 0, z: -16, alive: true, area: 'graves' });
    sim.step(0.05);
    expect(alive(sim).length).toBeGreaterThan(0);
    expect(alive(sim).length).toBeLessThanOrEqual(Math.round(AREAS.graves.waveSize * 1.3) + 4);
  });
});

describe('necromancer balance (2026-10-02 pass)', () => {
  it('max Wave Speed pays more than the intended band and stays dangerous but survivable (Drowned Nave)', () => {
    const base = band('nave', 2, 'intended');
    const max = band('nave', 2, 'max');
    expect(max.gold).toBeGreaterThan(base.gold * 1.3);
    expect(max.xp).toBeGreaterThan(base.xp * 1.1);
    expect(max.kills).toBeGreaterThan(base.kills * 0.6);
    // Was 5-11 deaths with a first death at 5-20 s; now a handful, and the median seed lasts a while.
    expect(max.deaths).toBeLessThan(5);
    expect(max.deaths).toBeGreaterThan(0.3);
    expect(max.firstDeath).toBeGreaterThan(20);
  });

  it('every necromancer farms the Sanctum and the Coliseum at arrival level with about one death or fewer', () => {
    for (const area of ['sanctum', 'coliseum'] as const) {
      for (const classIndex of [1, 2, 3, 4]) {
        expect(band(area, classIndex, 'intended').deaths, `${area} ${DISCIPLINES[classIndex === 1 ? 'ossuary' : classIndex === 2 ? 'gravecaller' : classIndex === 3 ? 'mourner' : 'rotweaver'].name}`).toBeLessThanOrEqual(1.7);
      }
    }
  });

  it('the Ossuary no longer dies far more than the other necromancers under pressure', () => {
    const oss = band('nave', 1, 'max').deaths;
    const others = [2, 3, 4].map((c) => band('nave', c, 'max').deaths);
    expect(oss).toBeLessThan(Math.max(...others) + 1);
    expect(oss).toBeLessThan(5);
  });
});
