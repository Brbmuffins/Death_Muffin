import type { InventorySlot } from '../net/types';
import type { DisciplineMods } from '../content/disciplines';
import { LEGION_UPGRADE } from '../content/upgrades';
import { BAG_SIZE } from './loot';
import {
  KIT_IDS,
  NO_LEGION,
  isNoLegion,
  kitIdForType,
  kitSlotId,
  legionBonus,
  pieceBonus,
  unusedAffixes,
  type KitId,
  type KitPiece,
  type LegionBonus,
  type PieceBonus,
} from './legionRules';

/**
 * The Legion kit on the client: finds the two kit rows in the inventory, turns them (and the reinforcement tier) into a LegionBonus
 * (legionRules.ts has the math), and folds that into the discipline mods the scene builds. Nothing here reaches the sim: the
 * thralls only ever see thrallHpMult / thrallDamageMult / thrallAttackSpeedMult / wardPerThrall, exactly as with set bonuses.
 * Thralls already standing keep the stats they were raised with; the bonus applies to every thrall raised after a change.
 */

export const pieceOf = (slot: InventorySlot): KitPiece => ({ itemType: slot.item_type, statBonus: slot.stat_bonus, affixes: slot.inst?.affixes ?? null });

/** The two pieces on the legion, by kit slot. */
export function kitPieces(slots: readonly InventorySlot[]): Partial<Record<KitId, InventorySlot>> {
  const out: Partial<Record<KitId, InventorySlot>> = {};
  for (const s of slots) {
    const id = kitSlotId(s.slot_index);
    if (id && s.quantity > 0) out[id] = s;
  }
  return out;
}

/** The bonus the legion has with these inventory rows and this many reinforcement tiers. */
export function legionOf(slots: readonly InventorySlot[], tier: number): LegionBonus {
  const worn = kitPieces(slots);
  return legionBonus({ weapon: worn.weapon ? pieceOf(worn.weapon) : null, armor: worn.armor ? pieceOf(worn.armor) : null }, tier);
}

/** The mods with the legion folded in (a new object). Fold it BEFORE the armour set bonuses, so withSetBonuses can still separate those. */
export function applyLegionMods(mods: DisciplineMods, b: LegionBonus): DisciplineMods {
  if (isNoLegion(b)) return mods;
  return {
    ...mods,
    thrallHpMult: mods.thrallHpMult * b.hpMult,
    thrallDamageMult: mods.thrallDamageMult * b.damageMult,
    thrallAttackSpeedMult: mods.thrallAttackSpeedMult * b.speedMult,
    wardPerThrall: mods.wardPerThrall + b.wardAdd,
  };
}

/** A stable string of what the legion wears; the scene rebuilds the discipline when it changes. */
export function legionSignature(slots: readonly InventorySlot[], tier: number): string {
  const w = kitPieces(slots);
  const roll = (s?: InventorySlot) => (s ? `${s.item_id}~${(s.inst?.affixes ?? []).map((a) => `${a.id}=${a.v}`).join(',')}` : '-');
  return `${roll(w.weapon)}|${roll(w.armor)}|${tier}`;
}

// --- Words -------------------------------------------------------------------------------------------------------

const pct = (x: number) => `${+(x * 100).toFixed(1)}%`;

/** One plain line per thing the bonus does, "Thralls hit +9.6% harder". Empty when it does nothing. */
export function bonusLines(b: { hp: number; damage: number; speed: number; ward: number }): string[] {
  const out: string[] = [];
  if (b.damage > 0.0004) out.push(`Thralls hit +${pct(b.damage)} harder`);
  if (b.hp > 0.0004) out.push(`Thralls have +${pct(b.hp)} health`);
  if (b.speed > 0.0004) out.push(`Thralls attack +${pct(b.speed)} faster`);
  if (b.ward > 0.0004) out.push(`${pct(b.ward)} less damage to you per thrall`);
  return out;
}

/** What one kit piece gives the legion in its slot, in words (and what in it is yours alone). */
export function pieceLines(kit: KitId, slot: InventorySlot): { lines: string[]; unused: string[] } {
  return { lines: bonusLines(pieceBonus(kit, pieceOf(slot))), unused: unusedAffixes(pieceOf(slot)) };
}

// --- Candidates ------------------------------------------------------------------------------------------------------

/** How much better a piece is than another, as one number: every kind of bonus counts, attack speed and ward a little extra. */
export const pieceValue = (p: PieceBonus) => p.hp + p.damage + 1.5 * p.speed + 2 * p.ward;

export interface KitCandidate {
  slot: InventorySlot;
  kit: KitId;
  bonus: PieceBonus;
  /** What the piece gives against what the kit holds in that slot now (an empty slot holds nothing). */
  delta: number;
  verdict: 'up' | 'down' | 'same';
  /** "+4.8% thrall damage, +1.2% attack speed" against the current piece. */
  text: string;
}

const DELTA_PARTS: { key: keyof PieceBonus; label: string; digits: number }[] = [
  { key: 'damage', label: 'thrall damage', digits: 1 },
  { key: 'hp', label: 'thrall health', digits: 1 },
  { key: 'speed', label: 'attack speed', digits: 1 },
  { key: 'ward', label: 'less damage to you per thrall', digits: 1 },
];

export function describeDelta(now: PieceBonus, next: PieceBonus): string {
  const parts: string[] = [];
  for (const p of DELTA_PARTS) {
    const d = Math.round((next[p.key] - now[p.key]) * 1000) / 10;
    if (d === 0) continue;
    parts.push(`${d > 0 ? '+' : '-'}${Math.abs(d).toFixed(p.digits)}% ${p.label}`);
  }
  return parts.join(', ') || 'no change';
}

/** The verdict for one bag piece against the kit slot it would fill. Null when it is not weapon or armour gear. */
export function kitCandidate(slots: readonly InventorySlot[], slot: InventorySlot): KitCandidate | null {
  const kit = kitIdForType(slot.item_type);
  if (!kit || slot.slot_index < 0 || slot.slot_index >= BAG_SIZE || slot.equipped) return null;
  const heldRow = kitPieces(slots)[kit];
  const held = heldRow ? pieceBonus(kit, pieceOf(heldRow)) : pieceBonus(kit, null);
  const bonus = pieceBonus(kit, pieceOf(slot));
  const delta = pieceValue(bonus) - pieceValue(held);
  const verdict = delta > 0.0005 ? 'up' : delta < -0.0005 ? 'down' : 'same';
  return { slot, kit, bonus, delta, verdict, text: describeDelta(held, bonus) };
}

/** Every weapon and armour piece in the bag, best upgrade for the legion first. */
export function kitCandidates(slots: readonly InventorySlot[]): KitCandidate[] {
  return slots
    .map((s) => kitCandidate(slots, s))
    .filter((c): c is KitCandidate => !!c)
    .sort((a, b) => b.delta - a.delta || a.slot.slot_index - b.slot.slot_index);
}

export { KIT_IDS, LEGION_UPGRADE, NO_LEGION };
