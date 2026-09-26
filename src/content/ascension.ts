/**
 * Ascension — the prestige loop (FUTURE_CONTENT "Replay & endgame depth").
 *
 * After the Prelate falls, the Altar of Ascension lets a character burn their
 * run: Damage / Wave Speed tiers, soul shards, area kills and unlocks reset
 * (the browser-local layer only — level, XP, gold and items are server-owned
 * and never touched). In return they earn Ashes, spent on permanent Covenant
 * Boons, and their Ascension rank rises: the world they run gets older and
 * deadlier, and pays more.
 *
 * Boons only ever change the ascended character (stats, costs, their own
 * casts), so they are fair in co-op. The rank is world-wide and, like
 * difficulty, the world keeper's rank runs the sim.
 */

export const ASCENSION = {
  /** Prelate kills this run needed before the Altar will take the run. */
  prelateKillsRequired: 1,
  /** Every enemy (and the Prelate) is this many levels older per rank. */
  levelsPerRank: 3,
  /** Gold and XP bonus per rank, on top of what the older enemies already pay. */
  rewardPerRank: 0.05,
  maxRank: 20,
};

export type BoonId =
  | 'vigil'
  | 'marrow_font'
  | 'bone_tithe'
  | 'quickened_coin'
  | 'first_rites'
  | 'shard_keeper'
  | 'soul_hunger'
  | 'swift_seals'
  | 'legion_pact';

export interface BoonDef {
  id: BoonId;
  name: string;
  /** What one rank of the boon does. */
  blurb: string;
  maxRank: number;
  /** Ashes for the next rank (index = ranks already owned). */
  cost: number[];
  /** Ascension rank the character must have reached to buy it. */
  requires?: number;
}

export const BOONS: Record<BoonId, BoonDef> = {
  vigil: { id: 'vigil', name: 'Vigil of Bone', blurb: '+8% maximum health.', maxRank: 3, cost: [4, 8, 14] },
  marrow_font: { id: 'marrow_font', name: 'Marrow Font', blurb: '+12% Grave Essence regeneration.', maxRank: 3, cost: [4, 8, 14] },
  bone_tithe: { id: 'bone_tithe', name: 'Bone Tithe', blurb: 'Damage upgrades cost 10% less.', maxRank: 3, cost: [3, 6, 10] },
  quickened_coin: { id: 'quickened_coin', name: 'Quickened Coin', blurb: 'Wave Speed upgrades cost 12% less.', maxRank: 2, cost: [4, 9] },
  first_rites: { id: 'first_rites', name: 'First Rites', blurb: 'Begin each run with 2 Damage tiers already bought.', maxRank: 2, cost: [6, 12] },
  shard_keeper: { id: 'shard_keeper', name: 'Shard Keeper', blurb: 'Begin each run holding 2 soul shards.', maxRank: 2, cost: [5, 10] },
  soul_hunger: { id: 'soul_hunger', name: 'Soul Hunger', blurb: 'Soul Harvest fills 8 souls sooner.', maxRank: 2, cost: [6, 12], requires: 1 },
  swift_seals: { id: 'swift_seals', name: 'Swift Seals', blurb: 'Sealed doors open after 20% fewer kills.', maxRank: 2, cost: [6, 12], requires: 2 },
  legion_pact: { id: 'legion_pact', name: 'Legion Pact', blurb: 'Command one more thrall.', maxRank: 1, cost: [25], requires: 3 },
};

export const BOON_ORDER: BoonId[] = [
  'vigil',
  'marrow_font',
  'bone_tithe',
  'quickened_coin',
  'first_rites',
  'shard_keeper',
  'soul_hunger',
  'swift_seals',
  'legion_pact',
];

export type BoonRanks = Partial<Record<BoonId, number>>;

/** Everything the boons change, flattened for the systems that apply them. */
export interface BoonEffects {
  maxHpMult: number;
  essenceRegenMult: number;
  damageCostMult: number;
  waveCostMult: number;
  startDamageTier: number;
  startShards: number;
  soulsDiscount: number;
  unlockKillsMult: number;
  extraThralls: number;
}

export function boonEffects(ranks: BoonRanks): BoonEffects {
  const r = (id: BoonId) => Math.max(0, Math.min(BOONS[id].maxRank, ranks[id] ?? 0));
  return {
    maxHpMult: 1 + 0.08 * r('vigil'),
    essenceRegenMult: 1 + 0.12 * r('marrow_font'),
    damageCostMult: 1 - 0.1 * r('bone_tithe'),
    waveCostMult: 1 - 0.12 * r('quickened_coin'),
    startDamageTier: 2 * r('first_rites'),
    startShards: 2 * r('shard_keeper'),
    soulsDiscount: 8 * r('soul_hunger'),
    unlockKillsMult: 1 - 0.2 * r('swift_seals'),
    extraThralls: r('legion_pact'),
  };
}

/** What a run did, as the Altar weighs it. */
export interface RunRecord {
  prelateKills: number;
  peakWaveTier: number;
  kills: number;
}

/** Ashes the Altar pays for a run at the given current rank. */
export function ashesForRun(run: RunRecord, rank: number): number {
  if (run.prelateKills < ASCENSION.prelateKillsRequired) return 0;
  const base =
    10 +
    5 * Math.min(4, run.prelateKills - 1) +
    2 * Math.max(0, Math.min(8, run.peakWaveTier)) +
    Math.min(15, Math.floor(run.kills / 300));
  return Math.round(base * (1 + 0.25 * rank));
}

/** Can this boon take another rank (ignoring cost)? Returns the reason if not. */
export function boonBlocked(id: BoonId, ranks: BoonRanks, ascension: number): string | null {
  const def = BOONS[id];
  const owned = ranks[id] ?? 0;
  if (owned >= def.maxRank) return 'Mastered';
  if (def.requires && ascension < def.requires) return `Ascension ${roman(def.requires)}`;
  return null;
}

export function boonCost(id: BoonId, ranks: BoonRanks): number | null {
  const owned = ranks[id] ?? 0;
  return owned >= BOONS[id].maxRank ? null : BOONS[id].cost[owned];
}

/** Level offset the world runs at for a rank. */
export function ascensionLevels(rank: number) {
  return Math.max(0, Math.min(ASCENSION.maxRank, rank)) * ASCENSION.levelsPerRank;
}

export function ascensionRewardMult(rank: number) {
  return 1 + ASCENSION.rewardPerRank * Math.max(0, Math.min(ASCENSION.maxRank, rank));
}

export function roman(n: number): string {
  if (n <= 0) return '0';
  const map: [number, string][] = [
    [10, 'X'],
    [9, 'IX'],
    [5, 'V'],
    [4, 'IV'],
    [1, 'I'],
  ];
  let out = '';
  for (const [v, s] of map) while (n >= v) (out += s), (n -= v);
  return out;
}
