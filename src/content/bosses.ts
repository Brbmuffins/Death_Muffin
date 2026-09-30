import type { AreaId } from './areas';

/**
 * A boss for every area (docs/agent-briefs/area-bosses.md). One awake boss per world. The Bell-Sworn Prelate keeps
 * its numbers; the three new bosses each have one mechanic that matters (graves / niches + corpses / pews).
 * Colours are enemy language only.
 */
export type BossId = 'prelate' | 'gravedigger' | 'abbess' | 'congregation' | 'saint' | 'regent';
export const BOSS_IDS: BossId[] = ['gravedigger', 'abbess', 'congregation', 'prelate', 'saint', 'regent'];

export interface BossDef {
  id: BossId;
  name: string;
  title: string;
  area: AreaId;
  arena: { x: number; z: number; r: number };
  /** The interactable that summons it (areas.ts). */
  summonId: string;
  summonLabel: string;
  shards: number;
  baseHp: number;
  modelSlug: 'prelate' | 'boss_gravedigger_king' | 'boss_bone_abbess' | 'boss_drowned_congregation' | 'boss_plague_saint' | 'boss_cinder_regent';
  portrait: string;
  /** Aura light + particle colour for the view. */
  color: number;
  /** HUD subtitle per phase (1–3). */
  phases: [string, string, string];
  /** Awaken / defeat banners. */
  awaken: string;
  defeated: [string, string];
}

export const BOSSES: Record<BossId, BossDef> = {
  gravedigger: {
    id: 'gravedigger',
    name: 'The Gravedigger King',
    title: 'Lord of the Hollow Graves',
    area: 'graves',
    arena: { x: -14, z: -22, r: 10 },
    summonId: 'kings_grave',
    summonLabel: "The King's Grave",
    shards: 2,
    baseHp: 15500,
    modelSlug: 'boss_gravedigger_king',
    portrait: 'art/portraits/boss_gravedigger_king.webp',
    color: 0xe0a458,
    phases: ['He digs', 'The graves give up their dead', 'Every grave is open'],
    awaken: 'The King climbs out of his own grave',
    defeated: ['The King Is Buried', 'The Hollow Graves fall quiet, for now'],
  },
  abbess: {
    id: 'abbess',
    name: 'The Bone Abbess',
    title: 'Keeper of the Marrow Ossuary',
    area: 'ossuary',
    arena: { x: 48, z: -24, r: 10 },
    summonId: 'abbess_reliquary',
    summonLabel: "The Abbess's Reliquary",
    shards: 3,
    baseHp: 13000,
    modelSlug: 'boss_bone_abbess',
    portrait: 'art/portraits/boss_bone_abbess.webp',
    color: 0xc8a06a,
    phases: ['The niches sing', 'The chorus doubles', 'The Abbess rebuilds'],
    awaken: 'The skull niches begin to sing',
    defeated: ['The Chorus Breaks', 'The Abbess returns to her reliquary'],
  },
  congregation: {
    id: 'congregation',
    name: 'The Drowned Congregation',
    title: 'Choir of the Drowned Nave',
    area: 'nave',
    arena: { x: 0, z: -61, r: 11 },
    summonId: 'drowned_font',
    summonLabel: 'The Drowned Font',
    shards: 4,
    baseHp: 19000,
    modelSlug: 'boss_drowned_congregation',
    portrait: 'art/portraits/boss_drowned_congregation.webp',
    color: 0x8fb4c8,
    phases: ['The hymn begins', 'The water rises', 'The flood hymn'],
    awaken: 'The nave water begins to rise',
    defeated: ['The Hymn Ends', 'The Congregation sinks back into the black water'],
  },
  saint: {
    id: 'saint',
    name: 'The Plague Saint',
    title: 'Mother of the Blight',
    area: 'cloister',
    arena: { x: 44, z: -121, r: 10 },
    summonId: 'saints_litter',
    summonLabel: "The Saint's Litter",
    shards: 5,
    baseHp: 24000,
    modelSlug: 'boss_plague_saint',
    portrait: '',
    color: 0x9cc43a,
    phases: ['The blight blesses her', 'Her flock gathers', 'The swarm'],
    awaken: 'The Saint rises from her litter',
    defeated: ['The Blight Recedes', 'The Plague Saint sinks back into her reliquary'],
  },
  regent: {
    id: 'regent',
    name: 'The Cinder Regent',
    title: 'Ember-Crowned Keeper of the Pyre',
    area: 'pyre',
    arena: { x: 90, z: -117, r: 11 },
    summonId: 'ember_altar',
    summonLabel: 'The Ember Altar',
    shards: 6,
    baseHp: 28000,
    modelSlug: 'boss_cinder_regent',
    portrait: '',
    color: 0xff7a2a,
    phases: ['The crown ignites', 'The pyre feeds', 'The pyre burns down'],
    awaken: 'The Regent rises from the embers',
    defeated: ['The Pyre Burns Out', 'The Cinder Regent crumbles to ash'],
  },
  prelate: {
    id: 'prelate',
    name: 'The Bell-Sworn Prelate',
    title: 'The Sundered Bell',
    area: 'sanctum',
    arena: { x: 0, z: -116, r: 13 },
    summonId: 'sundered_bell',
    summonLabel: 'The Sundered Bell',
    shards: 5,
    baseHp: 26000,
    modelSlug: 'prelate',
    portrait: 'art/portraits/prelate.webp',
    color: 0xa26bff,
    phases: ['The bell is silent', 'The procession begins', 'The bell is breaking'],
    awaken: 'The Sundered Bell tolls for you',
    defeated: ['The Bell Falls Silent', 'The Prelate is unmade — for now'],
  },
};

export const bossForSummon = (id: string): BossId | undefined => BOSS_IDS.find((b) => BOSSES[b].summonId === id);
export const isBossId = (v: unknown): v is BossId => typeof v === 'string' && (BOSS_IDS as string[]).includes(v);

/** A point on a boss arena's rim (fraction of its radius), angle measured like `atan2(dx, dz)`. */
export function arenaRim(id: BossId, angle: number, frac = 0.85): [number, number] {
  const a = BOSSES[id].arena;
  return [a.x + Math.sin(angle) * a.r * frac, a.z + Math.cos(angle) * a.r * frac];
}
/** Fixed spots shared by the layout (kept clear) and the brains. */
export const ABBESS_NICHE_SPOTS = [0, 1, 2, 3].map((i) => arenaRim('abbess', Math.PI / 4 + (i * Math.PI) / 2, 0.75));
export const GRAVEDIGGER_PITS = [0, 1, 2, 3].map((i) => arenaRim('gravedigger', Math.PI / 4 + (i * Math.PI) / 2, 0.55));
/** The summon objects stand at each arena's north edge (−z). */
export const summonSpot = (id: BossId): [number, number] => arenaRim(id, Math.PI, 0.85);

/** Gravedigger King. */
export const GRAVEDIGGER = {
  sweep: { r: 4.5, halfDeg: 50, windupMs: 900, dmg: 18, cd: 3.4 },
  burial: { hw: 0.6, hd: 1.2, windupMs: 1400, dmg: 12, rootS: 2, cd: 7 },
  exhume: { everyS: 14, ghouls: 2 },
  pits: { r: 1.2, reburyS: 3 },
};
/** Bone Abbess. */
export const ABBESS = {
  niches: 4,
  nicheHpFrac: 0.07,
  regenPerS: 0.0025,
  nicheBreakFrac: 0.04,
  lance: { everyS: 8, windupMs: 1200, len: 11, halfWidth: 0.8, dmg: 20 },
  chorus: { spokes: 8, len: 9, halfWidth: 0.7, windupMs: 1200, dmg: 22, cd: 9, rotateDeg: 22.5 },
  grasp: { r: 3.5, halfDeg: 55, windupMs: 700, dmg: 18, cd: 3 },
  communion: { channelS: 4, healPerCorpse: 0.01, cd: 16 },
};
/** Plague Saint (level-scaled with the Cloister). */
export const SAINT = {
  rain: { circles: [3, 5] as [number, number], r: 2, windupMs: 1400, dmg: 24, cd: 7, poolS: 6, poolSP3: 9, poolDpsMult: 0.3 },
  swing: { r: 4.5, halfDeg: 60, windupMs: 900, dmg: 26, cd: 3 },
  blessing: { healPerS: 0.006 },
  /** Plague Doctors near the arena feed her through a visible link: kill them (priority target) to cut it. */
  doctors: { healPerS: 0.001, beatS: 0.9 },
};

/**
 * Cinder Regent (Cinder Pyre, level-scaled). Coals mark circles that burn on; Cinder Cleave lays a firebreak down its
 * line; and the signature, Conflagration: the whole arena erupts unless you are standing on ash. Ash circles are
 * marked grey-white for the whole windup, so the fight is about reading the floor and getting there in time.
 */
export const REGENT = {
  coals: { circles: [4, 6] as [number, number], r: 1.8, windupMs: 1200, dmg: 22, cd: 7, poolS: 4, poolDpsMult: 0.3 },
  cleave: { r: 5.2, halfDeg: 60, windupMs: 900, dmg: 28, cd: 3, trail: [1.9, 3.7, 5.5], trailR: 1.4, trailS: 5, trailDpsMult: 0.3 },
  /** `safe` ash circles per phase (plus one per three extra players); the rest of the arena burns for `dmg`. */
  conflagration: { safe: [4, 3, 2] as [number, number, number], safeR: 2.7, windupMs: 2700, dmg: 46, cd: 15, embers: 4, emberS: 4 },
  /** Phase adds ring the arena on the change. */
  adds: { p2: ['cinder_husk', 'cinder_husk', 'cinder_husk', 'pyre_priest', 'pyre_priest'], p3: ['cinderhound', 'cinderhound', 'cinder_husk', 'cinder_husk'] } as const,
};

/** Drowned Congregation. */
export const CONGREGATION = {
  hymn: { halfDeg: 60, reach: 15, windupMs: 2200, dmgMult: 1.8, base: 18, cd: 11, soakedMult: 1.2 },
  grasp: { rings: [3, 5] as [number, number], r: 1.4, windupMs: 1300, dmg: 14, rootS: 1, cd: 7 },
  water: { dais: 3.2, slowP2: 0.85, slowP3: 0.7 },
  melee: { r: 3, halfDeg: 55, windupMs: 800, dmg: 18, cd: 3.2 },
};
