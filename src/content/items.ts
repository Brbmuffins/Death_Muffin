import type { ItemType, Rarity } from '../net/types';
import { PROCESSING_ITEMS } from './processing';
import { GARDEN_ITEMS } from './gardening';
import { ALCHEMY_HEALING, ALCHEMY_ITEMS } from './alchemy';
import { FEN_ITEMS } from './fenItems';
import { BREWS, type BrewKind } from './brews';
import { CHARM_ITEMS } from './cosmetics';
import { ARMOR_PIECES } from './armorSets';
import { NECRO_WEAPONS } from './necroWeapons';
import { REAGENT_BREW_ITEMS, REAGENT_ITEMS, reagentIcon } from './reagents';
import { RUNES } from './runes';

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

// Stack 99 = the server's default max_stack_size; with no cap the client built 41+ potion stacks the server refused,
// and every bag save after that failed (2026-10-03).
const m = (name: string, rarity: Rarity, sell: number, lore?: string, icon?: string): ItemMeta => ({
  name,
  type: 'material',
  rarity,
  sell,
  lore,
  icon,
  stack: 99,
});

/** A gathered material (migration 002-gathering.sql gives these max_stack_size 250). */
const g = (name: string, rarity: Rarity, sell: number, lore?: string): ItemMeta => ({ ...m(name, rarity, sell, lore), stack: 250 });

export const ITEMS: Record<string, ItemMeta> = {
  material_copper_shard: m('Copper Shard', 'common', 1, 'Pried from coffin fittings.', 'art/items/material_copper_shard.webp'),
  material_copper_bar: m('Copper Bar', 'common', 4, 'Smelted from grave-nails.', 'art/items/material_copper_bar.webp'),
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
    lore: 'A mourning band. The name inside is scratched out.', icon: 'art/items/ring_copper.webp',
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

// Grave Gardening (content/gardening.ts; server rows from migration 007-gardening.sql).
// The two tree saplings' art predates their ids (sapling_coffin_oak.webp is the Coffin-Oak sapling, sapling_oak the item).
const GARDEN_ICON: Record<string, string> = { sapling_oak: 'art/items/sapling_coffin_oak.webp', sapling_yew: 'art/items/sapling_churchyard_yew.webp' };
for (const [id, g] of Object.entries(GARDEN_ITEMS)) ITEMS[id] ??= { name: g.name, type: 'material', rarity: g.rarity, sell: g.sell, lore: g.lore, stack: g.stack, icon: GARDEN_ICON[id] };

// The two saplings' art was drawn under the plot names, not the item ids (docs/polish/atlas-findings.md).
for (const [id, icon] of Object.entries({ sapling_oak: 'art/items/sapling_coffin_oak.webp', sapling_yew: 'art/items/sapling_churchyard_yew.webp' })) if (ITEMS[id]) ITEMS[id].icon = icon;

// Pet charms (content/cosmetics.ts; server rows from migration 010-cosmetics.sql).
for (const [id, c] of Object.entries(CHARM_ITEMS)) ITEMS[id] ??= { name: c.name, type: 'material', rarity: c.rarity, sell: c.sell, lore: c.lore, stack: 1, icon: `art/items/${id}.svg` };

// Alchemy (content/alchemy.ts; server rows from migration 009-alchemy.sql).
for (const [id, a] of Object.entries(ALCHEMY_ITEMS)) ITEMS[id] ??= { name: a.name, type: 'material', rarity: a.rarity, sell: a.sell, lore: a.lore, stack: a.stack, icon: `art/items/${id}.svg` };

// Reagents, zone herbs, boss ichors and the brews made from them (content/reagents.ts; server rows from migration 014-alchemy-reagents.sql).
for (const [id, r] of Object.entries(REAGENT_ITEMS)) ITEMS[id] ??= { name: r.name, type: 'material', rarity: r.rarity, sell: r.sell, lore: r.lore, stack: r.stack, icon: reagentIcon(id) };
for (const [id, r] of Object.entries(REAGENT_BREW_ITEMS)) ITEMS[id] ??= { name: r.name, type: 'material', rarity: r.rarity, sell: r.sell, lore: r.lore, stack: r.stack, icon: reagentIcon(id) };
// The Mourning Fen's herbs and seeds (content/fenItems.ts; server rows from migration 015-fen.sql).
for (const [id, f] of Object.entries(FEN_ITEMS)) ITEMS[id] ??= { name: f.name, type: 'material', rarity: f.rarity, sell: f.sell, lore: f.lore, stack: f.stack, ...(id.startsWith('ichor_') ? { icon: `art/items/${id}.svg` } : {}) };

// Professions G6 (content/processing.ts; server rows from migration 004-processing.sql).
for (const [id, p] of Object.entries(PROCESSING_ITEMS)) ITEMS[id] ??= { name: p.name, type: 'material', rarity: p.rarity, sell: p.sell, lore: p.lore, stack: p.stack };

for (const piece of ARMOR_PIECES) ITEMS[piece.id] = {
  name: piece.name, type: piece.type, rarity: piece.rarity, sell: piece.sell,
  lore: piece.lore,
  icon: `art/items/${piece.id}.svg`, offlineStats: piece.stats,
};

// Necromancer weapon line (content/necroWeapons.ts; server rows from migration 013-necro-weapons.sql).
for (const w of NECRO_WEAPONS) ITEMS[w.id] = {
  name: w.name, type: w.type, rarity: w.rarity, sell: w.sell, lore: w.lore,
  icon: `art/items/${w.id}.svg`, offlineStats: w.stats,
};

// Relic runes (content/runes.ts; server rows from migration 024-relic-runes.sql). They stack to 99; the art is art/items/<id>.webp.
for (const r of Object.values(RUNES)) ITEMS[r.id] = { name: r.name, type: 'rune', rarity: r.rarity, sell: r.sell, lore: r.lore, stack: 99 };

export const RARITY_COLOR: Record<Rarity, string> = {
  common: '#b9b2a4',
  uncommon: '#8fb98a',
  rare: '#8fa6e8',
  epic: '#c6a4ff',
  legendary: '#ff9a2e',
};

/** Shape reinforcement for colour-blind readability (audit: rarity was colour-only). */
export const RARITY_MARK: Record<Rarity, string> = {
  common: '·',
  uncommon: '◆',
  rare: '◆◆',
  epic: '◆◆◆',
  legendary: '★',
};

export function itemMeta(id: string): ItemMeta {
  return ITEMS[id] ?? { name: id.replace(/_/g, ' '), type: 'material', rarity: 'common', sell: 0 };
}

/**
 * Buff flasks (2026-09-29): these were craftable but did nothing when used. Values match the server's
 * stat_bonus rows (now derived from BREWS in brews.ts; speed 0.2 / 30 s, damage_amp 0.15 / 45 s, resist_void 0.25 / 90 s; void resist wards all damage).
 */
export const BUFF_FLASKS: Record<string, { kind: BrewKind; value: number; seconds: number; label: string }> = Object.fromEntries(
  Object.entries(BREWS).map(([id, b]) => [id, { kind: b.effects[0].kind, value: b.effects[0].value, seconds: b.seconds, label: b.label }]),
);

export const HEALING_FLASKS: Record<string, number> = {
  flask_hp_major: 0.7,
  flask_hp_minor: 0.35,
  ...ALCHEMY_HEALING,
};
