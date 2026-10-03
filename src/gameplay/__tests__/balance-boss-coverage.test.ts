import { describe, expect, it } from 'vitest';
import { AREAS } from '../../content/areas';
import { BOSSES, type BossId } from '../../content/bosses';
import { runBossFight, type BossRun } from '../balance/boss';

/**
 * Boss bot coverage (BALANCE.md "Boss bot coverage"): the bot plays the weapon line, takes damage through the real Player
 * (Litany barrier) and meets the Fen's open water. Coarse, directional checks: they fail if the bot goes back to ignoring a mechanic.
 */
const at = (boss: BossId, over: Partial<BossRun> = {}): BossRun => {
  const L = AREAS[BOSSES[boss].area].level;
  return { level: L, damageTier: Math.round(L * 0.6), gearStats: Math.round(L * 0.8), classIndex: 3, dodge: true, boss, seed: 42, kit: 'typical', ...over };
};

describe('weapon play-styles in a boss fight', () => {
  it('the weapon changes the fight: each style kills at its own pace and with its own damage', () => {
    const dps = (main: 'staff' | 'scythe' | 'wand' | 'sickle') => runBossFight(at('abbess', { kitOverride: { main } })).dps;
    const rows = { staff: dps('staff'), scythe: dps('scythe'), wand: dps('wand'), sickle: dps('sickle') };
    expect(new Set(Object.values(rows).map((v) => Math.round(v))).size).toBe(4);
  });

  it('a scythe fights closer than a staff: slower, and never safer (with the 4 m boss reach it can match a staff that dodges)', () => {
    const staff = runBossFight(at('abbess', { kitOverride: { main: 'staff' } }));
    const scythe = runBossFight(at('abbess', { kitOverride: { main: 'scythe' } }));
    expect(scythe.outcome).toBe('win');
    expect(scythe.seconds).toBeGreaterThan(staff.seconds);
    expect(scythe.dmgPctPerMin).toBeGreaterThanOrEqual(staff.dmgPctPerMin);
  });

  it('the scythe reaps the boss (it deals real damage, not a no-op arc)', () => {
    const r = runBossFight(at('gravedigger', { kitOverride: { main: 'scythe' } }));
    expect(r.outcome).toBe('win');
    expect(r.dps).toBeGreaterThan(100);
  });
});

describe('Litany barrier', () => {
  it('a Reliquary / Ossuary kit raises a barrier and the barrier soaks boss damage', () => {
    const r = runBossFight(at('prelate', { classIndex: 1, kit: 'ascended', dodge: false }));
    expect(r.barrierMadePct).toBeGreaterThan(0);
    expect(r.barrierAbsorbedPct).toBeGreaterThan(0);
    expect(r.barrierAbsorbedPct).toBeLessThanOrEqual(r.barrierMadePct + 1e-6);
  });

  it('a discipline with no barrier mod raises none', () => {
    const r = runBossFight(at('prelate', { classIndex: 2, kit: 'none', dodge: false }));
    expect(r.barrierMadePct).toBe(0);
  });
});

describe('open water', () => {
  it('in the Fen a careless bot wades and is rooted by the hands; a careful one hops between dry hummocks', () => {
    const careless = runBossFight(at('mire', { dodge: false, seed: 43 }));
    const careful = runBossFight(at('mire', { dodge: true, seed: 43 }));
    expect(careless.wadingPct).toBeGreaterThan(60);
    expect(careless.rootedS).toBeGreaterThan(0);
    expect(careful.wadingPct).toBeLessThan(40);
    expect(careful.rootedS).toBeLessThan(careless.rootedS);
    expect(careful.dmgPctPerMin).toBeLessThan(careless.dmgPctPerMin / 2);
  });

  it('a boss with no water slows nobody', () => {
    expect(runBossFight(at('abbess', { dodge: false })).wadingPct).toBe(0);
  });
});
