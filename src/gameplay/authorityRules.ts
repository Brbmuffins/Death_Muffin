/**
 * Server authority, step 1: the plausibility numbers. Pure functions shared by the Death Muffin backend (authority.cjs, bundled into
 * gathering/authority-rules.cjs by `npm run build:server-rules`) and the unit tests, so the ceilings cannot drift from the game.
 *
 * Nothing here decides what the game pays: the client still rolls kills, gold and XP. These numbers say how much a character
 * could HAVE earned in a stretch of real time, so the backend can notice a save that claims more. docs/SERVER-AUTHORITY.md
 * explains where each constant comes from.
 */

import { AREAS, AREA_ORDER, type AreaId } from '../content/areas';
import { CHEST_PER_MIN_CEILING, DEPTH_LOOT_AREAS, FLOORS_PER_MIN_CEILING, FLOOR_DROP_CHANCE, chestDrops, depthEliteBonus, depthEnemyLevel, depthRoster, chestRunePool } from '../content/depths';
import { ASCENSION } from '../content/ascension';
import { AREA_REAGENT_DROPS, ELITE_REAGENT_MULT, ENEMY_REAGENT_DROPS, BOSS_ICHOR } from '../content/reagents';
import { AREA_RUNE_POOL, BOSS_RUNE_POOL, ELITE_RUNE_CHANCE, RUNE_WEIGHT, RUNES, SURGE_RUNE_CHANCE } from '../content/runes';

// ── Experience arithmetic ─────────────────────────────────────────────────────────────────────────────────────────────

/** The game's curve: advancing from `level` costs level x 100 (characterStats.xpToNext, server characterXpToNext). */
export const LEVEL_CAP = 255;

/** Lifetime experience of a (level, xp-into-level) pair: 100 x (1 + 2 + ... + level-1) + xp. */
export function totalXp(level: number, xp: number): number {
  const l = Math.max(1, Math.trunc(Number(level) || 1));
  return 50 * l * (l - 1) + Math.max(0, Math.trunc(Number(xp) || 0));
}

/** Inverse of totalXp, normalised (xp < level x 100) and capped at LEVEL_CAP. */
export function splitXp(total: number): { level: number; xp: number } {
  let t = Math.max(0, Math.trunc(Number(total) || 0));
  let level = 1;
  while (level < LEVEL_CAP && t >= level * 100) {
    t -= level * 100;
    level++;
  }
  return { level, xp: level >= LEVEL_CAP ? Math.min(t, LEVEL_CAP * 100 - 1) : t };
}

// ── Rate ceilings: experience and gold per real minute ───────────────────────────────────────────────────────────────

/**
 * What the best honest play earns in each hunting ground, per real minute. Measured with the balance harness
 * (`BALANCE_DIFFICULTY=hard BALANCE_SEEDS=2 BALANCE_BANDS=max BALANCE_KIT=auto npm run balance`, all nine disciplines, 2026-10-02):
 * Hard difficulty (x1.3 rewards), the "max" band (Wave Speed 8, the most a player can dial), the ascended kit, rank 0, the best
 * discipline per column. `kills` is kills per minute. See docs/SERVER-AUTHORITY.md "Ceilings".
 */
export const AREA_PEAK: Partial<Record<AreaId, { xp: number; gold: number; kills: number }>> = {
  graves: { xp: 2016, gold: 2470, kills: 205 },
  ossuary: { xp: 4902, gold: 4507, kills: 239 },
  nave: { xp: 10202, gold: 8808, kills: 260 },
  sanctum: { xp: 16503, gold: 13135, kills: 203 },
  cloister: { xp: 24015, gold: 17218, kills: 222 },
  pyre: { xp: 43551, gold: 29779, kills: 195 },
  warren: { xp: 1891, gold: 1718, kills: 186 },
  coliseum: { xp: 20609, gold: 16705, kills: 477 },
  fen: { xp: 74831, gold: 25498, kills: 184 },
  // Measured with the same settings on a held floor of depth 10 for a level-40 hero (enemy level 50): `npm run balance:depths`, BALANCE.md.
  depths: { xp: 30000, gold: 12000, kills: 150 },
};

/**
 * The Catacomb Depths (content/depths.ts). Its enemies are one level older per floor, so XP and gold per kill grow with the depth, which
 * the character's Chronicle records (`peak.depth`). The peak above was measured on a held floor of depth `refDepth` for a hero of level
 * `refHero` (BALANCE.md "Catacomb Depths"); `ceilingsFor` scales it to the enemy level a character could be facing, taking the deepest
 * floor it has recorded plus `slack` (a chronicle flush is up to half a minute behind the stairs), capped at `maxDepth`.
 */
export const DEPTHS_AUTHORITY = { refHero: 40, refDepth: 10, slack: 3, maxDepth: 120 } as const;
/** The Depths are open to anyone who has opened the Warren (the stair is in its west chamber). */
const DEPTHS_GATE: AreaId = 'warren';
export const depthBound = (deepest: number): number => Math.min(DEPTHS_AUTHORITY.maxDepth, Math.max(0, Math.trunc(Number(deepest) || 0)) + DEPTHS_AUTHORITY.slack);

export const AUTHORITY = {
  /** Safety factor over the best measured honest rate: party play, a skilled human out-killing the bot, and tool noise. */
  HEADROOM: 3,
  /** Multipliers the harness does not apply, at their maximum: kill chain (Requiem +25%), the weekly Omen (+20%), a wisdom tonic (+25% XP). */
  CHAIN: 1.25,
  OMEN: 1.2,
  WISDOM: 1.25,
  /** A co-op guest earns at the HOST's Ascension rank. The guest's own record cannot show it, so allow this many ranks above their own. */
  COOP_RANK_ALLOWANCE: 2,
  /** Lump-sum rewards that do not scale with time: boss XP, milestone gold (47 milestones, 8,000 gold at most each), contract payouts. */
  XP_BURST: 5000,
  GOLD_BURST: 40000,
  /** Non-combat gold per minute (labor, contracts, selling what a character already holds is credited separately). */
  NONCOMBAT_GOLD_PER_MIN: 1500,
  /** Allowance banks for at most this long: a character that sat idle for a day cannot claim a day of play at once. */
  BANK_MINUTES: 60,
  /** A character the server has never seen before starts with this many minutes in the bank. */
  FIRST_MINUTES: 2,
  /** The most an offline (browser-only) save may claim, in minutes of play, however long its own clock says. */
  OFFLINE_MAX_MINUTES: 7 * 24 * 60,
  /** An offline save claiming no play time at all is still allowed this much (a short session). */
  OFFLINE_MIN_MINUTES: 10,
  /** Item allowances refill at HEADROOM x the item's best honest pickup rate and bank for ITEM_BANK_MINUTES (shorter than XP: rare gear is the point). */
  ITEM_BANK_MINUTES: 10,
  ITEM_BURST_MINUTES: 2,
  ITEM_MIN_BURST: 4,
  /** The cap on gold credited for items sold, per character. */
  SALE_CREDIT_CAP: 3_000_000,
} as const;

const XP_LEVEL_STEP = 0.25; // loot.ts rollKill: xp * (1 + 0.25 x (enemy level - 1))
const GOLD_LEVEL_STEP = 0.15; // gold * (1 + 0.15 x (enemy level - 1))

export interface Ceilings {
  /** Experience per real minute, with headroom. */
  xpPerMin: number;
  goldPerMin: number;
  /** The ground that sets the rate (null when the character has not unlocked a hunting ground). */
  area: AreaId | null;
}

/** The enemy level an area serves a character: level-scaled grounds follow the character; Ascension ages every enemy. */
function enemyLevel(area: AreaId, characterLevel: number, rank: number): number {
  const a = AREAS[area];
  const base = a.scaling ? Math.max(a.scaling.minLevel, characterLevel) : a.level;
  return base + rank * ASCENSION.levelsPerRank;
}

/**
 * Per-minute ceilings for a character: the best ground it has unlocked, at its Ascension rank (plus the co-op allowance), scaled by
 * the harness' own formulas for enemy level and rank. `unlocked` and `ascension` come from the character's necromancer record.
 */
export function ceilingsFor(unlocked: readonly string[], ascension: number, characterLevel: number, deepest = 0): Ceilings {
  const rank = Math.min(ASCENSION.maxRank, Math.max(0, Math.trunc(ascension) || 0) + AUTHORITY.COOP_RANK_ALLOWANCE);
  const rankMult = 1 + ASCENSION.rewardPerRank * rank;
  let xp = 0;
  let gold = 0;
  let best: AreaId | null = null;
  for (const id of AREA_ORDER) {
    const peak = AREA_PEAK[id];
    if (!peak || !unlocked.includes(id === 'depths' ? DEPTHS_GATE : id)) continue;
    // The harness measured a rank-0 bot at the area's base level (a level-scaled ground at its floor; the Depths at their reference floor).
    const depths = id === 'depths';
    const baseLevel = depths ? depthEnemyLevel(DEPTHS_AUTHORITY.refDepth, DEPTHS_AUTHORITY.refHero) : AREAS[id].scaling ? AREAS[id].scaling!.minLevel : AREAS[id].level;
    const lvl = depths ? depthEnemyLevel(depthBound(deepest), characterLevel) + rank * ASCENSION.levelsPerRank : enemyLevel(id, characterLevel, rank);
    const x = (peak.xp * (1 + XP_LEVEL_STEP * (lvl - 1))) / (1 + XP_LEVEL_STEP * (baseLevel - 1)) * rankMult * AUTHORITY.CHAIN * AUTHORITY.OMEN * AUTHORITY.WISDOM;
    const g = (peak.gold * (1 + GOLD_LEVEL_STEP * (lvl - 1))) / (1 + GOLD_LEVEL_STEP * (baseLevel - 1)) * rankMult * AUTHORITY.CHAIN * AUTHORITY.OMEN;
    if (x > xp) {
      xp = x;
      best = id;
    }
    if (g > gold) gold = g;
  }
  return {
    xpPerMin: Math.ceil(xp * AUTHORITY.HEADROOM),
    goldPerMin: Math.ceil(Math.max(gold * AUTHORITY.HEADROOM, AUTHORITY.NONCOMBAT_GOLD_PER_MIN)),
    area: best,
  };
}

// ── Items: what can arrive in a bag from the ground ───────────────────────────────────────────────────────────────────

const BOSS_ICHORS = new Set(Object.values(BOSS_ICHOR));
/** Wave Speed 8 item chance (1 + 0.06 x 8 + 0.2 at the Nightfall milestone) and a fortune tonic (+30%): reagents.ts, upgrades.ts. */
const ITEM_CHANCE_PEAK = 1 + 0.06 * 8 + 0.2;
const FORTUNE_PEAK = 1.3;
/** Elites roll area loot six times as often (loot.ts rollKill). */
const ELITE_LOOT_MULT = 6;
/** Ichors: one per boss kill, and a summon costs soul shards from elites plus a 2-3 minute fight. */
const ICHOR_PER_MIN = 0.5;

/** Average quantity of one drop: materials come as 1 or 2 (35%) in rollItem; reagents have their own range. */
const MATERIAL_QTY = 1.35;

function buildGroundRates(): Record<string, number> {
  const rates: Record<string, number> = {};
  const add = (id: string, perMin: number) => {
    rates[id] = Math.max(rates[id] ?? 0, perMin);
  };
  /** What `kills` per minute in `lootId`'s ground drop: its loot table, its reagents (its own table plus the roster's), its elites' runes. */
  const addGround = (lootId: AreaId, kills: number, roster: readonly { id: string; weight: number }[], eliteChance: number, extraPerMin = 0) => {
    const area = AREAS[lootId];
    const elite = Math.min(1, eliteChance + 0.004 * 8);
    const total = area.loot.reduce((n, l) => n + l.weight, 0) || 1;
    const dropChance = Math.min(1, area.itemChance * ITEM_CHANCE_PEAK * FORTUNE_PEAK * (1 - elite + elite * ELITE_LOOT_MULT));
    for (const l of area.loot) add(l.item, ((kills * dropChance + extraPerMin) * l.weight) / total * MATERIAL_QTY);
    // Reagents: the area's own table plus the enemies in it that shed them (weighted by how often they spawn).
    const weights = roster.reduce((n, e) => n + e.weight, 0) || 1;
    const reagentPerKill = new Map<string, number>();
    const credit = (item: string, chance: number, qty: [number, number]) => {
      const c = Math.min(1, chance * FORTUNE_PEAK * (1 - elite + elite * ELITE_REAGENT_MULT));
      reagentPerKill.set(item, (reagentPerKill.get(item) ?? 0) + c * ((qty[0] + qty[1]) / 2));
    };
    for (const d of AREA_REAGENT_DROPS[lootId] ?? []) credit(d.item, d.chance, d.qty);
    for (const e of roster) for (const d of ENEMY_REAGENT_DROPS[e.id as keyof typeof ENEMY_REAGENT_DROPS] ?? []) credit(d.item, (d.chance * e.weight) / weights, d.qty);
    for (const [item, perKill] of reagentPerKill) add(item, kills * perKill);
    // Relic runes: an elite's small chance and a Grave Surge's offering (about one surge every two minutes), split by the pool's weights.
    const pool = AREA_RUNE_POOL[lootId] ?? [];
    const poolWeight = pool.reduce((n, r) => n + RUNE_WEIGHT[RUNES[r].rarity], 0) || 1;
    for (const r of pool) {
      const share = RUNE_WEIGHT[RUNES[r].rarity] / poolWeight;
      add(r, (kills * elite * ELITE_RUNE_CHANCE * ITEM_CHANCE_PEAK * FORTUNE_PEAK + 0.5 * SURGE_RUNE_CHANCE) * share);
    }
  };
  for (const id of AREA_ORDER) {
    const area = AREAS[id];
    const peak = AREA_PEAK[id];
    if (!peak || area.safe || area.instance) continue;
    addGround(id, peak.kills, area.enemies, area.eliteChance);
  }
  // The Catacomb Depths drop from the hunting ground whose gear matches the floor, so every id is already a drop; what is new is the
  // pace: the Depths' own kill rate on those tables, a floor-clear drop (FLOOR_DROP_CHANCE per floor) and a chest's drops, plus the
  // chest's rune. The deepest roster stands for the reagent mix and the deepest floor's elite chance for the elites.
  const depthsPeak = AREA_PEAK.depths;
  if (depthsPeak) {
    const deep = depthRoster(DEPTHS_AUTHORITY.maxDepth);
    const elite = AREAS.depths.eliteChance + depthEliteBonus(DEPTHS_AUTHORITY.maxDepth);
    const floorDrops = FLOORS_PER_MIN_CEILING * FLOOR_DROP_CHANCE + CHEST_PER_MIN_CEILING * chestDrops(DEPTHS_AUTHORITY.maxDepth);
    for (const lootId of DEPTH_LOOT_AREAS) addGround(lootId, depthsPeak.kills, deep, elite, floorDrops);
    for (const r of chestRunePool(DEPTHS_AUTHORITY.maxDepth)) add(r, CHEST_PER_MIN_CEILING);
  }
  // Boss runes: at most a boss kill a minute is a generous honest rate (ichors use the same figure).
  for (const pool of Object.values(BOSS_RUNE_POOL)) for (const r of pool) add(r, ICHOR_PER_MIN);
  for (const ichor of BOSS_ICHORS) add(ichor, ICHOR_PER_MIN);
  return rates;
}

/** Item id -> the most a character could pick up per minute, before headroom. Only items in a drop table appear here. */
export const GROUND_RATES: Readonly<Record<string, number>> = buildGroundRates();

/** True when the item can come off the ground at all (area loot, a mob's reagent, a boss's ichor). Everything else is crafted, gathered or bought server-side. */
export const isGroundItem = (itemId: string): boolean => Object.prototype.hasOwnProperty.call(GROUND_RATES, itemId);

/** Units of an item per minute a save may add to the bag from the ground (0 = never from a client save). */
export function itemRatePerMin(itemId: string): number {
  return isGroundItem(itemId) ? GROUND_RATES[itemId] * AUTHORITY.HEADROOM : 0;
}

/** The most an item's allowance can bank: its burst plus ITEM_BANK_MINUTES of its rate. 0 for items a save may never add. */
export function itemCap(itemId: string): number {
  const rate = itemRatePerMin(itemId);
  if (rate <= 0) return 0;
  return Math.ceil(Math.max(AUTHORITY.ITEM_MIN_BURST, rate * AUTHORITY.ITEM_BURST_MINUTES) + rate * AUTHORITY.ITEM_BANK_MINUTES);
}
