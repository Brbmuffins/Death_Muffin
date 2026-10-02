import { LEGION_UPGRADE } from '../content/upgrades';
import { affixEffect, affixText, type AffixRoll, type AffixStat } from './affixRules';

/**
 * The Legion kit (thrall gear, 2026-10-02): two reserved inventory slots outside the bag, like the tool belt, holding the
 * spare weapon and armour you would otherwise salvage. The legion wears them as a whole: every thrall gets the same bonus.
 *
 * Why two slots for the whole legion and not a pair per thrall kind: the legion is summoned in bulk and changes shape with
 * the corpses (warriors, archers, bone mages, bearers, wraiths), so per-kind slots would be ten boxes to fill and
 * most of them would sit empty. Two boxes ("Weapon", "Armour") is a WoW-addon-sized job: drop a spare piece in, read one
 * line, move on. The bow and staff props still show on archers and bone mages only.
 *
 * Rows are `equipped = 1` with `equipped_slot = 'kit_weapon' | 'kit_armor'`, so bag saves, crafting, selling, the Vault and
 * Salvage never see them (they only look at bag slots 0..BAG_SLOTS-1) and equippedBySlot ignores them (content/gear.ts).
 *
 * The conversion runs through the pipeline the game already has: a piece's stat points become thrall multipliers, and those
 * multipliers fold into the discipline `mods` (thrallHpMult, thrallDamageMult, thrallAttackSpeedMult) exactly like a set bonus
 * does (WorldScene.applyBoons), so the sim has no new code path. `npm run build:server-rules` bundles this file for the
 * Death Muffin backend, which uses the slot numbers and the eligibility rule; the bonus math is for the client and the tests.
 */

export const KIT_BASE = 120;
export const KIT_IDS = ['weapon', 'armor'] as const;
export type KitId = (typeof KIT_IDS)[number];
export const KIT_SLOT_COUNT = KIT_IDS.length;
export const KIT_LABEL: Record<KitId, string> = { weapon: 'Weapon', armor: 'Armour' };

export const isKitSlot = (slot: number) => Number.isInteger(slot) && slot >= KIT_BASE && slot < KIT_BASE + KIT_SLOT_COUNT;
export const kitSlotId = (slot: number): KitId | null => (isKitSlot(slot) ? KIT_IDS[slot - KIT_BASE] : null);
export const kitSlotIndex = (id: KitId) => KIT_BASE + KIT_IDS.indexOf(id);
export const kitEquippedSlot = (id: KitId) => `kit_${id}`;

/** Which kit slot a piece of gear fits, by item type: weapons and off-hands arm the legion, the five armour pieces armour it. */
export const KIT_WEAPON_TYPES = ['weapon', 'offhand'] as const;
export const KIT_ARMOR_TYPES = ['armor_head', 'armor_chest', 'armor_legs', 'armor_feet', 'armor_hands'] as const;
export function kitIdForType(itemType: string | null | undefined): KitId | null {
  if ((KIT_WEAPON_TYPES as readonly string[]).includes(itemType ?? '')) return 'weapon';
  if ((KIT_ARMOR_TYPES as readonly string[]).includes(itemType ?? '')) return 'armor';
  return null;
}

/**
 * How stat points become thrall bonuses. Points are the item's STR+AGI+INT+VIT bonus plus any flat stat affixes (a Copper Sword
 * is 4, an Iron Chestplate 11, a Moon Staff 36). Weapons give damage and a little attack speed, armour gives health. Each
 * piece is capped so one endgame relic cannot carry the legion alone. Affixes that thrall mods already read (Gravebound,
 * of the Legion, of the Ossuary Wall) count too, at a share of their worn strength: a spare piece should help the legion,
 * not double what the same piece would do on you.
 */
export const KIT_RATES = {
  weaponDamagePerPoint: 0.01,
  weaponDamageCap: 0.35,
  weaponSpeedPerPoint: 0.003,
  weaponSpeedCap: 0.1,
  armorHpPerPoint: 0.012,
  armorHpCap: 0.45,
  affixShare: 0.6,
};

export interface KitPiece {
  itemType: string;
  /** The server's stat_bonus JSON. */
  statBonus?: Record<string, number> | null;
  affixes?: readonly AffixRoll[] | null;
}

/** What one kit piece gives the legion, as additive fractions (0.05 = +5%). */
export interface PieceBonus {
  points: number;
  hp: number;
  damage: number;
  speed: number;
  /** Fraction of damage taken ignored per thrall (wardPerThrall), the same unit set bonuses use. */
  ward: number;
}

const STATS: AffixStat[] = ['stat_str', 'stat_agi', 'stat_int', 'stat_vit'];
const R = KIT_RATES;
const round4 = (x: number) => Math.round(x * 10000) / 10000;

export function statPoints(piece: KitPiece): number {
  let pts = 0;
  for (const k of STATS) pts += Math.max(0, piece.statBonus?.[k] ?? 0);
  for (const a of piece.affixes ?? []) for (const [k, v] of Object.entries(affixEffect(a).stats ?? {})) if (STATS.includes(k as AffixStat)) pts += Math.max(0, v as number);
  return pts;
}

/** The bonus one piece gives when it sits in kit slot `kit` (a piece in the wrong slot gives nothing). */
export function pieceBonus(kit: KitId, piece: KitPiece | null | undefined): PieceBonus {
  const none: PieceBonus = { points: 0, hp: 0, damage: 0, speed: 0, ward: 0 };
  if (!piece || kitIdForType(piece.itemType) !== kit) return none;
  const points = statPoints(piece);
  const out: PieceBonus = { ...none, points };
  if (kit === 'weapon') {
    out.damage = Math.min(R.weaponDamageCap, points * R.weaponDamagePerPoint);
    out.speed = Math.min(R.weaponSpeedCap, points * R.weaponSpeedPerPoint);
  } else out.hp = Math.min(R.armorHpCap, points * R.armorHpPerPoint);
  for (const a of piece.affixes ?? []) {
    const e = affixEffect(a);
    out.damage += ((e.mult?.thrallDamageMult ?? 1) - 1) * R.affixShare;
    out.hp += ((e.mult?.thrallHpMult ?? 1) - 1) * R.affixShare;
    out.ward += (e.add?.wardPerThrall ?? 0) * R.affixShare;
  }
  return { points, hp: round4(out.hp), damage: round4(out.damage), speed: round4(out.speed), ward: round4(out.ward) };
}

/** Affix lines on a kit piece that the legion does not use ("Whispering": essence regeneration is yours, not theirs). */
export function unusedAffixes(piece: KitPiece | null | undefined): string[] {
  const used = (a: AffixRoll) => {
    const e = affixEffect(a);
    return e.mult?.thrallDamageMult !== undefined || e.mult?.thrallHpMult !== undefined || e.add?.wardPerThrall !== undefined || !!e.stats;
  };
  return (piece?.affixes ?? []).filter((a) => !used(a)).map((a) => affixText(a));
}

/** The legion's whole bonus: multipliers for the discipline mods, plus the parts so the panel can show where each came from. */
export interface LegionBonus {
  hpMult: number;
  damageMult: number;
  speedMult: number;
  /** Added to the discipline's wardPerThrall. */
  wardAdd: number;
  /** The kit pieces alone (fractions) and the reinforcement alone. */
  kit: { hp: number; damage: number; speed: number; ward: number };
  reinforce: { tier: number; hp: number; damage: number; speed: number };
}

export const reinforceBonus = (tier: number) => {
  const t = Math.max(0, Math.min(LEGION_UPGRADE.maxTier, Math.floor(Number(tier) || 0)));
  return { tier: t, hp: round4(t * LEGION_UPGRADE.perTier), damage: round4(t * LEGION_UPGRADE.perTier), speed: round4(t * LEGION_UPGRADE.speedPerTier) };
};

export const NO_LEGION: LegionBonus = {
  hpMult: 1, damageMult: 1, speedMult: 1, wardAdd: 0,
  kit: { hp: 0, damage: 0, speed: 0, ward: 0 }, reinforce: { tier: 0, hp: 0, damage: 0, speed: 0 },
};

export function legionBonus(kit: Partial<Record<KitId, KitPiece | null>>, reinforceTier: number): LegionBonus {
  const w = pieceBonus('weapon', kit.weapon);
  const a = pieceBonus('armor', kit.armor);
  const k = { hp: round4(w.hp + a.hp), damage: round4(w.damage + a.damage), speed: round4(w.speed + a.speed), ward: round4(w.ward + a.ward) };
  const r = reinforceBonus(reinforceTier);
  return {
    hpMult: (1 + k.hp) * (1 + r.hp),
    damageMult: (1 + k.damage) * (1 + r.damage),
    speedMult: (1 + k.speed) * (1 + r.speed),
    wardAdd: k.ward,
    kit: k,
    reinforce: r,
  };
}

/** True when the legion bonus does nothing (so the scene can skip rebuilding the discipline). */
export const isNoLegion = (b: LegionBonus) => b.hpMult === 1 && b.damageMult === 1 && b.speedMult === 1 && b.wardAdd === 0;
