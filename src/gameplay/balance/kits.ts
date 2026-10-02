import type { InventorySlot } from '../../net/types';
import { AREAS, type AreaId } from '../../content/areas';
import { ARMOR_BY_ID, ARMOR_PARTS, ARMOR_PIECES, type ArmorPart } from '../../content/armorSets';
import { NECRO_DISCIPLINES, NECRO_TIERS, NECRO_TIER_INFO, NECRO_WEAPON_BY_ID, type NecroKind, type NecroTier } from '../../content/necroWeapons';
import { affixRange, type AffixRoll } from '../affixRules';

/**
 * Representative gear kits for the balance harness (`npm run balance` with BALANCE_KIT, `npm run balance:gear`).
 *
 * A kit is DATA: the worn items (real catalogue ids, so the real stats, set bonuses and weapon line apply) and the
 * affixes rolled on them. The harness turns it into inventory rows and runs the same `deriveStats` / `withSetBonuses`
 * the game uses, so a kit cannot drift from the live rules. Quality `q` is where a roll sits in its item-level range
 * (0 = weakest, 1 = best), so a kit keeps meaning the same thing when ranges are retuned.
 *
 * Kits (docs: BALANCE.md "Gear pass"):
 *   none      nothing worn: the harness as it always was (the `gearStats` stat stand-in covers ordinary gear).
 *   progress  what has dropped in EARLIER hunting grounds: the discipline's own set pieces and the weapon tier of those
 *             areas, one lever affix at a middling roll on the best piece. Graves has no earlier ground, so it is `none`.
 *   typical   a completed first-collection set + a matching weapon of the area's tier + two lever affixes (q 0.5).
 *   ascended  the ascended set + a moon weapon pair + one lever affix (q 0.75) on every worn piece, rotating through the levers.
 *   bis       as ascended, but three affixes (q 1.0) on every piece: the theoretical ceiling, never expected in play.
 */
export type KitName = 'none' | 'progress' | 'typical' | 'ascended' | 'bis';
export const KIT_NAMES: readonly KitName[] = ['none', 'progress', 'typical', 'ascended', 'bis'];

export interface KitItem {
  itemId: string;
  /** Wear only the item's base stats: not part of its set / weapon line (decomposition experiments). */
  plain?: boolean;
  /** What-if multiplier on the item's base stat points. */
  statScale?: number;
  ilvl: number;
  affixes: { id: string; q: number }[];
}

/** Progression order of the hunting grounds, for "what could I have found before this one". */
export const AREA_RANK: Partial<Record<AreaId, number>> = { graves: 1, warren: 2, ossuary: 2, coliseum: 3, nave: 3, sanctum: 4, cloister: 5, pyre: 6, fen: 7 };

/** First-collection armor drops by piece (armorSets.ts PART_AREA / ASCENDED_AREA), as progression ranks. */
const PIECE_RANK = (collection: 1 | 2, part: ArmorPart): number => {
  const first: Record<ArmorPart, number> = { head: 1, hands: 1, chest: 2, legs: 3, feet: 4 };
  const asc: Record<ArmorPart, number> = { head: 4, hands: 4, chest: 5, legs: 5, feet: 6 };
  return collection === 1 ? first[part] : asc[part];
};
/** Weapon tiers drop from these ranks on (NECRO_TIER_INFO areas). */
const TIER_RANK: Record<NecroTier, number> = { bone: 1, iron: 2, gold: 3, hell: 5, moon: 6 };

/** Per necromancer: the weapon pair that suits it and the lever affixes it wants, best first (BALANCE.md gear pass). */
export interface DisciplineKit {
  main: NecroKind;
  off: NecroKind | null;
  levers: string[];
}
export const DISCIPLINE_KIT: Record<string, DisciplineKit> = {
  ossuary: { main: 'staff', off: null, levers: ['s_ward', 's_thrall_hp', 'p_thrall_dmg', 'p_essence_regen'] },
  gravecaller: { main: 'sickle', off: 'skull_focus', levers: ['p_thrall_dmg', 's_thrall_hp', 'p_essence_regen', 's_ward'] },
  mourner: { main: 'wand', off: 'mourning_bell', levers: ['p_essence_regen', 'p_thrall_dmg', 's_thrall_hp', 's_ward'] },
  rotweaver: { main: 'sickle', off: 'grimoire', levers: ['s_miasma', 'p_withered', 'p_thrall_dmg', 'p_essence_regen'] },
};

const highestTier = (rank: number): NecroTier | null => [...NECRO_TIERS].reverse().find((t) => TIER_RANK[t] < rank) ?? null;
/** The tier a typical player of this area carries: what drops in the area itself (NECRO_TIER_INFO). */
const tierOfArea = (area: AreaId): NecroTier => [...NECRO_TIERS].reverse().find((t) => NECRO_TIER_INFO[t].area.includes(area)) ?? 'bone';

const setIds = (discipline: string) => ({ first: discipline, ascended: `${discipline}_ascended` });
const piecesOf = (setId: string) => ARMOR_PIECES.filter((p) => p.setId === setId);
const armorItem = (setId: string, part: ArmorPart, ilvl: number, affixes: KitItem['affixes'] = []): KitItem => ({ itemId: piecesOf(setId).find((p) => p.part === part)!.id, ilvl, affixes });
const weaponItem = (kind: NecroKind, tier: NecroTier, ilvl: number, affixes: KitItem['affixes'] = []): KitItem => ({ itemId: `${kind}_${tier}`, ilvl, affixes });

/**
 * `ascended`: one lever affix per piece, rotating through the discipline's levers (best first), so seven pieces carry the first
 * lever twice, the second twice, the third twice and the fourth once: good rolls, spread the way drops spread.
 * `bis`: the discipline's best three levers on EVERY piece, which stacks one multiplier seven times and is never expected in play.
 */
function withAffixes(items: KitItem[], levers: string[], perPiece: number, q: number, rotate: boolean): KitItem[] {
  return items.map((it, i) => ({
    ...it,
    affixes: rotate ? [{ id: levers[i % levers.length], q }] : levers.slice(0, perPiece).map((id) => ({ id, q })),
  }));
}

export interface KitRequest {
  kit: KitName;
  discipline: string;
  area: AreaId;
  /** Experiments: replace the discipline's weapon pair / weapon tier / lever list. */
  override?: {
    main?: NecroKind; off?: NecroKind | null; tier?: NecroTier; levers?: string[]; sets?: 'first' | 'ascended' | string;
    /** Decomposition: keep the items' base stats but switch these effects off ('sets' = armor bonuses, 'weapon' = the weapon line, 'affixes'). */
    strip?: ('sets' | 'weapon' | 'affixes')[];
    /** What-if: multiply every worn item's base stat points (the catalogue stats are DB rows; this measures a change without making it). */
    statScale?: number;
  };
}

/** The items a kit wears. Empty for `none` and for any non-necromancer (kits are tuned on the four necromancers). */
export function kitItems(req: KitRequest): KitItem[] {
  const strip = req.override?.strip;
  const scale = req.override?.statScale;
  const items = baseKitItems(req).map((it) => (scale && scale !== 1 ? { ...it, statScale: scale } : it));
  if (!strip?.length) return items;
  // A neutral id keeps the base stats (slot comes from the item type) but is in no set and not in the weapon line.
  return items.map((it) => {
    const isWeapon = !!NECRO_WEAPON_BY_ID[it.itemId];
    const plain = (isWeapon && strip.includes('weapon')) || (!isWeapon && strip.includes('sets'));
    return { ...it, plain: plain || it.plain, affixes: strip.includes('affixes') ? [] : it.affixes };
  });
}

function baseKitItems(req: KitRequest): KitItem[] {
  if (req.kit === 'none' || !NECRO_DISCIPLINES.includes(req.discipline)) return [];
  const base = DISCIPLINE_KIT[req.discipline];
  const o = req.override ?? {};
  const dk: DisciplineKit = { main: o.main ?? base.main, off: o.off === undefined ? base.off : o.off, levers: o.levers ?? base.levers };
  const sets = setIds(o.sets && !['first', 'ascended'].includes(o.sets) ? o.sets : req.discipline);
  const rank = AREA_RANK[req.area] ?? 1;
  const L = AREAS[req.area].level;

  if (req.kit === 'progress') {
    // Pieces of either collection whose drop ground is earlier than this one; the collection with more pieces wins,
    // so a half-finished set is not mixed with another half (a tie goes to the ascended set).
    const avail = (c: 1 | 2) => ARMOR_PARTS.filter((p) => PIECE_RANK(c, p) < rank);
    const c: 1 | 2 = avail(2).length >= avail(1).length && avail(2).length > 0 ? 2 : 1;
    const setId = c === 1 ? sets.first : sets.ascended;
    const items = avail(c).map((p) => armorItem(setId, p, Math.max(1, AREAS[piecesOf(setId).find((x) => x.part === p)!.area].level + 1)));
    const tier = o.tier ?? highestTier(rank);
    if (tier) {
      const wl = Math.max(1, L - 1);
      items.push(weaponItem(dk.main, tier, wl));
      if (dk.off && !NECRO_WEAPON_BY_ID[`${dk.main}_${tier}`].twoHanded) items.push(weaponItem(dk.off, tier, wl));
    }
    // One lever affix at a middling roll on the best piece (the last item is the weapon when there is one).
    if (items.length) items[items.length - 1] = { ...items[items.length - 1], affixes: [{ id: dk.levers[0], q: 0.5 }] };
    return items;
  }

  if (req.kit === 'typical') {
    const wl = L + 2;
    const items: KitItem[] = ARMOR_PARTS.map((p) => armorItem(sets.first, p, L + 2));
    const tier = o.tier ?? tierOfArea(req.area);
    items.push(weaponItem(dk.main, tier, wl));
    if (dk.off && !NECRO_WEAPON_BY_ID[`${dk.main}_${tier}`].twoHanded) items.push(weaponItem(dk.off, tier, wl));
    // Two lever affixes: the weapon carries the discipline's first lever, the chest its second.
    const weapon = items.findIndex((i) => NECRO_WEAPON_BY_ID[i.itemId]?.slot === 'main_hand');
    const chest = items.findIndex((i) => ARMOR_BY_ID[i.itemId]?.part === 'chest');
    items[weapon] = { ...items[weapon], affixes: [{ id: dk.levers[0], q: 0.5 }] };
    items[chest] = { ...items[chest], affixes: [{ id: dk.levers[1], q: 0.5 }] };
    return items;
  }

  // ascended / bis: the late kit does not depend on where you stand.
  const il = req.kit === 'bis' ? L + 4 : L + 2;
  const items: KitItem[] = ARMOR_PARTS.map((p) => armorItem(sets.ascended, p, il));
  const tier: NecroTier = o.tier ?? 'moon';
  items.push(weaponItem(dk.main, tier, il));
  if (dk.off && !NECRO_WEAPON_BY_ID[`${dk.main}_${tier}`].twoHanded) items.push(weaponItem(dk.off, tier, il));
  return req.kit === 'bis' ? withAffixes(items, dk.levers, 3, 1, false) : withAffixes(items, dk.levers, 1, 0.75, true);
}

let rowId = 1;
/** One catalogue item as a worn inventory row (the shape `deriveStats`, `resolveSetBonuses` and `gearPower` read). */
export function kitSlot(it: KitItem, index = 0): InventorySlot {
  const armor = ARMOR_BY_ID[it.itemId];
  const weapon = NECRO_WEAPON_BY_ID[it.itemId];
  const def = armor ?? weapon;
  if (!def) throw new Error(`kit item ${it.itemId} is not in the catalogue`);
  const affixes: AffixRoll[] = it.affixes.map((a) => {
    const [lo, hi] = affixRange(a.id, it.ilvl)!;
    return { id: a.id, v: lo + Math.round(Math.max(0, Math.min(1, a.q)) * (hi - lo)) };
  });
  return {
    id: rowId++, slot_index: 100 + index, quantity: 1, equipped: 1, item_id: it.plain ? `plain_${it.itemId}` : it.itemId, name: def.name, rarity: def.rarity, item_type: def.type,
    stat_bonus: it.statScale ? Object.fromEntries(Object.entries(def.stats).map(([k, v]) => [k, v * it.statScale!])) : def.stats, icon_id: null, sell_value: 1, crafted: 0, ilvl: it.ilvl, inst: { id: rowId, ilvl: it.ilvl, affixes },
  };
}

export const kitSlots = (items: KitItem[]): InventorySlot[] => items.map((it, i) => kitSlot(it, i));
/** Convenience: the worn rows for a kit request. */
export const resolveKit = (req: KitRequest): InventorySlot[] => kitSlots(kitItems(req));
