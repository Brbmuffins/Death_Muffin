/**
 * The Ossuary Vault (the shared stash in the Chapterhouse): pure move rules shared by the Death Muffin backend (vault.cjs, bundled
 * into gathering/vault-rules.cjs by `npm run build:server-rules`) and the DEV offline mock, so they cannot drift.
 *
 * Every function takes plain row arrays and returns new ones; nothing is mutated and nothing is half-applied: a move either fits
 * entirely or is refused with a player-readable error.
 */

import { BAG_SLOTS } from './gatheringRules';

export const VAULT_SLOTS = 120;
export const VAULT_TAB_SIZE = 40;

export interface VaultRow {
  slot: number;
  itemId: string;
  qty: number;
  /** Occupies its slot but never stacks or moves (equipped gear that sits in a bag row). */
  fixed?: boolean;
  /** A rolled loot instance (affixes.ts / loot_instances id): the row is one piece of gear, never stacks, and the id travels with it. */
  inst?: number;
  /** Sort hint for instance rows (affixRules.instancePower: affix count x 1000 + item level). */
  power?: number;
}

export interface VaultItemInfo {
  /** 1 for gear. */
  maxStack: number;
  itemType: string;
  rarity: string;
}
export type VaultInfo = (itemId: string) => VaultItemInfo;

export type VaultResult = { ok: true; bag: VaultRow[]; vault: VaultRow[]; moved: number } | { ok: false; error: string };

const bySlot = (a: VaultRow, b: VaultRow) => a.slot - b.slot;
const clone = (rows: VaultRow[]) => rows.map((r) => ({ ...r })).sort(bySlot);

/** Stack `qty` of an item onto matching stacks in `rows`, then into free slots below `size`. Mutates `rows`; returns what did NOT fit. */
function put(rows: VaultRow[], size: number, itemId: string, qty: number, maxStack: number, inst?: number, power?: number): number {
  let left = qty;
  const cap = inst !== undefined ? 1 : Math.max(1, maxStack);
  if (cap > 1) {
    for (const r of rows) {
      if (left <= 0) break;
      if (r.fixed || r.itemId !== itemId || r.qty >= cap) continue;
      const add = Math.min(left, cap - r.qty);
      r.qty += add;
      left -= add;
    }
  }
  const used = new Set(rows.map((r) => r.slot));
  for (let s = 0; s < size && left > 0; s++) {
    if (used.has(s)) continue;
    const add = Math.min(left, cap);
    rows.push({ slot: s, itemId, qty: add, ...(inst !== undefined ? { inst, ...(power !== undefined ? { power } : {}) } : {}) });
    used.add(s);
    left -= add;
  }
  return left;
}

const NO_ROOM_VAULT = 'The Vault has no room for that. Make space or sort it first.';
const NO_ROOM_BAG = 'Your Reliquary has no room for that. Make space first.';

/** Move (part of) the stack in `fromSlot` from one side to the other. `qty` omitted = the whole stack. */
export function moveStack(from: VaultRow[], to: VaultRow[], fromSlot: number, qty: number | undefined, toSize: number, info: VaultInfo, toVault: boolean): VaultResult {
  const src = clone(from);
  const dst = clone(to);
  const row = src.find((r) => r.slot === fromSlot);
  if (!row) return { ok: false, error: 'There is nothing in that slot.' };
  if (row.fixed) return { ok: false, error: 'Equipped gear cannot be stored. Unequip it first.' };
  const want = qty === undefined ? row.qty : Math.floor(Number(qty));
  if (!Number.isFinite(want) || want < 1) return { ok: false, error: 'Choose how many to move.' };
  const n = Math.min(want, row.qty);
  if (put(dst, toSize, row.itemId, n, info(row.itemId).maxStack, row.inst, row.power) > 0) return { ok: false, error: toVault ? NO_ROOM_VAULT : NO_ROOM_BAG };
  row.qty -= n;
  const left = src.filter((r) => r.qty > 0);
  return { ok: true, bag: toVault ? left : dst.sort(bySlot), vault: toVault ? dst.sort(bySlot) : left, moved: n };
}

export const depositStack = (bag: VaultRow[], vault: VaultRow[], bagSlot: number, qty: number | undefined, info: VaultInfo) =>
  moveStack(bag, vault, bagSlot, qty, VAULT_SLOTS, info, true);

export const withdrawStack = (bag: VaultRow[], vault: VaultRow[], vaultSlot: number, qty: number | undefined, info: VaultInfo) =>
  moveStack(vault, bag, vaultSlot, qty, BAG_SLOTS, info, false);

export type VaultSide = 'bag' | 'vault';

/**
 * Move (part of) the stack in `fromSlot` of one side to exactly `toSlot` of either side (the same side rearranges). An empty target takes
 * it; the same stackable item merges (what does not fit stays where it was); anything else swaps places (whole stacks only, and the
 * swapped row must be allowed on the source side). Equipped gear (fixed) never moves and is never swapped. `qty` omitted = the whole stack.
 */
export function moveToSlot(bag: VaultRow[], vault: VaultRow[], fromSide: VaultSide, fromSlot: number, toSide: VaultSide, toSlot: number, qty: number | undefined, info: VaultInfo): VaultResult {
  const b = clone(bag);
  const v = fromSide === 'vault' || toSide === 'vault' ? clone(vault) : vault.map((r) => ({ ...r }));
  const sideRows = (side: VaultSide) => (side === 'bag' ? b : v);
  const size = (side: VaultSide) => (side === 'bag' ? BAG_SLOTS : VAULT_SLOTS);
  if (!(Number.isInteger(toSlot) && toSlot >= 0 && toSlot < size(toSide))) return { ok: false, error: 'That slot does not exist.' };
  const src = sideRows(fromSide);
  const dst = sideRows(toSide);
  const row = src.find((r) => r.slot === fromSlot);
  if (!row) return { ok: false, error: 'There is nothing in that slot.' };
  if (row.fixed) return { ok: false, error: 'Equipped gear stays where it is. Unequip it first.' };
  const want = qty === undefined ? row.qty : Math.floor(Number(qty));
  if (!Number.isFinite(want) || want < 1) return { ok: false, error: 'Choose how many to move.' };
  const n = Math.min(want, row.qty);
  const done = (moved: number): VaultResult => ({ ok: true, bag: b.filter((r) => r.qty > 0).sort(bySlot), vault: v.filter((r) => r.qty > 0).sort(bySlot), moved });
  if (fromSide === toSide && fromSlot === toSlot) return done(0);
  const target = dst.find((r) => r.slot === toSlot);
  if (!target) {
    if (n === row.qty) {
      src.splice(src.indexOf(row), 1);
      dst.push({ ...row, slot: toSlot });
    } else {
      row.qty -= n;
      dst.push({ slot: toSlot, itemId: row.itemId, qty: n });
    }
    return done(n);
  }
  if (target.fixed) return { ok: false, error: 'That slot holds equipped gear.' };
  const cap = row.inst !== undefined || target.inst !== undefined ? 1 : Math.max(1, info(row.itemId).maxStack);
  if (target.itemId === row.itemId && cap > 1) {
    const add = Math.min(n, cap - target.qty);
    if (add <= 0) return { ok: false, error: 'That stack is full.' };
    target.qty += add;
    row.qty -= add;
    return done(add);
  }
  if (n !== row.qty) return { ok: false, error: 'Drop part of a stack on an empty slot or on the same item.' };
  if (src === dst) {
    target.slot = fromSlot;
    row.slot = toSlot;
  } else {
    src.splice(src.indexOf(row), 1);
    dst.splice(dst.indexOf(target), 1);
    dst.push({ ...row, slot: toSlot });
    src.push({ ...target, slot: fromSlot });
  }
  return done(n);
}

export type DepositKind = 'materials' | 'all';
const isMaterialLike = (type: string) => type === 'material' || type === 'consumable' || type === 'rune';

/** Deposit every bag stack of `kind` (never equipped rows, never `exceptSlots`). All or nothing. */
export function depositMany(bag: VaultRow[], vault: VaultRow[], kind: DepositKind, exceptSlots: number[], info: VaultInfo): VaultResult {
  const except = new Set(exceptSlots);
  const src = clone(bag);
  const dst = clone(vault);
  let moved = 0;
  const keep: VaultRow[] = [];
  for (const r of src) {
    const i = info(r.itemId);
    const take = !r.fixed && !except.has(r.slot) && (kind === 'all' || isMaterialLike(i.itemType));
    if (!take) {
      keep.push(r);
      continue;
    }
    if (put(dst, VAULT_SLOTS, r.itemId, r.qty, i.maxStack, r.inst, r.power) > 0) return { ok: false, error: 'The Vault cannot hold all of that. Nothing was moved. Sort the Vault or free some space.' };
    moved += r.qty;
  }
  if (!moved) return { ok: false, error: kind === 'materials' ? 'You carry no materials to deposit.' : 'You carry nothing to deposit.' };
  return { ok: true, bag: keep, vault: dst.sort(bySlot), moved };
}

const TYPE_ORDER = ['weapon', 'offhand', 'armor_head', 'armor_chest', 'armor_legs', 'armor_feet', 'armor_hands', 'ring', 'trinket', 'rune', 'consumable', 'material'];
const RARITY_ORDER = ['relic', 'legendary', 'epic', 'rare', 'uncommon', 'common'];
const rank = (list: string[], v: string) => {
  const i = list.indexOf(v);
  return i < 0 ? list.length : i;
};

const EFFECTIVE_BY_COUNT = ['common', 'uncommon', 'rare', 'epic'];

/** Merge stacks, then order by type, rarity (best first; a rolled piece counts as the better of its base and its affix tier), power and id. Packed from slot 0. */
export function sortVault(vault: VaultRow[], info: VaultInfo): VaultRow[] {
  const totals = new Map<string, number>();
  for (const r of vault) if (r.inst === undefined) totals.set(r.itemId, (totals.get(r.itemId) ?? 0) + r.qty);
  const stacks: { itemId: string; qty: number; inst?: number; power?: number }[] = [];
  for (const [itemId, total] of totals) {
    const cap = Math.max(1, info(itemId).maxStack);
    for (let left = total; left > 0; left -= cap) stacks.push({ itemId, qty: Math.min(cap, left) });
  }
  for (const r of vault) if (r.inst !== undefined) stacks.push({ itemId: r.itemId, qty: 1, inst: r.inst, power: r.power });
  const rarityRank = (s: { itemId: string; power?: number }) => {
    const base = rank(RARITY_ORDER, info(s.itemId).rarity);
    return s.power === undefined ? base : Math.min(base, rank(RARITY_ORDER, EFFECTIVE_BY_COUNT[Math.min(3, Math.floor(s.power / 1000))]));
  };
  stacks.sort((a, b) => {
    const ia = info(a.itemId);
    const ib = info(b.itemId);
    return (
      rank(TYPE_ORDER, ia.itemType) - rank(TYPE_ORDER, ib.itemType) ||
      rarityRank(a) - rarityRank(b) ||
      (a.itemId < b.itemId ? -1 : a.itemId > b.itemId ? 1 : 0) ||
      (b.power ?? 0) - (a.power ?? 0) ||
      b.qty - a.qty ||
      (a.inst ?? 0) - (b.inst ?? 0)
    );
  });
  return stacks.map((s, slot) => ({ slot, itemId: s.itemId, qty: s.qty, ...(s.inst !== undefined ? { inst: s.inst, ...(s.power !== undefined ? { power: s.power } : {}) } : {}) }));
}

/**
 * Put grants into a bag (stack, then free slots). Used by salvage. Returns null if they do not all fit; nothing is changed.
 */
export function addGrants(bag: VaultRow[], grants: { itemId: string; qty: number }[], info: VaultInfo): VaultRow[] | null {
  const rows = clone(bag);
  for (const g of grants) if (put(rows, BAG_SLOTS, g.itemId, g.qty, info(g.itemId).maxStack) > 0) return null;
  return rows.sort(bySlot);
}
