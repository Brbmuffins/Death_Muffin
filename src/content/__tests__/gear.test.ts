import { describe, expect, it } from 'vitest';
import { equipSlotOf, equippedBySlot, gearTier, offhandKind, weaponKind } from '../gear';
import type { InventorySlot } from '../../net/types';

const slot = (o: Partial<InventorySlot>) =>
  ({ id: 1, slot_index: 0, quantity: 1, equipped: 0, item_id: 'x', name: 'x', rarity: 'common', item_type: 'material', stat_bonus: null, icon_id: null, sell_value: 0, crafted: 0, ...o }) as InventorySlot;

describe('equipSlotOf', () => {
  it('prefers the server slot and falls back to the item type', () => {
    expect(equipSlotOf(slot({ item_type: 'weapon', equipped_slot: 'off_hand' }))).toBe('off_hand');
    expect(equipSlotOf(slot({ item_type: 'weapon', item_equipment_slot: 'main_hand' }))).toBe('main_hand');
    expect(equipSlotOf(slot({ item_type: 'armor_feet' }))).toBe('feet');
    expect(equipSlotOf(slot({ item_type: 'offhand' }))).toBe('off_hand');
    expect(equipSlotOf(slot({ item_type: 'material' }))).toBeNull();
  });
});

describe('equippedBySlot', () => {
  it('lists worn gear only, keyed by slot', () => {
    const worn = equippedBySlot([
      slot({ item_id: 'helm_gold', item_type: 'armor_head', equipped: 1, equipped_slot: 'head', slot_index: 100 }),
      slot({ item_id: 'helm_iron', item_type: 'armor_head', slot_index: 3 }),
    ]);
    expect(Object.keys(worn)).toEqual(['head']);
    expect(worn.head?.item_id).toBe('helm_gold');
  });
});

describe('gear looks', () => {
  it('reads material and weapon kind from ids and never returns nothing', () => {
    expect(gearTier('sword_iron').color).not.toBe(gearTier('sword_copper').color);
    expect(gearTier('mystery_thing', 'epic')).toBeTruthy();
    expect(weaponKind('staff_oak')).toBe('staff');
    expect(weaponKind('wood_spike_mace')).toBe('mace');
    expect(weaponKind('warmonger')).toBe('sword');
    expect(offhandKind('shield_sneaker')).toBe('shield');
  });
});
