import type { InventorySlot, ItemType } from '../net/types';

/** The nine equipment slots the server knows (reservedSlots in /api/inventory/equip). */
export type EquipSlot = 'head' | 'chest' | 'legs' | 'feet' | 'hands' | 'main_hand' | 'off_hand' | 'ring' | 'trinket';

export const EQUIP_SLOTS: { id: EquipSlot; label: string; glyph: string }[] = [
  { id: 'head', label: 'Head', glyph: '⛨' },
  { id: 'chest', label: 'Chest', glyph: '⛊' },
  { id: 'legs', label: 'Legs', glyph: '⛊' },
  { id: 'feet', label: 'Feet', glyph: '◭' },
  { id: 'hands', label: 'Hands', glyph: '✋' },
  { id: 'main_hand', label: 'Main hand', glyph: '⚔' },
  { id: 'off_hand', label: 'Off hand', glyph: '◐' },
  { id: 'ring', label: 'Ring', glyph: '◎' },
  { id: 'trinket', label: 'Trinket', glyph: '✦' },
];

const TYPE_TO_SLOT: Partial<Record<ItemType, EquipSlot>> = {
  weapon: 'main_hand',
  offhand: 'off_hand',
  armor_head: 'head',
  armor_chest: 'chest',
  armor_legs: 'legs',
  armor_feet: 'feet',
  armor_hands: 'hands',
  ring: 'ring',
  trinket: 'trinket',
};

const SLOT_IDS = new Set<string>(EQUIP_SLOTS.map((s) => s.id));

/** The slot an item goes in, or null for materials and consumables. The server's own answer wins. */
export function equipSlotOf(s: Pick<InventorySlot, 'item_type' | 'equipped_slot' | 'item_equipment_slot'>): EquipSlot | null {
  const own = s.equipped_slot ?? s.item_equipment_slot;
  if (own && SLOT_IDS.has(own)) return own as EquipSlot;
  return TYPE_TO_SLOT[s.item_type] ?? null;
}

/** What is currently worn, by slot. */
export function equippedBySlot(slots: readonly InventorySlot[]): Partial<Record<EquipSlot, InventorySlot>> {
  const out: Partial<Record<EquipSlot, InventorySlot>> = {};
  for (const s of slots) {
    if (!s.equipped) continue;
    const slot = equipSlotOf(s);
    if (slot) out[slot] = s;
  }
  return out;
}

// --- How gear looks on the model -------------------------------------------------------------

export type WeaponKind = 'sword' | 'dagger' | 'staff' | 'bow' | 'mace' | 'tome';
export type OffhandKind = 'shield' | 'tome';

/** Material tiers tint the prop; `glow` is an emissive tell for the rare end. */
export interface GearTier {
  color: number;
  metal: number;
  rough: number;
  glow?: number;
}

const TIERS: Record<string, GearTier> = {
  wood: { color: 0x4a3626, metal: 0.05, rough: 0.85 },
  bone: { color: 0xd8cfbd, metal: 0.05, rough: 0.7 },
  copper: { color: 0xb87333, metal: 0.75, rough: 0.4 },
  iron: { color: 0x7a7d86, metal: 0.8, rough: 0.42 },
  steel: { color: 0xb9c2d0, metal: 0.9, rough: 0.3 },
  gold: { color: 0xd9a441, metal: 0.9, rough: 0.28, glow: 0x6b4a10 },
  hell: { color: 0x8a2a1a, metal: 0.7, rough: 0.4, glow: 0xa02510 },
  moon: { color: 0xaab8e8, metal: 0.85, rough: 0.3, glow: 0x3a4a9a },
};

/** Guess a material tier from the item id ("helm_iron", "sword_copper", "staff_oak" …). */
export function gearTier(itemId: string, rarity?: string): GearTier {
  for (const key of ['moon', 'hell', 'gold', 'steel', 'iron', 'copper', 'bone']) if (itemId.includes(key)) return TIERS[key];
  if (/oak|wood|apprentice|spike/.test(itemId)) return TIERS.wood;
  // Unknown ids: let rarity pick a look so nothing renders as a grey placeholder.
  return rarity === 'epic' ? TIERS.gold : rarity === 'rare' ? TIERS.steel : rarity === 'uncommon' ? TIERS.iron : TIERS.copper;
}

export function weaponKind(itemId: string): WeaponKind {
  if (/staff|wand|focus/.test(itemId)) return 'staff';
  if (/bow/.test(itemId)) return 'bow';
  if (/dagger|knife/.test(itemId)) return 'dagger';
  if (/mace|hammer|club|flail/.test(itemId)) return 'mace';
  if (/tome|book/.test(itemId)) return 'tome';
  return 'sword';
}

export function offhandKind(itemId: string): OffhandKind {
  return /tome|book|lantern/.test(itemId) ? 'tome' : 'shield';
}
