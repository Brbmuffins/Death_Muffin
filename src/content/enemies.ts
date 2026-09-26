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
    hp: 42,
    speed: 2.6,
    radius: 0.45,
    damage: 7,
    attackRange: 1.3,
    windupMs: 420,
    cooldownMs: 1300,
    xp: 6,
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
    hp: 26,
    speed: 4.4,
    radius: 0.45,
    damage: 5,
    attackRange: 1.2,
    windupMs: 250,
    cooldownMs: 800,
    xp: 5,
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
    hp: 48,
    speed: 1.9,
    radius: 0.5,
    damage: 13,
    attackRange: 7.5,
    windupMs: 1100,
    cooldownMs: 3200,
    xp: 9,
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
    hp: 90,
    speed: 1.3,
    radius: 0.8,
    damage: 10,
    attackRange: 1.6,
    windupMs: 700,
    cooldownMs: 1800,
    xp: 12,
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
    hp: 70,
    speed: 2.0,
    radius: 0.5,
    damage: 6,
    attackRange: 6,
    windupMs: 1500,
    cooldownMs: 5500,
    xp: 14,
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
    hp: 24,
    speed: 2.9,
    radius: 0.42,
    damage: 5,
    attackRange: 1.2,
    windupMs: 380,
    cooldownMs: 1200,
    xp: 3,
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

/** Level scaling (areas set the level). */
export function enemyHpScale(level: number) {
  return 1 + 0.22 * (level - 1);
}
export function enemyDamageScale(level: number) {
  return 1 + 0.13 * (level - 1);
}
