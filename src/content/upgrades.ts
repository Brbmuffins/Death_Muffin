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

/**
 * The three diamonds on the Wave Speed bar are milestones: owning AND running
 * the dial at that tier adds a wave affix (FUTURE_CONTENT 0.4).
 */
export type WaveMilestoneId = 'vanguard' | 'restless' | 'nightfall';
export interface WaveMilestone {
  id: WaveMilestoneId;
  tier: number;
  name: string;
  blurb: string;
}
export const WAVE_MILESTONES: WaveMilestone[] = [
  { id: 'vanguard', tier: 3, name: 'Elite Vanguard', blurb: 'Every other wave climbs out behind an elite.' },
  { id: 'restless', tier: 6, name: 'Restless Crypts', blurb: 'Grave Surges break open 40% sooner.' },
  {
    id: 'nightfall',
    tier: 8,
    name: 'Nightfall',
    blurb: 'The moon darkens. Half the common dead rise Shrouded (half damage outside your Miasma). +25% gold, more relics.',
  },
];
/** Share of common spawns Nightfall shrouds. */
export const NIGHTFALL_SHROUD_CHANCE = 0.5;
/** Surge interval multiplier under Restless Crypts. */
export const RESTLESS_SURGE_MULT = 0.6;

export function milestoneActive(id: WaveMilestoneId, tier: number) {
  return tier >= WAVE_MILESTONES.find((m) => m.id === id)!.tier;
}

export function waveModifiers(tier: number): WaveModifiers {
  const nightfall = milestoneActive('nightfall', tier);
  return {
    intervalMult: 1 / (1 + 0.12 * tier),
    capMult: 1 + 0.09 * tier,
    sizeMult: 1 + 0.06 * tier,
    rewardMult: 1 + 0.1 * tier + (nightfall ? 0.25 : 0),
    itemChanceMult: 1 + 0.06 * tier + (nightfall ? 0.2 : 0),
    eliteBonus: 0.008 * tier,
    enemyHpMult: 1 + 0.03 * tier,
    enemyDamageMult: 1 + 0.035 * tier,
    speedPct: Math.round(12 * tier),
  };
}

export function damageBonusPct(tier: number) {
  return Math.round(DAMAGE_UPGRADE.perTier * tier * 100);
}

/** Milestone diamonds on each upgrade bar (reference HUD shows three). */
export function milestones(tier: number, maxTier: number): boolean[] {
  return [1 / 3, 2 / 3, 1].map((f) => tier >= Math.ceil(maxTier * f));
}
