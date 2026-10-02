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
function put(rows: VaultRow[], size: number, itemId: string, qty: number, maxStack: number): number {
  let left = qty;
  const cap = Math.max(1, maxStack);
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
    rows.push({ slot: s, itemId, qty: add });
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
  if (put(dst, toSize, row.itemId, n, info(row.itemId).maxStack) > 0) return { ok: false, error: toVault ? NO_ROOM_VAULT : NO_ROOM_BAG };
  row.qty -= n;
  const left = src.filter((r) => r.qty > 0);
  return { ok: true, bag: toVault ? left : dst.sort(bySlot), vault: toVault ? dst.sort(bySlot) : left, moved: n };
}

export const depositStack = (bag: VaultRow[], vault: VaultRow[], bagSlot: number, qty: number | undefined, info: VaultInfo) =>
  moveStack(bag, vault, bagSlot, qty, VAULT_SLOTS, info, true);

export const withdrawStack = (bag: VaultRow[], vault: VaultRow[], vaultSlot: number, qty: number | undefined, info: VaultInfo) =>
  moveStack(vault, bag, vaultSlot, qty, BAG_SLOTS, info, false);

export type DepositKind = 'materials' | 'all';
const isMaterialLike = (type: string) => type === 'material' || type === 'consumable';

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
    if (put(dst, VAULT_SLOTS, r.itemId, r.qty, i.maxStack) > 0) return { ok: false, error: 'The Vault cannot hold all of that. Nothing was moved. Sort the Vault or free some space.' };
    moved += r.qty;
  }
  if (!moved) return { ok: false, error: kind === 'materials' ? 'You carry no materials to deposit.' : 'You carry nothing to deposit.' };
  return { ok: true, bag: keep, vault: dst.sort(bySlot), moved };
}

const TYPE_ORDER = ['weapon', 'offhand', 'armor_head', 'armor_chest', 'armor_legs', 'armor_feet', 'armor_hands', 'ring', 'trinket', 'consumable', 'material'];
const RARITY_ORDER = ['relic', 'legendary', 'epic', 'rare', 'uncommon', 'common'];
const rank = (list: string[], v: string) => {
  const i = list.indexOf(v);
  return i < 0 ? list.length : i;
};

/** Merge stacks, then order by type, rarity (best first) and id. Returns the packed vault from slot 0. */
export function sortVault(vault: VaultRow[], info: VaultInfo): VaultRow[] {
  const totals = new Map<string, number>();
  for (const r of vault) totals.set(r.itemId, (totals.get(r.itemId) ?? 0) + r.qty);
  const stacks: { itemId: string; qty: number }[] = [];
  for (const [itemId, total] of totals) {
    const cap = Math.max(1, info(itemId).maxStack);
    for (let left = total; left > 0; left -= cap) stacks.push({ itemId, qty: Math.min(cap, left) });
  }
  stacks.sort((a, b) => {
    const ia = info(a.itemId);
    const ib = info(b.itemId);
    return rank(TYPE_ORDER, ia.itemType) - rank(TYPE_ORDER, ib.itemType) || rank(RARITY_ORDER, ia.rarity) - rank(RARITY_ORDER, ib.rarity) || (a.itemId < b.itemId ? -1 : a.itemId > b.itemId ? 1 : 0) || b.qty - a.qty;
  });
  return stacks.map((s, slot) => ({ slot, itemId: s.itemId, qty: s.qty }));
}

/**
 * Put grants into a bag (stack, then free slots). Used by salvage. Returns null if they do not all fit; nothing is changed.
 */
export function addGrants(bag: VaultRow[], grants: { itemId: string; qty: number }[], info: VaultInfo): VaultRow[] | null {
  const rows = clone(bag);
  for (const g of grants) if (put(rows, BAG_SLOTS, g.itemId, g.qty, info(g.itemId).maxStack) > 0) return null;
  return rows.sort(bySlot);
}
