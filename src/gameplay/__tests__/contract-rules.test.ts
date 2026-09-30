import { describe, expect, it } from 'vitest';
import { ITEMS } from '../../content/items';
import { bonusFor, candidatesFor, CONTRACT_SLOTS, dayKey, generateBoard, nextResetMs, streakOf } from '../contractRules';

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
          expect(o.qty).toBeGreaterThanOrEqual(4);
          expect(o.qty).toBeLessThanOrEqual(90);
          expect(o.rewardGold).toBeGreaterThan(0);
          if (o.rewardItem) expect(ITEMS[o.rewardItem.itemId], o.rewardItem.itemId).toBeTruthy();
        }
        expect(board[2].rewardItem).not.toBeNull();
      }
    }
  });

  it('never asks for something the skills cannot yet produce', () => {
    const low = new Set(candidatesFor({ woodcutting: 1, mining: 1, fishing: 1, gravedigging: 1 }).map((c) => c.itemId));
    const board = generateBoard(3, '2026-09-30', {});
    for (const o of board) expect(low.has(o.itemId)).toBe(true);
    expect(low.has('ore_steel')).toBe(false);
    expect(candidatesFor({ mining: 80 }).some((c) => c.itemId === 'ore_steel')).toBe(true);
  });

  it('pays a bonus of half the day\'s gold', () => {
    const board = generateBoard(3, '2026-09-30', { woodcutting: 20 });
    expect(bonusFor(board).gold).toBe(Math.round(board.reduce((n, o) => n + o.rewardGold, 0) / 2));
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
