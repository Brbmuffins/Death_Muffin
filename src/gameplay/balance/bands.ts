import type { BalanceRun } from './harness';

/** Level bands relative to the area's level: how a player plausibly arrives and pushes (BALANCE.md "Level bands"). */
export const BANDS: Record<string, (lvl: number) => Partial<BalanceRun>> = {
  /** Just arrived: at the area's level, a few damage tiers, waves at base speed. */
  intended: (lvl) => ({ level: lvl, damageTier: Math.round(lvl * 0.6), waveTier: 0, gearStats: Math.round(lvl * 0.8) }),
  /** Settled in: a few levels up, more damage, moderate Wave Speed. */
  geared: (lvl) => ({ level: lvl + 3, damageTier: Math.round(lvl * 0.9), waveTier: 3, gearStats: Math.round(lvl) }),
  /** Greedy: arrived-level power with Wave Speed pushed hard. */
  push: (lvl) => ({ level: lvl, damageTier: Math.round(lvl * 0.6), waveTier: 6, gearStats: Math.round(lvl * 0.8) }),
  /** Reckless: arrived-level power at max Wave Speed. Should kill a careless player. */
  max: (lvl) => ({ level: lvl, damageTier: Math.round(lvl * 0.6), waveTier: 8, gearStats: Math.round(lvl * 0.8) }),
};
