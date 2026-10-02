/**
 * Legendary set mechanics (docs/LEGENDARY-SETS.md): the numbers that are NOT set values.
 * The set values live in DisciplineMods (0 = off); this file holds the fixed shapes (radii, caps, durations),
 * the host-side clamp for the mods the shared sim reads, and the damage-reduction maths. Pure, so it is unit tested.
 */
import type { DisciplineMods } from '../content/disciplines';

export const LEGEND = {
  /** Thrall Death Burst radius (m). */
  deathBurstR: 3,
  /** Champion thralls: model scale, damage and health multipliers. */
  championScale: 1.35,
  championDamage: 2,
  championHp: 2,
  /** Marrow Spear rally: seconds the marked enemy takes the legion's extra damage. */
  rallyS: 4,
  /** Colossus Guard needs this many of your thralls standing. */
  colossusThralls: 3,
  /** Bone Ward's own cap (Player.takeDamage) and the cap on the whole stack with Colossus Guard. */
  wardCap: 0.6,
  totalCap: 0.75,
  /** Litany Shatter radius (m). */
  shatterR: 4,
  /** Wisps: heal share of max HP per second, simultaneous cap, orbit radius. */
  wispHealFrac: 0.02,
  wispCap: 3,
  /** Wraith/wisp nova radius (m) and the most novas one empowered cast releases. */
  novaR: 3,
  novaMax: 8,
  /** Contagion: how many neighbours, and how far, a dying enemy passes its Withered to. */
  spreadMax: 3,
  spreadR: 4,
  /** Chain Plague: per-enemy cooldown (s) and the most clouds it may keep alive at once. */
  burstCdS: 1,
  burstClouds: 4,
} as const;

/** The mods the shared WorldSim reads for each owner (the rest resolve on the owner's own client). */
export interface SimLegend {
  thrallDeathBurst: number;
  championEvery: number;
  spearRally: number;
  miasmaSpreadsWithered: number;
  witheredBurstAt: number;
}

export const NO_SIM_LEGEND: SimLegend = { thrallDeathBurst: 0, championEvery: 0, spearRally: 0, miasmaSpreadsWithered: 0, witheredBurstAt: 0 };

export function simLegendOf(m: Partial<DisciplineMods>): SimLegend {
  return {
    thrallDeathBurst: m.thrallDeathBurst ?? 0,
    championEvery: m.championEvery ?? 0,
    spearRally: m.spearRally ?? 0,
    miasmaSpreadsWithered: m.miasmaSpreadsWithered ?? 0,
    witheredBurstAt: m.witheredBurstAt ?? 0,
  };
}

export function simLegendActive(l: SimLegend): boolean {
  return l.thrallDeathBurst > 0 || l.championEvery > 0 || l.spearRally > 0 || l.miasmaSpreadsWithered > 0 || l.witheredBurstAt > 0;
}

const fin = (v: unknown) => (typeof v === 'number' && Number.isFinite(v) ? v : 0);
const clamp = (v: unknown, lo: number, hi: number) => Math.min(hi, Math.max(lo, fin(v)));

/** The host never trusts a claim: every field is clamped to what a legendary set could ever grant. */
export function clampSimLegend(raw: Partial<SimLegend> | undefined): SimLegend {
  if (!raw) return { ...NO_SIM_LEGEND };
  return {
    thrallDeathBurst: clamp(raw.thrallDeathBurst, 0, 2),
    championEvery: Math.floor(clamp(raw.championEvery, 0, 20)),
    spearRally: clamp(raw.spearRally, 0, 3),
    miasmaSpreadsWithered: clamp(raw.miasmaSpreadsWithered, 0, 1) > 0 ? 1 : 0,
    witheredBurstAt: Math.floor(clamp(raw.witheredBurstAt, 0, 12)),
  };
}

/** Withered stack cap, lifted to Chain Plague's burst threshold so the stacks can actually reach it. */
export function effectiveWitheredCap(m: Pick<DisciplineMods, 'witheredMaxStacks' | 'witheredBurstAt'>): number {
  return Math.max(m.witheredMaxStacks, m.witheredBurstAt ?? 0);
}

/** Colossus Guard is live with enough thralls standing. */
export function colossusActive(m: Pick<DisciplineMods, 'colossusGuard'>, thralls: number): boolean {
  return m.colossusGuard > 0 && thralls >= LEGEND.colossusThralls;
}

/**
 * The damage multiplier for an incoming blow (before Bulwark and the barrier): the ward's reduction (capped at 60% as ever)
 * and Colossus Guard combine multiplicatively, and the whole stack never reduces more than 75%.
 * With guard 0 this is exactly `1 - min(0.6, ward)`, the old behaviour.
 */
export function damageTakenMult(ward: number, guard: number): number {
  const m = (1 - Math.min(LEGEND.wardCap, ward)) * (1 - Math.min(0.9, Math.max(0, guard)));
  return Math.max(1 - LEGEND.totalCap, m);
}

/** Bone Ward reflect: the share of what the ward alone prevented, dealt back at the attacker. */
export function wardReflectDamage(raw: number, boneWard: number, reflect: number): number {
  if (reflect <= 0 || raw <= 0 || boneWard <= 0) return 0;
  return raw * Math.min(LEGEND.wardCap, boneWard) * reflect;
}

/** Litany Shatter: the barrier that was lost to damage times the mod. */
export function shatterDamage(barrierSize: number, mult: number): number {
  return barrierSize > 0 && mult > 0 ? barrierSize * mult : 0;
}
