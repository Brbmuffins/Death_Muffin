/**
 * Enemy roster (audit "Minimum enemy roster"): five behaviours that create
 * target priority and make corpse ownership matter, plus the Risen that a
 * Crypt Deacon raises from corpses you didn't claim in time.
 */
export type EnemyId = 'robber' | 'hound' | 'penitent' | 'sac' | 'deacon' | 'risen';
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
}

export const ENEMIES: Record<EnemyId, EnemyDef> = {
  robber: {
    id: 'robber',
    name: 'Grave Robber',
    behavior: 'melee',
    rig: 'humanoid',
    hp: 48,
    speed: 2.6,
    radius: 0.45,
    damage: 9,
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
    hp: 30,
    speed: 4.4,
    radius: 0.45,
    damage: 6,
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
    hp: 56,
    speed: 1.9,
    radius: 0.5,
    damage: 16,
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
    hp: 100,
    speed: 1.3,
    radius: 0.8,
    damage: 12,
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
    hp: 80,
    speed: 2.0,
    radius: 0.5,
    damage: 7,
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
    hp: 26,
    speed: 2.9,
    radius: 0.42,
    damage: 6,
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
