import type { RecipeRow } from './processing';

/**
 * Workbench recipes that give the old sell-only trade goods (Tin / Bronze Ingot, Grave Garnet, Bone Opal) a second use, owner
 * decision 3 Oct 2026 (docs/polish/loot.md item 14, server/proposals/trade-goods-recipes.md). Every result and ingredient is an
 * existing item row; migration 028-trade-goods-recipes.sql is generated from this list by tools/build-trade-goods-sql.mjs.
 *
 * Economy rule (a test pins it): the vendor value of the ingredients is at least the vendor value of the result, so no recipe is a
 * gold loop. The proposal's Bronze Warden Kit (3 Bronze + 2 Planks = 33 in, 55 out) broke its own "never pays out more than it
 * eats" rule, so it takes 6 Bronze Ingots (60 in, 55 out).
 */
export const TRADE_GOODS_RECIPES: RecipeRow[] = [
  ['craft_bronze_warden_kit', 'Bronze Warden Kit', 'mining', 12, 'kit_iron_warden', 1, [['ingot_bronze', 6], ['plank_oak', 2]]],
  ['craft_tin_augment', 'Tin Augment', 'mining', 5, 'augment_copper', 1, [['ingot_tin', 2]]],
  ['craft_garnet_ring', 'Garnet Ring', 'mining', 8, 'ring_copper', 1, [['gem_grave_garnet', 1], ['material_copper_bar', 2]]],
  ['craft_opal_flask', 'Opal Flask', 'fishing', 20, 'flask_damage', 2, [['gem_bone_opal', 1], ['fish_fillet', 3]]],
];
