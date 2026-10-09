import type { AreaId } from './areas';

/**
 * Legendary armor sets (docs/LEGENDARY-SETS.md): one rare, build-defining set per necromancer discipline. The pieces are built into
 * ARMOR_PIECES (armorSets.ts, collection 3); the bonuses are in setBonuses.ts; this file holds the names and the drop rules, which
 * are pure so the client (loot.ts) and the server's ground-rate ceiling (authorityRules.ts) read the same numbers.
 */
export type LegendaryPart = 'head' | 'chest' | 'hands' | 'legs' | 'feet';
const PARTS: LegendaryPart[] = ['head', 'chest', 'hands', 'legs', 'feet'];

export interface LegendarySet {
  /** The discipline this set is built for (its "own" set for smart loot). */
  disciplineId: string;
  name: string;
  wearer: string;
  color: number;
  accent: number;
  stats: readonly [string, string];
  lore: string;
  /** Piece names, head to feet. */
  pieces: Record<LegendaryPart, string>;
}

export const LEGENDARY_SETS: Record<string, LegendarySet> = {
  legion_unburied: {
    disciplineId: 'gravecaller', name: 'Legion of the Unburied', wearer: 'Gravecaller', color: 0x3a1f2b, accent: 0xff7a3d, stats: ['stat_int', 'stat_vit'],
    lore: 'Forged for the one who never lets the dead lie. The legion marches in its wearer’s footsteps, and does not stop.',
    pieces: { head: 'Warcrown of the Unburied', chest: 'Cuirass of the Unburied', hands: 'Gauntlets of the Unburied', legs: 'Greaves of the Unburied', feet: 'Marching Boots of the Unburied' },
  },
  colossus_mantle: {
    disciplineId: 'ossuary', name: 'Colossus Mantle', wearer: 'Ossuary', color: 0x7d7255, accent: 0xf2d98a, stats: ['stat_int', 'stat_vit'],
    lore: 'A giant’s ribs, hung with every vow the Covenant ever broke. What strikes the wearer is struck back.',
    pieces: { head: 'Colossus Cowl', chest: 'Colossus Mantle', hands: 'Colossus Fists', legs: 'Colossus Cuisses', feet: 'Colossus Footings' },
  },
  requiem_wraiths: {
    disciplineId: 'mourner', name: 'Requiem of Wraiths', wearer: 'Mourner', color: 0x2c4a5e, accent: 0x7fe3ff, stats: ['stat_int', 'stat_agi'],
    lore: 'Woven from the last breath of the mourned. The wraiths still sing in it, and some of them stay to help.',
    pieces: { head: 'Wraithveil Hood', chest: 'Requiem Shroud', hands: 'Wraithgrasp Gloves', legs: 'Wraithwoven Leggings', feet: 'Requiem Slippers' },
  },
  plague_choir: {
    disciplineId: 'rotweaver', name: 'Plague Choir', wearer: 'Rotweaver', color: 0x3d4a1c, accent: 0xb6ff4d, stats: ['stat_int', 'stat_vit'],
    lore: 'Sung into being by a congregation that died of its own hymn. Every note it carries is catching.',
    pieces: { head: 'Choirmaster’s Mask', chest: 'Plague Choir Surplice', hands: 'Blightmonger’s Gloves', legs: 'Choir Rotleggings', feet: 'Plague Choir Treads' },
  },
};

export const LEGENDARY_SET_IDS = Object.keys(LEGENDARY_SETS);
export const legendaryItemId = (setId: string, part: LegendaryPart): string => `leg_${setId}_${part}`;
/** The set built for a discipline, if it has one yet (necromancer first; other families get theirs later). */
export const legendarySetFor = (disciplineId: string): string | undefined => LEGENDARY_SET_IDS.find((id) => LEGENDARY_SETS[id].disciplineId === disciplineId);

// --- Drop rules ----------------------------------------------------------------------------------------------------------------------
export const LEGENDARY_DROP = {
  /**
   * Per boss kill, the SHALLOWEST rolling boss (the Bone Abbess); deeper bosses climb from here (`LEGENDARY_BOSS_CHANCE`). Owner, 3 Oct 2026:
   * "drop rates are like 3%... let's make it more achievable": it was a flat 15% (and 3% for the Gravedigger King), which the Atlas
   * showed as about 2% per piece.
   */
  bossChance: 0.2,
  /** Per Gravedigger King kill (the starter boss, Hollow Graves): lower, so the first legendary can be seen early (owner, 3 Oct 2026). */
  starterBossChance: 0.06,
  /** Per elite kill in the SHALLOWEST level-scaled area (Plague Cloister); the Pyre and the Fen climb from here (`LEGENDARY_ELITE_CHANCE`). */
  eliteChance: 0.005,
  /** Smart loot: the share of legendary drops that is the player's own discipline's set (the rest splits evenly over the others). */
  ownShare: 0.7,
} as const;

/** Bosses roll from every area but the first (the Hollow Graves are too early for build-defining gear). */
export const LEGENDARY_BOSS_AREAS: readonly AreaId[] = ['ossuary', 'nave', 'sanctum', 'cloister', 'pyre', 'fen'];
/** The starter boss's area: legendaries drop there at the lower starterBossChance. */
export const LEGENDARY_STARTER_AREA: AreaId = 'graves';

/** Legendary chance per boss kill, by area: deeper bosses leave more (drops get better as you descend). */
export const LEGENDARY_BOSS_CHANCE: Partial<Record<AreaId, number>> = { ossuary: 0.2, nave: 0.22, sanctum: 0.25, cloister: 0.28, pyre: 0.3, fen: 0.33 };
/** Legendary chance per elite kill, by level-scaled ground. */
export const LEGENDARY_ELITE_CHANCE: Partial<Record<AreaId, number>> = { cloister: 0.005, pyre: 0.007, fen: 0.009 };

/** Legendary chance for one boss kill in `area` (owner, 3 Oct 2026: 20% at the Abbess rising to 33% in the Fen, 6% for the Gravedigger King). */
export const legendaryBossChance = (area: AreaId): number =>
  LEGENDARY_BOSS_AREAS.includes(area) ? LEGENDARY_BOSS_CHANCE[area] ?? LEGENDARY_DROP.bossChance : area === LEGENDARY_STARTER_AREA ? LEGENDARY_DROP.starterBossChance : 0;
/** Legendary chance for one elite kill in `area` (0 outside the level-scaled grounds). */
export const legendaryEliteChance = (area: AreaId): number => LEGENDARY_ELITE_CHANCE[area] ?? 0;

/** Which set a legendary drop is, for a player of `disciplineId`: 70% their own, the rest shared evenly (even split with no own set). */
export function pickLegendarySet(disciplineId: string, rand: () => number): string {
  const own = legendarySetFor(disciplineId);
  const others = LEGENDARY_SET_IDS.filter((id) => id !== own);
  if (!own) return others[Math.floor(rand() * others.length) % others.length];
  if (rand() < LEGENDARY_DROP.ownShare) return own;
  return others[Math.floor(rand() * others.length) % others.length];
}

/**
 * The item id of one legendary drop (a piece of the chosen set). With `owned` (item ids already worn or in the bag) the piece is picked
 * among the ones you do NOT have, so a duplicate only comes once the whole set is in hand: finishing five pieces takes about five
 * drops instead of eleven. The Vault is not asked, so a piece stored there can still come again.
 */
export function pickLegendaryItem(disciplineId: string, rand: () => number, owned?: ReadonlySet<string>): string {
  const set = pickLegendarySet(disciplineId, rand);
  const missing = owned ? PARTS.filter((part) => !owned.has(legendaryItemId(set, part))) : PARTS;
  const parts = missing.length ? missing : PARTS;
  return legendaryItemId(set, parts[Math.floor(rand() * parts.length) % parts.length]);
}

/** The roll itself: an item id, or null. `chance` is bossChance / eliteChance. `owned` is read only when something drops. */
export function rollLegendary(disciplineId: string, chance: number, rand: () => number = Math.random, owned?: () => ReadonlySet<string>): string | null {
  return rand() < chance ? pickLegendaryItem(disciplineId, rand, owned?.()) : null;
}
