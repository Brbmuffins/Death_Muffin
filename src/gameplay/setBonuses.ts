import type { InventorySlot } from '../net/types';
import type { Discipline, DisciplineMods } from '../content/disciplines';
import { AREAS } from '../content/areas';
import { ARMOR_BY_ID, ARMOR_PIECES, ARMOR_PARTS, type ArmorPart, type ArmorPiece } from '../content/armorSets';
import { equippedBySlot } from '../content/gear';
import {
  SET_NAMES,
  bonusesOf,
  describeEffect,
  type SetAddKey,
  type SetBonusDef,
  type SetEffect,
  type SetMultKey,
  type SetStatKey,
  type SetTier,
} from '../content/setBonuses';

/**
 * Armor set bonuses, resolved from the worn item ids (like the necro weapon line: no server state).
 * They reach the game through the two pipelines that already exist:
 *   - flat stats: computeStats (gameplay/stats.ts) adds `stats` to the gear totals;
 *   - multipliers / additions: applySetMods folds `mult` / `add` into the discipline `mods`, where the scene
 *     builds the boon-adjusted discipline (WorldScene.applyBoons).
 */

/** The combined mult / add / stat effect of every active bonus. */
export interface SetTotals {
  mult: Partial<Record<SetMultKey, number>>;
  add: Partial<Record<SetAddKey, number>>;
  stats: Partial<Record<SetStatKey, number>>;
}

export const emptyTotals = (): SetTotals => ({ mult: {}, add: {}, stats: {} });

export interface MissingPiece {
  part: ArmorPart;
  name: string;
  /** Where it drops first (area name). */
  where: string;
}

export interface ResolvedBonus extends SetBonusDef {
  setId: string;
  setName: string;
  active: boolean;
  /** One plain line per effect. */
  lines: string[];
}

export interface SetStatus {
  setId: string;
  setName: string;
  disciplineId: string;
  collection: 1 | 2;
  color: number;
  accent: number;
  /** Pieces worn (distinct slots). */
  worn: number;
  wornParts: ArmorPart[];
  missing: MissingPiece[];
  bonuses: ResolvedBonus[];
  /** The next threshold above `worn`, or null when all are active. */
  next: SetTier | null;
}

export interface SetResolution {
  /** Sets with at least one worn piece, most worn first (ascended before first on a tie). */
  sets: SetStatus[];
  active: ResolvedBonus[];
  totals: SetTotals;
}

const PIECES_BY_SET = new Map<string, ArmorPiece[]>();
for (const p of ARMOR_PIECES) PIECES_BY_SET.set(p.setId, [...(PIECES_BY_SET.get(p.setId) ?? []), p]);

/** Worn armor pieces, one per slot (the server allows one item per slot). */
export function wornArmor(slots: readonly InventorySlot[]): ArmorPiece[] {
  const worn = equippedBySlot(slots);
  const out: ArmorPiece[] = [];
  for (const part of ARMOR_PARTS) {
    const piece = worn[part] && ARMOR_BY_ID[worn[part]!.item_id];
    if (piece && piece.part === part) out.push(piece);
  }
  return out;
}

export function setStatus(setId: string, wornParts: ArmorPart[]): SetStatus {
  const pieces = PIECES_BY_SET.get(setId) ?? [];
  const any = pieces[0];
  const worn = wornParts.length;
  const bonuses: ResolvedBonus[] = bonusesOf(setId).map((b) => ({ ...b, setId, setName: SET_NAMES[setId] ?? setId, active: worn >= b.pieces, lines: describeEffect(b.effect) }));
  return {
    setId,
    setName: SET_NAMES[setId] ?? setId,
    disciplineId: any?.disciplineId ?? '',
    collection: any?.collection ?? 1,
    color: any?.color ?? 0,
    accent: any?.accent ?? 0,
    worn,
    wornParts,
    missing: pieces.filter((p) => !wornParts.includes(p.part)).map((p) => ({ part: p.part, name: p.name, where: AREAS[p.area].name })),
    bonuses,
    next: bonuses.find((b) => !b.active)?.pieces ?? null,
  };
}

function addEffect(t: SetTotals, e: SetEffect) {
  for (const [k, v] of Object.entries(e.mult ?? {})) t.mult[k as SetMultKey] = (t.mult[k as SetMultKey] ?? 1) * v!;
  for (const [k, v] of Object.entries(e.add ?? {})) t.add[k as SetAddKey] = (t.add[k as SetAddKey] ?? 0) + v!;
  for (const [k, v] of Object.entries(e.stats ?? {})) t.stats[k as SetStatKey] = (t.stats[k as SetStatKey] ?? 0) + v!;
}

/** Everything the worn armor does: per-set status, the active bonuses and their combined effect. */
export function resolveSetBonuses(slots: readonly InventorySlot[]): SetResolution {
  const bySet = new Map<string, ArmorPart[]>();
  for (const p of wornArmor(slots)) bySet.set(p.setId, [...(bySet.get(p.setId) ?? []), p.part]);
  const sets = [...bySet].map(([id, parts]) => setStatus(id, parts)).sort((a, b) => b.worn - a.worn || b.collection - a.collection);
  const totals = emptyTotals();
  const active: ResolvedBonus[] = [];
  for (const s of sets) for (const b of s.bonuses) if (b.active) { active.push(b); addEffect(totals, b.effect); }
  return { sets, active, totals };
}

/** Flat stats from set bonuses (added to gear in computeStats). */
export function setStatTotals(slots: readonly InventorySlot[]): Partial<Record<SetStatKey, number>> {
  return resolveSetBonuses(slots).totals.stats;
}

/** A short stable string for the active bonuses; the scene rebuilds the discipline when it changes. */
export function setSignature(slots: readonly InventorySlot[]): string {
  return resolveSetBonuses(slots).active.map((b) => `${b.setId}:${b.pieces}`).join('|');
}

// --- Folding into the discipline mods ---------------------------------------------------------------

/** Which set totals are folded into a given mods object (so the same mods can be re-based for a hypothetical outfit). */
const APPLIED = new WeakMap<object, SetTotals>();

function shift(mods: DisciplineMods, t: SetTotals, dir: 1 | -1): DisciplineMods {
  const out: DisciplineMods = { ...mods };
  for (const [k, v] of Object.entries(t.mult)) (out as unknown as Record<string, number>)[k] *= dir === 1 ? v! : 1 / v!;
  for (const [k, v] of Object.entries(t.add)) (out as unknown as Record<string, number>)[k] += dir * v!;
  return out;
}

/** The mods with the set bonuses folded in (returns a new object; the same pattern as Covenant boons). */
export function applySetMods(mods: DisciplineMods, t: SetTotals): DisciplineMods {
  const out = shift(mods, t, 1);
  APPLIED.set(out, t);
  return out;
}

/** The discipline as if you wore `slots`: removes whatever sets are folded in now, adds those of `slots`. */
export function withSetBonuses(d: Discipline, slots: readonly InventorySlot[]): Discipline {
  const now = APPLIED.get(d.mods);
  const next = resolveSetBonuses(slots).totals;
  if (now && JSON.stringify(now) === JSON.stringify(next)) return d;
  const bare = now ? shift(d.mods, now, -1) : d.mods;
  if (!now && !Object.keys(next.mult).length && !Object.keys(next.add).length) return d;
  return { ...d, mods: applySetMods(bare, next) };
}

/** The discipline with set bonuses removed (to tell boons and sets apart on the sheet). */
export function withoutSetBonuses(d: Discipline): Discipline {
  const now = APPLIED.get(d.mods);
  return now ? { ...d, mods: shift(d.mods, now, -1) } : d;
}

// --- Relevance and swaps ----------------------------------------------------------------------------

const ANY_CLASS_MULT = new Set<SetMultKey>(['maxHpMult', 'essenceRegenMult']);

/** Whether an effect does anything for this discipline (thrall and rite effects need a necromancer). */
export function effectRelevant(e: SetEffect, d: Pick<Discipline, 'family'>): boolean {
  if (d.family === 'necromancer') return true;
  if (e.stats && Object.keys(e.stats).length) return true;
  return Object.keys(e.mult ?? {}).some((k) => ANY_CLASS_MULT.has(k as SetMultKey));
}

export interface SetChange {
  setName: string;
  pieces: SetTier;
}
export interface SetDiff {
  gained: SetChange[];
  lost: SetChange[];
}

/** Bonuses that switch on / off when the outfit goes from `before` to `after` (only ones that matter to `d`). */
export function diffSetBonuses(before: readonly InventorySlot[], after: readonly InventorySlot[], d: Pick<Discipline, 'family'>): SetDiff {
  const key = (b: ResolvedBonus) => `${b.setId}:${b.pieces}`;
  const a = resolveSetBonuses(before).active;
  const b = resolveSetBonuses(after).active;
  const ak = new Set(a.map(key));
  const bk = new Set(b.map(key));
  const pick = (list: ResolvedBonus[], not: Set<string>) =>
    list.filter((x) => !not.has(key(x)) && effectRelevant(x.effect, d)).map((x) => ({ setName: x.setName, pieces: x.pieces }));
  return { gained: pick(b, ak), lost: pick(a, bk) };
}

/** "completes Ivory Reliquary 4-piece" / "breaks your Gravecall 2-piece", or ''. */
export function setDiffText(diff: SetDiff): string {
  const parts: string[] = [];
  const top = (list: SetChange[]) => {
    // Several tiers of one set switch together: name the highest.
    const best = new Map<string, SetChange>();
    for (const c of list) if (!best.has(c.setName) || best.get(c.setName)!.pieces < c.pieces) best.set(c.setName, c);
    return [...best.values()];
  };
  const g = top(diff.gained).map((c) => `${c.setName} ${c.pieces}-piece`);
  const l = top(diff.lost).map((c) => `${c.setName} ${c.pieces}-piece`);
  if (g.length) parts.push(`completes ${g.join(' and ')}`);
  if (l.length) parts.push(`breaks your ${l.join(' and ')}`);
  return parts.join(', ');
}
