import type { Character, InventorySlot } from '../net/types';
import type { Discipline } from '../../server/rules/content/disciplines';
import { DAMAGE_UPGRADE } from '../../server/rules/content/upgrades';
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

/**
 * The per-stat coefficients behind every derived number. deriveStats reads these, and the Reliquary
 * tooltips and the Character sheet (gameplay/gearStats.ts) read them too, so the words can never drift
 * from the math.
 */
export const STAT_EFFECTS = {
  health: { base: 60, perVit: 8, perLevel: 14 },
  spell: { base: 6, perInt: 1.3, perStr: 0.4, perAgi: 0.2, perLevel: 1.6 },
  essence: { base: 100, perInt: 2, perLevel: 2 },
  essenceRegen: { base: 5, perInt: 0.1 },
  moveSpeed: { base: 5.4, perAgi: 0.003 },
  /** Thralls: a share of your health and of your unboosted spell power. */
  thrall: { hpShare: 0.45, damageShare: 0.4 },
} as const;

export function deriveStats(
  character: Character,
  slots: InventorySlot[],
  discipline: Discipline,
  damageTier: number,
): DerivedStats {
  const { total } = computeStats(character, slots);
  const level = Math.max(1, character.level ?? 1);
  const mods = discipline.mods;
  const E = STAT_EFFECTS;
  const dmgMult = 1 + DAMAGE_UPGRADE.perTier * damageTier;
  const maxHp = Math.round((E.health.base + total.stat_vit * E.health.perVit + (level - 1) * E.health.perLevel) * mods.maxHpMult);
  const baseSpellPower =
    (E.spell.base + total.stat_int * E.spell.perInt + total.stat_str * E.spell.perStr + total.stat_agi * E.spell.perAgi + (level - 1) * E.spell.perLevel) * dmgMult;
  // A line staff's passive (+10% spell damage) raises Spell power; thralls keep the unboosted figure.
  const spellPower = baseSpellPower * resolveWeaponLoadout(equippedBySlot(slots), discipline.id).spellMult;
  return {
    level,
    maxHp,
    spellPower,
    maxEssence: Math.round(E.essence.base + total.stat_int * E.essence.perInt + level * E.essence.perLevel),
    essenceRegen: (E.essenceRegen.base + total.stat_int * E.essenceRegen.perInt) * mods.essenceRegenMult,
    moveSpeed: E.moveSpeed.base * (1 + total.stat_agi * E.moveSpeed.perAgi),
    thrallHp: Math.round(maxHp * E.thrall.hpShare * mods.thrallHpMult),
    thrallDamage: baseSpellPower * E.thrall.damageShare * mods.thrallDamageMult,
    damageBonusPct: Math.round((dmgMult - 1) * 100),
  };
}

/** XP needed to advance from `level` (server rule: level × 100). */
export function xpToNext(level: number) {
  return level * 100;
}

// --- Plain-language deltas -------------------------------------------------------------------

export type DerivedKey = 'maxHp' | 'spellPower' | 'maxEssence' | 'essenceRegen' | 'moveSpeed' | 'thrallHp' | 'thrallDamage';

/** What each derived number is called to the player, in the order the UI lists them. */
export const DERIVED_LABELS: { key: DerivedKey; label: string; short: string }[] = [
  { key: 'maxHp', label: 'health', short: 'Health' },
  { key: 'spellPower', label: 'spell power', short: 'Spell power' },
  { key: 'maxEssence', label: 'essence', short: 'Essence' },
  { key: 'essenceRegen', label: 'essence/s', short: 'Essence/s' },
  { key: 'moveSpeed', label: 'move speed', short: 'Move speed' },
  { key: 'thrallHp', label: 'thrall health', short: 'Thrall health' },
  { key: 'thrallDamage', label: 'thrall damage', short: 'Thrall damage' },
];

/** Number as the player reads it: whole for health/essence, one decimal for power and regen. */
export function formatDerived(key: DerivedKey, v: number): string {
  switch (key) {
    case 'maxHp':
    case 'maxEssence':
    case 'thrallHp':
      return String(Math.round(v));
    case 'moveSpeed':
      return v.toFixed(2);
    default:
      return v.toFixed(1);
  }
}

export interface StatDeltaLine {
  key: DerivedKey;
  label: string;
  short: string;
  before: number;
  after: number;
  diff: number;
  /** Signed, formatted change as shown ("+48", "-1.2"; move speed as a percent: "+2.4%"). */
  text: string;
  tone: 'up' | 'down';
}

/** The change in one number, formatted; '' when it rounds to nothing (so lines never read "+0.0"). */
function deltaText(key: DerivedKey, before: number, after: number): string {
  if (key === 'moveSpeed') {
    const pct = before ? ((after - before) / before) * 100 : 0;
    const r = Math.round(pct * 10) / 10;
    return r === 0 ? '' : `${r > 0 ? '+' : '-'}${Math.abs(r).toFixed(1)}%`;
  }
  const digits = key === 'maxHp' || key === 'maxEssence' || key === 'thrallHp' ? 0 : 1;
  const f = 10 ** digits;
  const r = Math.round((after - before) * f) / f;
  return r === 0 ? '' : `${r > 0 ? '+' : '-'}${Math.abs(r).toFixed(digits)}`;
}

/** Every derived number that changes (to the precision the player sees) between two states. */
export function describeStatDelta(before: DerivedStats, after: DerivedStats): StatDeltaLine[] {
  const out: StatDeltaLine[] = [];
  for (const d of DERIVED_LABELS) {
    const b = before[d.key];
    const a = after[d.key];
    const text = deltaText(d.key, b, a);
    if (!text) continue;
    out.push({ ...d, before: b, after: a, diff: a - b, text, tone: a > b ? 'up' : 'down' });
  }
  return out;
}
