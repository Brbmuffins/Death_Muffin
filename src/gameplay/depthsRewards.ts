import { FLOOR_DROP_CHANCE, chestBonus, chestDrops, chestRuneChance, chestRunePool, depthLootArea, floorBonus } from '../../server/rules/content/depths';
import { ITEMS } from '../../server/rules/content/items';
import { pickRune } from '../../server/rules/content/runes';
import { isAffixGear } from '../../server/rules/gameplay/affixRules';
import { rollItem, settleCombatDrop, type LootDrop } from './loot';

/**
 * What the Catacomb Depths pay besides the kills themselves (content/depths.ts holds the numbers). Everything comes from the loot
 * tables the game already has (the hunting ground whose gear matches the depth), so no new item id exists and the server's authority
 * rules already know every one.
 */

/** A floor clear's gold and XP (average kills' worth) and, most of the time, an item from the depth's own ground. */
export function rollFloorClear(depth: number, level: number, rand: () => number = Math.random, disciplineId?: string): { gold: number; materialGold: number; xp: number; drop: LootDrop | null } {
  const bonus = floorBonus(depth, level);
  if (rand() >= FLOOR_DROP_CHANCE) return { ...bonus, materialGold: 0, drop: null };
  // A roll on a profession material pays its value as gold (loot.ts settleCombatDrop), kept apart from the floor's own gold.
  const s = settleCombatDrop(rollItem(depthLootArea(depth), rand, 1, disciplineId), true);
  return { ...bonus, materialGold: s.gold, drop: s.drop };
}

/** A piece of gear from the depth's ground (rolled until the table yields some; its gear is what a chest is for). */
export function rollGearDrop(depth: number, rand: () => number = Math.random, disciplineId?: string): LootDrop {
  const area = depthLootArea(depth);
  for (let i = 0; i < 60; i++) {
    const d = rollItem(area, rand, 1, disciplineId);
    const meta = ITEMS[d.item_id];
    if (meta && isAffixGear(meta.type)) return d;
  }
  return { item_id: 'helm_gold', quantity: 1 };
}

export interface ChestLoot {
  gold: number;
  /** Value of profession-material rolls, paid as gold (loot.ts settleCombatDrop); separate from the chest's own gold. */
  materialGold: number;
  xp: number;
  drops: LootDrop[];
}

/** The chest of a fifth floor: a rolled piece of gear, more drops from the depth's ground as it deepens, and now and then a rune. */
export function rollChest(depth: number, level: number, rand: () => number = Math.random, disciplineId?: string): ChestLoot {
  const bonus = chestBonus(depth, level);
  const area = depthLootArea(depth);
  const drops: LootDrop[] = [rollGearDrop(depth, rand, disciplineId)];
  let materialGold = 0;
  for (let i = 1; i < chestDrops(depth); i++) {
    const s = settleCombatDrop(rollItem(area, rand, 1, disciplineId), true);
    if (s.drop) drops.push(s.drop);
    materialGold += s.gold;
  }
  if (rand() < chestRuneChance(depth)) {
    const id = pickRune(chestRunePool(depth), rand);
    if (id) drops.push({ item_id: id, quantity: 1 });
  }
  return { gold: bonus.gold, materialGold, xp: bonus.xp, drops };
}
