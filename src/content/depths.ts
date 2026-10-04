import { AFFIX_ORDER, ENEMIES, type EliteAffix, type EnemyId } from './enemies';
import { RUNE_ORDER, RUNES, type RuneId } from './runes';
import type { AreaId } from './areas';

/**
 * The Catacomb Depths (docs/ALCHEMY-AND-WORLDS-PLAN.md W2): an endless descent, reached by the stair in the Warren's west chamber.
 * Pure data and formulas, shared by the sim (WorldSim.startDepths), the scene, the balance harness and the server's authority rules
 * (bundled by `npm run build:server-rules`), so the numbers have one home.
 *
 * The loop: each floor is "slay N, then the stair down opens". Depth d raises the dead's level, every fifth floor gives elites one more
 * affix (from the existing pool) and holds a chest, and dying or leaving ends the run (what you looted is yours).
 */
export const DEPTHS = {
  /**
   * The spec said `max(20, player) + d`. A level-20 floor is wrong for the first visitors: the Warren opens at 150 Graves kills (level ~8-12),
   * and enemy health grows 22% of a level-1 body per level (x5 at level 20 against x2.3 at level 12), so depth 1 would be a wall. The floor
   * is the Warren's own entry level instead: `max(12, your level) + depth`. A level-60 hero meets level-61 dead on depth 1 (the Pyre and the
   * Fen are level-scaled the same way) and level-80 dead on depth 20.
   */
  minLevel: 12,
  /** The hero's level is read as the highest among the living players on the floor (solo only for now). */
  levelsPerDepth: 1,
  /** Most dead alive at once on a floor (the plan's "~24"); the global cap (72) is far above it. */
  cap: 24,
  /** Every Nth floor holds a chest and gives elites one more affix. */
  chestEvery: 5,
  extraAffixEvery: 5,
  /** Elites carry at most this many affixes beyond their first (the pool holds four in all). */
  maxExtraAffixes: 3,
  /** Seconds after a floor begins before the first of the dead climbs out. */
  firstWaveDelayS: 1.4,
  /** A floor-clear banner stays this long (ms). */
  bannerMs: 3200,
} as const;

/**
 * Why the stair will not take a hero down right now, in the words the stair says (null = it will). Being in a party never blocks it:
 * the floors live in one keeper's sim and the relay carries no layout, so a party member steps out of the party for the descent (the
 * scene disconnects them, they keep their own world, and they rejoin the party when the run ends). Only a fallen hero is refused.
 */
export function depthsEntryBlock(o: { alive: boolean }): string | null {
  if (!o.alive) return 'You are in no state to descend.';
  return null;
}

/**
 * The floor the stair can resume at: the deepest floor the character's Chronicle holds (`peak.depth`), or 0 when there is nothing to
 * resume (never been below depth 1). Only a depth the character has already reached is ever offered, so a resumed run cannot start
 * past what the server's ledger proved (killRules: a floor may be cleared at most one past the deepest proven).
 */
export const resumeDepth = (peak: number): number => {
  const d = Math.floor(Number(peak) || 0);
  return d >= 2 ? d : 0;
};

/** Kills a floor asks for before the stair down opens: 10 on depth 1, rising to 30 from depth 21. */
export const floorKills = (depth: number): number => Math.min(30, 9 + Math.max(1, Math.floor(depth)));

/** The dead's level on `depth`, for a hero (the highest on the floor) of level `heroLevel`. Ascension adds its own levels on top (WorldSim). */
export const depthEnemyLevel = (depth: number, heroLevel: number): number =>
  Math.max(DEPTHS.minLevel, Math.floor(heroLevel) || 1) + Math.floor(Math.max(1, depth) * DEPTHS.levelsPerDepth);

/** Affixes an elite carries beyond its first on `depth`: one more every fifth floor, up to the whole pool. */
export const extraAffixes = (depth: number): number => Math.min(DEPTHS.maxExtraAffixes, Math.floor(Math.max(0, depth) / DEPTHS.extraAffixEvery));

/** Extra elite chance on top of the area's: deeper floors breed more elites, up to +14 points. */
export const depthEliteBonus = (depth: number): number => Math.min(0.14, 0.005 * Math.max(0, depth));

/** A wave's size and the pause between waves; the floor never spawns more than it still needs (see WorldSim.updateDepths). */
export const depthWaveSize = (depth: number): number => Math.min(9, 5 + Math.floor(depth / 6));
export const depthWaveGapS = (depth: number): number => Math.max(2.4, 4.4 - 0.05 * depth);

export const hasChest = (depth: number): boolean => depth > 0 && depth % DEPTHS.chestEvery === 0;

/** Which of the pool's affixes a new elite on `depth` carries beyond its first (distinct, never the one it has); `rand` returns [0, 1). */
export function pickExtraAffixes(depth: number, primary: EliteAffix | undefined, rand: () => number): EliteAffix[] {
  const pool = AFFIX_ORDER.filter((a) => a !== primary);
  const out: EliteAffix[] = [];
  const n = Math.min(extraAffixes(depth), pool.length);
  while (out.length < n && pool.length) out.push(pool.splice(Math.floor(rand() * pool.length), 1)[0]);
  return out;
}

// --- Who walks the floors -----------------------------------------------------------------------------------------------------

/** The whole roster is reused (no new art). Newer kinds join as the floors go down; weights per band. */
const BANDS: { from: number; add: { id: EnemyId; weight: number }[] }[] = [
  { from: 1, add: [{ id: 'rat', weight: 30 }, { id: 'robber', weight: 22 }, { id: 'ghoul', weight: 14 }, { id: 'bat', weight: 12 }, { id: 'sac', weight: 10 }, { id: 'hound', weight: 8 }] },
  { from: 5, add: [{ id: 'penitent', weight: 12 }, { id: 'deacon', weight: 8 }, { id: 'acolyte', weight: 6 }, { id: 'wraith', weight: 6 }, { id: 'moth', weight: 6 }] },
  { from: 10, add: [{ id: 'templar', weight: 8 }, { id: 'censer', weight: 6 }, { id: 'gargoyle', weight: 8 }, { id: 'seraph', weight: 6 }, { id: 'plague_doctor', weight: 8 }, { id: 'flagellant', weight: 8 }] },
  { from: 15, add: [{ id: 'golem', weight: 5 }, { id: 'cinder_husk', weight: 8 }, { id: 'cinderhound', weight: 8 }, { id: 'pyre_priest', weight: 6 }, { id: 'slag_brute', weight: 5 }, { id: 'bog_hag', weight: 7 }, { id: 'drowned_sexton', weight: 4 }] },
];

/** The weighted roster of a floor. The common dead thin out as the strange ones arrive (a rat is never more than a third of the mix). */
export function depthRoster(depth: number): { id: EnemyId; weight: number }[] {
  const out = new Map<EnemyId, number>();
  for (const b of BANDS) {
    if (depth < b.from) continue;
    for (const e of b.add) out.set(e.id, e.weight);
  }
  // Past the first band the starter dead fade: each band down halves them.
  const bands = BANDS.filter((b) => depth >= b.from).length;
  const fade = Math.pow(0.6, Math.max(0, bands - 1));
  for (const e of BANDS[0].add) out.set(e.id, Math.max(3, Math.round(e.weight * fade)));
  return [...out].map(([id, weight]) => ({ id, weight }));
}

// --- What the floors pay ----------------------------------------------------------------------------------------------------------

/**
 * Kills drop from the loot table of the hunting ground whose gear matches the depth, so the Depths hands out nothing the game does not
 * already (every id is in a live drop table, and the server's authority rules already know it). Reagents and runes follow the same area.
 */
export function depthLootArea(depth: number): AreaId {
  if (depth >= 30) return 'fen';
  if (depth >= 20) return 'pyre';
  if (depth >= 15) return 'cloister';
  if (depth >= 10) return 'sanctum';
  if (depth >= 5) return 'coliseum';
  return 'ossuary';
}

/** Every ground whose loot a Depths floor may use (for the server's allowances). */
export const DEPTH_LOOT_AREAS: AreaId[] = ['ossuary', 'coliseum', 'sanctum', 'cloister', 'pyre', 'fen'];

/** The average gold and XP of one kill on a floor, from its roster at enemy level `level` (loot.ts rollKill's own formulas). */
export function averageKill(depth: number, level: number): { gold: number; xp: number } {
  const roster = depthRoster(depth);
  const total = roster.reduce((n, e) => n + e.weight, 0) || 1;
  let gold = 0;
  let xp = 0;
  for (const e of roster) {
    const d = ENEMIES[e.id];
    gold += ((e.weight / total) * (d.gold[0] + d.gold[1])) / 2;
    xp += (e.weight / total) * d.xp;
  }
  return { gold: gold * (1 + 0.15 * (level - 1)), xp: xp * (1 + 0.25 * (level - 1)) };
}

/** Chance that clearing a floor leaves an item on the stair. */
export const FLOOR_DROP_CHANCE = 0.65;

/** Clearing a floor pays this many average kills of gold and XP on top of the kills themselves; a chest pays CHEST_KILLS. */
export const FLOOR_BONUS_KILLS = 5;
export const CHEST_KILLS = 14;

export function floorBonus(depth: number, level: number): { gold: number; xp: number } {
  const k = averageKill(depth, level);
  return { gold: Math.round(k.gold * FLOOR_BONUS_KILLS), xp: Math.round(k.xp * FLOOR_BONUS_KILLS) };
}

export function chestBonus(depth: number, level: number): { gold: number; xp: number } {
  const k = averageKill(depth, level);
  const tier = Math.floor(depth / DEPTHS.chestEvery);
  const mult = 1 + 0.12 * (tier - 1);
  return { gold: Math.round(k.gold * CHEST_KILLS * mult), xp: Math.round(k.xp * CHEST_KILLS * mult) };
}

/** A chest holds this many drops (the first is always a piece of gear): 3 at depth 5, one more every 10 floors. */
export const chestDrops = (depth: number): number => 3 + Math.floor(Math.max(0, depth - 5) / 10);

/** Runes: a chest may hold one (25% at depth 5, +4% per chest, 70% at most; was 10%, +2%, 35%); the uncommon and rare kinds, and from depth 10 the epic ones too. */
export const chestRuneChance = (depth: number): number => Math.min(0.7, 0.25 + 0.04 * (Math.floor(depth / DEPTHS.chestEvery) - 1));
export function chestRunePool(depth: number): RuneId[] {
  return RUNE_ORDER.filter((id) => RUNES[id].rarity !== 'epic' || depth >= 10);
}

/** The most chests an honest run opens per minute (floors take at least ~25 s at the best; a chest comes every fifth). The server's allowances use this. */
export const CHEST_PER_MIN_CEILING = 0.5;
/** The most floors an honest player clears per minute at the best of play (the floor-clear drop's ceiling). */
export const FLOORS_PER_MIN_CEILING = 3;
