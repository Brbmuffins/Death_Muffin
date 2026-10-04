/**
 * Ascension: the prestige loop, now driven by Vows (FUTURE_CONTENT "Replay & endgame depth", reworked 2026-10-03).
 *
 * Before a run the player swears Vows at the Altar of Ascension: curses that make the world harder (older dead, tougher dead,
 * Deacon hosts, Prelate Echoes) or the hero frailer (no healing flasks, thinner graves). Every vow has a HEAT value; the
 * heat of the vows sworn is the run's rank, and the more heat a run carries the more Ashes it pays when the Prelate falls
 * and the run is burned. Seals do NOT reset on Ascension: difficulty comes from the vows the player chose, not from
 * repeating the same grind.
 *
 * Soul shards unlock new vows and new Covenant Boons. Ashes buy boons. Boons only ever change the ascended character
 * (or, for corpse life, the room they keep), so they are fair in co-op.
 *
 * `ascension` on the necro record is the BEST rank ever completed (leaderboard, titles). The rank a run is playing at is
 * `vowHeat(state.vows)`.
 */

export const ASCENSION = {
  /** Prelate kills this run needed before the Altar will take the run. */
  prelateKillsRequired: 1,
  /** Every enemy (and the Prelate) is this many levels older per step of the Elder Dead vow. */
  levelsPerRank: 3,
  /** Gold and XP bonus per point of heat, on top of what the older enemies already pay. */
  rewardPerRank: 0.05,
  /** Heat past this earns no further gold / XP bonus (Ashes keep rising). */
  rewardHeatCap: 30,
  /** Largest heat a character can swear (the sum of every vow at its top step). Informational; vows enforce their own caps. */
  maxRank: 50,
  /** Ashes: +20% per point of heat on the run's base payout. */
  ashesPerHeat: 0.2,
};

export type VowId =
  | 'elder_dead'
  | 'iron_dead'
  | 'swollen_waves'
  | 'deacon_host'
  | 'elite_surge'
  | 'prelate_echo'
  | 'thin_graves'
  | 'frail_vessel'
  | 'famished'
  | 'brittle_thralls'
  | 'dry_cellar';

export interface VowDef {
  id: VowId;
  name: string;
  /** One line: what one step does (shown under the name; `perStep` adds the per-step numbers the UI prints). */
  blurb: string;
  /** Steps a player can swear (1 = a plain on/off vow). */
  maxRank: number;
  /** Heat per step. */
  heat: number;
  /** Soul shards to unlock at the Altar (0 = known from the start). */
  unlockShards: number;
  /** Does it change the world (shared by the room, run by the world keeper) or only the one who swore it? */
  scope: 'world' | 'self';
}

export const VOWS: Record<VowId, VowDef> = {
  elder_dead: { id: 'elder_dead', name: 'Elder Dead', blurb: 'The dead rise 3 levels older per step.', maxRank: 20, heat: 1, unlockShards: 0, scope: 'world' },
  iron_dead: { id: 'iron_dead', name: 'Iron Dead', blurb: 'Enemies have 25% more health per step.', maxRank: 3, heat: 1, unlockShards: 0, scope: 'world' },
  frail_vessel: { id: 'frail_vessel', name: 'Frail Vessel', blurb: 'You have 12% less maximum health per step.', maxRank: 3, heat: 1, unlockShards: 0, scope: 'self' },
  famished: { id: 'famished', name: 'Famished Rites', blurb: 'Grave Essence returns 20% slower per step.', maxRank: 2, heat: 1, unlockShards: 100, scope: 'self' },
  thin_graves: { id: 'thin_graves', name: 'Thin Graves', blurb: 'Corpses rot 25% sooner per step.', maxRank: 2, heat: 1, unlockShards: 120, scope: 'world' },
  brittle_thralls: { id: 'brittle_thralls', name: 'Brittle Dead', blurb: 'Your thralls have 20% less health per step.', maxRank: 2, heat: 1, unlockShards: 150, scope: 'self' },
  swollen_waves: { id: 'swollen_waves', name: 'Swollen Waves', blurb: 'Every wave brings 25% more of the dead per step.', maxRank: 3, heat: 1, unlockShards: 200, scope: 'world' },
  dry_cellar: { id: 'dry_cellar', name: 'Dry Cellar', blurb: 'Healing flasks no longer work for you (brews and meals still do).', maxRank: 1, heat: 2, unlockShards: 250, scope: 'self' },
  elite_surge: { id: 'elite_surge', name: 'Bloodied Elites', blurb: 'Elites are 8% more common per step.', maxRank: 3, heat: 1, unlockShards: 300, scope: 'world' },
  deacon_host: { id: 'deacon_host', name: 'Deacon Host', blurb: 'Crypt Deacons are twice as common (step 2: three times).', maxRank: 2, heat: 2, unlockShards: 400, scope: 'world' },
  prelate_echo: { id: 'prelate_echo', name: 'Prelate Echoes', blurb: 'The Prelate learns a new trick per step: a second bell, an elite procession, chasing rain.', maxRank: 3, heat: 2, unlockShards: 600, scope: 'world' },
};

export const VOW_ORDER: VowId[] = [
  'elder_dead',
  'iron_dead',
  'swollen_waves',
  'deacon_host',
  'elite_surge',
  'prelate_echo',
  'thin_graves',
  'frail_vessel',
  'famished',
  'brittle_thralls',
  'dry_cellar',
];

export type VowRanks = Partial<Record<VowId, number>>;

/** The steps of a vow actually sworn (clamped to the vow's own cap; unknown ids are ignored). */
export function vowSteps(vows: VowRanks | undefined, id: VowId): number {
  return Math.max(0, Math.min(VOWS[id].maxRank, Math.floor(Number(vows?.[id])) || 0));
}

/** Only known vows at steps within their caps (untrusted input from a snapshot or a save). */
export function sanitizeVows(raw: unknown): VowRanks {
  const out: VowRanks = {};
  if (!raw || typeof raw !== 'object') return out;
  for (const id of VOW_ORDER) {
    const n = vowSteps(raw as VowRanks, id);
    if (n) out[id] = n;
  }
  return out;
}

/** The rank a run plays at: the sum of the heat of every vow sworn. */
export function vowHeat(vows: VowRanks | undefined): number {
  let h = 0;
  for (const id of VOW_ORDER) h += vowSteps(vows, id) * VOWS[id].heat;
  return h;
}

/** Only the vows that reshape the world itself (the rest curse the one who swore them): what the sim runs and the room shares. */
export function worldVows(vows: VowRanks | undefined): VowRanks {
  const out: VowRanks = {};
  for (const id of VOW_ORDER) if (VOWS[id].scope === 'world' && vowSteps(vows, id)) out[id] = vowSteps(vows, id);
  return out;
}

/** Everything the vows change, flattened for the systems that apply them. */
export interface VowEffects {
  /** Levels every enemy and boss runs older. */
  levels: number;
  enemyHpMult: number;
  waveSizeMult: number;
  deaconMult: number;
  eliteBonus: number;
  /** Prelate Echoes sworn (0..3). */
  echoes: number;
  corpseLifeMult: number;
  maxHpMult: number;
  essenceRegenMult: number;
  thrallHpMult: number;
  noFlasks: boolean;
}

export function vowEffects(vows: VowRanks | undefined): VowEffects {
  const s = (id: VowId) => vowSteps(vows, id);
  return {
    levels: ASCENSION.levelsPerRank * s('elder_dead'),
    enemyHpMult: 1 + 0.25 * s('iron_dead'),
    waveSizeMult: 1 + 0.25 * s('swollen_waves'),
    deaconMult: 1 + s('deacon_host'),
    eliteBonus: 0.08 * s('elite_surge'),
    echoes: s('prelate_echo'),
    corpseLifeMult: 1 - 0.25 * s('thin_graves'),
    maxHpMult: 1 - 0.12 * s('frail_vessel'),
    essenceRegenMult: 1 - 0.2 * s('famished'),
    thrallHpMult: 1 - 0.2 * s('brittle_thralls'),
    noFlasks: s('dry_cellar') > 0,
  };
}

/** Gold and XP multiplier for a run at `heat`. */
export function ascensionRewardMult(heat: number) {
  return 1 + ASCENSION.rewardPerRank * Math.max(0, Math.min(ASCENSION.rewardHeatCap, Math.floor(heat) || 0));
}

/** Level offset a plain rank of Elder Dead gives (kept for the balance harness and the older "rank N world" shorthand). */
export function ascensionLevels(rank: number) {
  return Math.max(0, Math.min(VOWS.elder_dead.maxRank, Math.floor(rank) || 0)) * ASCENSION.levelsPerRank;
}

/** The older single-number world (`sim.ascension = N`, old snapshots, old saves) is N steps of Elder Dead. */
export function legacyVows(rank: number): VowRanks {
  const n = Math.max(0, Math.min(VOWS.elder_dead.maxRank, Math.floor(Number(rank)) || 0));
  return n ? { elder_dead: n } : {};
}

/** The key under which an unlockable thing is recorded in `NecroState.unlocks`. */
export const vowKey = (id: VowId) => `vow:${id}`;
export const boonKey = (id: BoonId) => `boon:${id}`;

/** Is this vow / boon open to the character? (Free ones always are.) */
export function isUnlocked(unlocks: readonly string[] | undefined, key: string): boolean {
  if (key.startsWith('vow:')) {
    const d = VOWS[key.slice(4) as VowId];
    return !!d && (d.unlockShards === 0 || !!unlocks?.includes(key));
  }
  if (key.startsWith('boon:')) {
    const d = BOONS[key.slice(5) as BoonId];
    return !!d && (d.unlockShards === 0 || !!unlocks?.includes(key));
  }
  return false;
}

/** Shards the Altar asks for an unlock key (null = unknown key). */
export function unlockCost(key: string): number | null {
  if (key.startsWith('vow:')) return VOWS[key.slice(4) as VowId]?.unlockShards ?? null;
  if (key.startsWith('boon:')) return BOONS[key.slice(5) as BoonId]?.unlockShards ?? null;
  return null;
}

export type BoonId =
  | 'vigil'
  | 'marrow_font'
  | 'bone_tithe'
  | 'quickened_coin'
  | 'first_rites'
  | 'shard_keeper'
  | 'soul_hunger'
  | 'swift_seals'
  | 'legion_pact'
  | 'bonded_dead'
  | 'lingering_dead'
  | 'grave_feast'
  | 'bone_ward'
  | 'hollow_sacrifice'
  | 'carrion_bloom';

export interface BoonDef {
  id: BoonId;
  name: string;
  /** What one rank of the boon does. */
  blurb: string;
  maxRank: number;
  /** Ashes for the next rank (index = ranks already owned). */
  cost: number[];
  /** Best Ascension rank (heat of a completed run) the character must have reached to buy it. */
  requires?: number;
  /** Soul shards to unlock it at the Altar (0 = open from the start). */
  unlockShards: number;
  /** A boon that changes HOW you play rather than adding a percentage. */
  shape?: boolean;
}

export const BOONS: Record<BoonId, BoonDef> = {
  vigil: { id: 'vigil', name: 'Vigil of Bone', blurb: '+8% maximum health.', maxRank: 3, cost: [4, 8, 14], unlockShards: 0 },
  marrow_font: { id: 'marrow_font', name: 'Marrow Font', blurb: '+12% Grave Essence regeneration.', maxRank: 3, cost: [4, 8, 14], unlockShards: 0 },
  bone_tithe: { id: 'bone_tithe', name: 'Bone Tithe', blurb: 'Damage upgrades cost 10% less.', maxRank: 3, cost: [3, 6, 10], unlockShards: 0 },
  quickened_coin: { id: 'quickened_coin', name: 'Quickened Coin', blurb: 'Wave Speed upgrades cost 12% less.', maxRank: 2, cost: [4, 9], unlockShards: 0 },
  first_rites: { id: 'first_rites', name: 'First Rites', blurb: 'Begin each run with 2 Damage tiers already bought.', maxRank: 2, cost: [6, 12], unlockShards: 0 },
  shard_keeper: { id: 'shard_keeper', name: 'Shard Keeper', blurb: 'Never begin a run holding fewer than 2 soul shards.', maxRank: 2, cost: [5, 10], unlockShards: 0 },
  soul_hunger: { id: 'soul_hunger', name: 'Soul Hunger', blurb: 'Soul Harvest fills 8 souls sooner.', maxRank: 2, cost: [6, 12], requires: 1, unlockShards: 0 },
  swift_seals: { id: 'swift_seals', name: 'Swift Seals', blurb: 'Sealed doors not yet opened need 20% fewer kills.', maxRank: 2, cost: [6, 12], requires: 2, unlockShards: 0 },
  legion_pact: { id: 'legion_pact', name: 'Legion Pact', blurb: 'Command one more thrall.', maxRank: 1, cost: [25], requires: 3, unlockShards: 0 },
  lingering_dead: { id: 'lingering_dead', name: 'Lingering Dead', blurb: 'Corpses last 50% longer.', maxRank: 2, cost: [8, 18], unlockShards: 150, shape: true },
  grave_feast: { id: 'grave_feast', name: 'Grave Feast', blurb: 'Every corpse you consume heals you for 3% of your maximum health.', maxRank: 2, cost: [8, 16], unlockShards: 200, shape: true },
  bonded_dead: { id: 'bonded_dead', name: 'Bonded Dead', blurb: 'A thrall rises beside you whenever you enter a hunting ground with none.', maxRank: 1, cost: [10], unlockShards: 300, shape: true },
  hollow_sacrifice: { id: 'hollow_sacrifice', name: 'Hollow Sacrifice', blurb: 'A thrall you sacrifice leaves a fresh corpse behind.', maxRank: 1, cost: [14], unlockShards: 350, shape: true },
  bone_ward: { id: 'bone_ward', name: 'Bone Ward', blurb: 'Each thrall standing beside you turns away 2% more of the damage you take.', maxRank: 2, cost: [10, 20], unlockShards: 400, shape: true },
  carrion_bloom: { id: 'carrion_bloom', name: 'Carrion Bloom', blurb: 'Corpses caught inside your Miasma burst.', maxRank: 1, cost: [16], unlockShards: 500, shape: true },
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
  'bonded_dead',
  'lingering_dead',
  'grave_feast',
  'bone_ward',
  'hollow_sacrifice',
  'carrion_bloom',
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
  /** Corpses last this many times longer (1 = normal). */
  corpseLifeMult: number;
  /** Fraction of maximum health restored per corpse consumed (added to the discipline's own). */
  corpseHeal: number;
  /** Extra damage reduction per standing thrall (added to the discipline's own). */
  wardPerThrall: number;
  bondedDead: boolean;
  sacrificeLeavesCorpse: boolean;
  miasmaBurstsCorpses: boolean;
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
    corpseLifeMult: 1 + 0.5 * r('lingering_dead'),
    corpseHeal: 0.03 * r('grave_feast'),
    wardPerThrall: 0.02 * r('bone_ward'),
    bondedDead: r('bonded_dead') > 0,
    sacrificeLeavesCorpse: r('hollow_sacrifice') > 0,
    miasmaBurstsCorpses: r('carrion_bloom') > 0,
  };
}

/** What a run did, as the Altar weighs it. */
export interface RunRecord {
  prelateKills: number;
  peakWaveTier: number;
  kills: number;
}

/** Ashes the Altar pays for a run carrying `heat` (the heat of the vows sworn for it). A run with no vows still pays the base. */
export function ashesForRun(run: RunRecord, heat: number): number {
  if (run.prelateKills < ASCENSION.prelateKillsRequired) return 0;
  const base =
    10 +
    5 * Math.min(4, run.prelateKills - 1) +
    2 * Math.max(0, Math.min(8, run.peakWaveTier)) +
    Math.min(15, Math.floor(run.kills / 300));
  return Math.round(base * (1 + ASCENSION.ashesPerHeat * Math.max(0, Math.floor(heat) || 0)));
}

/** Can this boon take another rank (ignoring cost)? Returns the reason if not. `unlocks` defaults to "everything open" for the shape-free callers. */
export function boonBlocked(id: BoonId, ranks: BoonRanks, bestRank: number, unlocks?: readonly string[]): string | null {
  const def = BOONS[id];
  const owned = ranks[id] ?? 0;
  if (owned >= def.maxRank) return 'Mastered';
  if (unlocks && !isUnlocked(unlocks, boonKey(id))) return `Unlock it with ${def.unlockShards} soul shards`;
  if (def.requires && bestRank < def.requires) return `Ascension ${roman(def.requires)}`;
  return null;
}

export function boonCost(id: BoonId, ranks: BoonRanks): number | null {
  const owned = ranks[id] ?? 0;
  return owned >= BOONS[id].maxRank ? null : BOONS[id].cost[owned];
}

export function roman(n: number): string {
  if (n <= 0) return '0';
  const map: [number, string][] = [
    [50, 'L'],
    [40, 'XL'],
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
