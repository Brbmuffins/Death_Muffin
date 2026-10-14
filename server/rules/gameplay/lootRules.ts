/**
 * What a kill, a boss, a Grave Surge or a first kill drops: the server's copy of the Godot client's roll (godot/rules/loot/loot.gd,
 * DmLoot), so the server can decide drops itself (server authority Phase 1, ROADMAP). Both must consume their random streams in exactly
 * the same order: the client rolls a drop the instant a kill lands from a server-issued stream (`dropStream`), and the server rolls the
 * same drop from the same stream when it is claimed. `lootRules.test.ts` writes the fixture the Godot suite `loot_parity` replays.
 *
 * A `Rand` is `() => number` in [0, 1). Drops are { item_id, quantity }.
 */
import { AREAS, type AreaId } from '../content/areas';
import { BOSSES } from '../content/bosses';
import { DISCIPLINES } from '../content/disciplines';
import { FLOOR_DROP_CHANCE, chestBonus, chestDrops, chestRuneChance, chestRunePool, depthLootArea, floorBonus, hasChest } from '../content/depths';
import { clampDropLevel, isAffixGear, rollInstance, type DropSource, type ItemInstanceData } from './affixRules';
import { ARMOR_BY_ID } from '../content/armorSets';
import { DIFFICULTIES, type Difficulty } from '../content/difficulty';
import { ELITE, ENEMIES, type EnemyId } from '../content/enemies';
import { ITEMS } from '../content/items';
import { legendaryBossChance, legendaryEliteChance, rollLegendary } from '../content/legendarySets';
import { AREA_REAGENT_DROPS, BOSS_ICHOR, ELITE_REAGENT_MULT, ENEMY_REAGENT_DROPS } from '../content/reagents';
import { AREA_RUNE_POOL, BOSS_REPEAT_RUNE_CHANCE, BOSS_RUNE_POOL, SURGE_RUNE_CHANCE, eliteRuneChance, pickRune } from '../content/runes';
import { WAVE_UPGRADE } from '../content/upgrades';
import { smartTable, type LootEntry } from './smartLoot';

export type Rand = () => number;
export type Drop = { item_id: string; quantity: number; instance?: ItemInstanceData };
export type Reward = { gold: number; materialGold: number; shards: number; items: Drop[]; xp: number };

export const KILL_LOOT = { itemChanceMult: 0.5, materialQtyMult: 2, goldEveryKills: 4 } as const;
const NIGHTFALL_TIER = 8;
const PROFESSION_PREFIXES = ['ore_', 'ingot_', 'material_', 'log_', 'plank_', 'bones_', 'seed_', 'herb_', 'gem_'];

// ── Shared random stream ──────────────────────────────────────────────────────────────────────────────────────────────────

/**
 * sfc32 over four 32-bit words, warmed up 12 steps. Pure integer math, so the GDScript copy (DmDropStream) gives the same floats.
 * The server derives the words from a secret per (character, kind, index); the client is handed them ahead of time.
 */
export function dropStream(seed: readonly [number, number, number, number]): Rand {
  let [a, b, c, d] = seed.map((w) => w >>> 0);
  const next = (): number => {
    const t0 = (a + b) >>> 0;
    a = (b ^ (b >>> 9)) >>> 0;
    b = (c + (c << 3)) >>> 0;
    c = ((c << 21) | (c >>> 11)) >>> 0;
    d = (d + 1) >>> 0;
    const t = (t0 + d) >>> 0;
    c = (c + t) >>> 0;
    return t / 4294967296;
  };
  for (let i = 0; i < 12; i++) next();
  return next;
}

// ── Small helpers (each mirrors its GDScript twin) ────────────────────────────────────────────────────────────────────────

/** Math.round for the values loot sees (DmMath.js_round). */
export const jsRound = (x: number): number => {
  const f = Math.floor(x);
  return x - f >= 0.5 ? f + 1 : f;
};
export const randInt = (rand: Rand, mn: number, mx: number): number => Math.floor(mn + rand() * (mx - mn + 1));

export function pickWeighted<T extends { weight: number }>(items: readonly T[], r: number): T | null {
  if (!items.length) return null;
  let total = 0;
  for (const i of items) total += i.weight;
  let roll = r * total;
  for (const i of items) {
    if (roll < i.weight) return i;
    roll -= i.weight;
  }
  return items[items.length - 1];
}

export function waveMods(tier: number): { rewardMult: number; xpMult: number; itemChanceMult: number } {
  const night = tier >= NIGHTFALL_TIER;
  return {
    rewardMult: 1 + 0.1 * tier + (night ? 0.25 : 0),
    xpMult: 1 + 0.05 * tier + (night ? 0.15 : 0),
    itemChanceMult: 1 + 0.06 * tier + (night ? 0.2 : 0),
  };
}

export const isProfessionMaterial = (id: string): boolean => PROFESSION_PREFIXES.some((p) => id.startsWith(p));

/** A profession material from a combat roll pays its sell value in gold instead (gems kept for bosses). */
export function settleCombatDrop(d: Drop, keepGems = false): { drop: Drop | null; gold: number } {
  if (!isProfessionMaterial(d.item_id) || (keepGems && d.item_id.startsWith('gem_'))) return { drop: d, gold: 0 };
  const sell = Number((ITEMS as Record<string, { sell?: number }>)[d.item_id]?.sell ?? 1);
  return { drop: null, gold: Math.max(1, jsRound(sell * d.quantity)) };
}

const areaDef = (area: string) => (AREAS as Record<string, { loot: LootEntry[]; itemChance: number; scaling?: unknown }>)[area];
const itemMeta = (id: string) => (ITEMS as Record<string, { type?: string; rarity?: string } | undefined>)[id];
const rewardMult = (d: string): number => Number((DIFFICULTIES as Record<string, { rewardMult: number }>)[d].rewardMult);

// ── Rolls ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────

export function rollItem(area: string, rand: Rand, materialQtyMult = 1, disciplineId = ''): Drop {
  const table = disciplineId ? smartTable(area as AreaId, disciplineId) : areaDef(area).loot;
  const pick = pickWeighted(table, rand())!;
  let qty = 1;
  if ((itemMeta(pick.item)?.type ?? '') === 'material') qty = (1 + (rand() < 0.35 ? 1 : 0)) * materialQtyMult;
  return { item_id: pick.item, quantity: qty };
}

/** Reagents: independent of the area roll, per area and per enemy kind. No rand is consumed where none can drop. */
export function rollReagents(def: string, area: string, elite: boolean, itemChanceMult = 1, rand: Rand): Drop[] {
  const specs = [...(AREA_REAGENT_DROPS[area as AreaId] ?? []), ...(ENEMY_REAGENT_DROPS[def as EnemyId] ?? [])];
  const out: Drop[] = [];
  for (const s of specs) {
    if (rand() >= Math.min(1, s.chance * itemChanceMult * (elite ? ELITE_REAGENT_MULT : 1))) continue;
    out.push({ item_id: s.item, quantity: randInt(rand, s.qty[0], s.qty[1]) });
  }
  return out;
}

export function rollEliteRune(area: string, itemChanceMult = 1, rand: Rand): Drop | null {
  const pool = AREA_RUNE_POOL[area as AreaId] ?? [];
  if (!pool.length || rand() >= Math.min(1, eliteRuneChance(area as AreaId) * itemChanceMult)) return null;
  const id = pickRune(pool, rand);
  return id ? { item_id: id, quantity: 1 } : null;
}

export type KillInput = {
  def: string; area: string; level: number; elite: boolean; waveTier: number; difficulty: Difficulty | string;
  itemChanceMult?: number; disciplineId?: string; owned?: () => ReadonlySet<string>; runePity?: number;
};

/** One kill's spoils. Three streams, as the client: `rand` (gold, item, legendary), `reagentRand`, `runeRand`. */
export function rollKill(k: KillInput, rand: Rand, reagentRand: Rand, runeRand: Rand): Reward {
  const d = ENEMIES[k.def as EnemyId];
  const a = areaDef(k.area);
  const mods = waveMods(k.waveTier);
  const diff = rewardMult(k.difficulty);
  const icm = k.itemChanceMult ?? 1;
  const disc = k.disciplineId ?? '';
  const levelMult = 1 + 0.15 * (k.level - 1);
  const gold = jsRound(randInt(rand, d.gold[0], d.gold[1]) * levelMult * mods.rewardMult * diff * (k.elite ? ELITE.goldMult : 1));
  let materialGold = 0;
  let shards = 0;
  if (k.elite) shards = rand() < 0.25 ? 2 : 1;
  const items: Drop[] = [];
  const chance = Math.min(1, a.itemChance * mods.itemChanceMult * icm * (k.elite ? 6 : KILL_LOOT.itemChanceMult));
  if (a.loot.length && rand() < chance) {
    const s = settleCombatDrop(rollItem(k.area, rand, k.elite ? 1 : KILL_LOOT.materialQtyMult, disc));
    if (s.drop) items.push(s.drop);
    materialGold += s.gold;
  }
  if (disc && k.elite && a.scaling) {
    const lid = rollLegendary(disc, legendaryEliteChance(k.area as AreaId), rand, k.owned);
    if (lid) items.push({ item_id: lid, quantity: 1 });
  }
  items.push(...rollReagents(k.def, k.area, k.elite, icm, reagentRand));
  if (k.elite) {
    const rune = rollEliteRune(k.area, icm * mods.itemChanceMult * (k.runePity ?? 1), runeRand);
    if (rune) items.push(rune);
  }
  const xp = jsRound(d.xp * (1 + 0.25 * (k.level - 1)) * mods.xpMult * diff * (k.elite ? ELITE.xpMult : 1));
  return { gold, materialGold, shards, items, xp };
}

/** A Grave Surge's offering: the area's item, or (35%) a rune in its place; never a profession material. */
export function rollSurgeItem(area: string, rand: Rand, disciplineId = ''): Drop {
  const pool = AREA_RUNE_POOL[area as AreaId] ?? [];
  if (pool.length && rand() < SURGE_RUNE_CHANCE) {
    const id = pickRune(pool, rand);
    if (id) return { item_id: id, quantity: 1 };
  }
  for (let i = 0; i < 40; i++) {
    const d = rollItem(area, rand, 1, disciplineId);
    if (!isProfessionMaterial(d.item_id)) return d;
  }
  return rollItem(area, rand, 1, disciplineId);
}

/** A boss's rune: the Prelate and a boss's first kill always leave one; repeats roll 50%. null where the boss has no pool. */
export function rollBossRune(boss: string, first: boolean, rand: Rand): Drop | null {
  const pool = BOSS_RUNE_POOL[boss] ?? [];
  if (!pool.length) return null;
  if (!(boss === 'prelate' || first) && rand() >= BOSS_REPEAT_RUNE_CHANCE) return null;
  const id = pickRune(pool, rand);
  return id ? { item_id: id, quantity: 1 } : null;
}

export type BossInput = { waveTier: number; difficulty: Difficulty | string; area: string; costShards: number; boss: string; disciplineId?: string; owned?: () => ReadonlySet<string> };

export function rollBoss(b: BossInput, rand: Rand): Reward {
  const mods = waveMods(b.waveTier);
  const diff = rewardMult(b.difficulty);
  const k = b.costShards / 5;
  const disc = b.disciplineId ?? '';
  const items: Drop[] = [];
  let materialGold = 0;
  for (let i = 0; i < 3; i++) {
    const s = settleCombatDrop(rollItem(b.area, rand, 1, disc), true);
    if (s.drop) items.push(s.drop);
    materialGold += s.gold;
  }
  if (disc && legendaryBossChance(b.area as AreaId) > 0) {
    const lid = rollLegendary(disc, legendaryBossChance(b.area as AreaId), rand, b.owned);
    if (lid) items.push({ item_id: lid, quantity: 1 });
  }
  if (b.boss) items.push({ item_id: (BOSS_ICHOR as Record<string, string>)[b.boss], quantity: 1 });
  return { gold: jsRound(320 * k * mods.rewardMult * diff), materialGold, shards: b.costShards >= 5 ? 3 : Math.max(1, Math.trunc(b.costShards) - 1), items, xp: jsRound(900 * k * diff) };
}

/** A boss's first kill per character: a guaranteed rare-or-better item. */
export function rollFirstKillItem(area: string, rand: Rand, disciplineId = ''): Drop {
  const table = areaDef(area).loot;
  if (disciplineId) {
    const own = table.map((e) => e.item).filter((id) => {
      const r = String(itemMeta(id)?.rarity ?? '');
      return (ARMOR_BY_ID as Record<string, { disciplineId: string } | undefined>)[id]?.disciplineId === disciplineId && (r === 'rare' || r === 'epic');
    });
    if (own.length && rand() < 0.75) return { item_id: own[Math.floor(rand() * own.length)], quantity: 1 };
  }
  for (let i = 0; i < 30; i++) {
    const d = rollItem(area, rand, 1, disciplineId);
    const r2 = String(itemMeta(d.item_id)?.rarity ?? '');
    if (r2 === 'rare' || r2 === 'epic') return d;
  }
  const rares = table.map((e) => e.item).filter((id) => {
    const m = itemMeta(id);
    return !!m && m.type !== 'material' && (m.rarity === 'rare' || m.rarity === 'epic');
  });
  const idx = Math.floor(rand() * rares.length);
  return { item_id: idx < rares.length ? rares[idx] : 'helm_gold', quantity: 1 };
}

/** Whether an item can roll an instance (gear only): DmAffixes.can_roll. */
export const canRoll = (itemId: string): boolean => isAffixGear(String(itemMeta(itemId)?.type ?? ''));

/**
 * The rolled instance of every gear piece in `items`, in order, from one stream (`gearRand`): what the client shows on the ground at once and
 * the server stores when the piece is claimed. The drop level is clamped to the character's reach first (clampDropLevel), as the server
 * always did. Returns new drop objects; non-gear drops come back unchanged.
 */
export function rollGearInstances(items: readonly Drop[], level: number, characterLevel: number, source: DropSource, gearRand: Rand): Drop[] {
  const lvl = clampDropLevel(level, characterLevel);
  return items.map((d) => (canRoll(d.item_id) ? { ...d, instance: rollInstance({ rarity: String(itemMeta(d.item_id)?.rarity ?? 'common') }, lvl, source, gearRand) } : d));
}

// ── The Catacomb Depths (DmDepthsRewards) ───────────────────────────────────────────────────────────────────────────────────

export type DepthsReward = { gold: number; xp: number; materialGold: number; drops: Drop[] };

/** A floor clear's gold / XP and, most of the time (FLOOR_DROP_CHANCE), an item from the depth's ground. */
export function rollFloorClear(depth: number, level: number, rand: Rand, disciplineId = ''): DepthsReward {
  const bonus = floorBonus(depth, level);
  if (rand() >= FLOOR_DROP_CHANCE) return { gold: bonus.gold, xp: bonus.xp, materialGold: 0, drops: [] };
  const s = settleCombatDrop(rollItem(depthLootArea(depth), rand, 1, disciplineId), true);
  return { gold: bonus.gold, xp: bonus.xp, materialGold: s.gold, drops: s.drop ? [s.drop] : [] };
}

/** A piece of gear from the depth's ground (rolled until the table yields some). */
export function rollGearDrop(depth: number, rand: Rand, disciplineId = ''): Drop {
  const area = depthLootArea(depth);
  for (let i = 0; i < 60; i++) {
    const d = rollItem(area, rand, 1, disciplineId);
    const meta = itemMeta(d.item_id);
    if (meta && isAffixGear(String(meta.type ?? ''))) return d;
  }
  return { item_id: 'helm_gold', quantity: 1 };
}

/** The chest of a fifth floor: gear first, then chestDrops(depth) - 1 more from the ground, maybe a rune. */
export function rollChest(depth: number, level: number, rand: Rand, disciplineId = ''): DepthsReward {
  const bonus = chestBonus(depth, level);
  const area = depthLootArea(depth);
  const drops: Drop[] = [rollGearDrop(depth, rand, disciplineId)];
  let materialGold = 0;
  for (let i = 1; i < chestDrops(depth); i++) {
    const s = settleCombatDrop(rollItem(area, rand, 1, disciplineId), true);
    if (s.drop) drops.push(s.drop);
    materialGold += s.gold;
  }
  if (rand() < chestRuneChance(depth)) {
    const id = pickRune(chestRunePool(depth), rand);
    if (id) drops.push({ item_id: id, quantity: 1 });
  }
  return { gold: bonus.gold, materialGold, xp: bonus.xp, drops };
}

// ── Drop events (server authority Phase 1) ─────────────────────────────────────────────────────────────────────────────────

/**
 * A drop event is one roll the server can replay: one kill, one elite kill, one boss kill or one quelled Grave Surge, rolled from that
 * event's own streams. The client rolls it the moment the event happens (DmLoot.roll_event), the server rolls it again when a drop of it is
 * claimed (backend drops.cjs). `items` carry their `source` and, for gear, their `instance`. Kinds have separate counters, so an elite's
 * streams are never an ordinary kill's.
 */
export type DropKind = 'kill' | 'elite' | 'boss' | 'surge' | 'floor' | 'chest';
export const DROP_KINDS: readonly DropKind[] = ['kill', 'elite', 'boss', 'surge', 'floor', 'chest'];
/** The streams each kind draws from, in this order (seed words are issued per stream). */
export const EVENT_STREAMS: Record<DropKind, readonly string[]> = {
  kill: ['rand', 'reagent', 'rune', 'gear'],
  elite: ['rand', 'reagent', 'rune', 'gear'],
  boss: ['rand', 'gear'],
  surge: ['rand', 'gear'],
  floor: ['rand', 'gear'],
  chest: ['rand', 'gear'],
};
/** One event's streams from its single seed (the tape carries one seed per event): sub-seeds are drawn from dropStream(seed) in EVENT_STREAMS order. */
export function eventStreams(kind: DropKind, seed: readonly [number, number, number, number]): Record<string, Rand> {
  const base = dropStream(seed);
  const u32 = () => Math.floor(base() * 4294967296) >>> 0;
  const out: Record<string, Rand> = {};
  for (const name of EVENT_STREAMS[kind]) out[name] = dropStream([u32(), u32(), u32(), u32()]);
  return out;
}
export type EventFacts = {
  /** kill / elite */ def?: string; itemChanceMult?: number; runePity?: number;
  /** boss */ boss?: string; costShards?: number; first?: boolean;
  /** floor / chest (the Catacomb Depths) */ depth?: number;
  area: string; level: number; waveTier?: number; difficulty?: string; disciplineId?: string; characterLevel: number; owned?: readonly string[];
};
export type EventDrop = Drop & { source: DropSource };
export type EventRoll = { reward: Reward | DepthsReward | null; items: EventDrop[] };

const tag = (items: readonly Drop[], source: DropSource): EventDrop[] => items.map((d) => ({ ...d, source }));

export function rollEvent(kind: DropKind, f: EventFacts, s: Record<string, Rand>): EventRoll {
  const owned = () => new Set(f.owned ?? []);
  const disc = f.disciplineId ?? '';
  if (kind === 'kill' || kind === 'elite') {
    const reward = rollKill({ def: f.def ?? '', area: f.area, level: f.level, elite: kind === 'elite', waveTier: f.waveTier ?? 0, difficulty: f.difficulty ?? 'medium',
      itemChanceMult: f.itemChanceMult ?? 1, disciplineId: disc, owned, runePity: f.runePity ?? 1 }, s.rand, s.reagent, s.rune);
    // Ordinary kills drop half as often, so their gear rolls at elite quality (as in the original game).
    return { reward, items: tag(rollGearInstances(reward.items, f.level, f.characterLevel, 'elite', s.gear), 'elite') };
  }
  if (kind === 'boss') {
    const boss = f.boss ?? '';
    const reward = rollBoss({ waveTier: f.waveTier ?? 0, difficulty: f.difficulty ?? 'medium', area: f.area, costShards: f.costShards ?? 5, boss, disciplineId: disc, owned }, s.rand);
    const first = !!f.first && boss !== 'prelate';
    const firstItem = first ? rollFirstKillItem(f.area, s.rand, disc) : null;
    const rune = rollBossRune(boss, first, s.rand);
    const spoils = rune ? [...reward.items, rune] : reward.items;
    const items = tag(rollGearInstances(spoils, f.level, f.characterLevel, 'boss', s.gear), 'boss');
    if (firstItem) items.push(...tag(rollGearInstances([firstItem], f.level, f.characterLevel, 'first_kill', s.gear), 'first_kill'));
    return { reward, items };
  }
  if (kind === 'floor' || kind === 'chest') {
    const depth = Math.max(1, Math.trunc(f.depth ?? 1));
    const reward = kind === 'floor' ? rollFloorClear(depth, f.level, s.rand, disc) : rollChest(depth, f.level, s.rand, disc);
    // A floor's item rolls as a surge offering, a chest's as a boss's spoils (the qualities DmDepths always gave them).
    const source: DropSource = kind === 'floor' ? 'surge' : 'boss';
    return { reward, items: tag(rollGearInstances(reward.drops, f.level, f.characterLevel, source, s.gear), source) };
  }
  const offering = rollSurgeItem(f.area, s.rand, disc);
  return { reward: null, items: tag(rollGearInstances([offering], f.level, f.characterLevel, 'surge', s.gear), 'surge') };
}

// ── Lookups the backend's drop claims need (drops.cjs) ─────────────────────────────────────────────────────────────────────

export const isEnemy = (def: string): boolean => Object.prototype.hasOwnProperty.call(ENEMIES, def);
export const isLootArea = (area: string): boolean => Object.prototype.hasOwnProperty.call(AREAS, area) && (areaDef(area).loot.length > 0 || !!AREA_RUNE_POOL[area as AreaId]);
export function bossInfo(id: string): { area: string; shards: number } | null {
  const b = (BOSSES as Record<string, { area: string; shards: number } | undefined>)[id];
  return b ? { area: b.area, shards: b.shards } : null;
}
/** The discipline id of a character's class index ('' when unknown): the smart-loot table and legendary sets follow it. */
export function disciplineIdFor(classIndex: number): string {
  for (const [id, d] of Object.entries(DISCIPLINES as Record<string, { classIndex: number }>)) if (d.classIndex === classIndex) return id;
  return '';
}
export const isLegendaryItem = (id: string): boolean => id.startsWith('leg_');
export { runePityMult } from '../content/runes';
export { hasChest };
/** The highest Wave Speed anyone can own (a hard limit on a claimed drop's facts). */
export const MAX_WAVE_TIER: number = WAVE_UPGRADE.maxTier;
