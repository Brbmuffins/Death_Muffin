import type { ItemType, Rarity } from '../net/types';

/**
 * The Scythe of Undeath: ONE test weapon for the Reaper that carries the three affixes a set could have (Haunting Wraith casts three in a cone,
 * every soul in her bag adds damage and defense, a soul gained at a full bag casts a free Wraith). It is a normal item as far as the server is
 * concerned (stats only; the client reads the worn id, client/rules/combat/dm_undeath_scythe.gd), made at the Workbench from cheap parts,
 * and is meant to be dissolved once the set idea it tests is decided. Server row and recipe: migration 061-scythe-of-undeath.sql.
 */
export const UNDEATH_SCYTHE: {
  id: string; name: string; type: ItemType; slot: 'main_hand'; rarity: Rarity; stats: Record<string, number>; sell: number; lore: string;
} = {
  id: 'scythe_of_undeath',
  name: 'Scythe of Undeath',
  type: 'weapon',
  slot: 'main_hand',
  rarity: 'legendary',
  stats: { stat_int: 26, stat_vit: 11 },
  sell: 400,
  lore: 'Test weapon. Haunting Wraith raises three wraiths in a cone. Each soul in your bag adds 2% damage and 1% less damage taken. A soul gained with a full bag casts a free Haunting Wraith.',
};

/** Workbench recipe (Smithing, level 1, same row shape as NECRO_RECIPES): easy on purpose. */
export const UNDEATH_RECIPE: [string, string, string, number, string, number, [string, number][]] = [
  'craft_scythe_of_undeath', UNDEATH_SCYTHE.name, 'mining', 1, UNDEATH_SCYTHE.id, 1, [['ingot_copper', 1], ['bones_old', 1]],
];
