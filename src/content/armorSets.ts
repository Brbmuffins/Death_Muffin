import type { AreaId } from './areas';
import type { ItemType, Rarity } from '../net/types';

export type ArmorPart = 'head' | 'chest' | 'hands' | 'legs' | 'feet';
export const ARMOR_PARTS: ArmorPart[] = ['head', 'chest', 'hands', 'legs', 'feet'];

interface ArmorSet {
  name: string;
  wearer: string;
  color: number;
  accent: number;
  stats: readonly [string, string];
  lore: string;
}

/** Five equippable pieces for each discipline. These are themed, not class locked: class changes are free. */
export const ARMOR_SETS: Record<string, ArmorSet> = {
  gravecaller: { name: 'Gravecall', wearer: 'Gravecaller', color: 0x817b9d, accent: 0xc7bddc, stats: ['stat_int', 'stat_vit'], lore: 'Stitched for those who command the newly buried.' },
  warden: { name: 'Lamplight', wearer: 'Grave Warden', color: 0x917047, accent: 0xf4bd67, stats: ['stat_vit', 'stat_str'], lore: 'Brass and soot from the grave watch.' },
  monk: { name: 'Bellwake', wearer: 'Bell Monk', color: 0x917962, accent: 0xe4c186, stats: ['stat_str', 'stat_agi'], lore: 'Worn thin by a thousand measured tolls.' },
  ossuary: { name: 'Ivory Reliquary', wearer: 'Ossuary', color: 0xd2c7a8, accent: 0x9b8ee2, stats: ['stat_int', 'stat_vit'], lore: 'Bone plates engraved with the Covenant dead.' },
  mourner: { name: 'Widowveil', wearer: 'Mourner', color: 0x666a8c, accent: 0xa4b9e0, stats: ['stat_int', 'stat_agi'], lore: 'Funeral cloth that remembers every name.' },
  witch: { name: 'Carrionbloom', wearer: 'Carrion Witch', color: 0x627542, accent: 0xc5da80, stats: ['stat_int', 'stat_vit'], lore: 'Living thorns bind the seams shut.' },
  rotweaver: { name: 'Blightweave', wearer: 'Rotweaver', color: 0x748447, accent: 0xc9e46d, stats: ['stat_int', 'stat_vit'], lore: 'A sickly mantle spun where the plague took root.' },
  knight: { name: 'Hollow Oath', wearer: 'Hollow Knight', color: 0x666b7c, accent: 0xc94f4f, stats: ['stat_str', 'stat_vit'], lore: 'Blackened plate still bearing its broken vow.' },
  veil: { name: 'Threshold', wearer: 'Veilwalker', color: 0x66618e, accent: 0xaea5f0, stats: ['stat_agi', 'stat_int'], lore: 'A border of silver marks the edge between worlds.' },
};

/** A second, late-game silhouette and palette for every discipline. */
export const ASCENDED_ARMOR_SETS: Record<string, ArmorSet> = {
  gravecaller: { name: 'Epitaph Sovereign', wearer: 'Gravecaller', color: 0x40385f, accent: 0xd7c9ff, stats: ['stat_int', 'stat_vit'], lore: 'A sovereign name is written on every bone clasp.' },
  warden: { name: 'Nightwatch Beacon', wearer: 'Grave Warden', color: 0x4f4636, accent: 0xffd476, stats: ['stat_vit', 'stat_str'], lore: 'Its caged flame answers the last watch bell.' },
  monk: { name: 'Last Toll', wearer: 'Bell Monk', color: 0x635141, accent: 0xffdd9c, stats: ['stat_str', 'stat_agi'], lore: 'Bronze thread hums with the final note.' },
  ossuary: { name: 'Marrow Regent', wearer: 'Ossuary', color: 0xb6a882, accent: 0xf3ecce, stats: ['stat_int', 'stat_vit'], lore: 'The reliquary opens only for its bearer.' },
  mourner: { name: 'Pale Requiem', wearer: 'Mourner', color: 0x454968, accent: 0xc8dcff, stats: ['stat_int', 'stat_agi'], lore: 'A hush follows wherever the silver hem falls.' },
  witch: { name: 'Thorn Covenant', wearer: 'Carrion Witch', color: 0x3b563e, accent: 0xb8f18d, stats: ['stat_int', 'stat_vit'], lore: 'The roots draw strength from what lies beneath.' },
  rotweaver: { name: 'Virulent Choir', wearer: 'Rotweaver', color: 0x475b26, accent: 0xdfff71, stats: ['stat_int', 'stat_vit'], lore: 'A bright plague song runs through its seams.' },
  knight: { name: 'Oathbreaker', wearer: 'Hollow Knight', color: 0x353946, accent: 0xff776f, stats: ['stat_str', 'stat_vit'], lore: 'The oath is broken; the shield remains.' },
  veil: { name: 'Umbral Crossing', wearer: 'Veilwalker', color: 0x393456, accent: 0xc8b8ff, stats: ['stat_agi', 'stat_int'], lore: 'The wearer leaves no shadow on either side.' },
};

export interface ArmorPiece {
  id: string;
  setId: string;
  disciplineId: string;
  collection: 1 | 2;
  setName: string;
  part: ArmorPart;
  name: string;
  type: ItemType;
  rarity: Rarity;
  area: AreaId;
  stats: Record<string, number>;
  color: number;
  accent: number;
  wearer: string;
  lore: string;
  sell: number;
}

const PART_NAMES: Record<ArmorPart, string> = { head: 'Crown', chest: 'Vestment', hands: 'Grips', legs: 'Legguards', feet: 'Treads' };
const PART_POWER: Record<ArmorPart, number> = { head: 2, chest: 4, hands: 2, legs: 3, feet: 2 };
const RARITY_SCALE: Record<Rarity, number> = { common: 1, uncommon: 1, rare: 2, epic: 3 };
const PART_AREA: Record<ArmorPart, AreaId> = { head: 'graves', hands: 'graves', chest: 'ossuary', legs: 'nave', feet: 'sanctum' };
const PART_RARITY: Record<ArmorPart, Rarity> = { head: 'uncommon', hands: 'uncommon', chest: 'rare', legs: 'rare', feet: 'epic' };
const ASCENDED_AREA: Record<ArmorPart, AreaId> = { head: 'sanctum', hands: 'sanctum', chest: 'cloister', legs: 'cloister', feet: 'pyre' };
const ASCENDED_RARITY: Record<ArmorPart, Rarity> = { head: 'rare', hands: 'rare', chest: 'epic', legs: 'epic', feet: 'epic' };

function piecesFor(sets: Record<string, ArmorSet>, collection: 1 | 2): ArmorPiece[] {
  return Object.entries(sets).flatMap(([disciplineId, set]) =>
  ARMOR_PARTS.map((part) => ({
    id: collection === 1 ? `set_${disciplineId}_${part}` : `set_${disciplineId}_ascended_${part}`,
    setId: collection === 1 ? disciplineId : `${disciplineId}_ascended`,
    disciplineId,
    collection,
    setName: set.name,
    part,
    name: `${set.name} ${PART_NAMES[part]}`,
    type: `armor_${part}` as ItemType,
    rarity: collection === 1 ? PART_RARITY[part] : ASCENDED_RARITY[part],
    area: collection === 1 ? PART_AREA[part] : ASCENDED_AREA[part],
    stats: { [set.stats[0]]: PART_POWER[part] * RARITY_SCALE[collection === 1 ? PART_RARITY[part] : ASCENDED_RARITY[part]] + (collection === 2 ? 1 : 0), [set.stats[1]]: Math.max(1, Math.floor(PART_POWER[part] * RARITY_SCALE[collection === 1 ? PART_RARITY[part] : ASCENDED_RARITY[part]] / 2)) },
    color: set.color,
    accent: set.accent,
    wearer: set.wearer,
    lore: set.lore,
    sell: PART_POWER[part] * ((collection === 1 ? PART_RARITY[part] : ASCENDED_RARITY[part]) === 'epic' ? 22 : (collection === 1 ? PART_RARITY[part] : ASCENDED_RARITY[part]) === 'rare' ? 13 : 7) + (collection === 2 ? 20 : 0),
  })));
}

export const ARMOR_PIECES: ArmorPiece[] = [...piecesFor(ARMOR_SETS, 1), ...piecesFor(ASCENDED_ARMOR_SETS, 2)];

export const ARMOR_BY_ID: Record<string, ArmorPiece> = Object.fromEntries(ARMOR_PIECES.map((piece) => [piece.id, piece]));

/** Equal weight per class and piece within an area's armor pool. */
export function armorLoot(area: AreaId) {
  return ARMOR_PIECES.filter((piece) => piece.area === area || (piece.collection === 1 && (area === 'cloister' || area === 'pyre') && piece.area !== 'graves') || (piece.collection === 2 && area === 'pyre' && piece.area === 'cloister'))
    .map((piece) => ({ item: piece.id, weight: 1 }));
}
