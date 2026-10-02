/**
 * Item level and affixes (GRIND-LOOP §3 #2): the pure rules for server-rolled loot instances.
 * `npm run build:server-rules` bundles this file into gathering/affix-rules.cjs for the Death Muffin backend (loot.cjs rolls with it,
 * the Vault, Salvage, bag save and offline sync validate with it); the DEV offline mock and the client read the same functions, so
 * the numbers on a tooltip are the numbers the server rolled and the game applies.
 *
 * An instance is `{ ilvl, affixes: [{ id, v }] }`. `v` is a whole number whose unit depends on the affix (see `unit`): stat points,
 * tenths of a percent, or a plain count. Whole numbers keep the JSON exact and make validation a range check.
 *
 * Every affix effect is one the game already reads (the same keys armor set bonuses use), so nothing here needs new sim code:
 *  - `stats` are flat STR/AGI/INT/VIT, added to the gear totals (gameplay/stats.ts computeStats);
 *  - `mult` / `add` fold into the discipline `mods` (WorldScene.applyBoons), exactly like set bonuses and Covenant boons.
 */

export type AffixKind = 'prefix' | 'suffix';
export type AffixStat = 'stat_str' | 'stat_agi' | 'stat_int' | 'stat_vit';
export type AffixMultKey = 'thrallHpMult' | 'thrallDamageMult' | 'essenceRegenMult' | 'miasmaRadiusMult';
export type AffixAddKey = 'witheredMaxStacks' | 'wardPerThrall';

/** Same shape as content/setBonuses SetEffect (kept structural so this file has no runtime imports). */
export interface AffixEffect {
  mult?: Partial<Record<AffixMultKey, number>>;
  add?: Partial<Record<AffixAddKey, number>>;
  stats?: Partial<Record<AffixStat, number>>;
}

export interface AffixRoll {
  id: string;
  v: number;
}
export interface ItemInstanceData {
  ilvl: number;
  affixes: AffixRoll[];
}

export const MAX_AFFIXES = 3;
export const ILVL_MAX = 99;

/** Where a drop came from; it raises the item level a little and the odds of more affixes. */
export type DropSource = 'kill' | 'elite' | 'boss' | 'first_kill' | 'surge';
export const DROP_SOURCES: readonly DropSource[] = ['kill', 'elite', 'boss', 'first_kill', 'surge'];

/** Item types that can roll an instance (the same list the Reliquary and the Bone Grinder treat as gear). */
export const AFFIX_GEAR_TYPES = ['weapon', 'offhand', 'armor_head', 'armor_chest', 'armor_legs', 'armor_feet', 'armor_hands', 'ring', 'trinket'] as const;
export const isAffixGear = (itemType: string) => (AFFIX_GEAR_TYPES as readonly string[]).includes(itemType);

type Unit = 'stat' | 'pct' | 'count' | 'wardPct';

export interface AffixDef {
  id: string;
  kind: AffixKind;
  /** The word on the item name: "Gravebound" before it, "of the Legion" after it. */
  word: string;
  /** Two affixes of one group never share an item (Brutal and "of the Reaver" are both STR). */
  group: string;
  /** Plugs into a necromancer lever (thralls, essence, Miasma, Withered, ward); highlighted in the UI. */
  necro: boolean;
  weight: number;
  unit: Unit;
  /** [lo, hi] for an item level. */
  range: (ilvl: number) => [number, number];
  effect: (v: number) => AffixEffect;
  /** "+4 INT", "Thralls hit +4.5% harder". */
  text: (v: number) => string;
}

const clampInt = (x: number, lo: number, hi: number) => Math.max(lo, Math.min(hi, Math.round(x)));
/** A +-30% window around the centre for this item level, as whole numbers. */
const around = (centre: number, cap: number, floor = 1): [number, number] => {
  const lo = clampInt(centre * 0.7, floor, cap);
  return [lo, clampInt(Math.max(centre * 1.3, lo), lo, cap)];
};
const tenths = (v: number) => `${+(v / 10).toFixed(1)}%`;

const STAT_NAME: Record<AffixStat, string> = { stat_str: 'STR', stat_agi: 'AGI', stat_int: 'INT', stat_vit: 'VIT' };
const statDef = (stat: AffixStat, kind: AffixKind, word: string): AffixDef => ({
  id: `${kind === 'prefix' ? 'p' : 's'}_${stat.slice(5)}`,
  kind,
  word,
  group: stat,
  necro: false,
  weight: 9,
  unit: 'stat',
  range: (L) => around(1 + 0.3 * L, 40),
  effect: (v) => ({ stats: { [stat]: v } }),
  text: (v) => `+${v} ${STAT_NAME[stat]}`,
});

/** The whole pool. Ids are stored in the database: never rename one, only add. */
export const AFFIXES: readonly AffixDef[] = [
  statDef('stat_str', 'prefix', 'Brutal'),
  statDef('stat_agi', 'prefix', 'Fleet'),
  statDef('stat_int', 'prefix', 'Occult'),
  statDef('stat_vit', 'prefix', 'Stout'),
  statDef('stat_str', 'suffix', 'of the Reaver'),
  statDef('stat_agi', 'suffix', 'of the Hound'),
  statDef('stat_int', 'suffix', 'of the Seer'),
  statDef('stat_vit', 'suffix', 'of the Tomb'),
  {
    id: 'p_thrall_dmg', kind: 'prefix', word: 'Gravebound', group: 'thrall_dmg', necro: true, weight: 13, unit: 'pct',
    range: (L) => around(10 * (1.5 + 0.22 * L), 150),
    effect: (v) => ({ mult: { thrallDamageMult: 1 + v / 1000 } }),
    text: (v) => `Thralls hit +${tenths(v)} harder`,
  },
  {
    id: 's_thrall_hp', kind: 'suffix', word: 'of the Legion', group: 'thrall_hp', necro: true, weight: 13, unit: 'pct',
    range: (L) => around(10 * (2 + 0.28 * L), 200),
    effect: (v) => ({ mult: { thrallHpMult: 1 + v / 1000 } }),
    text: (v) => `Thralls have +${tenths(v)} health`,
  },
  {
    id: 'p_essence_regen', kind: 'prefix', word: 'Whispering', group: 'essence_regen', necro: true, weight: 11, unit: 'pct',
    range: (L) => around(10 * (2 + 0.25 * L), 150),
    effect: (v) => ({ mult: { essenceRegenMult: 1 + v / 1000 } }),
    text: (v) => `+${tenths(v)} essence regeneration`,
  },
  {
    id: 's_miasma', kind: 'suffix', word: 'of the Rotting Mist', group: 'miasma', necro: true, weight: 9, unit: 'pct',
    range: (L) => around(10 * (3 + 0.35 * L), 250),
    effect: (v) => ({ mult: { miasmaRadiusMult: 1 + v / 1000 } }),
    text: (v) => `Miasma is +${tenths(v)} wider`,
  },
  {
    id: 'p_withered', kind: 'prefix', word: 'Blighted', group: 'withered', necro: true, weight: 8, unit: 'count',
    range: (L) => [1, clampInt(1 + Math.floor(L / 12), 1, 4)],
    effect: (v) => ({ add: { witheredMaxStacks: v } }),
    text: (v) => `+${v} max Withered stack${v === 1 ? '' : 's'}`,
  },
  {
    id: 's_ward', kind: 'suffix', word: 'of the Ossuary Wall', group: 'ward', necro: true, weight: 9, unit: 'wardPct',
    range: (L) => around(1 + 0.12 * L, 8),
    effect: (v) => ({ add: { wardPerThrall: v / 1000 } }),
    text: (v) => `${tenths(v)} less damage taken per thrall`,
  },
];

const BY_ID = new Map(AFFIXES.map((a) => [a.id, a]));
export const affixDef = (id: string): AffixDef | undefined => BY_ID.get(id);

/** The [lo, hi] a roll of this affix may have on an item of this level. */
export function affixRange(id: string, ilvl: number): [number, number] | null {
  const d = BY_ID.get(id);
  return d ? d.range(clampInt(ilvl, 1, ILVL_MAX)) : null;
}

export const affixEffect = (a: AffixRoll): AffixEffect => BY_ID.get(a.id)?.effect(a.v) ?? {};
export const affixText = (a: AffixRoll): string => BY_ID.get(a.id)?.text(a.v) ?? a.id;
export const affixIsNecro = (a: AffixRoll): boolean => !!BY_ID.get(a.id)?.necro;
export const affixKind = (a: AffixRoll): AffixKind | null => BY_ID.get(a.id)?.kind ?? null;
export const affixWord = (a: AffixRoll): string => BY_ID.get(a.id)?.word ?? '';
/** 0..1: where the roll sits between the weakest and strongest this item level allows. */
export function affixQuality(a: AffixRoll, ilvl: number): number {
  const r = affixRange(a.id, ilvl);
  return !r || r[1] <= r[0] ? 1 : Math.max(0, Math.min(1, (a.v - r[0]) / (r[1] - r[0])));
}

// --- Item level --------------------------------------------------------------------------------------------------------------------

/** Levels a drop source adds to the level of whatever dropped it. */
const SOURCE_ILVL: Record<DropSource, number> = { kill: 0, elite: 2, boss: 4, first_kill: 5, surge: 2 };

/** Item level from the dropper's level. The server calls this with a level it has clamped to the character's reach. */
export const itemLevelFor = (level: number, source: DropSource): number => clampInt((Number(level) || 1) + (SOURCE_ILVL[source] ?? 0), 1, ILVL_MAX);

/** How far above their own level a character may claim a drop came from (a level-5 character in a level-13 zone is real). */
export const ILVL_REACH = 10;
export const clampDropLevel = (level: number, characterLevel: number): number => clampInt(Number(level) || 1, 1, Math.min(ILVL_MAX, Math.max(1, characterLevel) + ILVL_REACH));

// --- Rolling ---------------------------------------------------------------------------------------------------------------------------

const COUNT_WEIGHTS: Record<string, [number, number, number, number]> = {
  common: [60, 30, 9, 1],
  uncommon: [40, 38, 18, 4],
  rare: [22, 38, 30, 10],
  epic: [10, 30, 40, 20],
  legendary: [0, 15, 45, 40],
  relic: [0, 15, 45, 40],
};
/** Multipliers on [0, 1, 2, 3] affixes for a drop source, and the fewest affixes it guarantees. */
const SOURCE_COUNT: Record<DropSource, { mult: [number, number, number, number]; min: number }> = {
  kill: { mult: [1, 1, 1, 1], min: 0 },
  elite: { mult: [0.6, 1, 1.4, 1.8], min: 0 },
  surge: { mult: [0.5, 1, 1.5, 2], min: 0 },
  boss: { mult: [0.15, 0.8, 1.6, 2.4], min: 1 },
  first_kill: { mult: [0, 0.3, 1.6, 2.6], min: 2 },
};

/** How many affixes a drop gets: the base item's rarity sets the odds, the source tilts them. */
export function rollAffixCount(rarity: string, source: DropSource, rand: () => number): number {
  const base = COUNT_WEIGHTS[rarity] ?? COUNT_WEIGHTS.common;
  const s = SOURCE_COUNT[source] ?? SOURCE_COUNT.kill;
  const w = base.map((x, i) => (i < s.min ? 0 : x * s.mult[i]));
  const total = w.reduce((a, b) => a + b, 0) || 1;
  let r = rand() * total;
  for (let i = 0; i < 4; i++) {
    r -= w[i];
    if (r < 0) return i;
  }
  return Math.max(s.min, 0);
}

/** Roll the item level and the affixes. `rand` returns [0, 1). Deterministic for a given sequence. */
export function rollInstance(item: { rarity: string }, level: number, source: DropSource, rand: () => number): ItemInstanceData {
  const ilvl = itemLevelFor(level, source);
  const count = rollAffixCount(item.rarity, source, rand);
  const affixes: AffixRoll[] = [];
  const used = new Set<string>();
  for (let n = 0; n < count; n++) {
    const pool = AFFIXES.filter((a) => !used.has(a.group));
    const total = pool.reduce((s, a) => s + a.weight, 0);
    let r = rand() * total;
    let pick = pool[pool.length - 1];
    for (const a of pool) {
      r -= a.weight;
      if (r < 0) {
        pick = a;
        break;
      }
    }
    used.add(pick.group);
    const [lo, hi] = pick.range(ilvl);
    affixes.push({ id: pick.id, v: lo + Math.min(hi - lo, Math.floor(rand() * (hi - lo + 1))) });
  }
  return { ilvl, affixes };
}

/** Player-readable problem with an instance claimed for an item (offline sync import), or null when it is a legal roll. */
export function instanceProblem(inst: unknown, itemType: string): string | null {
  if (!isAffixGear(itemType)) return 'Only gear can carry affixes.';
  const i = inst as Partial<ItemInstanceData> | null;
  if (!i || typeof i !== 'object' || !Number.isInteger(i.ilvl) || (i.ilvl as number) < 1 || (i.ilvl as number) > ILVL_MAX) return 'Invalid item level.';
  if (!Array.isArray(i.affixes) || i.affixes.length > MAX_AFFIXES) return 'Invalid affixes.';
  const groups = new Set<string>();
  for (const a of i.affixes) {
    const d = a && typeof a.id === 'string' ? BY_ID.get(a.id) : undefined;
    if (!d || !Number.isInteger(a.v)) return 'Unknown affix.';
    if (groups.has(d.group)) return 'Duplicate affix.';
    groups.add(d.group);
    const [lo, hi] = d.range(i.ilvl as number);
    if (a.v < lo || a.v > hi) return 'An affix roll is out of range for its item level.';
  }
  return null;
}

/** A clean copy of a (legal) instance, so extra fields from a client never reach the database. */
export const cleanInstance = (inst: ItemInstanceData): ItemInstanceData => ({ ilvl: inst.ilvl, affixes: inst.affixes.map((a) => ({ id: a.id, v: a.v })) });

// --- Names, rarity and value ---------------------------------------------------------------------------------------------

/** "Gravebound Iron Helm of the Legion": the first prefix and the first suffix; a third affix shows in the lines only. */
export function affixedName(baseName: string, affixes: readonly AffixRoll[]): string {
  const pre = affixes.find((a) => affixKind(a) === 'prefix');
  const suf = affixes.find((a) => affixKind(a) === 'suffix');
  return [pre && affixWord(pre), baseName, suf && affixWord(suf)].filter(Boolean).join(' ');
}

const RARITY_RANK = ['common', 'uncommon', 'rare', 'epic', 'legendary', 'relic'];
/** Rarity colour reflects the affix count: 1 uncommon, 2 rare, 3 epic. A base item never loses rarity. */
export function effectiveRarity(baseRarity: string, affixCount: number): string {
  const floor = RARITY_RANK[Math.max(0, Math.min(3, affixCount))];
  return RARITY_RANK.indexOf(floor) > RARITY_RANK.indexOf(baseRarity) ? floor : baseRarity;
}

/** What the vendor pays: higher item levels and every affix add to the base price. */
export function instanceSellValue(base: number, inst: ItemInstanceData | null | undefined): number {
  if (!inst) return base;
  return Math.max(base, Math.round(base * (1 + 0.02 * inst.ilvl) * (1 + 0.35 * inst.affixes.length)));
}

/** A rough "how good is this roll" for sorting: more affixes first, then item level. */
export const instancePower = (inst: ItemInstanceData | null | undefined): number => (inst ? inst.affixes.length * 1000 + inst.ilvl : 0);

// --- Totals -----------------------------------------------------------------------------------------------------------------------------

export interface AffixTotals {
  mult: Partial<Record<AffixMultKey, number>>;
  add: Partial<Record<AffixAddKey, number>>;
  stats: Partial<Record<AffixStat, number>>;
}
export const emptyAffixTotals = (): AffixTotals => ({ mult: {}, add: {}, stats: {} });

/** Fold one instance's affixes into running totals (multipliers multiply, additions and stats add). */
export function addInstanceTotals(t: AffixTotals, affixes: readonly AffixRoll[]): AffixTotals {
  for (const a of affixes) {
    const e = affixEffect(a);
    for (const [k, v] of Object.entries(e.mult ?? {})) t.mult[k as AffixMultKey] = (t.mult[k as AffixMultKey] ?? 1) * (v as number);
    for (const [k, v] of Object.entries(e.add ?? {})) t.add[k as AffixAddKey] = (t.add[k as AffixAddKey] ?? 0) + (v as number);
    for (const [k, v] of Object.entries(e.stats ?? {})) t.stats[k as AffixStat] = (t.stats[k as AffixStat] ?? 0) + (v as number);
  }
  return t;
}
