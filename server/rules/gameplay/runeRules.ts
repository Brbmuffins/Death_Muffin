import { RUNES, RUNE_IDS, RUNE_RITES, isRuneId, isRuneRite, type RuneId, type RuneRite } from '../content/runes';

/**
 * Relic rune sockets (2026-10-02): one socket per rite, kept the way the tool belt and the Legion kit are kept: as reserved inventory
 * rows outside the 48-slot bag. A socketed rune is `equipped = 1, equipped_slot = 'rune_<rite>'` in slot RUNE_BASE + the rite's index, so
 * bag saves, crafting, selling, salvage and the Vault never see it, and the live UNIQUE (character_id, equipped_slot) key gives "one rune per
 * rite" for free. Unlike server/proposals/relic-runes.md this needs no new table; the offline full sync already carries reserved rows.
 *
 * `npm run build:server-rules` bundles this file for the Death Muffin backend (slot numbers and fit rule; the behaviour lives in the client).
 */

export const RUNE_BASE = 130;
export const RUNE_SLOT_COUNT = RUNE_RITES.length;

export const isRuneSlot = (slot: number) => Number.isInteger(slot) && slot >= RUNE_BASE && slot < RUNE_BASE + RUNE_SLOT_COUNT;
export const runeSlotRite = (slot: number): RuneRite | null => (isRuneSlot(slot) ? RUNE_RITES[slot - RUNE_BASE] : null);
export const runeSlotIndex = (rite: RuneRite) => RUNE_BASE + RUNE_RITES.indexOf(rite);
export const runeEquippedSlot = (rite: RuneRite) => `rune_${rite}`;

/** Does this rune belong in this rite's socket? */
export const runeFits = (runeId: string, rite: string): boolean => isRuneId(runeId) && isRuneRite(rite) && RUNES[runeId].rite === rite;

/** The sockets: which rune sits in which rite. */
export type RuneSockets = Partial<Record<RuneRite, RuneId>>;

/** The sockets held by a list of inventory rows (anything with a slot index and an item id). */
export function socketsOf(rows: readonly { slot_index: number; item_id: string; quantity?: number }[]): RuneSockets {
  const out: RuneSockets = {};
  for (const r of rows) {
    const rite = runeSlotRite(r.slot_index);
    if (rite && (r.quantity ?? 1) > 0 && runeFits(r.item_id, rite)) out[rite] = r.item_id as RuneId;
  }
  return out;
}

/** How many of each rune the bag holds (reserved socket rows and equipped rows do not count). */
export function ownedRunes(rows: readonly { slot_index: number; item_id: string; quantity: number; equipped?: number }[]): Partial<Record<RuneId, number>> {
  const out: Partial<Record<RuneId, number>> = {};
  for (const r of rows) if (r.slot_index >= 0 && r.slot_index < 100 && !r.equipped && isRuneId(r.item_id)) out[r.item_id] = (out[r.item_id] ?? 0) + r.quantity;
  return out;
}

/** A stable string of the sockets, for "did anything change" checks. */
export const socketsSignature = (s: RuneSockets): string => RUNE_RITES.map((r) => s[r] ?? '-').join('|');

export { RUNE_IDS, isRuneId, isRuneRite };
