/**
 * The shared necromancer kit. Data only — behaviour lives in
 * gameplay/AbilitySystem.ts. `power` multiplies the caster's spell power.
 */
export type AbilityId = 'bone_needle' | 'marrow_spear' | 'exhume' | 'miasma' | 'black_litany';
export type Targeting = 'enemy' | 'direction' | 'corpse' | 'ground' | 'self';

export interface AbilityDef {
  id: AbilityId;
  /** 0 = primary (left click), 1–4 = hotbar keys. */
  slot: 0 | 1 | 2 | 3 | 4;
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
};

export const HOTBAR: AbilityId[] = ['marrow_spear', 'exhume', 'miasma', 'black_litany'];

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
  thrall: { spark: 0xe8dfcc, wraith: 0x8fb4ff },
  enemy: { toll: 0xd9a441, rot: 0x7fa05a, curse: 0x8a3a4a, slam: 0x9a6a3a, toxic: 0x6f8f3a },
  boss: { bronze: 0xd9a441, shard: 0xc8a06a, spirit: 0xb9c8ff },
} as const;
