import { beltTool } from '../net/api';
import type { InventorySlot } from '../net/types';
import { BAG_SIZE, type Inventory } from '../gameplay/loot';
import { BELT_KINDS, bestToolPerKind, isBeltSlot, toolKindOf, beltSlotKind, type BeltKind } from '../../server/rules/gameplay/gatheringRules';

/** The gathering tool belt (slots 110-113, one tool each) and the helpers the Reliquary and Skills panel share. */
export const BELT_LABEL: Record<BeltKind, string> = { hatchet: 'Hatchet', pickaxe: 'Pickaxe', rod: 'Rod', spade: 'Spade' };

/** What hangs on the belt, by tool kind. */
export function beltTools(slots: readonly InventorySlot[]): Partial<Record<BeltKind, InventorySlot>> {
  const out: Partial<Record<BeltKind, InventorySlot>> = {};
  for (const s of slots) {
    const kind = beltSlotKind(s.slot_index);
    if (kind && s.quantity > 0) out[kind] = s;
  }
  return out;
}

export const bagTools = (slots: readonly InventorySlot[]) => slots.filter((s) => s.slot_index >= 0 && s.slot_index < BAG_SIZE && toolKindOf(s.item_id) !== null);

/** The one-time offer: with an empty belt, the best bag tool of each kind (empty list = nothing to offer). */
export function beltOffer(slots: readonly InventorySlot[]): InventorySlot[] {
  if (Object.keys(beltTools(slots)).length) return [];
  const tools = bagTools(slots);
  const best = bestToolPerKind(tools.map((s) => s.item_id));
  return BELT_KINDS.flatMap((k) => (best[k] ? [tools.find((s) => s.item_id === best[k])!] : []));
}

export const isOnBelt = (slot: Pick<InventorySlot, 'slot_index'>) => isBeltSlot(slot.slot_index);

const offerKey = (characterId: number) => `dm_belt_offer_${characterId}`;
export function offerDismissed(characterId: number) {
  try { return localStorage.getItem(offerKey(characterId)) === '1'; } catch { return false; }
}
export function dismissOffer(characterId: number) {
  try { localStorage.setItem(offerKey(characterId), '1'); } catch { /* private mode */ }
}

/**
 * Belt or unbelt tools on the server (one at a time, in order) with no bag save in flight. The server's reply becomes the bag.
 * A refusal ("Your bag is full...") throws with the server's readable text.
 */
export async function moveTools(inventory: Inventory, characterId: number, moves: { slot_index: number; equipped: 0 | 1 }[]) {
  await inventory.exclusive(async () => {
    for (const m of moves) inventory.replace(await beltTool(characterId, m.slot_index, m.equipped));
  });
}
