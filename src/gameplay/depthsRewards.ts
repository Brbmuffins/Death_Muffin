import { FLOOR_DROP_CHANCE, chestBonus, chestDrops, chestRuneChance, chestRunePool, depthLootArea, floorBonus } from '../content/depths';
import { ITEMS } from '../content/items';
import { pickRune } from '../content/runes';
import { isAffixGear } from './affixRules';
import { rollItem, type LootDrop } from './loot';

/**
 * What the Catacomb Depths pay besides the kills themselves (content/depths.ts holds the numbers). Everything comes from the loot
 * tables the game already has (the hunting ground whose gear matches the depth), so no new item id exists and the server's authority
 * rules already know every one.
 */

/** A floor clear's gold and XP (average kills' worth) and, most of the time, an item from the depth's own ground. */
export function rollFloorClear(depth: number, level: number, rand: () => number = Math.random): { gold: number; xp: number; drop: LootDrop | null } {
  const bonus = floorBonus(depth, level);
  return { ...bonus, drop: rand() < FLOOR_DROP_CHANCE ? rollItem(depthLootArea(depth), rand) : null };
}

/** A piece of gear from the depth's ground (rolled until the table yields some; its gear is what a chest is for). */
export function rollGearDrop(depth: number, rand: () => number = Math.random): LootDrop {
  const area = depthLootArea(depth);
  for (let i = 0; i < 60; i++) {
    const d = rollItem(area, rand);
    const meta = ITEMS[d.item_id];
    if (meta && isAffixGear(meta.type)) return d;
  }
  return { item_id: 'helm_gold', quantity: 1 };
}

export interface ChestLoot {
  gold: number;
  xp: number;
  drops: LootDrop[];
}

/** The chest of a fifth floor: a rolled piece of gear, more drops from the depth's ground as it deepens, and now and then a rune. */
export function rollChest(depth: number, level: number, rand: () => number = Math.random): ChestLoot {
  const bonus = chestBonus(depth, level);
  const area = depthLootArea(depth);
  const drops: LootDrop[] = [rollGearDrop(depth, rand)];
  for (let i = 1; i < chestDrops(depth); i++) drops.push(rollItem(area, rand));
  if (rand() < chestRuneChance(depth)) {
    const id = pickRune(chestRunePool(depth), rand);
    if (id) drops.push({ item_id: id, quantity: 1 });
  }
  return { gold: bonus.gold, xp: bonus.xp, drops };
}
