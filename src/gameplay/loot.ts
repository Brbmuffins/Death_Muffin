import type { InventorySlot } from '../net/types';
import { BAG_SIZE } from '../ui/InventoryPanel';

export interface LootDrop {
  item_id: string;
  quantity: number;
}

// DropTable equivalent (Unity Week 4 parity). Item ids are seeded server-side.
// Documented simplification: loot rolls are per-player and client-side — each
// party member rolls their own drop, no contention. Fine for PvE co-op;
// revisit if the economy ever matters competitively.
const DROP_TABLE: { chance: number; item_id: string; min: number; max: number }[] = [
  { chance: 0.6, item_id: 'material_copper_shard', min: 1, max: 2 },
  { chance: 0.25, item_id: 'material_copper_bar', min: 1, max: 1 },
  { chance: 0.1, item_id: 'ring_copper', min: 1, max: 1 },
  // remaining 5%: no drop
];

export function rollLoot(): LootDrop | null {
  let roll = Math.random();
  for (const entry of DROP_TABLE) {
    if (roll < entry.chance) {
      return {
        item_id: entry.item_id,
        quantity: entry.min + Math.floor(Math.random() * (entry.max - entry.min + 1)),
      };
    }
    roll -= entry.chance;
  }
  return null;
}

/**
 * Adds a drop to a slot array: stacks onto an existing slot of the same item
 * (materials), otherwise takes the first free slot_index. Returns the new
 * array for POST /api/inventory/save, or null when the bag is full.
 */
export function addToSlots(slots: InventorySlot[], drop: LootDrop): InventorySlot[] | null {
  const stack = slots.find((s) => s.item_id === drop.item_id && s.item_type === 'material');
  if (stack) {
    return slots.map((s) =>
      s === stack ? { ...s, quantity: s.quantity + drop.quantity } : s,
    );
  }
  const used = new Set(slots.map((s) => s.slot_index));
  let free = -1;
  for (let i = 0; i < BAG_SIZE; i++) {
    if (!used.has(i)) {
      free = i;
      break;
    }
  }
  if (free === -1) return null;
  return [
    ...slots,
    {
      // Joined item fields come back from the server on save; placeholders here.
      id: 0,
      slot_index: free,
      quantity: drop.quantity,
      equipped: 0,
      item_id: drop.item_id,
      name: drop.item_id,
      rarity: 'common',
      item_type: 'material',
      stat_bonus: null,
      icon_id: null,
      sell_value: 0,
      crafted: 0,
    },
  ];
}

/** Payload shape for POST /api/inventory/save. */
export function toSavePayload(slots: InventorySlot[]) {
  return slots.map((s) => ({
    slot_index: s.slot_index,
    item_id: s.item_id,
    quantity: s.quantity,
    equipped: s.equipped,
  }));
}
