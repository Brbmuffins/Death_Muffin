import { describe, expect, it } from 'vitest';
import type { InventorySlot } from '../../net/types';
import { sortBagSlots } from '../loot';

const slot = (slot_index: number, item_id: string, item_type: string, rarity: string, extra: Partial<InventorySlot> = {}) =>
  ({ id: slot_index, slot_index, quantity: 1, equipped: 0, item_id, name: item_id, rarity, item_type, stat_bonus: null, icon_id: null, sell_value: 1, crafted: 0, ...extra }) as InventorySlot;

describe('sortBagSlots', () => {
  it('orders the bag by type then rarity and packs it from slot 0', () => {
    const out = sortBagSlots([
      slot(3, 'ore', 'material', 'common'),
      slot(7, 'sword_c', 'weapon', 'common'),
      slot(9, 'sword_r', 'weapon', 'rare'),
    ]);
    const byIndex = [...out].sort((a, b) => a.slot_index - b.slot_index).map((s) => s.item_id);
    expect(byIndex).toEqual(['sword_r', 'sword_c', 'ore']);
  });

  it('leaves worn gear and tool-belt slots alone and loses nothing', () => {
    const worn = slot(100, 'helm', 'armor_head', 'rare', { equipped: 1 });
    const input = [slot(5, 'ore', 'material', 'common'), worn, slot(2, 'ring', 'ring', 'rare')];
    const out = sortBagSlots(input);
    expect(out).toHaveLength(3);
    expect(out.find((s) => s.item_id === 'helm')!.slot_index).toBe(100);
    expect(out.find((s) => s.item_id === 'ring')!.slot_index).toBe(0);
    expect(out.find((s) => s.item_id === 'ore')!.slot_index).toBe(1);
  });
});
