import { PROCESSING_RECIPES, type RecipeRow } from './processing';
import { ALCHEMY_RECIPES } from './alchemy';
import { NECRO_RECIPES } from './necroWeapons';
import { REAGENT_RECIPES } from './reagents';
import { FEN_RECIPES } from './fenItems';

/**
 * Every Workbench / station recipe the client knows, one list: [id, name, profession, level, result, quantity, ingredients].
 * The first block is what the live server's /api/recipes held on 2026-09-26 (the offline mock serves it; the Gear Atlas reads it
 * for "how do I craft this"); the rest are the generated rows each content file owns, which the server migrations are built from.
 */
export const BASE_RECIPE_ROWS: RecipeRow[] = [
  ['recipe_copper_bar', 'Smelt Copper Bar', 'mining', 1, 'material_copper_bar', 1, [['material_copper_shard', 3]]],
  ['smelt_copper_ingot', 'Smelt Copper Ingot', 'mining', 1, 'ingot_copper', 1, [['ore_copper', 3]]],
  ['craft_copper_helm', 'Copper Helm', 'mining', 3, 'helm_copper', 1, [['ingot_copper', 2]]],
  ['recipe_copper_ring', 'Forge Copper Ring', 'mining', 3, 'ring_copper', 1, [['material_copper_bar', 2]]],
  ['smelt_tin_ingot', 'Smelt Tin Ingot', 'mining', 3, 'ingot_tin', 1, [['ore_tin', 3]]],
  ['craft_copper_augment', 'Copper Augment', 'mining', 5, 'augment_copper', 1, [['ingot_copper', 1]]],
  ['recipe_copper_plate', 'Forge Copper Plate', 'mining', 5, 'plate_copper', 1, [['material_copper_bar', 4]]],
  ['recipe_copper_sword', 'Forge Copper Sword', 'mining', 5, 'sword_copper', 1, [['material_copper_bar', 3]]],
  ['smelt_iron_ingot', 'Smelt Iron Ingot', 'mining', 5, 'ingot_iron', 1, [['ore_iron', 3]]],
  ['craft_iron_helm', 'Iron Helm', 'mining', 8, 'helm_iron', 1, [['ingot_iron', 2]]],
  ['smelt_bronze_ingot', 'Smelt Bronze Ingot', 'mining', 8, 'ingot_bronze', 1, [['ore_bronze', 3]]],
  ['craft_forge_tempered_flask', 'Forge-Tempered Flask', 'mining', 10, 'flask_damage', 1, [['fish_fillet', 3], ['ingot_iron', 2]]],
  ['craft_iron_chestplate', 'Iron Chestplate', 'mining', 10, 'chest_iron', 1, [['ingot_copper', 1], ['ingot_iron', 3]]],
  ['craft_iron_augment', 'Iron Augment', 'mining', 12, 'augment_iron', 1, [['ingot_iron', 1]]],
  ['craft_iron_warden_kit', 'Iron Warden Kit', 'mining', 12, 'kit_iron_warden', 1, [['ingot_iron', 3], ['plank_oak', 2]]],
  ['smelt_silver_ingot', 'Smelt Silver Ingot', 'mining', 12, 'ingot_silver', 1, [['ore_silver', 3]]],
  ['smelt_gold_ingot', 'Smelt Gold Ingot', 'mining', 15, 'ingot_gold', 1, [['ore_gold', 3]]],
  ['craft_gold_tempered_helm', 'Gold-Tempered Helm', 'mining', 18, 'helm_gold', 1, [['ingot_gold', 2], ['ingot_iron', 1]]],
  ['smelt_steel_ingot', 'Smelt Steel Ingot', 'mining', 20, 'ingot_steel', 1, [['ore_steel', 3]]],
  ['smelt_hell_ingot', 'Smelt Hell Ingot', 'mining', 35, 'ingot_hell', 1, [['ore_hell', 3]]],
  ['smelt_moon_ingot', 'Smelt Moon Ingot', 'mining', 50, 'ingot_moon', 1, [['ore_moon', 3]]],
  ['craft_minor_healing_potion', 'Minor Healing Potion', 'fishing', 1, 'flask_hp_minor', 1, [['fish_fillet', 2]]],
  ['prepare_river_fillet', 'Prepare River Fillet', 'fishing', 1, 'fish_fillet', 1, [['fish_river', 2]]],
  ['craft_swiftness_flask', 'Swiftness Flask', 'fishing', 3, 'flask_speed', 1, [['fish_fillet', 2], ['ingot_copper', 1]]],
  ['craft_void_resist_flask', 'Void Resist Flask', 'fishing', 5, 'flask_void_resist', 1, [['fish_fillet', 3], ['ingot_copper', 2]]],
  ['craft_major_healing_flask', 'Major Healing Flask', 'fishing', 8, 'flask_hp_major', 1, [['fish_fillet', 4], ['ingot_iron', 1]]],
  ['mill_oak_plank', 'Mill Oak Plank', 'woodcutting', 1, 'plank_oak', 1, [['log_oak', 3]]],
  ['craft_oak_shortbow', 'Oak Shortbow', 'woodcutting', 3, 'bow_oak', 1, [['plank_oak', 3]]],
  ['craft_oak_staff', 'Oak Staff', 'woodcutting', 3, 'staff_oak', 1, [['plank_oak', 3]]],
];

export const ALL_RECIPE_ROWS: RecipeRow[] = [...BASE_RECIPE_ROWS, ...PROCESSING_RECIPES, ...ALCHEMY_RECIPES, ...NECRO_RECIPES, ...REAGENT_RECIPES, ...FEN_RECIPES];
