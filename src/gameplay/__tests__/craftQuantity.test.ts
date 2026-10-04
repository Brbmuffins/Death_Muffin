import { describe, expect, it } from 'vitest';
import { clampCraftQty, hasSkillAndMaterials, maxCraftable, MAX_CRAFT_BATCH } from '../craftQuantity';
import type { InventorySlot } from '../../net/types';

const slot = (i: number, id: string, q: number, equipped = 0) => ({ slot_index: i, item_id: id, quantity: q, equipped }) as InventorySlot;
const recipe = { result_item_id: 'bar', result_quantity: 1, ingredients: [{ item_id: 'ore', quantity: 2, name: 'Ore' }] };
const space = (stack = Infinity, bagSize = 8) => ({ bagSize, stackOf: () => stack });

describe('clampCraftQty', () => {
  it('keeps whole numbers in 1..max and repairs junk', () => {
    expect(clampCraftQty(5)).toBe(5);
    expect(clampCraftQty('7')).toBe(7);
    expect(clampCraftQty(2.9)).toBe(2);
    expect(clampCraftQty(0)).toBe(1);
    expect(clampCraftQty(-3)).toBe(1);
    expect(clampCraftQty(NaN)).toBe(1);
    expect(clampCraftQty('abc')).toBe(1);
    expect(clampCraftQty(9999)).toBe(MAX_CRAFT_BATCH);
  });
});

describe('hasSkillAndMaterials (the Only craftable filter)', () => {
  const r = { ...recipe, skill_level_required: 5 };
  const count = (have: Record<string, number>) => (id: string) => have[id] ?? 0;
  it('needs the skill level and every ingredient', () => {
    expect(hasSkillAndMaterials(r, 5, count({ ore: 2 }))).toBe(true);
    expect(hasSkillAndMaterials(r, 4, count({ ore: 2 }))).toBe(false);
    expect(hasSkillAndMaterials(r, 5, count({ ore: 1 }))).toBe(false);
    expect(hasSkillAndMaterials(r, 5, count({}))).toBe(false);
  });
  it('one missing ingredient hides the recipe', () => {
    const two = { ...r, ingredients: [...r.ingredients, { item_id: 'coal', quantity: 1, name: 'Coal' }] };
    expect(hasSkillAndMaterials(two, 5, count({ ore: 9 }))).toBe(false);
    expect(hasSkillAndMaterials(two, 5, count({ ore: 9, coal: 1 }))).toBe(true);
  });
});

describe('maxCraftable', () => {
  it('is limited by materials across stacks', () => {
    expect(maxCraftable(recipe, [slot(0, 'ore', 5), slot(1, 'ore', 4)], space())).toBe(4);
    expect(maxCraftable(recipe, [slot(0, 'ore', 1)], space())).toBe(0);
  });
  it('limits the most limiting ingredient', () => {
    const r = { ...recipe, ingredients: [...recipe.ingredients, { item_id: 'coal', quantity: 1, name: 'Coal' }] };
    expect(maxCraftable(r, [slot(0, 'ore', 20), slot(1, 'coal', 3)], space())).toBe(3);
  });
  it('is limited by bag room when results cannot stack', () => {
    // 2 slots in use (ore + a relic), 4-slot bag: 2 free slots, but crafting empties the ore slot after 3 crafts.
    expect(maxCraftable(recipe, [slot(0, 'ore', 100), slot(1, 'relic', 1)], space(1, 4))).toBe(2);
  });
  it('stacks results into partial stacks and freed slots', () => {
    expect(maxCraftable(recipe, [slot(0, 'ore', 6), slot(1, 'bar', 1)], space(250, 2))).toBe(3);
  });
  it('a full bag with a result that needs a slot makes nothing, unless ingredients free one', () => {
    const full = Array.from({ length: 4 }, (_, i) => slot(i, `x${i}`, 1));
    expect(maxCraftable(recipe, full, space(250, 4))).toBe(0);
    expect(maxCraftable(recipe, [slot(0, 'ore', 2), slot(1, 'a', 1), slot(2, 'b', 1), slot(3, 'c', 1)], space(250, 4))).toBe(1);
  });
  it('ignores equipped gear as ingredients and counts it as occupying room', () => {
    expect(maxCraftable(recipe, [slot(0, 'ore', 10, 1)], space())).toBe(0);
  });
  it('honours the cap', () => {
    expect(maxCraftable(recipe, [slot(0, 'ore', 999)], space(), 10)).toBe(10);
    expect(maxCraftable(recipe, [slot(0, 'ore', 9999)], space())).toBe(MAX_CRAFT_BATCH);
  });
});
