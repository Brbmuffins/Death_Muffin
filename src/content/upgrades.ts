/**
 * The two power axes from the pitch: Damage (clear power) and Wave Speed
 * (pressure + reward). Wave Speed is a risk lever — the player buys tiers,
 * then dials the ACTIVE tier anywhere from 0 to what they own.
 */
export const DAMAGE_UPGRADE = {
  maxTier: 25,
  perTier: 0.08,
  cost: (tier: number) => Math.round(40 * Math.pow(1.5, tier)),
};

export const WAVE_UPGRADE = {
  maxTier: 8,
  cost: (tier: number) => Math.round(120 * Math.pow(1.75, tier)),
};

export interface WaveModifiers {
  intervalMult: number;
  capMult: number;
  sizeMult: number;
  rewardMult: number;
  itemChanceMult: number;
  eliteBonus: number;
  /** Faster waves are angrier waves: the dial raises danger per enemy, not just density. */
  enemyHpMult: number;
  enemyDamageMult: number;
  /** Shown in the HUD as "+N% Wave Speed". */
  speedPct: number;
}

export function waveModifiers(tier: number): WaveModifiers {
  return {
    intervalMult: 1 / (1 + 0.16 * tier),
    capMult: 1 + 0.12 * tier,
    sizeMult: 1 + 0.12 * tier,
    rewardMult: 1 + 0.1 * tier,
    itemChanceMult: 1 + 0.06 * tier,
    eliteBonus: 0.008 * tier,
    enemyHpMult: 1 + 0.03 * tier,
    enemyDamageMult: 1 + 0.05 * tier,
    speedPct: Math.round(16 * tier),
  };
}

export function damageBonusPct(tier: number) {
  return Math.round(DAMAGE_UPGRADE.perTier * tier * 100);
}

/** Milestone diamonds on each upgrade bar (reference HUD shows three). */
export function milestones(tier: number, maxTier: number): boolean[] {
  return [1 / 3, 2 / 3, 1].map((f) => tier >= Math.ceil(maxTier * f));
}
