import { describe, expect, it } from 'vitest';
import { addToSlots } from '../loot';
import { DEFAULT_LOOT_RULES, lootAction, readLootRules, type LootRules } from '../lootFilter';

const slot = (item_id: string) => addToSlots([], { item_id, quantity: 1 })![0];
const rules = (over: Partial<LootRules>): LootRules => ({ ...DEFAULT_LOOT_RULES, ...over });

describe('loot rules (Settings -> Loot): ground, auto-loot or gold, per rarity', () => {
  it('by default everything lands on the ground', () => {
    for (const id of ['helm_copper', 'ring_copper', 'helm_gold', 'staff_hell']) expect(lootAction(slot(id), DEFAULT_LOOT_RULES)).toBe('ground');
  });

  it('each tier follows its own rule', () => {
    const r = rules({ common: 'gold', uncommon: 'ground', rare: 'auto', epic: 'auto' });
    expect(lootAction(slot('helm_copper'), r)).toBe('gold');
    expect(lootAction(slot('ring_copper'), r)).toBe('ground');
    expect(lootAction(slot('helm_gold'), r)).toBe('auto');
    expect(lootAction(slot('staff_hell'), r)).toBe('auto');
  });

  it('set pieces, legendaries and upgrades for you are never sold; a gold rule leaves them on the ground', () => {
    const r = rules({ uncommon: 'gold', epic: 'gold', legendary: 'gold' as never });
    expect(lootAction(slot('set_gravecaller_head'), r)).toBe('ground');
    expect(lootAction(slot('leg_legion_unburied_head'), r)).toBe('ground');
    expect(lootAction(slot('ring_copper'), r, () => true)).toBe('ground');
    expect(lootAction(slot('set_gravecaller_head'), rules({ uncommon: 'auto' }))).toBe('auto'); // auto-loot still applies to them
  });

  it('materials, flasks and runes are not gear and always land', () => {
    const r = rules({ common: 'gold', uncommon: 'auto', rare: 'gold', epic: 'gold' });
    for (const id of ['ore_copper', 'flask_hp_minor']) expect(lootAction(slot(id), r)).toBe('ground');
  });

  it('saved rules are cleaned, and the first release\'s single filter carries over', () => {
    expect(readLootRules({ common: 'auto', rare: 'nonsense', legendary: 'gold' })).toEqual(rules({ common: 'auto' }));
    expect(readLootRules(undefined, 'rare')).toEqual(rules({ common: 'gold', uncommon: 'gold' }));
    expect(readLootRules(undefined, 'any')).toEqual(DEFAULT_LOOT_RULES);
  });
});
