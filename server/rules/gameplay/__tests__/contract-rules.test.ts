import { describe, expect, it } from 'vitest';
import { ITEMS } from '../../content/items';
import { NODES } from '../gatheringRules';
import { bonusFor, candidatesFor, CONTRACT_SLOTS, dayKey, generateBoard, nextResetMs, RELIC_ORDERS, streakOf } from '../contractRules';

describe('contract board', () => {
  it('is deterministic per character and day, and differs between days and characters', () => {
    const a = generateBoard(7, '2026-09-30', { woodcutting: 10 });
    expect(generateBoard(7, '2026-09-30', { woodcutting: 10 })).toEqual(a);
    expect(generateBoard(7, '2026-10-01', { woodcutting: 10 })).not.toEqual(a);
    expect(generateBoard(8, '2026-09-30', { woodcutting: 10 })).not.toEqual(a);
  });

  it('always gives three distinct, known, reasonably sized orders — even to a level 1 character', () => {
    for (const levels of [{}, { woodcutting: 40, mining: 40, fishing: 40, gravedigging: 40 }, { mining: 90, fishing: 90, gravedigging: 90, woodcutting: 90 }]) {
      for (let c = 1; c <= 30; c++) {
        const board = generateBoard(c, '2026-09-30', levels);
        expect(board).toHaveLength(CONTRACT_SLOTS);
        expect(new Set(board.map((o) => o.itemId)).size).toBe(CONTRACT_SLOTS);
        for (const o of board) {
          expect(ITEMS[o.itemId], o.itemId).toBeTruthy();
          // Relic orders (rare gems, fragments, seals) ask for the fixed handful the table names; any other order a whole number of at least one.
          const relic = RELIC_ORDERS.find((r) => r.itemId === o.itemId);
          if (relic) expect(o.qty).toBe(relic.qty);
          expect(Number.isInteger(o.qty)).toBe(true);
          expect(o.qty).toBeGreaterThanOrEqual(1);
          expect(o.rewardGold).toBeGreaterThan(0);
          if (o.rewardItem) expect(ITEMS[o.rewardItem.itemId], o.rewardItem.itemId).toBeTruthy();
        }
        expect(board[CONTRACT_SLOTS - 1].rewardItem).not.toBeNull(); // the hard order always pays an item
      }
    }
  });

  it('never asks for something the skills cannot yet produce', () => {
    const low = new Set(candidatesFor({ woodcutting: 1, mining: 1, fishing: 1, gravedigging: 1 }).map((c) => c.itemId));
    const board = generateBoard(3, '2026-09-30', {});
    for (const o of board) expect(low.has(o.itemId)).toBe(true);
    // the deepest mining find waits for its level and is asked for once the level is there
    const deepest = Object.values(NODES).filter((n) => n.skill === 'mining').reduce((a, b) => (b.level > a.level ? b : a));
    expect(deepest.level).toBeGreaterThan(1);
    expect(low.has(deepest.item)).toBe(false);
    expect(candidatesFor({ mining: deepest.level - 1 }).some((c) => c.itemId === deepest.item)).toBe(false);
    expect(candidatesFor({ mining: deepest.level }).some((c) => c.itemId === deepest.item)).toBe(true);
  });

  it('pays a bonus that is a share of the day\'s gold, so it follows the rewards', () => {
    const board = generateBoard(3, '2026-09-30', { woodcutting: 20 });
    const bonus = bonusFor(board).gold;
    expect(bonus).toBeGreaterThan(0);
    const doubled = board.map((o) => ({ ...o, rewardGold: o.rewardGold * 2 }));
    expect(Math.abs(bonusFor(doubled).gold - bonus * 2)).toBeLessThanOrEqual(1); // rounding only
    expect(bonusFor(board).item.itemId).toBeTruthy();
  });
});

describe('day handling', () => {
  it('keys days in UTC and resets at the next midnight', () => {
    const t = Date.UTC(2026, 8, 30, 23, 59, 0);
    expect(dayKey(t)).toBe('2026-09-30');
    expect(nextResetMs(t)).toBe(Date.UTC(2026, 9, 1));
  });

  it('counts a streak through today or yesterday, and breaks on a gap', () => {
    expect(streakOf(['2026-09-30', '2026-09-29', '2026-09-28'], '2026-09-30')).toBe(3);
    expect(streakOf(['2026-09-29', '2026-09-28'], '2026-09-30')).toBe(2);
    expect(streakOf(['2026-09-27', '2026-09-28'], '2026-09-30')).toBe(0);
    expect(streakOf(['2026-09-30', '2026-09-28'], '2026-09-30')).toBe(1);
    expect(streakOf(['2026-09-30', '2026-09-29', '2026-08-31', '2026-09-01'], '2026-09-30')).toBe(2);
  });
});
