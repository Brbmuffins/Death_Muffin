import { describe, expect, it } from 'vitest';
import { NODES, actionMs } from '../gatheringRules';
import { LABOR, assignBlocker, claimRng, estimate, hashSeed, laborActions, laborSlots, postsFor, rollLabor, totalGatherLevel } from '../laborRules';

const oak = NODES.coffin_oak;

describe('laborers', () => {
  it('unlock one slot, then one per 50 gathering levels, up to four', () => {
    expect(laborSlots(4)).toBe(1);
    expect(laborSlots(49)).toBe(1);
    expect(laborSlots(50)).toBe(2);
    expect(laborSlots(150)).toBe(4);
    expect(laborSlots(999)).toBe(4);
    expect(totalGatherLevel({})).toBe(4);
    expect(totalGatherLevel({ woodcutting: 20, mining: 10, fishing: 1, gravedigging: 5, gardening: 90 })).toBe(36);
  });

  it('only offers posts the level allows', () => {
    expect(postsFor({}).every((n) => n.level === 1)).toBe(true);
    expect(postsFor({ mining: 40 }).some((n) => n.id === 'seam_gold')).toBe(true);
    expect(assignBlocker('seam_gold', {})).toMatch(/level 40/);
    expect(assignBlocker('nope', {})).toMatch(/not a place/);
    expect(assignBlocker('coffin_oak', {})).toBeNull();
  });

  it('works at a fraction of the player pace, capped at eight hours', () => {
    const hour = 3_600_000;
    const perHour = (hour / actionMs(oak)) * LABOR.factor;
    expect(laborActions(oak, hour)).toBe(Math.floor(perHour));
    expect(laborActions(oak, 8 * hour)).toBe(laborActions(oak, 20 * hour));
    expect(laborActions(oak, 5_000)).toBe(0);
  });

  it('estimates and rolls consistently, and pays a quarter of the XP into the real level', () => {
    const elapsed = 4 * 3_600_000;
    const est = estimate(oak, 10, elapsed);
    expect(est.actions).toBeGreaterThan(100);
    const roll = rollLabor(oak, { level: 10, xp: 0 }, elapsed, claimRng(hashSeed(1, 0, 1234)));
    expect(roll.actions).toBe(est.actions);
    const logs = roll.items.find((i) => i.itemId === 'log_oak')?.qty ?? 0;
    expect(Math.abs(logs - est.items)).toBeLessThan(est.actions * 0.2);
    // A player would earn roughly 4x this XP from the same finds.
    expect(roll.xp).toBeLessThan(logs * oak.xp * 0.4);
    expect(roll.xp).toBeGreaterThan(0);
  });

  it('is repeatable for the same claim and different for another', () => {
    const a = rollLabor(oak, { level: 1, xp: 0 }, 3_600_000, claimRng(hashSeed(7, 0, 999)));
    const b = rollLabor(oak, { level: 1, xp: 0 }, 3_600_000, claimRng(hashSeed(7, 0, 999)));
    const c = rollLabor(oak, { level: 1, xp: 0 }, 3_600_000, claimRng(hashSeed(7, 1, 999)));
    expect(b).toEqual(a);
    expect(c.items).not.toEqual(a.items);
  });
});
