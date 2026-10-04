import { ARMOR_BY_ID } from '../content/armorSets';
import { affixIsNecro, effectiveRarity, isAffixGear } from './affixRules';
import type { InventorySlot } from '../net/types';

/**
 * Settings -> Loot, one rule per gear rarity (owner, 2026-10-04: "the user should be able to pick if they want to auto loot ... and/or
 * the gold for each. best of both worlds"):
 * - `ground`: the drop lands and is yours when you walk over it (the default for every tier; loot never comes looking for you).
 * - `auto`: it goes straight into your bag as it drops (onto the ground instead when the bag is full).
 * - `gold`: it never lands; its sell value is paid at once.
 * Only gear follows these rules. Set pieces, legendaries, a rolled necromancer affix and anything worth wearing for you (an upgrade or a
 * set bonus gained, the rule "Sell all junk" keeps) are never turned into gold: a `gold` rule leaves them on the ground. Flasks, brews,
 * reagents and runes are not gear and always land.
 */
export type LootTier = 'common' | 'uncommon' | 'rare' | 'epic' | 'legendary';
export type LootAction = 'ground' | 'auto' | 'gold';
export type LootRules = Record<LootTier, LootAction>;

export const LOOT_TIERS: { id: LootTier; label: string }[] = [
  { id: 'common', label: 'Common' },
  { id: 'uncommon', label: 'Uncommon' },
  { id: 'rare', label: 'Rare' },
  { id: 'epic', label: 'Epic' },
  { id: 'legendary', label: 'Legendary' },
];
export const LOOT_ACTIONS: { id: LootAction; label: string }[] = [
  { id: 'ground', label: 'On the ground' },
  { id: 'auto', label: 'Auto-loot' },
  { id: 'gold', label: 'Sell for gold' },
];
/** Legendaries are always worth keeping, so they cannot be sold off by a rule. */
export const actionsFor = (tier: LootTier) => (tier === 'legendary' ? LOOT_ACTIONS.filter((a) => a.id !== 'gold') : LOOT_ACTIONS);

export const DEFAULT_LOOT_RULES: LootRules = { common: 'ground', uncommon: 'ground', rare: 'ground', epic: 'ground', legendary: 'ground' };

/** Saved rules, cleaned; `legacyFilter` is the single "Loot filter" of the first release (tiers below it became gold). */
export function readLootRules(saved: unknown, legacyFilter?: unknown): LootRules {
  const out: LootRules = { ...DEFAULT_LOOT_RULES };
  const order: LootTier[] = ['common', 'uncommon', 'rare', 'epic'];
  const cut = order.indexOf(legacyFilter as LootTier);
  if (cut > 0) for (const t of order.slice(0, cut)) out[t] = 'gold';
  if (saved && typeof saved === 'object') {
    for (const { id } of LOOT_TIERS) {
      const a = (saved as Record<string, unknown>)[id];
      if (actionsFor(id).some((x) => x.id === a)) out[id] = a as LootAction;
    }
  }
  return out;
}

/** What happens to this freshly rolled drop under the player's rules. */
export function lootAction(slot: InventorySlot, rules: LootRules, keep?: (s: InventorySlot) => boolean): LootAction {
  if (!isAffixGear(slot.item_type)) return 'ground';
  const affixes = slot.inst?.affixes ?? [];
  const r = effectiveRarity(slot.rarity, affixes.length);
  const tier: LootTier = r === 'relic' ? 'legendary' : (LOOT_TIERS.some((t) => t.id === r) ? r : 'common') as LootTier;
  const action = rules[tier];
  if (action !== 'gold') return action;
  const protectedPiece = tier === 'legendary' || !!ARMOR_BY_ID[slot.item_id] || affixes.some(affixIsNecro) || !!keep?.(slot);
  return protectedPiece ? 'ground' : 'gold';
}
