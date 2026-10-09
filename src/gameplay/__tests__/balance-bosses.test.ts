import { describe, expect, it } from 'vitest';
import { AREAS } from '../../../server/rules/content/areas';
import { BOSSES, BOSS_IDS } from '../../../server/rules/content/bosses';
import { runBossFight } from '../balance/boss';

/**
 * Every area boss at its arrival level, no gear kit (BALANCE.md "polish round 2"): a careful player wins in a real
 * fight (2-5 minutes, three phases), and ignoring the telegraphs hurts. Coarse on purpose, same spirit as balance.test.ts.
 */
describe.each(BOSS_IDS)('boss %s at arrival level', (boss) => {
  const L = AREAS[BOSSES[boss].area].level;
  const intended = { level: L, damageTier: Math.round(L * 0.6), gearStats: Math.round(L * 0.8), boss };

  it.each([2, 3])('discipline %i: a dodging player wins a real fight', (classIndex) => {
    const r = runBossFight({ ...intended, classIndex, dodge: true, seed: 42 });
    expect(r.outcome).toBe('win');
    expect(r.seconds).toBeGreaterThan(100);
    expect(r.seconds).toBeLessThan(300);
    expect(r.phase2At).toBeGreaterThan(0);
    expect(r.phase3At).toBeGreaterThan(r.phase2At);
  });

  it('standing in every telegraph costs at least 60% of max health a minute', () => {
    const r = runBossFight({ ...intended, classIndex: 3, dodge: false, seed: 42 });
    expect(r.dmgPctPerMin).toBeGreaterThan(60);
  });
});
