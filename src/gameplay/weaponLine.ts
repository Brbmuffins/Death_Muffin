import {
  NECRO_DISCIPLINES,
  NECRO_TIERS,
  NECRO_WEAPON_BY_ID,
  NECRO_WEAPON_TUNING as T,
  type NecroMainKind,
  type NecroTier,
} from '../content/necroWeapons';

/**
 * What the necromancer's equipped weapon and off-hand change (docs/ALCHEMY-AND-WORLDS-PLAN.md N1).
 * Pure: the scene resolves it from worn gear, and AbilitySystem, deriveStats and the auto-combat reach read it.
 * Every number comes from NECRO_WEAPON_TUNING.
 */
export interface WeaponLoadout {
  /** The main-hand kind, or null (no line weapon, or not a necromancer discipline). */
  main: NecroMainKind | null;
  mainTier: NecroTier | null;
  /** The off-hand id's kind / tier, when it is part of the line. */
  off: 'skull_focus' | 'grimoire' | 'mourning_bell' | null;
  offTier: NecroTier | null;
  /** Derived Spell power multiplier (staff passive). */
  spellMult: number;
  /** Bone Needle modifiers. */
  needleRangeMult: number;
  needlePierce: number;
  needleCadenceMult: number;
  needleDamageMult: number;
  needleWithered: number;
  /** The LMB is a reaping arc instead of a needle. */
  reap: boolean;
  /** Exhume gives back this share of its essence cost. */
  exhumeRefund: number;
  /** Thrall cap bonus (skull focus, gold and above). */
  thrallBonus: number;
  /** Rite cooldown multiplier (grimoire); the LMB primary is exempt. */
  riteCooldownMult: number;
  /** Allies healed per wraith hit, as a share of their max health (mourning bell, Mourner only). */
  bellAllyHeal: number;
}

export const NO_LOADOUT: WeaponLoadout = Object.freeze({
  main: null, mainTier: null, off: null, offTier: null,
  spellMult: 1, needleRangeMult: 1, needlePierce: 0, needleCadenceMult: 1, needleDamageMult: 1, needleWithered: 0, reap: false,
  exhumeRefund: 0, thrallBonus: 0, riteCooldownMult: 1, bellAllyHeal: 0,
}) as WeaponLoadout;

const tierAtLeast = (tier: NecroTier, min: NecroTier) => NECRO_TIERS.indexOf(tier) >= NECRO_TIERS.indexOf(min);

/** Resolve the loadout from the worn item ids. Other classes (and items outside the line) change nothing. */
export function resolveWeaponLoadout(
  worn: { main_hand?: { item_id: string } | null; off_hand?: { item_id: string } | null },
  disciplineId: string,
): WeaponLoadout {
  if (!NECRO_DISCIPLINES.includes(disciplineId)) return NO_LOADOUT;
  const main = worn.main_hand ? NECRO_WEAPON_BY_ID[worn.main_hand.item_id] : undefined;
  const off = worn.off_hand ? NECRO_WEAPON_BY_ID[worn.off_hand.item_id] : undefined;
  if (!main && !off) return NO_LOADOUT;
  const l: WeaponLoadout = { ...NO_LOADOUT };
  if (main) {
    l.main = main.kind as NecroMainKind;
    l.mainTier = main.tier;
    switch (main.kind) {
      case 'staff':
        l.needleRangeMult = T.staff.needleRangeMult;
        l.needlePierce = T.staff.pierce;
        l.spellMult = T.staff.spellDamageMult;
        break;
      case 'scythe':
        l.reap = true;
        break;
      case 'wand':
        l.needleCadenceMult = T.wand.cadenceMult;
        l.needleDamageMult = T.wand.damageMult;
        break;
      case 'sickle':
        l.needleWithered = T.sickle.witheredStacks;
        l.exhumeRefund = T.sickle.exhumeRefund;
        break;
    }
  }
  if (off) {
    l.off = off.kind as WeaponLoadout['off'];
    l.offTier = off.tier;
    if (off.kind === 'skull_focus' && tierAtLeast(off.tier, T.skull_focus.minTier)) l.thrallBonus = T.skull_focus.thrallCap;
    else if (off.kind === 'grimoire') l.riteCooldownMult = T.grimoire.riteCooldownMult;
    else if (off.kind === 'mourning_bell' && disciplineId === 'mourner') l.bellAllyHeal = T.mourning_bell.allyHealFrac;
  }
  return l;
}

/** Reach of an ability for this loadout: a scythe's primary is a short arc, a staff's needle flies farther. */
export function abilityRange(id: string, baseRange: number, l: WeaponLoadout): number {
  if (id !== 'bone_needle') return baseRange;
  if (l.reap) return T.scythe.reach;
  return baseRange * l.needleRangeMult;
}

/** Cooldown (ms) of an ability: wand cadence and scythe swing on the needle, grimoire on the rites. */
export function abilityCooldownMs(id: string, baseMs: number, l: WeaponLoadout, isPrimary: boolean): number {
  if (id === 'bone_needle') return l.reap ? T.scythe.cooldownMs : baseMs / l.needleCadenceMult;
  return isPrimary ? baseMs : baseMs * l.riteCooldownMult;
}

/** Cast lock (ms) after a cast: the needle's shortens with cadence; a scythe swing lingers a little. */
export function abilityLockMs(id: string, baseMs: number, l: WeaponLoadout): number {
  if (id !== 'bone_needle') return baseMs;
  return l.reap ? T.scythe.lockMs : baseMs / l.needleCadenceMult;
}

/**
 * The enemies a scythe arc strikes: inside `reach` (plus body radius) and within half the arc of the aim
 * direction (or hugging the caster), nearest first, at most `maxHits`.
 */
export function reapTargets<E extends { x: number; z: number; radius: number }>(
  caster: { x: number; z: number },
  aim: { x: number; z: number },
  candidates: Iterable<E>,
): E[] {
  let dx = aim.x - caster.x;
  let dz = aim.z - caster.z;
  const l = Math.hypot(dx, dz) || 1;
  dx /= l;
  dz /= l;
  const cosMax = Math.cos(((T.scythe.arcDeg / 2) * Math.PI) / 180);
  const hits: { e: E; d: number }[] = [];
  for (const e of candidates) {
    const rx = e.x - caster.x;
    const rz = e.z - caster.z;
    const d = Math.hypot(rx, rz);
    if (d > T.scythe.reach + e.radius) continue;
    if (d >= e.radius && (rx * dx + rz * dz) / d < cosMax) continue;
    hits.push({ e, d });
  }
  hits.sort((a, b) => a.d - b.d);
  return hits.slice(0, T.scythe.maxHits).map((h) => h.e);
}

/** The enemy a staff needle pierces into: the nearest behind the target, in the needle's lane. */
export function pierceTargets<E extends { id: number; x: number; z: number; radius: number }>(
  from: { x: number; z: number },
  target: { x: number; z: number; id?: number },
  candidates: Iterable<E>,
  count: number,
): E[] {
  if (count <= 0) return [];
  let dx = target.x - from.x;
  let dz = target.z - from.z;
  const l = Math.hypot(dx, dz) || 1;
  dx /= l;
  dz /= l;
  const behind: { e: E; along: number }[] = [];
  for (const e of candidates) {
    if (e.id === target.id) continue;
    const rx = e.x - from.x;
    const rz = e.z - from.z;
    const along = rx * dx + rz * dz - l;
    if (along <= 0 || along > T.staff.pierceReach) continue;
    if (Math.abs(rx * dz - rz * dx) > T.staff.pierceLane + e.radius) continue;
    behind.push({ e, along });
  }
  behind.sort((a, b) => a.along - b.along);
  return behind.slice(0, count).map((h) => h.e);
}
