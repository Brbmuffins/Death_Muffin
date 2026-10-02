import type { InventorySlot, Rarity } from '../net/types';
import { ITEMS } from '../content/items';
import { equippedBySlot } from '../content/gear';
import {
  addInstanceTotals,
  affixIsNecro,
  affixKind,
  affixQuality,
  affixText,
  affixedName,
  effectiveRarity,
  emptyAffixTotals,
  instanceSellValue,
  isAffixGear,
  type AffixRoll,
  type AffixTotals,
  type DropSource,
  type ItemInstanceData,
} from './affixRules';

/**
 * Client side of item level and affixes (rules: affixRules.ts, shared with the server). The server owns every roll; this file only
 * reads them: `decorateSlot` turns the raw columns of a rolled row into a readable one (full name, rarity colour by affix count,
 * price), and the helpers feed the stat pipeline and the tooltips.
 */

export interface SlotInstance extends ItemInstanceData {
  id: number;
}

/** Whether an item id can roll an instance (gear only: weapons, armor, rings, trinkets, off-hands). */
export const canRoll = (itemId: string): boolean => {
  const t = ITEMS[itemId]?.type;
  return !!t && isAffixGear(t);
};

function parseAffixes(raw: unknown): AffixRoll[] {
  let v = raw;
  if (typeof v === 'string') {
    try {
      v = JSON.parse(v);
    } catch {
      return [];
    }
  }
  if (!Array.isArray(v)) return [];
  return v.filter((a): a is AffixRoll => !!a && typeof a.id === 'string' && Number.isInteger(a.v));
}

/** A row with its roll read in. Idempotent: a row that was already decorated comes back unchanged. */
export function decorateSlot<T extends InventorySlot>(row: T): T {
  if (row.inst || row.instance_id == null || row.ilvl == null) return row;
  const affixes = parseAffixes(row.affixes);
  const inst = { id: Number(row.instance_id), ilvl: Number(row.ilvl), affixes };
  const baseName = row.base_name ?? row.name;
  const baseRarity = (row.base_rarity ?? row.rarity) as Rarity;
  const baseSell = row.base_sell ?? row.sell_value;
  return {
    ...row,
    affixes,
    inst,
    base_name: baseName,
    base_rarity: baseRarity,
    base_sell: baseSell,
    name: affixedName(baseName, affixes),
    rarity: effectiveRarity(baseRarity, affixes.length) as Rarity,
    sell_value: instanceSellValue(baseSell, inst),
  };
}

export const decorateSlots = <T extends InventorySlot>(rows: T[]): T[] => (Array.isArray(rows) ? rows.map(decorateSlot) : rows);

/** The roll on a row, or null for plain gear and materials. */
export const instanceOf = (slot: Pick<InventorySlot, 'inst'>): SlotInstance | null => slot.inst ?? null;

/** A server reply for one drop (POST /api/loot/roll-gear), as the LootDrop carries it. */
export interface DropInstance {
  id: number;
  ilvl: number;
  affixes: AffixRoll[];
}

/** Everything the affixes on WORN gear add to the stat pipeline: flat stats, plus multipliers and additions for the discipline mods. */
export function wornAffixTotals(slots: readonly InventorySlot[]): AffixTotals {
  const t = emptyAffixTotals();
  for (const s of Object.values(equippedBySlot(slots))) if (s?.inst) addInstanceTotals(t, s.inst.affixes);
  return t;
}

/** A short stable string of the worn rolls; the scene rebuilds the discipline when it changes. */
export function affixSignature(slots: readonly InventorySlot[]): string {
  return Object.values(equippedBySlot(slots))
    .filter((s) => s?.inst)
    .map((s) => `${s!.item_id}~${s!.inst!.affixes.map((a) => `${a.id}=${a.v}`).join(',')}`)
    .join('|');
}

export interface AffixLine {
  roll: AffixRoll;
  text: string;
  necro: boolean;
  kind: 'prefix' | 'suffix';
  /** 0..1 where the roll sits in its range for this item level. */
  quality: number;
}

/** The affix lines of a row, in the order rolled. */
export function affixLines(slot: Pick<InventorySlot, 'inst'>): AffixLine[] {
  const inst = slot.inst;
  if (!inst) return [];
  return inst.affixes.map((a) => ({ roll: a, text: affixText(a), necro: affixIsNecro(a), kind: affixKind(a) ?? 'prefix', quality: affixQuality(a, inst.ilvl) }));
}

/** What a drop is rolled with: the level of whatever dropped it and where it came from. */
export interface RollContext {
  level: number;
  source: DropSource;
}

/** The salvage-rule view of a row's roll: `{ ilvl, affixes: count }`, or nothing for plain gear. */
export const rollOf = (slot: Pick<InventorySlot, 'inst'>): { ilvl?: number; affixes?: number } => (slot.inst ? { ilvl: slot.inst.ilvl, affixes: slot.inst.affixes.length } : {});

/** Plain-text lines for a native `title` tooltip ("Item level 22", then each affix). */
export const rollTitleLines = (slot: Pick<InventorySlot, 'inst'>): string[] =>
  slot.inst ? [`Item level ${slot.inst.ilvl}`, ...affixLines(slot).map((l) => `${l.necro ? '\u2020 ' : '  '}${l.text}`)] : [];
