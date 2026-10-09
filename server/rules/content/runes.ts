/**
 * Relic runes: socketable spell modifiers (docs/agent-briefs/build-depth-aspects-runes.md §3, server/proposals/relic-runes.md).
 *
 * A rune changes HOW a rite behaves, not how hard it hits. Each of the five necromancer rites has one socket; a rune only fits
 * the rite it was made for. Runes are items (`item_type 'rune'`, stackable) that drop from elites, Grave Surges and bosses, can be
 * kept in the Vault and ground in the Bone Grinder. A socketed rune is an inventory row in a reserved slot (gameplay/runeRules.ts).
 *
 * Every number the sim, the cast code, the tooltips and the Codex use lives in RUNE_TUNING, so the words cannot drift from the game.
 * Item ids equal the icon file names (public/art/items/<id>.webp).
 */
import type { AreaId } from './areas';

export const RUNE_RITES = ['bone_needle', 'marrow_spear', 'exhume', 'miasma', 'black_litany'] as const;
export type RuneRite = (typeof RUNE_RITES)[number];

export const RUNE_IDS = [
  'rune_splinter',
  'rune_marrow_tap',
  'rune_volley',
  'rune_ossuary_ring',
  'rune_impale',
  'rune_mass_grave',
  'rune_bone_colossus',
  'rune_creeping_rot',
  'rune_contagion',
  'rune_hollow_choir',
  'rune_requiem',
] as const;
export type RuneId = (typeof RUNE_IDS)[number];
export type RuneRarity = 'uncommon' | 'rare' | 'epic';

/** The numbers behind every rune (ms, seconds, metres and shares as named). */
export const RUNE_TUNING = {
  /** Bone Needle. */
  splinter: { reach: 6, damageFrac: 0.3 },
  marrowTap: { essenceBonus: 4, damageMult: 0.7 },
  volley: { every: 4, needles: 3, damageFrac: 0.4, reach: 9 },
  /** Marrow Spear: the ring bursts on the cursor, pulled back to the spear's reach. */
  ring: { radius: 3, maxCastRange: 12, damageMult: 0.8 },
  impale: { rootS: 1.5, damageMult: 1.5 },
  /** Exhume. `slots` is how many legion places the colossus fills. */
  massGrave: { count: 3, statMult: 0.75, pickRadius: 4 },
  colossus: {
    corpses: 5,
    minCorpses: 3,
    slots: 2,
    pickRadius: 6,
    hpPerCorpse: 0.8,
    damagePerCorpse: 0.7,
    cleaveRadius: 2.4,
    cleaveFrac: 0.6,
    range: 2.4,
    interval: 1.2,
    speed: 4.8,
    /** Cooldown multiplier on Exhume's 500 ms (4 s), applied only to a cast that raised a Colossus. */
    cooldownMult: 8,
  },
  /** Miasma Circle. */
  creepingRot: { speed: 1.5, radiusMult: 0.85, seekReach: 12 },
  contagion: { neighbours: 2, reach: 4.5, minStacks: 2 },
  /** Black Litany. */
  hollowChoir: { powerMult: 0.6 },
  requiem: { delayMs: 2000, radiusMult: 1.7 },
} as const;

export interface RuneDef {
  id: RuneId;
  name: string;
  rite: RuneRite;
  rarity: RuneRarity;
  sell: number;
  /** Relic-flavoured line for tooltips. */
  lore: string;
  /** One line for lists: the change in a handful of words. */
  short: string;
  /** What exactly changes, one plain sentence each (numbers come from RUNE_TUNING). */
  lines: string[];
  /** The price paid, or null when the rune is strictly a trade of one thing for another. */
  cost: string | null;
}

const pct = (x: number) => `${Math.round(x * 100)}%`;
const T = RUNE_TUNING;

export const RUNES: Record<RuneId, RuneDef> = {
  rune_splinter: {
    id: 'rune_splinter',
    name: 'Rune of Splinters',
    rite: 'bone_needle',
    rarity: 'uncommon',
    sell: 25,
    lore: 'The needle shatters on bone and the shards keep looking.',
    short: 'Hits splinter to a second foe',
    lines: [`When a needle hits, a splinter flies to the nearest other enemy within ${T.splinter.reach} m for ${pct(T.splinter.damageFrac)} of the damage. Under a scythe, each reaping swing throws one splinter, from the nearest enemy it struck to the nearest one it missed.`],
    cost: null,
  },
  rune_marrow_tap: {
    id: 'rune_marrow_tap',
    name: 'Rune of Marrow-Tap',
    rite: 'bone_needle',
    rarity: 'uncommon',
    sell: 25,
    lore: 'Every wound is a spigot.',
    short: 'More essence, softer needle',
    lines: [`Each needle hit returns ${T.marrowTap.essenceBonus} more Grave Essence. Under a scythe, each swing that lands returns ${T.marrowTap.essenceBonus} more once, however many enemies it strikes.`],
    cost: `Needles and scythe swings hit for ${pct(1 - T.marrowTap.damageMult)} less.`,
  },
  rune_volley: {
    id: 'rune_volley',
    name: 'Rune of the Volley',
    rite: 'bone_needle',
    rarity: 'rare',
    sell: 60,
    lore: 'Four breaths, then a flock.',
    short: 'Every 4th needle is a volley',
    lines: [`Every ${T.volley.every}th needle you throw becomes a volley of ${T.volley.needles}, aimed at ${T.volley.needles} different enemies within ${T.volley.reach} m (or all at one target if it stands alone). The volley returns the essence of one needle between them. Needle only: a scythe's swing is not a volley.`],
    cost: `Each volley needle hits for ${pct(T.volley.damageFrac)}.`,
  },
  rune_ossuary_ring: {
    id: 'rune_ossuary_ring',
    name: 'Ossuary Ring Rune',
    rite: 'marrow_spear',
    rarity: 'rare',
    sell: 60,
    lore: 'The dead rise in a circle, like a congregation.',
    short: 'Spikes erupt in a ring',
    lines: [`Instead of a line, bone erupts in a ${T.ring.radius} m ring at the cursor, striking everything inside and applying Fracture and Hemorrhage as usual.`],
    cost: `It no longer reaches down a long line, and strikes for ${pct(T.ring.damageMult)}.`,
  },
  rune_impale: {
    id: 'rune_impale',
    name: 'Rune of Impaling',
    rite: 'marrow_spear',
    rarity: 'uncommon',
    sell: 25,
    lore: 'One thorn, driven deep.',
    short: 'Skewers and roots the first foe',
    lines: [`The spear stops at the first enemy it meets, hits it for ${pct(T.impale.damageMult - 1)} more and roots it for ${T.impale.rootS} s (a boss shrugs the root off but takes the hit).`],
    cost: 'It no longer pierces the line behind.',
  },
  rune_mass_grave: {
    id: 'rune_mass_grave',
    name: 'Mass Grave Rune',
    rite: 'exhume',
    rarity: 'rare',
    sell: 60,
    lore: 'Why dig one grave when the field is full?',
    short: 'Raise up to 3 corpses at once',
    lines: [`Exhume raises up to ${T.massGrave.count} corpses near the cursor at once, each with ${pct(T.massGrave.statMult)} of the usual thrall health and damage.`],
    cost: 'Each thrall is weaker, and it spends more corpses.',
  },
  rune_bone_colossus: {
    id: 'rune_bone_colossus',
    name: 'Bone Colossus Rune',
    rite: 'exhume',
    rarity: 'epic',
    sell: 150,
    lore: 'Five dead, bound as one, and it remembers being a wall.',
    short: 'Five corpses become one giant thrall',
    lines: [
      `When ${T.colossus.minCorpses} or more corpses lie within ${T.colossus.pickRadius} m of the one you name, Exhume consumes up to ${T.colossus.corpses} of them and raises one Bone Colossus instead. With fewer, or while a Colossus stands, it raises an ordinary thrall.`,
      `Its health is ${(T.colossus.hpPerCorpse * T.colossus.corpses).toFixed(1)}x and its damage ${(T.colossus.damagePerCorpse * T.colossus.corpses).toFixed(1)}x a thrall's with five corpses (less with fewer), and every blow cleaves ${T.colossus.cleaveRadius} m.`,
      `It fills ${T.colossus.slots} legion places and you can only keep one: raising another replaces it.`,
    ],
    cost: `Exhume takes ${(500 * T.colossus.cooldownMult) / 1000} s to ready again after raising a Colossus.`,
  },
  rune_creeping_rot: {
    id: 'rune_creeping_rot',
    name: 'Creeping Rot Rune',
    rite: 'miasma',
    rarity: 'uncommon',
    sell: 25,
    lore: 'Rot that has learned to walk.',
    short: 'The circle crawls toward foes',
    lines: [`The circle drifts ${T.creepingRot.speed} m/s toward the nearest enemy within ${T.creepingRot.seekReach} m of it.`],
    cost: `The circle is ${pct(1 - T.creepingRot.radiusMult)} narrower.`,
  },
  rune_contagion: {
    id: 'rune_contagion',
    name: 'Contagion Rune',
    rite: 'miasma',
    rarity: 'rare',
    sell: 60,
    lore: 'It does not stop at the grave.',
    short: 'Dying Withered foes infect others',
    lines: [`A Withered enemy that dies spreads its Withered stacks (minus one) to the ${T.contagion.neighbours} nearest enemies within ${T.contagion.reach} m, and those spread it again when they die (it needs ${T.contagion.minStacks} stacks to jump).`],
    cost: null,
  },
  rune_hollow_choir: {
    id: 'rune_hollow_choir',
    name: 'Hollow Choir Rune',
    rite: 'black_litany',
    rarity: 'rare',
    sell: 60,
    lore: 'The dead sing, and are not spent.',
    short: 'Your thralls sing instead of dying',
    lines: ['Black Litany no longer sacrifices your thralls. They still lend their voices to its power.'],
    cost: `The burst hits for ${pct(1 - T.hollowChoir.powerMult)} less.`,
  },
  rune_requiem: {
    id: 'rune_requiem',
    name: 'Requiem Rune',
    rite: 'black_litany',
    rarity: 'epic',
    sell: 150,
    lore: 'A hymn is only terrible once it is finished.',
    short: 'The burst lands 2 s later, twice as wide',
    lines: [`Black Litany marks the ground, then bursts ${T.requiem.delayMs / 1000} s later over ${T.requiem.radiusMult}x the radius. Corpses and thralls are consumed when it bursts.`],
    cost: 'Enemies can walk out of it, and it can take more of your thralls.',
  },
};

export const RUNE_ORDER: RuneId[] = [...RUNE_IDS];

export const isRuneId = (id: unknown): id is RuneId => typeof id === 'string' && Object.prototype.hasOwnProperty.call(RUNES, id);
export const isRuneRite = (id: unknown): id is RuneRite => typeof id === 'string' && (RUNE_RITES as readonly string[]).includes(id);
export const runesFor = (rite: RuneRite): RuneDef[] => RUNE_ORDER.map((id) => RUNES[id]).filter((r) => r.rite === rite);

// --- Where runes drop -----------------------------------------------------------------------------------------------

/** Every rune of a rarity. */
const byRarity = (...rarities: RuneRarity[]): RuneId[] => RUNE_ORDER.filter((id) => (rarities as string[]).includes(RUNES[id].rarity));

/**
 * The pool an ordinary elite or Grave Surge in a hunting ground rolls from: the first grounds shed uncommon runes only, the
 * middle ones add rares, the deep ones (Bell Sanctum onward) may shed an epic. Safe grounds shed none.
 */
export const AREA_RUNE_POOL: Partial<Record<AreaId, RuneId[]>> = {
  graves: byRarity('uncommon'),
  ossuary: byRarity('uncommon', 'rare'),
  nave: byRarity('uncommon', 'rare'),
  sanctum: byRarity('uncommon', 'rare', 'epic'),
  cloister: byRarity('uncommon', 'rare', 'epic'),
  pyre: byRarity('uncommon', 'rare', 'epic'),
  fen: byRarity('uncommon', 'rare', 'epic'),
  warren: byRarity('uncommon', 'rare'),
  coliseum: byRarity('uncommon', 'rare', 'epic'),
};

/** Epic runes count a third as often as the others in an area pool. */
export const RUNE_WEIGHT: Record<RuneRarity, number> = { uncommon: 3, rare: 2, epic: 1 };

/**
 * The chance an elite kill sheds a rune, before Wave Speed and fortune, by hunting ground (owner, 3 Oct 2026: "where do you get them?").
 * It was a flat 0.6%: about one rune in 2,000-4,700 kills, which nobody ever saw. Now 5% in the Hollow Graves, one point more per rung
 * of the descent, 12% in the Mourning Fen (about one rune per 15-60 minutes of ordinary hunting, sooner in the deep grounds).
 */
export const ELITE_RUNE_CHANCE_BY_AREA: Partial<Record<AreaId, number>> = {
  graves: 0.05, warren: 0.055, ossuary: 0.06, nave: 0.07, coliseum: 0.08, sanctum: 0.09, cloister: 0.1, pyre: 0.11, fen: 0.12,
};
/** The first ground's chance: the floor every other ground builds on. */
export const ELITE_RUNE_CHANCE = ELITE_RUNE_CHANCE_BY_AREA.graves!;
export const eliteRuneChance = (area: AreaId): number => ELITE_RUNE_CHANCE_BY_AREA[area] ?? ELITE_RUNE_CHANCE;
/** The chance a Grave Surge offering is a rune instead of the area's item. */
export const SURGE_RUNE_CHANCE = 0.35;
/** The chance a repeat boss kill leaves a rune (the first kill, and the Prelate, always do). */
export const BOSS_REPEAT_RUNE_CHANCE = 0.5;

/** What each boss may leave (docs/agent-briefs/build-depth-aspects-runes.md §3.4); later bosses draw from everything their predecessors do. */
export const BOSS_RUNE_POOL: Record<string, RuneId[]> = {
  gravedigger: ['rune_splinter', 'rune_marrow_tap', 'rune_mass_grave'],
  abbess: ['rune_ossuary_ring', 'rune_impale', 'rune_bone_colossus', 'rune_volley'],
  congregation: ['rune_creeping_rot', 'rune_contagion', 'rune_hollow_choir'],
  prelate: ['rune_requiem', ...RUNE_ORDER],
  saint: ['rune_creeping_rot', 'rune_contagion', 'rune_hollow_choir', 'rune_requiem', 'rune_bone_colossus'],
  regent: [...RUNE_ORDER],
  mire: [...RUNE_ORDER],
};

/** A weighted pick from a pool of rune ids (epics are rarer). `rand` returns [0, 1). */
export function pickRune(pool: readonly RuneId[], rand: () => number): RuneId | null {
  if (!pool.length) return null;
  const weights = pool.map((id) => RUNE_WEIGHT[RUNES[id].rarity]);
  let roll = rand() * weights.reduce((a, b) => a + b, 0);
  for (let i = 0; i < pool.length; i++) {
    roll -= weights[i];
    if (roll < 0) return pool[i];
  }
  return pool[pool.length - 1];
}

/** Where a rune can be found, in words (the Codex says this for a rune you have not found yet). */
export function runeSources(id: RuneId): string {
  const bosses = Object.entries(BOSS_RUNE_POOL).filter(([, pool]) => pool.includes(id) && !(pool.length === RUNE_ORDER.length + 1)).map(([b]) => b);
  const names: Record<string, string> = { gravedigger: 'the Gravedigger King', abbess: 'the Bone Abbess', congregation: 'the Drowned Congregation', saint: 'the Plague Saint' };
  const from = bosses.filter((b) => names[b]).map((b) => names[b]);
  const rarity = RUNES[id].rarity;
  const grounds = rarity === 'uncommon' ? 'any hunting ground' : rarity === 'rare' ? 'the Marrow Ossuary and deeper' : 'the Bell Sanctum and deeper';
  return `${from.length ? `${from.join(', ')}; ` : ''}elites and Grave Surges in ${grounds}; chests in the Catacomb Depths${rarity === 'epic' ? ' (from depth 10)' : ''}`;
}
