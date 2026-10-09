import type { Rarity } from '../../../src/net/types';
import { TOOL_KIND, TOOL_METALS, type SkillId } from '../gameplay/gatheringRules';

/**
 * Professions G6 — processing (docs/PROFESSIONS-ROADMAP.md §3, §13). One source for the new items
 * and recipes: the client catalogue (content/items.ts) and the offline mock read it directly, and
 * `node tools/build-processing-sql.mjs` writes the server migration from it, so the three can't drift.
 *
 *  - Carpentry (Sawpit):   every log mills into its plank.
 *  - Cooking (Cooking Fire): every fish cooks into a meal (heal over time, see MEALS).
 *  - Bonework (Bone Kiln): bones grind into bone meal (a flask ingredient now, compost later).
 *  - Tools (Workbench):    hatchet / pickaxe / rod / spade in six metals, from ingots and planks.
 */
export interface ProcessingItem {
  name: string;
  rarity: Rarity;
  sell: number;
  lore: string;
  kind: 'material' | 'consumable';
  stack: number;
}
/** [id, name, profession, level, result, quantity, ingredients] — the same shape as the mock's rows. */
export type RecipeRow = [string, string, string, number, string, number, [string, number][]];

const WOODS: [wood: string, name: string, level: number, rarity: Rarity, sell: number, lore: string][] = [
  ['elm', 'Elm Plank', 5, 'common', 8, 'Hangman-elm, straight-grained and grim.'],
  ['willow', 'Willow Plank', 15, 'uncommon', 16, 'Red-streaked where the sap bled.'],
  ['yew', 'Yew Plank', 40, 'uncommon', 26, 'Churchyard yew: springy, and it remembers.'],
  ['blackthorn', 'Blackthorn Plank', 55, 'rare', 42, 'Still thorny at the knots.'],
  ['ghostwood', 'Ghostwood Plank', 70, 'rare', 60, 'Pale, cold, and lighter than air should allow.'],
  ['bone_elder', 'Bone Elder Plank', 85, 'epic', 90, 'It clacks like bone when you stack it.'],
];
const FISH: [fish: string, name: string, level: number, rarity: Rarity, sell: number, lore: string][] = [
  ['crypt_eel', 'Smoked Crypt Eel', 12, 'common', 10, 'Smoked over coffin-wood. Heals over time.'],
  ['bell_carp', 'Bell Carp Stew', 28, 'uncommon', 20, 'It still rings faintly in the bowl. Heals over time.'],
  ['drowned_pike', 'Drowned Pike Fillet', 42, 'uncommon', 30, 'All teeth removed. Most of them. Heals over time.'],
  ['lanternfish', 'Lanternfish Supper', 60, 'rare', 48, 'It glows on the plate. Heals over time.'],
  ['coelacanth', 'Coelacanth Feast', 78, 'epic', 80, 'Older than the Covenant, and filling. Heals over time.'],
];
/** Meals heal a share of max health over `seconds` (can stack with a flask; one meal at a time). */
export const MEALS: Record<string, { healFrac: number; seconds: number }> = {
  meal_crypt_eel: { healFrac: 0.3, seconds: 10 },
  meal_bell_carp: { healFrac: 0.4, seconds: 10 },
  meal_drowned_pike: { healFrac: 0.5, seconds: 10 },
  meal_lanternfish: { healFrac: 0.6, seconds: 10 },
  meal_coelacanth: { healFrac: 0.75, seconds: 10 },
};
const TOOL_NAMES: Record<string, string> = { hatchet: 'Hatchet', pickaxe: 'Pickaxe', rod: 'Fishing Rod', spade: 'Grave Spade' };
const METAL_NAME = ['Copper', 'Iron', 'Silver', 'Steel', 'Hell', 'Moon'];
const METAL_RARITY: Rarity[] = ['common', 'common', 'uncommon', 'rare', 'rare', 'epic'];
/** Tier → [mining level, ingots, planks (by wood)]. */
const TOOL_COST: [number, number, string, number][] = [
  [1, 2, 'plank_oak', 1],
  [8, 3, 'plank_elm', 2],
  [14, 3, 'plank_willow', 2],
  [22, 4, 'plank_yew', 2],
  [38, 4, 'plank_blackthorn', 3],
  [52, 5, 'plank_ghostwood', 3],
];

export const PROCESSING_ITEMS: Record<string, ProcessingItem> = {};
export const PROCESSING_RECIPES: RecipeRow[] = [];

for (const [wood, name, level, rarity, sell, lore] of WOODS) {
  PROCESSING_ITEMS[`plank_${wood}`] = { name, rarity, sell, lore, kind: 'material', stack: 250 };
  PROCESSING_RECIPES.push([`mill_${wood}_plank`, `Mill ${name}`, 'woodcutting', level, `plank_${wood}`, 1, [[`log_${wood}`, 3]]]);
}
for (const [fish, name, level, rarity, sell, lore] of FISH) {
  PROCESSING_ITEMS[`meal_${fish}`] = { name, rarity, sell, lore, kind: 'consumable', stack: 99 };
  PROCESSING_RECIPES.push([`cook_${fish}`, `Cook ${name}`, 'fishing', level, `meal_${fish}`, 1, [[`fish_${fish}`, 2]]]);
}
PROCESSING_ITEMS.bone_meal = { name: 'Bone Meal', rarity: 'common', sell: 4, lore: 'Ground at the Bone Kiln. Mourning beds love it.', kind: 'material', stack: 250 };
PROCESSING_RECIPES.push(
  ['grind_bones_old', 'Grind Old Bones', 'gravedigging', 1, 'bone_meal', 1, [['bones_old', 4]]],
  ['grind_bones_barrow', 'Grind Barrow Bones', 'gravedigging', 20, 'bone_meal', 1, [['bones_barrow', 2]]],
  ['grind_bones_crypt', 'Grind Crypt Bones', 'gravedigging', 40, 'bone_meal', 2, [['bones_crypt', 1]]],
  ['grind_bones_ancient', 'Grind Ancient Bones', 'gravedigging', 70, 'bone_meal', 5, [['bones_ancient', 1]]],
  // Bone meal's first use: a cheaper road to the Major Healing Flask (no iron).
  ['brew_bone_ash_flask', 'Brew Bone-Ash Flask', 'fishing', 10, 'flask_hp_major', 1, [['fish_fillet', 3], ['bone_meal', 2]]],
);
for (const skill of Object.keys(TOOL_KIND) as SkillId[]) {
  const kind = TOOL_KIND[skill]!;
  TOOL_METALS.forEach((metal, i) => {
    const id = `tool_${kind}_${metal}`;
    const [level, ingots, plank, planks] = TOOL_COST[i];
    PROCESSING_ITEMS[id] = {
      name: `${METAL_NAME[i]} ${TOOL_NAMES[kind]}`,
      rarity: METAL_RARITY[i],
      sell: 10 * (i + 1) * (i + 1),
      lore: `Carry it in your bag or on the tool belt: +${5 * (i + 1)}% gathering success (the best tool you carry counts).`,
      kind: 'material',
      stack: 1,
    };
    PROCESSING_RECIPES.push([`smith_${kind}_${metal}`, `Forge ${PROCESSING_ITEMS[id].name}`, 'mining', level, id, 1, [[`ingot_${metal}`, ingots], [plank, planks]]]);
  });
}
