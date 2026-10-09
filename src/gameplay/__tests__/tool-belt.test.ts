import { describe, expect, it } from 'vitest';
import { BELT_BASE, BELT_KINDS, beltSlotKind, beltSlotOf, bestToolPerKind, isBeltSlot, toolKindOf, toolTierFor } from '../../../server/rules/gameplay/gatheringRules';
import { beltOffer, beltTools } from '../../ui/toolBelt';
import type { InventorySlot } from '../../net/types';

const row = (slot_index: number, item_id: string): InventorySlot => ({
  id: slot_index, slot_index, quantity: 1, equipped: slot_index >= BELT_BASE ? 1 : 0, item_id, name: item_id, rarity: 'common',
  item_type: 'material', stat_bonus: null, icon_id: null, sell_value: 1, crafted: 0,
});

describe('tool belt rules', () => {
  it('four reserved slots 110-113, one per kind, clear of gear (100-108) and the 48-slot bag', () => {
    expect(BELT_KINDS.map((k) => beltSlotOf(`tool_${k}_copper`))).toEqual([110, 111, 112, 113]);
    expect([109, 110, 113, 114].map(isBeltSlot)).toEqual([false, true, true, false]);
    expect(beltSlotKind(112)).toBe('rod');
    expect(beltSlotKind(48)).toBeNull();
  });

  it('only real tools have a kind', () => {
    expect(toolKindOf('tool_spade_moon')).toBe('spade');
    expect(toolKindOf('tool_spade_adamant')).toBeNull();
    expect(toolKindOf('tool_hatchet')).toBeNull();
    expect(toolKindOf('staff_oak')).toBeNull();
  });

  it('the best of belt and bag counts', () => {
    expect(toolTierFor('woodcutting', ['tool_hatchet_copper', 'tool_hatchet_steel'])).toBe(4);
    expect(bestToolPerKind(['tool_hatchet_iron', 'tool_hatchet_hell', 'tool_rod_copper', 'ore_copper'])).toEqual({ hatchet: 'tool_hatchet_hell', rod: 'tool_rod_copper' });
  });

  it('the one-time offer: best bag tool per kind, only while the belt is empty', () => {
    const bag = [row(0, 'tool_hatchet_copper'), row(5, 'tool_hatchet_steel'), row(9, 'tool_spade_iron'), row(11, 'ore_copper')];
    expect(beltOffer(bag).map((s) => s.slot_index)).toEqual([5, 9]);
    expect(beltOffer([...bag, row(111, 'tool_pickaxe_copper')])).toEqual([]);
    expect(beltOffer([row(1, 'ore_copper')])).toEqual([]);
    expect(beltTools([...bag, row(111, 'tool_pickaxe_copper')]).pickaxe?.item_id).toBe('tool_pickaxe_copper');
  });
});
