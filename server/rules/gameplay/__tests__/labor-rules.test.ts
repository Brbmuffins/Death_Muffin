import { describe, expect, it } from 'vitest';
import { GATHER_SKILLS, NODES, actionMs } from '../gatheringRules';
import { LABOR, assignBlocker, claimRng, estimate, hashSeed, laborActions, laborSlots, postsFor, rollLabor, totalGatherLevel } from '../laborRules';

const oak = NODES.coffin_oak;
/** The base nodes a laborer can work (the garden is for the player). */
const posts = Object.values(NODES).filter((n) => n.skill !== 'gardening');

describe('laborers', () => {
  it('unlock one slot, then one more per LABOR.levelsPerSlot gathering levels, up to LABOR.maxSlots', () => {
    expect(laborSlots(0)).toBe(1);
    expect(laborSlots(LABOR.levelsPerSlot - 1)).toBe(1);
    expect(laborSlots(LABOR.levelsPerSlot)).toBe(Math.min(2, LABOR.maxSlots));
    let last = 0;
    for (let total = 0; total <= LABOR.levelsPerSlot * (LABOR.maxSlots + 2); total++) {
      const slots = laborSlots(total);
      expect(slots).toBeGreaterThanOrEqual(last); // more levels never take a laborer away
      expect(slots).toBeLessThanOrEqual(LABOR.maxSlots);
      last = slots;
    }
    expect(last).toBe(LABOR.maxSlots);
    expect(laborSlots(LABOR.levelsPerSlot * LABOR.maxSlots * 100)).toBe(LABOR.maxSlots);
  });

  it('counts the levels of the gather skills only, each at least 1', () => {
    expect(totalGatherLevel({})).toBe(GATHER_SKILLS.length);
    const levels = Object.fromEntries(GATHER_SKILLS.map((s, i) => [s, 5 + i * 7]));
    const sum = GATHER_SKILLS.reduce((n, s) => n + levels[s], 0);
    expect(totalGatherLevel(levels)).toBe(sum);
    expect(totalGatherLevel({ ...levels, not_a_gather_skill: 90 })).toBe(sum);
    expect(totalGatherLevel({ [GATHER_SKILLS[0]]: 0 })).toBe(GATHER_SKILLS.length);
  });

  it('only offers posts the level allows', () => {
    expect(postsFor({}).every((n) => n.level === 1)).toBe(true);
    const deepest = posts.reduce((a, b) => (b.level > a.level ? b : a));
    expect(deepest.level).toBeGreaterThan(1);
    expect(postsFor({}).some((n) => n.id === deepest.id)).toBe(false);
    expect(postsFor({ [deepest.skill]: deepest.level }).some((n) => n.id === deepest.id)).toBe(true);
    expect(assignBlocker(deepest.id, {})).toMatch(new RegExp(`level ${deepest.level}`));
    expect(assignBlocker(deepest.id, { [deepest.skill]: deepest.level })).toBeNull();
    expect(assignBlocker('nope', {})).toMatch(/not a place/);
    expect(assignBlocker(oak.id, {})).toBeNull();
  });

  it('works at a fraction of the player pace, and stops accruing at the cap', () => {
    const hour = 3_600_000;
    const perHour = (hour / actionMs(oak)) * LABOR.factor;
    expect(laborActions(oak, hour)).toBe(Math.floor(perHour));
    expect(laborActions(oak, LABOR.capMs)).toBe(laborActions(oak, LABOR.capMs * 3));
    expect(laborActions(oak, 0)).toBe(0);
    // one action takes actionMs / factor of work: a hair short gives nothing, a hair over gives one
    const oneAction = actionMs(oak) / LABOR.factor;
    if (oneAction < LABOR.capMs) {
      expect(laborActions(oak, Math.floor(oneAction) - 1)).toBe(0);
      expect(laborActions(oak, Math.ceil(oneAction) + 1)).toBeGreaterThanOrEqual(1);
    }
  });

  it('estimates and rolls consistently, and pays LABOR.xpFrac of the XP into the real level', () => {
    // a long enough shift for about 400 actions (or the cap, if that comes first), so the averages mean something
    const elapsed = Math.min(LABOR.capMs, Math.ceil((400 / LABOR.factor) * actionMs(oak)));
    const level = oak.level + 9;
    const est = estimate(oak, level, elapsed);
    expect(est.actions).toBeGreaterThan(0);
    const roll = rollLabor(oak, { level, xp: 0 }, elapsed, claimRng(hashSeed(1, 0, 1234)));
    expect(roll.actions).toBe(est.actions);
    const logs = roll.items.find((i) => i.itemId === oak.item)?.qty ?? 0;
    expect(Math.abs(logs - est.items)).toBeLessThan(est.actions * 0.2);
    // every find is worth the node's XP to a player; a laborer banks only its share of that
    expect(roll.xp).toBe(Math.floor(logs * oak.xp * LABOR.xpFrac));
    expect(roll.xp).toBeGreaterThan(0);
  });

  it('is repeatable for the same claim and different for another', () => {
    const start = { level: oak.level, xp: 0 };
    const a = rollLabor(oak, start, LABOR.capMs, claimRng(hashSeed(7, 0, 999)));
    const b = rollLabor(oak, start, LABOR.capMs, claimRng(hashSeed(7, 0, 999)));
    const c = rollLabor(oak, start, LABOR.capMs, claimRng(hashSeed(7, 1, 999)));
    expect(a.actions).toBeGreaterThan(0);
    expect(b).toEqual(a);
    expect(c.items).not.toEqual(a.items);
  });
});
