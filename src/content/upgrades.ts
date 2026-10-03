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

/**
 * Legion reinforcement (thrall gear, 2026-10-02): the gold sink for the Legion kit. Each tier binds the dead a little tighter:
 * +3% thrall health and damage and +1% attack speed, on top of whatever the kit pieces give. Like Damage and Wave Speed the
 * tiers reset when you Ascend (gold is meant to flow back into the run); the kit pieces themselves are never lost.
 * Twelve tiers cost about 74k gold in all (the 25 damage tiers cost about 2.0M, the last one 673k; Wave Speed about 14k), the last one about 30k.
 */
export const LEGION_UPGRADE = {
  maxTier: 12,
  perTier: 0.03,
  speedPerTier: 0.01,
  cost: (tier: number) => Math.round(120 * Math.pow(1.65, tier)),
};

export interface WaveModifiers {
  intervalMult: number;
  capMult: number;
  sizeMult: number;
  rewardMult: number;
  /** XP per kill. Rewards keep climbing with the dial even where the density terms level off. */
  xpMult: number;
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

/**
 * Pressure per tier. The bot (and a human) clears roughly 100 bodies a minute, and the base wave rate is
 * already about that, so every extra body per second past tier ~3 only piles up in front of you: kills/min
 * stop rising while deaths climb (the 2026-10-02 necro pass measured 5-11 deaths per 3 minutes at tier 8
 * and a third of the intended kill rate). So the density terms (interval, cap, wave size) climb at full
 * rate to tier 3 and at a quarter of it after; the reward terms keep climbing, so tiers 6-8 pay more per
 * minute than the intended band for the risk they add. Per-enemy HP, damage and elite chance stay gentle.
 */
const DENSITY_FULL_TIERS = 3;
const DENSITY_TAIL = 0.55;
export function densityTier(tier: number) {
  return Math.min(tier, DENSITY_FULL_TIERS) + DENSITY_TAIL * Math.max(0, tier - DENSITY_FULL_TIERS);
}

export function waveModifiers(tier: number): WaveModifiers {
  const nightfall = milestoneActive('nightfall', tier);
  const d = densityTier(tier);
  return {
    intervalMult: 1 / (1 + 0.12 * d),
    capMult: 1 + 0.09 * d,
    sizeMult: 1 + 0.06 * d,
    rewardMult: 1 + 0.1 * tier + (nightfall ? 0.25 : 0),
    xpMult: 1 + 0.05 * tier + (nightfall ? 0.15 : 0),
    itemChanceMult: 1 + 0.06 * tier + (nightfall ? 0.2 : 0),
    eliteBonus: 0.004 * tier,
    enemyHpMult: 1 + 0.018 * tier,
    enemyDamageMult: 1 + 0.026 * tier,
    // How much sooner the next wave comes (the interval is 1/(1+0.12*density)). It used to be 12 x tier, which read +96% at tier 8 for a +69% wave rate.
    speedPct: Math.round(12 * d),
  };
}

export function damageBonusPct(tier: number) {
  return Math.round(DAMAGE_UPGRADE.perTier * tier * 100);
}

/** Milestone diamonds on each upgrade bar (reference HUD shows three). */
export function milestones(tier: number, maxTier: number): boolean[] {
  return [1 / 3, 2 / 3, 1].map((f) => tier >= Math.ceil(maxTier * f));
}
