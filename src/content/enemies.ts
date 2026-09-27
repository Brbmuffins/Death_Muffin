import type { AreaId } from './areas';

/**
 * Enemy roster (audit "Minimum enemy roster"): five behaviours that create
 * target priority and make corpse ownership matter, plus the Risen that a
 * Crypt Deacon raises from corpses you didn't claim in time.
 */
export type EnemyId =
  | 'robber'
  | 'hound'
  | 'penitent'
  | 'sac'
  | 'deacon'
  | 'risen'
  // Enemy variety pack (2026-09-27): each reuses a shipped behaviour with one new twist.
  | 'censer'
  | 'wraith'
  | 'rat'
  | 'golem';
export type CorpseKind = 'normal' | 'resonant' | 'swift' | 'toxic' | 'none';
export type Behavior = 'melee' | 'flank' | 'caster' | 'hazard' | 'support';
export type RigKind = 'humanoid' | 'quadruped' | 'bloat' | 'robed';

export interface EnemyDef {
  id: EnemyId;
  name: string;
  behavior: Behavior;
  rig: RigKind;
  hp: number;
  speed: number;
  radius: number;
  damage: number;
  attackRange: number;
  /** Telegraph time before the hit lands (ms). */
  windupMs: number;
  cooldownMs: number;
  xp: number;
  gold: [number, number];
  corpse: CorpseKind;
  scale: number;
  /** Model slug when a generated GLB exists; procedural rig otherwise. */
  modelSlug?: string;
  blurb: string;
  /** Casters: the attack released after the windup (default: the Penitent's cone). */
  attack?: 'cone' | 'scream';
  /** Hazard slam radius (default 1.9). */
  slamRadius?: number;
  /** Climbs out as a pack of this many (one wave pick). */
  pack?: [number, number];
  /** Leaves this many corpses when it dies (default 1). */
  deathCorpses?: number;
  /** Censer aura: nearby dead are Incensed (see CENSER). */
  aura?: boolean;
}

export const ENEMIES: Record<EnemyId, EnemyDef> = {
  robber: {
    id: 'robber',
    name: 'Grave Robber',
    behavior: 'melee',
    rig: 'humanoid',
    hp: 68,
    speed: 2.6,
    radius: 0.45,
    damage: 11,
    attackRange: 1.3,
    windupMs: 420,
    cooldownMs: 1300,
    xp: 4,
    gold: [2, 5],
    corpse: 'normal',
    scale: 1,
    modelSlug: 'grave_robber',
    blurb: 'Diggers who never left the graves they looted.',
  },
  hound: {
    id: 'hound',
    name: 'Bone Hound',
    behavior: 'flank',
    rig: 'quadruped',
    hp: 42,
    speed: 4.4,
    radius: 0.45,
    damage: 8,
    attackRange: 1.2,
    windupMs: 250,
    cooldownMs: 800,
    xp: 3,
    gold: [1, 4],
    corpse: 'swift',
    scale: 1,
    modelSlug: 'bone_hound',
    blurb: 'Fast flankers. Their corpses rise as hounds of your own.',
  },
  penitent: {
    id: 'penitent',
    name: 'Bellbound Penitent',
    behavior: 'caster',
    rig: 'robed',
    hp: 78,
    speed: 1.9,
    radius: 0.5,
    damage: 18,
    attackRange: 7.5,
    windupMs: 1100,
    cooldownMs: 3200,
    xp: 6,
    gold: [3, 7],
    corpse: 'resonant',
    scale: 1.05,
    blurb: 'Tolls a cone of grave-sound. Its corpse resonates: Black Litany counts it twice.',
  },
  sac: {
    id: 'sac',
    name: 'Carrion Sac',
    behavior: 'hazard',
    rig: 'bloat',
    hp: 140,
    speed: 1.3,
    radius: 0.8,
    damage: 15,
    attackRange: 1.6,
    windupMs: 700,
    cooldownMs: 1800,
    xp: 8,
    gold: [4, 9],
    corpse: 'toxic',
    scale: 1.2,
    blurb: 'Slow and swollen. Its corpse ruptures into a toxic pool unless consumed quickly.',
  },
  deacon: {
    id: 'deacon',
    name: 'Crypt Deacon',
    behavior: 'support',
    rig: 'robed',
    hp: 112,
    speed: 2.0,
    radius: 0.5,
    damage: 9,
    attackRange: 6,
    windupMs: 1500,
    cooldownMs: 5500,
    xp: 9,
    gold: [5, 10],
    corpse: 'normal',
    scale: 1.15,
    blurb: 'Kill it first — it steals your corpses and raises them against you.',
  },
  risen: {
    id: 'risen',
    name: 'Risen',
    behavior: 'melee',
    rig: 'humanoid',
    hp: 36,
    speed: 2.9,
    radius: 0.42,
    damage: 8,
    attackRange: 1.2,
    windupMs: 380,
    cooldownMs: 1200,
    xp: 2,
    gold: [0, 1],
    corpse: 'none',
    scale: 0.95,
    modelSlug: 'skeleton_thrall',
    blurb: 'A corpse a deacon claimed before you did.',
  },
  // --- Enemy variety pack. Colour language: enemy bronze for the censer's incense,
  // pale choir-blue for the wraith's song (never the player's Chill blue on the ground).
  censer: {
    id: 'censer',
    name: 'Censer Bearer',
    behavior: 'melee',
    rig: 'robed',
    hp: 96,
    speed: 2.1,
    radius: 0.5,
    damage: 7,
    attackRange: 1.5,
    windupMs: 520,
    cooldownMs: 1700,
    xp: 8,
    gold: [4, 8],
    corpse: 'normal',
    scale: 1.05,
    modelSlug: 'censer_bearer',
    aura: true,
    blurb: 'Swings bronze incense over the pack: the dead around it move and strike faster. Kill it first.',
  },
  wraith: {
    id: 'wraith',
    name: 'Choir Wraith',
    behavior: 'caster',
    rig: 'robed',
    hp: 58,
    speed: 2.5,
    radius: 0.45,
    damage: 17,
    attackRange: 9,
    windupMs: 1250,
    cooldownMs: 3600,
    xp: 7,
    gold: [3, 7],
    corpse: 'none',
    scale: 1.1,
    modelSlug: 'choir_wraith',
    attack: 'scream',
    blurb: 'Sings a ring of grave-song onto where you stand. Step out before the hymn breaks. Leaves no corpse.',
  },
  rat: {
    id: 'rat',
    name: 'Ossuary Skull-Rat',
    behavior: 'flank',
    rig: 'quadruped',
    hp: 18,
    speed: 4.8,
    radius: 0.3,
    damage: 4,
    attackRange: 0.9,
    windupMs: 200,
    cooldownMs: 700,
    xp: 1,
    gold: [0, 1],
    corpse: 'none',
    scale: 1,
    modelSlug: 'skull_rat',
    pack: [4, 6],
    blurb: 'Pours out of the walls in skittering packs. Too small to leave a corpse: burn them with rot and frost.',
  },
  golem: {
    id: 'golem',
    name: 'Bone Golem',
    behavior: 'hazard',
    rig: 'humanoid',
    hp: 430,
    speed: 1.5,
    radius: 1.0,
    damage: 26,
    attackRange: 2.1,
    windupMs: 950,
    cooldownMs: 2700,
    xp: 30,
    gold: [15, 30],
    corpse: 'normal',
    scale: 1,
    modelSlug: 'bone_golem',
    slamRadius: 2.8,
    deathCorpses: 3,
    blurb: 'Dozens of the dead fused into one. Its slam cracks a wide ring; it falls apart into three corpses.',
  },
};

/** Censer Bearer aura: the dead within `radius` are Incensed (refreshed each second). */
export const CENSER = { radius: 5, hasteS: 1.5, moveMult: 1.3, attackRateMult: 1.25 };
/** Choir Wraith scream: a ring of song lands where the target stood. */
export const SCREAM = { radius: 2.2 };

/**
 * Processions: some waves arrive as a themed band instead of the area's usual
 * mix — a banner names them. `lead` climbs out first (always, if room).
 */
export interface WaveTheme {
  id: string;
  name: string;
  blurb: string;
  roster: { id: EnemyId; weight: number }[];
  sizeMult: number;
  lead?: EnemyId;
}
export const PROCESSION = { chance: 0.3, minWave: 2 };
export const WAVE_THEMES: Partial<Record<AreaId, WaveTheme[]>> = {
  graves: [
    { id: 'kennel', name: 'The Kennel Loosed', blurb: 'Hounds and rats, all teeth', roster: [{ id: 'hound', weight: 75 }, { id: 'rat', weight: 25 }], sizeMult: 1.15 },
    { id: 'bellringers', name: "The Bellringers' Round", blurb: 'Penitents under a censer', roster: [{ id: 'penitent', weight: 50 }, { id: 'robber', weight: 35 }, { id: 'censer', weight: 15 }], sizeMult: 0.9, lead: 'censer' },
  ],
  ossuary: [
    { id: 'skittering', name: 'The Skittering', blurb: 'The walls empty of rats', roster: [{ id: 'rat', weight: 100 }], sizeMult: 1.4 },
    { id: 'golem', name: 'The Ossuary Wakes', blurb: 'A golem climbs out of the bone-piles', roster: [{ id: 'robber', weight: 45 }, { id: 'rat', weight: 35 }, { id: 'hound', weight: 20 }], sizeMult: 0.8, lead: 'golem' },
  ],
  nave: [
    { id: 'choir', name: 'The Drowned Choir', blurb: 'Wraiths sing over the flood', roster: [{ id: 'wraith', weight: 55 }, { id: 'penitent', weight: 25 }, { id: 'censer', weight: 20 }], sizeMult: 0.85 },
    { id: 'carrion', name: 'The Carrion Tide', blurb: 'Sacs and rats wash in', roster: [{ id: 'sac', weight: 60 }, { id: 'rat', weight: 40 }], sizeMult: 0.9 },
  ],
  sanctum: [
    { id: 'procession', name: 'The Procession', blurb: 'Censers, bells and deacons march', roster: [{ id: 'censer', weight: 30 }, { id: 'penitent', weight: 35 }, { id: 'deacon', weight: 15 }, { id: 'wraith', weight: 20 }], sizeMult: 0.9, lead: 'golem' },
  ],
};

export const ELITE = {
  hpMult: 3.6,
  damageMult: 1.5,
  scale: 1.35,
  xpMult: 4,
  goldMult: 5,
  shardChance: 1,
};

/**
 * Elite affixes (FUTURE_CONTENT "Encounter systems"): every elite rolls one on
 * spawn. Behaviour lives in WorldSim; the index in AFFIX_ORDER (+1) is what
 * snapshots carry, so only append to it.
 */
export type EliteAffix = 'bellTolled' | 'hungering' | 'shrouded' | 'vengeful';
export const AFFIX_ORDER: EliteAffix[] = ['bellTolled', 'hungering', 'shrouded', 'vengeful'];

export const ELITE_AFFIXES: Record<EliteAffix, { name: string; blurb: string }> = {
  bellTolled: { name: 'Bell-Tolled', blurb: 'Every few seconds it tolls a stunning ring — step out of the bronze circle.' },
  hungering: { name: 'Hungering', blurb: 'Devours nearby corpses to heal. Spend or burst them first.' },
  shrouded: { name: 'Shrouded', blurb: 'Takes half damage unless it stands in your Miasma or a rot pool.' },
  vengeful: { name: 'Vengeful', blurb: 'Bursts into three Risen when it dies.' },
};

export const AFFIX_TUNING = {
  bellTolled: { intervalS: 6, windupS: 0.9, r: 3, damageMult: 0.6, stunMs: 500 },
  hungering: { intervalS: 4, reach: 5, healFrac: 0.15 },
  shrouded: { damageTakenMult: 0.5 },
  vengeful: { risen: 3 },
};

/**
 * Grave Surges: every 90–150s of combat a crypt cracks open and pours three
 * rapid waves out over 20s. Kill ≥80% of what it spawned for a guaranteed item.
 */
export const SURGE = {
  firstDelayS: 100,
  minIntervalS: 90,
  maxIntervalS: 150,
  durationS: 20,
  /** Seconds after the surge opens that each wave climbs out. */
  waveAtS: [1.5, 7.5, 13.5],
  waveSizeMult: 1.2,
  clearFrac: 0.8,
};

/** Level scaling (areas set the level). */
export function enemyHpScale(level: number) {
  return 1 + 0.22 * (level - 1);
}
export function enemyDamageScale(level: number) {
  return 1 + 0.15 * (level - 1);
}
