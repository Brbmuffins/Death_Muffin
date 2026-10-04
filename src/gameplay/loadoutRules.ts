import { RUNE_RITES, isRuneId, isRuneRite, type RuneId, type RuneRite } from '../content/runes';
import { runeFits, runeSlotIndex, runeSlotRite } from './runeRules';

/**
 * Loadout presets (2026-10-03): a necromancer saves her rites (primary + the five keys), the rune in each rite's socket and the worn
 * main-hand weapon and off-hand under one name, and one click puts them all back.
 *
 * Pure rules shared by the web client, the offline mock and the Death Muffin backend (`npm run build:server-rules` bundles this file):
 * what a valid preset looks like, how to read the gear half of one off the inventory rows, and how to apply one to a bag.
 *
 * The rites half lives in browser storage (gameplay/loadout.ts) and is applied by the client; the server stores it with the preset so it
 * follows the character to another device. The gear half (weapon, off-hand, runes) is applied by `applyLoadout` over the inventory rows,
 * inside one transaction on the server, so ownership is never taken from the client.
 */

export const MAX_PRESETS = 6;
export const NAME_MAX = 24;
export const BAG_SLOTS = 48;
export const MAIN_HAND_SLOT = 105;
export const OFF_HAND_SLOT = 106;

/** A piece of worn gear: the item, and the roll it carries (null for a plain item). */
export interface GearRef {
  itemId: string;
  instanceId: number | null;
}

export interface LoadoutPreset {
  name: string;
  rites: { primary: string; keys: string[] };
  /** Rune per rite; a rite that is absent had an empty socket when the preset was saved. */
  runes: Partial<Record<RuneRite, RuneId>>;
  /** Main hand and off-hand; null = nothing worn then, and applying leaves that hand as it is. */
  weapon: GearRef | null;
  offhand: GearRef | null;
}

const ID_RE = /^[a-z0-9_]{1,64}$/;
const isId = (x: unknown): x is string => typeof x === 'string' && ID_RE.test(x);

function cleanGear(raw: unknown): GearRef | null | undefined {
  if (raw === null || raw === undefined) return null;
  if (typeof raw !== 'object') return undefined;
  const g = raw as { itemId?: unknown; instanceId?: unknown };
  if (!isId(g.itemId)) return undefined;
  const inst = g.instanceId === null || g.instanceId === undefined ? null : g.instanceId;
  if (inst !== null && !(typeof inst === 'number' && Number.isInteger(inst) && inst > 0)) return undefined;
  return { itemId: g.itemId, instanceId: inst };
}

/** The name a preset may carry: trimmed, control characters out, 1..NAME_MAX characters; null if nothing is left. */
export function cleanName(raw: unknown): string | null {
  if (typeof raw !== 'string') return null;
  // eslint-disable-next-line no-control-regex
  const s = raw.replace(/[\u0000-\u001f\u007f<>]/g, '').replace(/\s+/g, ' ').trim().slice(0, NAME_MAX).trim();
  return s ? s : null;
}

/** A valid preset from untrusted input, or an error a player can read. Rite ids are checked for shape only (the client sanitizes them against its kit on apply). */
export function normalizePreset(raw: unknown): { ok: true; preset: LoadoutPreset } | { ok: false; error: string } {
  if (!raw || typeof raw !== 'object') return { ok: false, error: 'That loadout is not readable.' };
  const r = raw as Record<string, any>;
  const name = cleanName(r.name);
  if (!name) return { ok: false, error: 'Give the loadout a name.' };
  const rites = r.rites;
  if (!rites || !isId(rites.primary) || !Array.isArray(rites.keys) || rites.keys.length !== 5 || !rites.keys.every(isId)) return { ok: false, error: 'A loadout holds a primary and five rites.' };
  if (new Set(rites.keys).size !== 5) return { ok: false, error: 'A rite can sit on one key only.' };
  const runes: Partial<Record<RuneRite, RuneId>> = {};
  if (r.runes !== undefined && r.runes !== null) {
    if (typeof r.runes !== 'object' || Array.isArray(r.runes)) return { ok: false, error: 'The runes are not readable.' };
    for (const [rite, id] of Object.entries(r.runes as Record<string, unknown>)) {
      if (id === null || id === undefined) continue;
      if (!isRuneRite(rite) || typeof id !== 'string' || !isRuneId(id) || !runeFits(id, rite)) return { ok: false, error: 'A rune in that loadout does not fit its rite.' };
      runes[rite] = id;
    }
  }
  const weapon = cleanGear(r.weapon);
  const offhand = cleanGear(r.offhand);
  if (weapon === undefined || offhand === undefined) return { ok: false, error: 'The weapon in that loadout is not readable.' };
  return { ok: true, preset: { name, rites: { primary: rites.primary, keys: [...rites.keys] }, runes, weapon, offhand } };
}

/** One inventory row, as far as the rules care. Extra fields (ids, names) ride along untouched. */
export interface Row {
  slot_index: number;
  item_id: string;
  quantity: number;
  equipped?: number | boolean;
  equipped_slot?: string | null;
  instance_id?: number | null;
  [extra: string]: unknown;
}

export interface ItemInfo {
  maxStack: number;
  /** 'main_hand' | 'off_hand' | other gear slot | null for items that are not gear. */
  equipSlot: string | null;
  twoHanded: boolean;
}

export type SkipReason = 'missing' | 'no_room' | 'wrong_slot';
export interface Skip {
  part: 'weapon' | 'offhand' | 'rune';
  /** The rite for a rune; null otherwise. */
  rite: RuneRite | null;
  /** What the preset wanted (a rune id for a rune put in, null when the preset wanted the socket emptied). */
  itemId: string | null;
  reason: SkipReason;
}
export interface Applied {
  part: 'weapon' | 'offhand' | 'rune';
  rite: RuneRite | null;
  /** The item now worn / socketed, or null when a socket was emptied. */
  itemId: string | null;
}
export interface ApplyReport {
  applied: Applied[];
  skipped: Skip[];
  /** Everything the preset asked for already stood that way. */
  unchanged: boolean;
}

const inBag = (r: Row) => r.slot_index >= 0 && r.slot_index < BAG_SLOTS;
const same = (a: number | null | undefined, b: number | null | undefined) => (a ?? null) === (b ?? null);

/** The gear half of a preset as the rows stand now: worn weapon and off-hand (with their rolls) and the socketed runes. */
export function captureGear(rows: readonly { slot_index: number; item_id: string; instance_id?: number | null }[]): { weapon: GearRef | null; offhand: GearRef | null; runes: Partial<Record<RuneRite, RuneId>> } {
  const ref = (slot: number): GearRef | null => {
    const r = rows.find((x) => x.slot_index === slot);
    return r ? { itemId: r.item_id, instanceId: r.instance_id ?? null } : null;
  };
  const runes: Partial<Record<RuneRite, RuneId>> = {};
  for (const r of rows) {
    const rite = runeSlotRite(r.slot_index);
    if (rite && runeFits(r.item_id, rite)) runes[rite] = r.item_id as RuneId;
  }
  return { weapon: ref(MAIN_HAND_SLOT), offhand: ref(OFF_HAND_SLOT), runes };
}

/**
 * Apply the gear half of a preset to the inventory rows. Pure: returns new rows (the input is not touched) and what was done and skipped.
 * Rows keep their identity fields (`id`), so a caller can persist the difference. Every step either completes or leaves the rows exactly as
 * they were and is reported as skipped, so a full bag never loses an item: whatever leaves a worn slot or a socket needs a place in the bag,
 * and without one the swap is refused ("no_room") and the old piece stays where it is.
 */
export function applyLoadout(input: readonly Row[], info: (itemId: string) => ItemInfo, preset: Pick<LoadoutPreset, 'weapon' | 'offhand' | 'runes'>): { rows: Row[]; report: ApplyReport } {
  let rows: Row[] = input.map((r) => ({ ...r }));
  const report: ApplyReport = { applied: [], skipped: [], unchanged: true };
  const isEq = (r: Row, slot: number) => r.slot_index === slot;

  const freeSlots = (): number[] => {
    const used = new Set(rows.filter(inBag).map((r) => r.slot_index));
    const out: number[] = [];
    for (let i = 0; i < BAG_SLOTS; i++) if (!used.has(i)) out.push(i);
    return out;
  };

  /** Put one unit of `itemId` in the bag (onto a stack with room, else a free slot). False if there is no place. */
  const giveBack = (itemId: string): boolean => {
    const cap = info(itemId).maxStack;
    const stack = rows.find((r) => inBag(r) && r.item_id === itemId && !r.equipped && (r.instance_id ?? null) === null && r.quantity < cap);
    if (stack) {
      stack.quantity += 1;
      return true;
    }
    const free = freeSlots()[0];
    if (free === undefined) return false;
    rows.push({ slot_index: free, item_id: itemId, quantity: 1, equipped: 0, equipped_slot: null, instance_id: null });
    return true;
  };

  /** Run a step that mutates `rows`; if it reports failure the rows are restored. */
  const step = (fn: () => SkipReason | null): SkipReason | null => {
    const snapshot = rows.map((r) => ({ ...r }));
    const reason = fn();
    if (reason) rows = snapshot;
    return reason;
  };

  const hand = (part: 'weapon' | 'offhand', want: GearRef | null, equipSlot: 'main_hand' | 'off_hand', reserved: number) => {
    if (!want) return;
    const worn = rows.find((r) => isEq(r, reserved));
    if (worn && worn.item_id === want.itemId && same(worn.instance_id, want.instanceId)) return;
    const from = rows.find((r) => inBag(r) && !r.equipped && r.item_id === want.itemId && same(r.instance_id, want.instanceId));
    const skip = (reason: SkipReason) => report.skipped.push({ part, rite: null, itemId: want.itemId, reason });
    if (!from) return skip('missing');
    const meta = info(want.itemId);
    if (meta.equipSlot !== equipSlot) return skip('wrong_slot');
    const reason = step(() => {
      const displaced = rows.filter((r) => r !== from && ((isEq(r, reserved)) || (meta.twoHanded && isEq(r, OFF_HAND_SLOT)) || (equipSlot === 'off_hand' && isEq(r, MAIN_HAND_SLOT) && info(r.item_id).twoHanded)));
      const bagSlot = from.slot_index;
      // The weapon's own bag slot is vacated, so it takes the first displaced piece; the rest need free slots.
      const free = freeSlots();
      if (displaced.length > free.length + 1) return 'no_room';
      from.slot_index = reserved;
      from.equipped = 1;
      from.equipped_slot = equipSlot;
      displaced.forEach((d, i) => {
        d.slot_index = i === 0 ? bagSlot : free[i - 1];
        d.equipped = 0;
        d.equipped_slot = null;
      });
      return null;
    });
    if (reason) return skip(reason);
    report.applied.push({ part, rite: null, itemId: want.itemId });
    report.unchanged = false;
  };
  hand('weapon', preset.weapon, 'main_hand', MAIN_HAND_SLOT);
  hand('offhand', preset.offhand, 'off_hand', OFF_HAND_SLOT);

  for (const rite of RUNE_RITES) {
    const want = preset.runes[rite] ?? null;
    const socket = runeSlotIndex(rite);
    const current = rows.find((r) => r.slot_index === socket);
    if ((current?.item_id ?? null) === want) continue;
    if (want !== null && !runeFits(want, rite)) {
      report.skipped.push({ part: 'rune', rite, itemId: want, reason: 'wrong_slot' });
      continue;
    }
    const reason = step(() => {
      if (want !== null) {
        const from = rows.find((r) => inBag(r) && !r.equipped && r.item_id === want && (r.instance_id ?? null) === null && r.quantity > 0);
        if (!from) return 'missing';
        if (from.quantity > 1) from.quantity -= 1;
        else rows = rows.filter((r) => r !== from);
      }
      if (current) {
        rows = rows.filter((r) => r !== current);
        if (!giveBack(current.item_id)) return 'no_room';
      }
      if (want !== null) rows.push({ slot_index: socket, item_id: want, quantity: 1, equipped: 1, equipped_slot: `rune_${rite}`, instance_id: null });
      return null;
    });
    if (reason) {
      report.skipped.push({ part: 'rune', rite, itemId: want, reason });
      continue;
    }
    report.applied.push({ part: 'rune', rite, itemId: want });
    report.unchanged = false;
  }
  rows.sort((a, b) => a.slot_index - b.slot_index);
  return { rows, report };
}

