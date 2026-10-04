import { ARMOR_BY_ID } from '../content/armorSets';
import { affixIsNecro, effectiveRarity, isAffixGear } from './affixRules';
import type { InventorySlot } from '../net/types';

/**
 * Settings -> Loot filter (owner, 2026-10-04: "looting feels really bloated"). Gear below the chosen rarity never lands on the
 * ground: it is paid out at once as its sell value, so nothing is lost and nothing needs walking to. Only plain gear is filtered.
 * Set pieces, legendaries, a rolled necromancer affix and anything worth wearing for you (an upgrade or a set bonus gained, the same
 * rule "Sell all junk" keeps) always drop. Flasks, brews, reagents and runes are not gear and always drop. New characters see everything.
 */
export type LootFilter = 'any' | 'uncommon' | 'rare' | 'epic';
export const LOOT_FILTERS: { id: LootFilter; label: string }[] = [
  { id: 'any', label: 'Everything' },
  { id: 'uncommon', label: 'Uncommon and better' },
  { id: 'rare', label: 'Rare and better' },
  { id: 'epic', label: 'Epic and better' },
];
const RANK = ['common', 'uncommon', 'rare', 'epic', 'legendary', 'relic'];

/** True when the filter turns this freshly rolled gear drop into gold instead of a ground drop. */
export function filteredOut(slot: InventorySlot, filter: LootFilter, keep?: (s: InventorySlot) => boolean): boolean {
  if (filter === 'any' || !isAffixGear(slot.item_type) || ARMOR_BY_ID[slot.item_id]) return false;
  const affixes = slot.inst?.affixes ?? [];
  if (affixes.some(affixIsNecro)) return false;
  const rarity = effectiveRarity(slot.rarity, affixes.length);
  if (RANK.indexOf(rarity) >= RANK.indexOf(filter) || rarity === 'legendary') return false;
  return !keep?.(slot);
}
