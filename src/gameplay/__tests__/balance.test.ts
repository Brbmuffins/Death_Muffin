import { describe, expect, it } from 'vitest';
import { AREAS } from '../../../server/rules/content/areas';
import { runBossFight } from '../balance/boss';
import { runBalance } from '../balance/harness';

/**
 * Balance guard rails (coarse on purpose — BALANCE.md holds the real targets).
 * They catch content changes that make the game trivial or impossible.
 */
const L = AREAS.sanctum.level;
const intended = { level: L, damageTier: Math.round(L * 0.6), gearStats: Math.round(L * 0.8) };

describe('balance guard rails', () => {
  it('the Prelate is a real fight for a careful arrival-level player', () => {
    const r = runBossFight({ ...intended, classIndex: 3, dodge: true, seed: 42 });
    expect(r.outcome).toBe('win');
    expect(r.seconds).toBeGreaterThan(90);
    expect(r.seconds).toBeLessThan(300);
    expect(r.phase2At).toBeGreaterThan(0);
    expect(r.phase3At).toBeGreaterThan(r.phase2At);
  });

  it('standing in every telegraph at arrival level gets you killed', () => {
    const r = runBossFight({ ...intended, classIndex: 3, dodge: false, seed: 42 });
    expect(r.outcome).toBe('wipe');
  });

  it('the Hollow Graves are survivable but not free for a new character', () => {
    const runs = [1, 2, 3, 4].map((classIndex) =>
      runBalance({ area: 'graves', level: 1, classIndex, damageTier: 1, waveTier: 0, gearStats: 1, minutes: 2, seed: 42 }),
    );
    for (const r of runs) {
      expect(r.deaths).toBe(0);
      expect(r.killsPerMin).toBeGreaterThan(40);
    }
    // Across the four disciplines the dead land some blows.
    expect(runs.reduce((s, r) => s + r.damageTakenPerMin, 0)).toBeGreaterThan(0);
  });
});
