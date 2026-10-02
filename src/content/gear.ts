import type { InventorySlot, ItemType } from '../net/types';
import { ARMOR_BY_ID, ARMOR_PIECES } from './armorSets';
import { isKitSlot } from '../gameplay/legionRules';

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

/** What is currently worn, by slot. The Legion kit (slots 120+) is equipped too, but on the thralls, never on you. */
export function equippedBySlot(slots: readonly InventorySlot[]): Partial<Record<EquipSlot, InventorySlot>> {
  const out: Partial<Record<EquipSlot, InventorySlot>> = {};
  for (const s of slots) {
    if (!s.equipped || isKitSlot(s.slot_index)) continue;
    const slot = equipSlotOf(s);
    if (slot) out[slot] = s;
  }
  return out;
}

/** Rebuild an equipment map from the item ids other players broadcast (no rarity: tiers come from the id). */
export function gearFromIds(ids: Record<string, string> | undefined): Partial<Record<EquipSlot, { item_id: string }>> {
  const out: Partial<Record<EquipSlot, { item_id: string }>> = {};
  if (!ids) return out;
  for (const [slot, id] of Object.entries(ids)) if (SLOT_IDS.has(slot) && typeof id === 'string') out[slot as EquipSlot] = { item_id: id };
  return out;
}

// --- How gear looks on the model -------------------------------------------------------------

/** Necro weapon line (docs/ALCHEMY-AND-WORLDS-PLAN.md N1): scythe, wand and sickle play differently from the staff. */
export type WeaponKind = 'sword' | 'dagger' | 'staff' | 'bow' | 'mace' | 'tome' | 'scythe' | 'wand' | 'sickle';
export type OffhandKind = 'shield' | 'tome' | 'skull' | 'bell';

/** Material tiers tint the prop; `glow` is an emissive tell for the rare end. */
export interface GearTier {
  color: number;
  metal: number;
  rough: number;
  glow?: number;
}

const TIERS: Record<string, GearTier> = {
  wood: { color: 0x4a3626, metal: 0.05, rough: 0.85 },
  leather: { color: 0x6b4f34, metal: 0.05, rough: 0.9 },
  bone: { color: 0xd8cfbd, metal: 0.05, rough: 0.7 },
  copper: { color: 0xb87333, metal: 0.75, rough: 0.4 },
  iron: { color: 0x7a7d86, metal: 0.8, rough: 0.42 },
  steel: { color: 0xb9c2d0, metal: 0.9, rough: 0.3 },
  gold: { color: 0xd9a441, metal: 0.9, rough: 0.28, glow: 0x6b4a10 },
  hell: { color: 0x8a2a1a, metal: 0.7, rough: 0.4, glow: 0xa02510 },
  moon: { color: 0xaab8e8, metal: 0.85, rough: 0.3, glow: 0x3a4a9a },
};

/** Emissive tints in the existing tiers are dark (0x6b4a10); a bright accent used raw floods the whole body flat. */
function dimColor(hex: number, k: number): number {
  const c = (shift: number) => Math.round(((hex >> shift) & 255) * k);
  return (c(16) << 16) | (c(8) << 8) | c(0);
}

/** Pieces of one legendary set worn together that wake its glow on the hero. */
export const LEGENDARY_AURA_PIECES = 4;

/**
 * The glow colour of a worn legendary set (4 or more pieces of the same one), or null. It is only a brighter emissive tell on the body
 * regions the hero already tints (no light, no particles, no per-frame work), and dimmed so it stays an accent rather than a flood.
 */
export function legendaryAura(items: Partial<Record<string, { item_id: string } | undefined>>): number | null {
  const count = new Map<string, number>();
  for (const it of Object.values(items)) {
    const p = it && ARMOR_BY_ID[it.item_id];
    if (p && p.collection === 3) count.set(p.setId, (count.get(p.setId) ?? 0) + 1);
  }
  for (const [setId, n] of count) if (n >= LEGENDARY_AURA_PIECES) return dimColor(ARMOR_PIECES.find((p) => p.setId === setId)!.accent, 0.5);
  return null;
}

/** Guess a material tier from the item id ("helm_iron", "sword_copper", "staff_oak" …). */
export function gearTier(itemId: string, rarity?: string): GearTier {
  const armor = ARMOR_BY_ID[itemId];
  if (armor) return { color: armor.color, metal: armor.disciplineId === 'knight' || armor.disciplineId === 'warden' ? 0.75 : 0.24, rough: armor.collection === 3 ? 0.3 : armor.collection === 2 ? 0.38 : 0.55, glow: armor.collection === 3 ? dimColor(armor.accent, 0.3) : armor.collection === 2 || armor.rarity === 'epic' ? dimColor(armor.accent, armor.collection === 2 ? 0.22 : 0.14) : undefined };
  for (const key of ['moon', 'hell', 'gold', 'steel', 'iron', 'copper', 'bone']) if (itemId.includes(key)) return TIERS[key];
  if (/oak|wood|apprentice|spike/.test(itemId)) return TIERS.wood;
  // Unknown ids: let rarity pick a look so nothing renders as a grey placeholder.
  return rarity === 'epic' ? TIERS.gold : rarity === 'rare' ? TIERS.steel : rarity === 'uncommon' ? TIERS.iron : TIERS.leather;
}

export function weaponKind(itemId: string): WeaponKind {
  if (/scythe/.test(itemId)) return 'scythe';
  if (/sickle/.test(itemId)) return 'sickle';
  if (/wand/.test(itemId)) return 'wand';
  if (/staff|focus/.test(itemId)) return 'staff';
  if (/bow/.test(itemId)) return 'bow';
  if (/dagger|knife/.test(itemId)) return 'dagger';
  if (/mace|hammer|club|flail/.test(itemId)) return 'mace';
  if (/tome|book/.test(itemId)) return 'tome';
  return 'sword';
}

export function offhandKind(itemId: string): OffhandKind {
  if (/skull_focus/.test(itemId)) return 'skull';
  if (/mourning_bell/.test(itemId)) return 'bell';
  return /tome|book|lantern|grimoire/.test(itemId) ? 'tome' : 'shield';
}
