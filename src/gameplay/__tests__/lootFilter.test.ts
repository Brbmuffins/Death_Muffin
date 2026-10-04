import { describe, expect, it } from 'vitest';
import { addToSlots } from '../loot';
import { filteredOut } from '../lootFilter';

const slot = (item_id: string, affixes: { id: string; v: number }[] = []) =>
  addToSlots([], { item_id, quantity: 1, ...(affixes.length ? { instance: { id: 1, ilvl: 10, affixes } } : {}) })![0];

describe('loot filter (Settings -> Loot filter)', () => {
  it('"Everything" (the default) never filters', () => {
    expect(filteredOut(slot('helm_copper'), 'any')).toBe(false);
  });

  it('plain gear below the chosen rarity is filtered; at or above it drops', () => {
    expect(filteredOut(slot('helm_copper'), 'uncommon')).toBe(true);
    expect(filteredOut(slot('ring_copper'), 'uncommon')).toBe(false);
    expect(filteredOut(slot('ring_copper'), 'rare')).toBe(true);
    expect(filteredOut(slot('helm_gold'), 'rare')).toBe(false);
    expect(filteredOut(slot('helm_gold'), 'epic')).toBe(true);
    expect(filteredOut(slot('staff_hell'), 'epic')).toBe(false);
  });

  it('set pieces, legendaries and anything you would wear always drop', () => {
    expect(filteredOut(slot('set_gravecaller_head'), 'epic')).toBe(false);
    expect(filteredOut(slot('leg_legion_unburied_head'), 'epic')).toBe(false);
    expect(filteredOut(slot('helm_copper'), 'epic', () => true)).toBe(false); // an upgrade for you
  });

  it('materials, flasks and runes are not gear and are never filtered', () => {
    expect(filteredOut(slot('ore_copper'), 'epic')).toBe(false);
    expect(filteredOut(slot('flask_hp_minor'), 'epic')).toBe(false);
  });
});
