import type { InventorySlot, Recipe } from '../net/types';

/** Most crafts one batch may ask for. The Workbench loops single, server-validated crafts, so this only bounds the loop. */
export const MAX_CRAFT_BATCH = 100;

/** Clamp a typed quantity to a whole number in 1..max (NaN and junk become 1). */
export function clampCraftQty(raw: unknown, max = MAX_CRAFT_BATCH): number {
  const n = Math.floor(Number(raw));
  if (!Number.isFinite(n) || n < 1) return 1;
  return Math.min(n, Math.max(1, max));
}

/** The Workbench's "Only craftable" filter: the rite's skill level is met and every ingredient is in the bag (bag room is not counted). */
export function hasSkillAndMaterials(recipe: Pick<Recipe, 'ingredients' | 'skill_level_required'>, skill: number, count: (itemId: string) => number): boolean {
  return skill >= recipe.skill_level_required && recipe.ingredients.every((ing) => count(ing.item_id) >= ing.quantity);
}

/** The filter is one browser-local setting for every crafting page (the Workbench and each Acre station), not per character. */
export const ONLY_CRAFTABLE_KEY = 'dm_only_craftable';

export function loadOnlyCraftable(storage: Pick<Storage, 'getItem'> | null): boolean {
  try {
    return storage?.getItem(ONLY_CRAFTABLE_KEY) === '1';
  } catch {
    return false;
  }
}

export function saveOnlyCraftable(storage: Pick<Storage, 'setItem'> | null, on: boolean): void {
  try {
    storage?.setItem(ONLY_CRAFTABLE_KEY, on ? '1' : '0');
  } catch {
    /* storage full or blocked: the filter just will not persist */
  }
}

export interface CraftSpace {
  /** Bag size in slots (the bag grid is slot 0..bagSize-1). */
  bagSize: number;
  /** Max stack of an item (1 = never stacks, Infinity = no cap). */
  stackOf: (itemId: string) => number;
}

/**
 * How many times `recipe` can be crafted in a row from `slots`, by materials AND bag room, capped at `cap`.
 * Simulates each craft the way the server does: ingredients come out of unequipped stacks (freeing emptied
 * slots), the result tops up partial stacks and then needs a free slot.
 */
export function maxCraftable(recipe: Pick<Recipe, 'ingredients' | 'result_item_id' | 'result_quantity'>, slots: readonly InventorySlot[], space: CraftSpace, cap = MAX_CRAFT_BATCH): number {
  const bag = slots.filter((s) => !s.equipped && s.slot_index >= 0 && s.slot_index < space.bagSize).map((s) => ({ id: s.item_id, q: s.quantity }));
  const occupiedByEquipped = slots.filter((s) => s.equipped && s.slot_index >= 0 && s.slot_index < space.bagSize).length;
  const resultQty = Math.max(1, Number(recipe.result_quantity) || 1);
  const stack = Math.max(1, space.stackOf(recipe.result_item_id));
  let made = 0;
  while (made < cap) {
    for (const ing of recipe.ingredients) {
      if (bag.filter((b) => b.id === ing.item_id).reduce((n, b) => n + b.q, 0) < ing.quantity) return made;
    }
    for (const ing of recipe.ingredients) {
      let need = ing.quantity;
      for (const b of bag) {
        if (b.id !== ing.item_id || need <= 0) continue;
        const take = Math.min(need, b.q);
        b.q -= take;
        need -= take;
      }
    }
    for (let i = bag.length - 1; i >= 0; i--) if (bag[i].q <= 0) bag.splice(i, 1);
    let left = resultQty;
    if (stack > 1) {
      for (const b of bag) {
        if (b.id !== recipe.result_item_id || b.q >= stack || left <= 0) continue;
        const add = Math.min(left, stack - b.q);
        b.q += add;
        left -= add;
      }
    }
    while (left > 0) {
      if (bag.length + occupiedByEquipped >= space.bagSize) return made;
      const add = Math.min(left, stack);
      bag.push({ id: recipe.result_item_id, q: add });
      left -= add;
    }
    made++;
  }
  return made;
}
