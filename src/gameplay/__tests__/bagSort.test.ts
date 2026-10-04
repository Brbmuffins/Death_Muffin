import { describe, expect, it } from 'vitest';
import type { InventorySlot } from '../../net/types';
import { sortBagSlots } from '../loot';
import { ItemLocks } from '../itemLocks';

const slot = (slot_index: number, item_id: string, item_type: string, rarity: string, extra: Partial<InventorySlot> = {}) =>
  ({ id: slot_index, slot_index, quantity: 1, equipped: 0, item_id, name: item_id, rarity, item_type, stat_bonus: null, icon_id: null, sell_value: 1, crafted: 0, ...extra }) as InventorySlot;

const inOrder = (slots: InventorySlot[]) => [...slots].filter((s) => s.slot_index < 100).sort((a, b) => a.slot_index - b.slot_index);

describe('sortBagSlots', () => {
  it('orders by type, rarity (best first), item level, then name, packed from slot 0', () => {
    const out = inOrder(
      sortBagSlots([
        slot(3, 'ore_copper', 'material', 'common'),
        slot(7, 'sword_c', 'weapon', 'common'),
        slot(9, 'sword_r_b', 'weapon', 'rare', { ilvl: 5 }),
        slot(10, 'sword_r_a', 'weapon', 'rare', { ilvl: 9 }),
        slot(11, 'axe_r', 'weapon', 'rare', { ilvl: 5 }),
      ]),
    );
    expect(out.map((s) => s.item_id)).toEqual(['sword_r_a', 'axe_r', 'sword_r_b', 'sword_c', 'ore_copper']);
    expect(out.map((s) => s.slot_index)).toEqual([0, 1, 2, 3, 4]);
  });

  it('merges material stacks up to the stack size and reports where slots went', () => {
    const moves = new Map<number, number>();
    const out = inOrder(
      sortBagSlots([slot(2, 'ore_copper', 'material', 'common', { quantity: 200 }), slot(5, 'ore_copper', 'material', 'common', { quantity: 100 }), slot(6, 'ring', 'ring', 'rare')], moves),
    );
    expect(out.map((s) => [s.item_id, s.quantity])).toEqual([['ring', 1], ['ore_copper', 250], ['ore_copper', 50]]);
    expect(moves.get(6)).toBe(0);
    expect(moves.get(2)).toBe(1);
  });

  it('never merges gear, and leaves worn gear and belt slots alone', () => {
    const input = [slot(5, 'ring', 'ring', 'rare'), slot(6, 'ring', 'ring', 'rare'), slot(100, 'helm', 'armor_head', 'rare', { equipped: 1 })];
    const out = sortBagSlots(input);
    expect(out).toHaveLength(3);
    expect(out.find((s) => s.item_id === 'helm')!.slot_index).toBe(100);
    expect(out.filter((s) => s.item_id === 'ring').map((s) => s.slot_index).sort()).toEqual([0, 1]);
  });

  it('keeps item locks on the items they were on', () => {
    const locks = new ItemLocks(1, null);
    locks.toggle({ slot_index: 4, item_id: 'ring' });
    const moves = new Map<number, number>();
    sortBagSlots([slot(1, 'ore_copper', 'material', 'common'), slot(4, 'ring', 'ring', 'rare')], moves);
    locks.remap(moves);
    expect(locks.isLocked({ slot_index: 0, item_id: 'ring' })).toBe(true);
    expect(locks.isLocked({ slot_index: 4, item_id: 'ring' })).toBe(false);
  });
});
