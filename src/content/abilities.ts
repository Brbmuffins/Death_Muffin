/**
 * The shared necromancer kit. Data only — behaviour lives in
 * gameplay/AbilitySystem.ts. `power` multiplies the caster's spell power.
 */
export type AbilityId =
  | 'bone_needle'
  | 'marrow_spear'
  | 'exhume'
  | 'miasma'
  | 'black_litany'
  | 'corpse_explosion'
  // Discipline signature rites (level 10, key R / 6).
  | 'ossuary_wall'
  | 'command_rend'
  | 'dirge'
  | 'plague_bloom';
export type Targeting = 'enemy' | 'direction' | 'corpse' | 'ground' | 'self';
/** Hotbar position: 1–4 = number keys, 5 = right-click (also key 5), 6 = the discipline's signature (R / 6). */
export type HotbarSlot = 1 | 2 | 3 | 4 | 5 | 6;

export interface AbilityDef {
  id: AbilityId;
  /** 0 = primary (left click), 1–4 = hotbar keys, 5 = right-click, 6 = signature. */
  slot: 0 | HotbarSlot;
  name: string;
  description: string;
  icon: string;
  targeting: Targeting;
  cooldownMs: number;
  essenceCost: number;
  range: number;
  radius: number;
  power: number;
}

export const ABILITIES: Record<AbilityId, AbilityDef> = {
  bone_needle: {
    id: 'bone_needle',
    slot: 0,
    name: 'Bone Needle',
    description: 'Fling a sliver of marrow. Each hit returns 6 Grave Essence.',
    icon: 'art/abilities/necro-needle.png',
    targeting: 'enemy',
    cooldownMs: 380,
    essenceCost: 0,
    range: 11,
    radius: 0.35,
    power: 1.0,
  },
  marrow_spear: {
    id: 'marrow_spear',
    slot: 1,
    name: 'Marrow Spear',
    description: 'A line of bone erupts toward the cursor, piercing everything and applying Fracture (+15% damage taken, 3 stacks).',
    icon: 'art/abilities/necro-spear.png',
    targeting: 'direction',
    cooldownMs: 2200,
    essenceCost: 18,
    range: 12,
    radius: 0.9,
    power: 2.1,
  },
  exhume: {
    id: 'exhume',
    slot: 2,
    name: 'Exhume',
    description: 'Consume the corpse nearest the cursor and raise it as your thrall. At the cap, your oldest thrall crumbles.',
    icon: 'art/abilities/necro-exhume.png',
    targeting: 'corpse',
    cooldownMs: 500,
    essenceCost: 12,
    range: 13,
    radius: 3.2,
    power: 0,
  },
  miasma: {
    id: 'miasma',
    slot: 3,
    name: 'Miasma Circle',
    description: 'Seed rot at the cursor for 6s. Enemies inside are slowed 40% and gain a Withered stack each second.',
    icon: 'art/abilities/necro-miasma.png',
    targeting: 'ground',
    cooldownMs: 7000,
    essenceCost: 25,
    range: 14,
    radius: 3.8,
    power: 0.22,
  },
  black_litany: {
    id: 'black_litany',
    slot: 4,
    name: 'Black Litany',
    description: 'Consume every corpse and sacrifice every thrall within 7m in one ritual burst. Power grows with what you give.',
    icon: 'art/abilities/necro-litany.png',
    targeting: 'self',
    cooldownMs: 14000,
    essenceCost: 40,
    range: 0,
    radius: 7,
    power: 1.5,
  },
  corpse_explosion: {
    id: 'corpse_explosion',
    slot: 5,
    name: 'Corpse Explosion',
    description:
      'Right-click a corpse to burst it in a 3m blast of marrow and bone. Resonant corpses blast wider, toxic corpses leave a rot pool, elite corpses hit twice as hard.',
    // Placeholder art until a dedicated icon exists (the HUD re-tints it ember).
    icon: 'art/abilities/necro-litany.png',
    targeting: 'corpse',
    cooldownMs: 600,
    essenceCost: 15,
    range: 13,
    /** Blast radius; the sim owns it (clients never send a radius). */
    radius: 3,
    power: 1.8,
  },
  // --- Signature rites: one per discipline, unlocked at SIGNATURE_LEVEL. Icons are retinted
  // placeholders until dedicated art is generated (ASSET_PIPELINE.md).
  ossuary_wall: {
    id: 'ossuary_wall',
    slot: 6,
    name: 'Ossuary Wall',
    description: 'Raise a 7m wall of fused bone across the cursor line for 6s. The dead cannot pass it and Penitent cones break on it.',
    icon: 'art/abilities/necro-spear.png',
    targeting: 'direction',
    cooldownMs: 16000,
    essenceCost: 30,
    range: 10,
    radius: 3.5,
    power: 0,
  },
  command_rend: {
    id: 'command_rend',
    slot: 6,
    name: 'Command: Rend',
    description: 'Your whole legion leaps to the cursor and cleaves everything around it. Costs each thrall 15% of its health instead of essence.',
    icon: 'art/abilities/necro-exhume.png',
    targeting: 'ground',
    cooldownMs: 9000,
    essenceCost: 0,
    range: 13,
    radius: 2.2,
    power: 0,
  },
  dirge: {
    id: 'dirge',
    slot: 6,
    name: 'Dirge',
    description: 'Toll a 4s funeral bell-song around you: you and your thralls mend each second, and enemy casters inside are Silenced.',
    icon: 'art/abilities/necro-litany.png',
    targeting: 'self',
    cooldownMs: 18000,
    essenceCost: 35,
    range: 0,
    radius: 6,
    power: 0.6,
  },
  plague_bloom: {
    id: 'plague_bloom',
    slot: 6,
    name: 'Plague Bloom',
    description: 'Plant a rot flower at the cursor. It pulses Withered and every 2s seeds a new bloom on the nearest corpse, chaining through the corpse field.',
    icon: 'art/abilities/necro-miasma.png',
    targeting: 'ground',
    cooldownMs: 12000,
    essenceCost: 28,
    range: 14,
    radius: 2.4,
    power: 0.3,
  },
};

/** Level at which each discipline's signature rite unlocks. */
export const SIGNATURE_LEVEL = 10;

/** Each discipline's signature rite (DisciplineId → ability). */
export const SIGNATURE_BY_DISCIPLINE = {
  ossuary: 'ossuary_wall',
  gravecaller: 'command_rend',
  mourner: 'dirge',
  rotweaver: 'plague_bloom',
} as const satisfies Record<string, AbilityId>;

export type SignatureKind = 'wall' | 'rend' | 'dirge' | 'bloom';
export const SIGNATURE_KIND: Partial<Record<AbilityId, SignatureKind>> = {
  ossuary_wall: 'wall',
  command_rend: 'rend',
  dirge: 'dirge',
  plague_bloom: 'bloom',
};

/** Host-side tuning for the signature rites (the intent carries only aim + spell power). */
export const SIGNATURE = {
  wall: { length: 7, thickness: 0.8, durationS: 6, maxCastRange: 11 },
  rend: { cleaveRadius: 2.2, damageMult: 2.5, hpCost: 0.15, maxCastRange: 14 },
  dirge: { radius: 6, durationS: 4, thrallHealFrac: 0.08, silenceS: 1.2 },
  bloom: { radius: 2.4, durationS: 8, spreadEveryS: 2, spreadReach: 6, maxGenerations: 3, childDurationS: 6, witheredCap: 8, maxCastRange: 15 },
};

/** Hotbar order; index + 1 is the HotbarSlot. Slot 5 is the right-click action. */
export const HOTBAR: AbilityId[] = ['marrow_spear', 'exhume', 'miasma', 'black_litany', 'corpse_explosion'];

/** Corpse Explosion tuning (host-side; the intent only carries the caster's damage). */
export const DETONATE = {
  radius: 3,
  resonantRadiusMult: 1.6,
  eliteDamageMult: 2,
  /** Sim-side clamp on the damage a client may claim (mirrors the realtime server). */
  maxDamage: 100000,
  /** Toxic corpses leave a friendly rot pool: radius, duration, dps as a share of the blast. */
  rotRadius: 2.6,
  rotDurationMs: 4000,
  rotDpsShare: 0.12,
  rotWitheredCap: 5,
};

/** Soul Harvest (client-side): kills fill the meter; when full the next big spell is free and 50% larger. */
export const SOUL_HARVEST = {
  souls: 50,
  areaMult: 1.5,
  spells: ['marrow_spear', 'miasma', 'black_litany'] as AbilityId[],
};

/** Litany scaling: added spell-power multiples per consumed corpse / thrall. */
export const LITANY_PER_CORPSE = 0.6;
export const LITANY_PER_RESONANT = 1.2;
export const LITANY_PER_THRALL = 1.4;
export const LITANY_MAX_MULT = 14;

export const FRACTURE = { perStack: 0.15, maxStacks: 3, durationMs: 5000 };
export const WITHERED = { dpsPerStack: 0.18, durationMs: 5000 };
export const MIASMA_SLOW = 0.6;
export const NEEDLE_ESSENCE = 6;

/**
 * Per-spell colour identity (user direction: spells must not all read as dark
 * purple). Violet is reserved for the signature ultimate; the rest spread
 * across bone, marrow, spirit and rot so a crowded fight stays legible.
 */
export const SPELL_FX = {
  needle: { core: 0xf3e8d2, trail: 0xe9c98f, impact: 0xfff1d6, dust: 0xd8cfbd },
  spear: { bone: 0xe0d6c2, crack: 0xb4502e, dust: 0x4a3a30, marrow: 0x8a2c3c },
  exhume: { spirit: 0x6fe3c8, deep: 0x1f8f86, beam: 0x9ff5e0 },
  miasma: { rot: 0xa8c23a, deep: 0x4f6b1f, spore: 0x2b3317 },
  litany: { core: 0x9b5cff, hot: 0xe6d6ff, void: 0x160a24 },
  /** Corpse Explosion — marrow: ember + dried crimson, with bone shrapnel. */
  detonate: { ember: 0xff6a2a, hot: 0xffc58a, crimson: 0x8a2c3c, bone: 0xe0d6c2, smoke: 0x2a1614 },
  /** Soul Harvest — spirit: jade/teal. */
  souls: { jade: 0x6fe3c8, deep: 0x1f8f86, pale: 0x9ff5e0 },
  thrall: { spark: 0xe8dfcc, wraith: 0x8fb4ff },
  enemy: { toll: 0xd9a441, rot: 0x7fa05a, curse: 0x8a3a4a, slam: 0x9a6a3a, toxic: 0x6f8f3a },
  /** Elite affix tells (bell = bronze, hunger = olive rot, shroud = grave dusk, vengeance = ember). */
  affix: { bell: 0xd9a441, drool: 0x8a8f2a, shroud: 0x3a3448, vengeful: 0xe0552a },
  /** Grave Surge — enemy bell/crypt bronze. */
  surge: { crack: 0xc8923a, glow: 0xd9a441 },
  boss: { bronze: 0xd9a441, shard: 0xc8a06a, spirit: 0xb9c8ff },
  /** Signature rites: Ossuary Wall = bone ivory/amber, Rend = spirit jade, Dirge = Mourner cold blue, Bloom = rot chartreuse. */
  wall: { bone: 0xe8dcc0, amber: 0xd9a66b, dust: 0x6a5a48 },
  rend: { jade: 0x6fe3c8, pale: 0xc8fff0, bone: 0xe0d6c2 },
  dirge: { frost: 0x9fc4ff, deep: 0x5b7fd6, pale: 0xdde8ff },
  bloom: { petal: 0xc7e04a, rot: 0x6f8f22, spore: 0x2b3317 },
} as const;
