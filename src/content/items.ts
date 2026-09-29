import type { ItemType, Rarity } from '../net/types';
import { PROCESSING_ITEMS } from './processing';

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
  /** Max stack size when the server caps it (gathered materials: 250). Unset = no client cap. */
  stack?: number;
}

const m = (name: string, rarity: Rarity, sell: number, lore?: string, icon?: string): ItemMeta => ({
  name,
  type: 'material',
  rarity,
  sell,
  lore,
  icon,
});

/** A gathered material (migration 002-gathering.sql gives these max_stack_size 250). */
const g = (name: string, rarity: Rarity, sell: number, lore?: string): ItemMeta => ({ ...m(name, rarity, sell, lore), stack: 250 });

export const ITEMS: Record<string, ItemMeta> = {
  material_copper_shard: m('Copper Shard', 'common', 1, 'Pried from coffin fittings.', 'art/items/material_copper_shard.png'),
  material_copper_bar: m('Copper Bar', 'common', 4, 'Smelted from grave-nails.', 'art/items/material_copper_bar.png'),
  ore_copper: g('Copper Ore', 'common', 1, 'Green-veined stone from the grave soil.'),
  ingot_copper: m('Copper Ingot', 'common', 4),
  ore_tin: g('Tin Ore', 'common', 1, 'Dull ore, cold as a burial ring.'),
  ingot_tin: m('Tin Ingot', 'common', 4),
  ore_iron: g('Iron Ore', 'uncommon', 3, 'Rusted from ossuary damp.'),
  ingot_iron: m('Iron Ingot', 'uncommon', 9),
  ore_bronze: g('Bronze Ore', 'uncommon', 3),
  ingot_bronze: m('Bronze Ingot', 'uncommon', 9),
  ore_silver: g('Silver Ore', 'uncommon', 6, 'Corpse-silver; it tarnishes near the living.'),
  ingot_silver: m('Silver Ingot', 'uncommon', 18),
  ore_gold: g('Gold Ore', 'rare', 12, 'Tithe-gold from the drowned nave.'),
  ingot_gold: m('Gold Ingot', 'rare', 36),
  ore_steel: g('Steel Ore', 'rare', 14),
  ingot_steel: m('Steel Ingot', 'rare', 40),
  ore_hell: g('Hell Ore', 'epic', 30),
  ingot_hell: m('Hell Ingot', 'epic', 90),
  ore_moon: g('Moon Ore', 'epic', 40),
  ingot_moon: m('Moon Ingot', 'epic', 120),
  fish_river: g('River Fish', 'common', 1),
  fish_fillet: m('River Fillet', 'common', 2),
  log_oak: g('Oak Log', 'common', 1, 'Coffin-wood, still sound.'),
  plank_oak: m('Oak Plank', 'common', 3),
  // Gathering (docs/PROFESSIONS-ROADMAP.md §4; rows added by migration 002-gathering.sql).
  log_elm: g('Elm Log', 'common', 3, "Cut from a hangman's elm. The rope scars run deep."),
  log_willow: g('Willow Log', 'uncommon', 6, 'The sap runs red and never quite dries.'),
  log_yew: g('Yew Log', 'uncommon', 10, 'Churchyard yew: the roots drink from the graves.'),
  log_blackthorn: g('Blackthorn Log', 'rare', 16, 'Thorned even after the axe.'),
  log_ghostwood: g('Ghostwood Log', 'rare', 24, 'Pale, cold and lighter than it should be.'),
  log_bone_elder: g('Bone Elder Log', 'epic', 36, 'It knocks like bone when you stack it.'),
  fish_crypt_eel: g('Crypt Eel', 'common', 3, 'Slid out of a flooded vault.'),
  fish_bell_carp: g('Bell Carp', 'uncommon', 6, 'Its scales ring faintly when tapped.'),
  fish_drowned_pike: g('Drowned Pike', 'uncommon', 10, 'All teeth and black water.'),
  fish_lanternfish: g('Lanternfish', 'rare', 16, 'Still glowing, even out of the water.'),
  fish_coelacanth: g('Abyssal Coelacanth', 'epic', 30, 'Older than the Covenant, and it looks it.'),
  bones_old: g('Old Bones', 'common', 1, "A pauper's remains. Grind them for the garden."),
  bones_barrow: g('Barrow Bones', 'common', 4, 'Heavy bones from a burial mound.'),
  bones_crypt: g('Crypt Bones', 'uncommon', 8, 'Crypt-dust still clings to them.'),
  bones_ancient: g('Ancient Bones', 'rare', 18, "A barrow-king's bones, crowned with lichen."),
  seed_mourning_moss: g('Mourning Moss Seed', 'common', 2, 'Plant it in a mourning bed.'),
  reliquary_fragment: g('Reliquary Fragment', 'rare', 25, 'Gilded shards from a broken reliquary.'),
  covenant_seal: g('Covenant Seal', 'epic', 60, 'The wax still bears the Ossuary mark.'),
  gem_grave_garnet: g('Grave Garnet', 'uncommon', 20, 'Blood-dark and cold.'),
  gem_bone_opal: g('Bone Opal', 'rare', 45, 'Milky fire trapped in bone.'),
  gem_void_sapphire: g('Void Sapphire', 'epic', 90, 'Its colour has no bottom.'),
  flask_hp_minor: m('Minor Healing Potion', 'common', 5, 'Restores 35% health. Press Q.'),
  flask_hp_major: m('Major Healing Flask', 'uncommon', 15, 'Restores 70% health. Press Q.'),
  flask_speed: m('Swiftness Flask', 'uncommon', 10, '+20% movement speed for 30 seconds.'),
  flask_damage: m('Forge-Tempered Flask', 'rare', 20, '+15% spell damage for 45 seconds.'),
  flask_void_resist: m('Void Resist Flask', 'uncommon', 12, 'Wards off 25% of all damage for 90 seconds.'),
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

// Professions G6 (content/processing.ts; server rows from migration 004-processing.sql).
for (const [id, p] of Object.entries(PROCESSING_ITEMS)) ITEMS[id] ??= { name: p.name, type: 'material', rarity: p.rarity, sell: p.sell, lore: p.lore, stack: p.stack };

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

/**
 * Buff flasks (2026-09-29): these were craftable but did nothing when used. Values match the server's
 * stat_bonus rows (speed 0.2 / 30 s, damage_amp 0.15 / 45 s, resist_void 0.25 / 90 s; void resist wards all damage).
 */
export const BUFF_FLASKS: Record<string, { kind: 'speed' | 'damage' | 'ward'; value: number; seconds: number; label: string }> = {
  flask_speed: { kind: 'speed', value: 0.2, seconds: 30, label: 'Swift' },
  flask_damage: { kind: 'damage', value: 0.15, seconds: 45, label: 'Forge-tempered' },
  flask_void_resist: { kind: 'ward', value: 0.25, seconds: 90, label: 'Warded' },
};

export const HEALING_FLASKS: Record<string, number> = {
  flask_hp_major: 0.7,
  flask_hp_minor: 0.35,
};
