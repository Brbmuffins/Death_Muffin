import { AREAS, type AreaId } from '../content/areas';
import { ARMOR_BY_ID } from '../content/armorSets';
import { DISCIPLINES } from '../content/disciplines';
import { NECRO_WEAPON_BY_ID } from '../content/necroWeapons';

/**
 * Smart loot for class gear (2026-10-03): an area's table lists every discipline's armour set at equal weight, so only about 1 piece
 * in 9 was your own (the other 8 had no set bonus for you) and the four necromancer weapon kinds dropped for every class. With a
 * discipline given, half of the area's class-armour weight goes to your own set (the rest is shared by the other eight, so the share of
 * armour in the table does not change), and necromancer weapons drop at a third of their weight for the other families.
 * Without a discipline (the balance harness, tests, the Depths) the table is used as listed.
 */
export const SMART_LOOT = { ownArmorShare: 0.5, foreignWeaponMult: 1 / 3 } as const;

export type LootEntry = { item: string; weight: number };
const smartCache = new Map<string, LootEntry[]>();

export function smartTable(area: AreaId, disciplineId: string): LootEntry[] {
  const key = `${area}|${disciplineId}`;
  let t = smartCache.get(key);
  if (t) return t;
  const table = AREAS[area].loot;
  const armor = table.filter((e) => ARMOR_BY_ID[e.item]);
  const own = armor.filter((e) => ARMOR_BY_ID[e.item].disciplineId === disciplineId);
  const total = armor.reduce((n, e) => n + e.weight, 0);
  const ownTotal = own.reduce((n, e) => n + e.weight, 0);
  const necro = (DISCIPLINES as Record<string, { family: string } | undefined>)[disciplineId]?.family === 'necromancer';
  t = table.map((e) => {
    const piece = ARMOR_BY_ID[e.item];
    if (piece && ownTotal > 0 && ownTotal < total) {
      const mine = piece.disciplineId === disciplineId;
      return { item: e.item, weight: mine ? (e.weight / ownTotal) * total * SMART_LOOT.ownArmorShare : (e.weight / (total - ownTotal)) * total * (1 - SMART_LOOT.ownArmorShare) };
    }
    if (!necro && NECRO_WEAPON_BY_ID[e.item]) return { item: e.item, weight: e.weight * SMART_LOOT.foreignWeaponMult };
    return e;
  });
  smartCache.set(key, t);
  return t;
}

