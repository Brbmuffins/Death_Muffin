import type { ItemType, Rarity } from '../net/types';

/**
 * Client-side display metadata for item ids the live server knows about
 * (harvested from /api/recipes on 2026-09-26). The server's items table stays
 * the source of truth for real stats — `offlineStats` is only used by the
 * DEV offline backend. Loot tables may only reference ids listed here, so a
 * pickup can never POST an item id the server would reject.
 */
export interface ItemMeta {
  name: string;
  type: ItemType;
  rarity: Rarity;
  sell: number;
  /** Relic-flavoured line shown in tooltips; the server name stays primary. */
  lore?: string;
  icon?: string;
  offlineStats?: Record<string, number>;
}

const m = (name: string, rarity: Rarity, sell: number, lore?: string, icon?: string): ItemMeta => ({
  name,
  type: 'material',
  rarity,
  sell,
  lore,
  icon,
});

export const ITEMS: Record<string, ItemMeta> = {
  material_copper_shard: m('Copper Shard', 'common', 1, 'Pried from coffin fittings.', 'art/items/material_copper_shard.png'),
  material_copper_bar: m('Copper Bar', 'common', 4, 'Smelted from grave-nails.', 'art/items/material_copper_bar.png'),
  ore_copper: m('Copper Ore', 'common', 1, 'Green-veined stone from the grave soil.'),
  ingot_copper: m('Copper Ingot', 'common', 4),
  ore_tin: m('Tin Ore', 'common', 1, 'Dull ore, cold as a burial ring.'),
  ingot_tin: m('Tin Ingot', 'common', 4),
  ore_iron: m('Iron Ore', 'uncommon', 3, 'Rusted from ossuary damp.'),
  ingot_iron: m('Iron Ingot', 'uncommon', 9),
  ore_bronze: m('Bronze Ore', 'uncommon', 3),
  ingot_bronze: m('Bronze Ingot', 'uncommon', 9),
  ore_silver: m('Silver Ore', 'uncommon', 6, 'Corpse-silver; it tarnishes near the living.'),
  ingot_silver: m('Silver Ingot', 'uncommon', 18),
  ore_gold: m('Gold Ore', 'rare', 12, 'Tithe-gold from the drowned nave.'),
  ingot_gold: m('Gold Ingot', 'rare', 36),
  ore_steel: m('Steel Ore', 'rare', 14),
  ingot_steel: m('Steel Ingot', 'rare', 40),
  ore_hell: m('Hell Ore', 'epic', 30),
  ingot_hell: m('Hell Ingot', 'epic', 90),
  ore_moon: m('Moon Ore', 'epic', 40),
  ingot_moon: m('Moon Ingot', 'epic', 120),
  fish_river: m('River Fish', 'common', 1),
  fish_fillet: m('River Fillet', 'common', 2),
  log_oak: m('Oak Log', 'common', 1, 'Coffin-wood, still sound.'),
  plank_oak: m('Oak Plank', 'common', 3),
  flask_hp_minor: m('Minor Healing Potion', 'common', 5, 'Restores 35% health. Press Q.'),
  flask_hp_major: m('Major Healing Flask', 'uncommon', 15, 'Restores 70% health. Press Q.'),
  flask_speed: m('Swiftness Flask', 'uncommon', 10),
  flask_damage: m('Forge-Tempered Flask', 'rare', 20),
  flask_void_resist: m('Void Resist Flask', 'uncommon', 12),
  ring_copper: {
    name: 'Copper Ring', type: 'ring', rarity: 'uncommon', sell: 12,
    lore: 'A mourning band. The name inside is scratched out.', icon: 'art/items/ring_copper.png',
    offlineStats: { stat_int: 2, stat_vit: 1 },
  },
  helm_copper: { name: 'Copper Helm', type: 'armor_head', rarity: 'common', sell: 10, lore: 'Dented by a grave-robber\'s spade.', offlineStats: { stat_vit: 3 } },
  plate_copper: { name: 'Copper Plate', type: 'armor_chest', rarity: 'uncommon', sell: 20, offlineStats: { stat_vit: 6 } },
  sword_copper: { name: 'Copper Sword', type: 'weapon', rarity: 'uncommon', sell: 18, offlineStats: { stat_str: 4 } },
  staff_oak: { name: 'Oak Staff', type: 'weapon', rarity: 'uncommon', sell: 16, lore: 'A coffin-oak focus. Bone Needles fly truer.', offlineStats: { stat_int: 5 } },
  bow_oak: { name: 'Oak Shortbow', type: 'weapon', rarity: 'common', sell: 14, offlineStats: { stat_agi: 4 } },
  augment_copper: { name: 'Copper Augment', type: 'trinket', rarity: 'common', sell: 8, offlineStats: { stat_int: 2 } },
  augment_iron: { name: 'Iron Augment', type: 'trinket', rarity: 'uncommon', sell: 22, offlineStats: { stat_int: 4 } },
  helm_iron: { name: 'Iron Helm', type: 'armor_head', rarity: 'uncommon', sell: 24, offlineStats: { stat_vit: 5, stat_str: 1 } },
  chest_iron: { name: 'Iron Chestplate', type: 'armor_chest', rarity: 'rare', sell: 45, lore: 'Salt-bloomed plate from a crypt knight.', offlineStats: { stat_vit: 9, stat_str: 2 } },
  helm_gold: { name: 'Gold-Tempered Helm', type: 'armor_head', rarity: 'rare', sell: 60, lore: 'Prelate\'s regalia, bell-dented.', offlineStats: { stat_vit: 6, stat_int: 4 } },
  kit_iron_warden: { name: 'Iron Warden Kit', type: 'trinket', rarity: 'rare', sell: 55, offlineStats: { stat_vit: 4, stat_int: 4 } },
};

export const RARITY_COLOR: Record<Rarity, string> = {
  common: '#b9b2a4',
  uncommon: '#8fb98a',
  rare: '#8fa6e8',
  epic: '#c6a4ff',
};

/** Shape reinforcement for colour-blind readability (audit: rarity was colour-only). */
export const RARITY_MARK: Record<Rarity, string> = {
  common: '·',
  uncommon: '◆',
  rare: '◆◆',
  epic: '◆◆◆',
};

export function itemMeta(id: string): ItemMeta {
  return ITEMS[id] ?? { name: id.replace(/_/g, ' '), type: 'material', rarity: 'common', sell: 0 };
}

export const HEALING_FLASKS: Record<string, number> = {
  flask_hp_major: 0.7,
  flask_hp_minor: 0.35,
};
