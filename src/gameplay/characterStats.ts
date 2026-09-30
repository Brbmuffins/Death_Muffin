import type { Character, InventorySlot } from '../net/types';
import type { Discipline } from '../content/disciplines';
import { DAMAGE_UPGRADE } from '../content/upgrades';
import { computeStats } from './stats';
import { equippedBySlot } from '../content/gear';
import { resolveWeaponLoadout } from './weaponLine';

/**
 * One source of truth for derived combat stats (the audit found the arena and
 * boss using different HP/attack formulas). Every scene and system reads this.
 */
export interface DerivedStats {
  level: number;
  maxHp: number;
  spellPower: number;
  maxEssence: number;
  essenceRegen: number;
  moveSpeed: number;
  thrallHp: number;
  thrallDamage: number;
  damageBonusPct: number;
}

export function deriveStats(
  character: Character,
  slots: InventorySlot[],
  discipline: Discipline,
  damageTier: number,
): DerivedStats {
  const { total } = computeStats(character, slots);
  const level = Math.max(1, character.level ?? 1);
  const mods = discipline.mods;
  const dmgMult = 1 + DAMAGE_UPGRADE.perTier * damageTier;
  const maxHp = Math.round((60 + total.stat_vit * 8 + (level - 1) * 14) * mods.maxHpMult);
  const baseSpellPower =
    (6 + total.stat_int * 1.3 + total.stat_str * 0.4 + total.stat_agi * 0.2 + (level - 1) * 1.6) * dmgMult;
  // A line staff's passive (+10% spell damage) raises Spell power; thralls keep the unboosted figure.
  const spellPower = baseSpellPower * resolveWeaponLoadout(equippedBySlot(slots), discipline.id).spellMult;
  return {
    level,
    maxHp,
    spellPower,
    maxEssence: Math.round(100 + total.stat_int * 2 + level * 2),
    essenceRegen: (5 + total.stat_int * 0.1) * mods.essenceRegenMult,
    moveSpeed: 5.4 * (1 + total.stat_agi * 0.003),
    thrallHp: Math.round(maxHp * 0.45 * mods.thrallHpMult),
    thrallDamage: baseSpellPower * 0.4 * mods.thrallDamageMult,
    damageBonusPct: Math.round((dmgMult - 1) * 100),
  };
}

/** XP needed to advance from `level` (server rule: level × 100). */
export function xpToNext(level: number) {
  return level * 100;
}
