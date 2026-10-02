/**
 * Salvaging rules (the Bone Grinder in the Sexton's Acre): break unwanted gear down into crafting materials and alchemy reagents.
 * Pure and DOM-free; `npm run build:server-rules` bundles this file into gathering/salvage-rules.cjs for salvage.cjs, and the DEV
 * offline backend calls the same function, so the two cannot drift.
 *
 * Every id returned here is an existing item (a unit test checks them against the item catalogue).
 */

import { LEVEL_CAP } from './gatheringRules';

export const SALVAGE_SKILL = 'salvaging';

/** Item types the grinder accepts (the same list the Reliquary treats as gear). */
export const SALVAGE_GEAR_TYPES = ['weapon', 'offhand', 'armor_head', 'armor_chest', 'armor_legs', 'armor_feet', 'armor_hands', 'ring', 'trinket'] as const;
export const isSalvageGear = (itemType: string) => (SALVAGE_GEAR_TYPES as readonly string[]).includes(itemType);
/** Relic runes (content/runes.ts) can be ground too, one at a time, and give reagents only (no ingots or planks). */
export const isSalvageRune = (itemType: string) => itemType === 'rune';
export const isSalvageable = (itemType: string) => isSalvageGear(itemType) || isSalvageRune(itemType);

export const SALVAGE_RARITIES = ['common', 'uncommon', 'rare', 'epic', 'legendary', 'relic'] as const;
export type SalvageRarity = (typeof SALVAGE_RARITIES)[number];

/** +0.5% per Salvaging level of one extra material. */
export const SALVAGE_BONUS_PER_LEVEL = 0.005;
/** Rolled gear pays a little more: each affix adds 12% and each item level 0.3% to a second extra-material chance (capped), and 15% per affix to the XP. */
export const SALVAGE_AFFIX_BONUS = 0.12;
export const SALVAGE_ILVL_BONUS = 0.003;
export const SALVAGE_AFFIX_XP = 0.15;

/** Chance of one more material from a rolled piece's item level and affixes (0 for plain gear). */
export const instanceYieldBonus = (item: Pick<SalvageItem, 'ilvl' | 'affixes'>): number =>
  item.ilvl === undefined && !item.affixes ? 0 : Math.min(0.9, (item.affixes ?? 0) * SALVAGE_AFFIX_BONUS + (item.ilvl ?? 0) * SALVAGE_ILVL_BONUS);

export interface SalvageItem {
  id: string;
  item_type: string;
  rarity: string;
  /** A rolled instance (affixRules.ts): its item level and how many affixes it carries. Plain gear leaves both out. */
  ilvl?: number;
  affixes?: number;
}
export interface SalvageGrant {
  item_id: string;
  quantity: number;
}
export interface SalvageResult {
  items: SalvageGrant[];
  xp: number;
}

interface Tier {
  ingots: string[];
  planks: string[];
  qty: [number, number];
  xp: number;
  /** Chance of wraith ectoplasm. */
  ecto: number;
  /** Chance of plague bile or cinder ash (one of the two). */
  rare: number;
  /** Chance of a bone meal. */
  meal: number;
}

const TIERS: Record<SalvageRarity, Tier> = {
  common: { ingots: ['ingot_copper'], planks: ['plank_oak'], qty: [1, 1], xp: 4, ecto: 0, rare: 0, meal: 0.15 },
  uncommon: { ingots: ['ingot_iron'], planks: ['plank_willow'], qty: [1, 1], xp: 9, ecto: 0.2, rare: 0, meal: 0.2 },
  rare: { ingots: ['ingot_silver', 'ingot_steel'], planks: ['plank_yew', 'plank_ghostwood'], qty: [1, 2], xp: 18, ecto: 0.3, rare: 0, meal: 0.25 },
  epic: { ingots: ['ingot_gold'], planks: ['plank_blackthorn'], qty: [2, 2], xp: 36, ecto: 0.4, rare: 0.3, meal: 0.3 },
  legendary: { ingots: ['ingot_hell'], planks: ['plank_bone_elder'], qty: [2, 3], xp: 64, ecto: 0.5, rare: 0.5, meal: 0.35 },
  relic: { ingots: ['ingot_moon'], planks: ['plank_bone_elder'], qty: [3, 3], xp: 100, ecto: 0.6, rare: 0.7, meal: 0.4 },
};

const tierOf = (rarity: string): Tier => TIERS[(SALVAGE_RARITIES as readonly string[]).includes(rarity) ? (rarity as SalvageRarity) : 'common'];

/** Staffs, wands and grimoires (and their kin) are wood and parchment: they give planks. Everything else gives ingots. */
export const yieldsPlanks = (item: { id: string }) => /staff|wand|grimoire|tome|crozier|book/.test(item.id);

const REAGENT_RARE = ['reagent_plague_bile', 'reagent_cinder_ash'];
/** A rune is ground to reagents only: a little more Grave Dust than gear gives. */
const RUNE_DUST: [number, number] = [2, 4];

/** Every id salvaging can ever return (for tests, previews and the migration check). */
export function salvageItemIds(): string[] {
  const ids = new Set<string>(['reagent_grave_dust', 'reagent_wraith_ectoplasm', 'bone_meal', ...REAGENT_RARE]);
  for (const t of Object.values(TIERS)) for (const id of [...t.ingots, ...t.planks]) ids.add(id);
  return [...ids];
}

/** What one salvage can give, for the panel preview (no rolling). */
export function salvagePreview(item: SalvageItem): { materials: string[]; materialQty: [number, number]; reagents: { id: string; chance: number; qty: [number, number] }[]; xp: number; extraChance: number } {
  const t = tierOf(item.rarity);
  const rune = isSalvageRune(item.item_type);
  const reagents = [{ id: 'reagent_grave_dust', chance: 1, qty: (rune ? RUNE_DUST : [1, 2]) as [number, number] }];
  if (t.ecto) reagents.push({ id: 'reagent_wraith_ectoplasm', chance: t.ecto, qty: [1, 1] });
  if (t.rare) for (const id of REAGENT_RARE) reagents.push({ id, chance: t.rare / 2, qty: [1, 1] });
  if (t.meal) reagents.push({ id: 'bone_meal', chance: t.meal, qty: [1, 1] });
  if (rune) return { materials: [], materialQty: [0, 0], reagents, xp: t.xp, extraChance: 0 };
  return { materials: yieldsPlanks(item) ? t.planks : t.ingots, materialQty: t.qty, reagents, xp: Math.round(t.xp * (1 + (item.affixes ?? 0) * SALVAGE_AFFIX_XP)), extraChance: instanceYieldBonus(item) };
}

const between = (rand: () => number, [lo, hi]: [number, number]) => lo + Math.floor(rand() * (hi - lo + 1));
const pick = <T>(rand: () => number, list: T[]): T => list[Math.min(list.length - 1, Math.floor(rand() * list.length))];

/** Roll one piece of gear. `rand` returns [0, 1). Deterministic for a given sequence. */
export function salvageYield(item: SalvageItem, salvagingLevel: number, rand: () => number): SalvageResult {
  const t = tierOf(item.rarity);
  const level = Math.max(1, Math.min(LEVEL_CAP, Math.floor(Number(salvagingLevel)) || 1));
  const out = new Map<string, number>();
  const add = (id: string, n: number) => out.set(id, (out.get(id) ?? 0) + n);

  if (isSalvageRune(item.item_type)) {
    add('reagent_grave_dust', between(rand, RUNE_DUST));
    if (t.ecto && rand() < t.ecto) add('reagent_wraith_ectoplasm', 1);
    if (t.rare && rand() < t.rare) add(pick(rand, REAGENT_RARE), 1);
    if (t.meal && rand() < t.meal) add('bone_meal', 1);
    return { items: [...out].map(([item_id, quantity]) => ({ item_id, quantity })), xp: t.xp };
  }

  const material = pick(rand, yieldsPlanks(item) ? t.planks : t.ingots);
  add(material, between(rand, t.qty));
  if (rand() < level * SALVAGE_BONUS_PER_LEVEL) add(material, 1);

  add('reagent_grave_dust', between(rand, [1, 2]));
  if (t.ecto && rand() < t.ecto) add('reagent_wraith_ectoplasm', 1);
  if (t.rare && rand() < t.rare) add(pick(rand, REAGENT_RARE), 1);
  if (t.meal && rand() < t.meal) add('bone_meal', 1);

  // Plain gear stops here (its random sequence is unchanged); a rolled piece gets one more chance at a material.
  const extra = instanceYieldBonus(item);
  if (extra > 0 && rand() < extra) add(material, 1);

  return { items: [...out].map(([item_id, quantity]) => ({ item_id, quantity })), xp: Math.round(t.xp * (1 + (item.affixes ?? 0) * SALVAGE_AFFIX_XP)) };
}

/** Merge several yields into one list (what the bag is asked to hold). */
export function mergeGrants(lists: SalvageGrant[][]): SalvageGrant[] {
  const out = new Map<string, number>();
  for (const l of lists) for (const g of l) out.set(g.item_id, (out.get(g.item_id) ?? 0) + g.quantity);
  return [...out].map(([item_id, quantity]) => ({ item_id, quantity }));
}
