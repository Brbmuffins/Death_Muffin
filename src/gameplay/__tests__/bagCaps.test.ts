import { describe, expect, it } from 'vitest';
import { ITEMS } from '../../../server/rules/content/items';
import { BAG_SIZE, addToSlots } from '../loot';

describe('addToSlots honours the server stack rules', () => {
  it('gear never stacks: a quantity of 3 takes three slots', () => {
    const slots = addToSlots([], { item_id: 'kit_iron_warden', quantity: 3 })!;
    expect(slots.map((s) => s.quantity)).toEqual([1, 1, 1]);
  });

  it('every stackable item splits at its cap, and the cap equals the catalogue cap', () => {
    for (const [id, m] of Object.entries(ITEMS)) {
      if (!m.stack) continue;
      const slots = addToSlots([], { item_id: id, quantity: m.stack + 1 })!;
      expect(slots.map((s) => s.quantity).sort((a, b) => b - a), id).toEqual([m.stack, 1]);
    }
  });

  it('a full bag refuses and keeps nothing half-added', () => {
    let slots = [] as ReturnType<typeof addToSlots> & object;
    for (let i = 0; i < BAG_SIZE; i++) slots = addToSlots(slots, { item_id: 'helm_copper', quantity: 1 })!;
    expect(addToSlots(slots, { item_id: 'helm_copper', quantity: 1 })).toBeNull();
  });
});
