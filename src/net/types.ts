// Shapes verified against the live /api/* endpoints (see context: inventory
// rows come back joined with their items row).

export type Rarity = 'common' | 'uncommon' | 'rare' | 'epic';

export type ItemType =
  | 'weapon'
  | 'armor_head'
  | 'armor_chest'
  | 'armor_legs'
  | 'armor_feet'
  | 'armor_hands'
  | 'offhand'
  | 'ring'
  | 'trinket'
  | 'material';

export interface InventorySlot {
  id: number;
  slot_index: number;
  quantity: number;
  equipped: 0 | 1;
  item_id: string;
  name: string;
  rarity: Rarity;
  item_type: ItemType;
  /** Where an equipped item sits (server INV_SELECT); null/absent in the bag. */
  equipped_slot?: string | null;
  /** The item's own slot (server items.equipment_slot). */
  item_equipment_slot?: string | null;
  stat_bonus: Record<string, number> | null;
  icon_id: string | null;
  sell_value: number;
  crafted: 0 | 1;
}

export interface Profession {
  profession_id: string;
  skill_level: number;
  skill_xp: number;
}

export interface RecipeIngredient {
  item_id: string;
  quantity: number;
  name: string;
}

export interface Recipe {
  id: string;
  name: string;
  profession_id: string;
  skill_level_required: number;
  result_item_id: string;
  result_quantity: number;
  ingredients: RecipeIngredient[];
}

/** GET/POST /character. The server may send extra legacy columns; these are the ones the client uses. */
export interface Character {
  id: number;
  class_index: number;
  class_name: string;
  level: number;
  experience: number;
  gold: number;
  stat_str: number;
  stat_agi: number;
  stat_int: number;
  stat_vit: number;
  /** Death Muffin staff flags (`formatCharacter`); absent on older servers. */
  gm_enabled?: boolean;
  gm_level?: number;
  gm_permissions?: string;
}
