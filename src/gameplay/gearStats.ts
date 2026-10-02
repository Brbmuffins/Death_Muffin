import type { Character, InventorySlot } from '../net/types';
import { DISCIPLINES, type Discipline, type DisciplineId } from '../content/disciplines';
import { DAMAGE_UPGRADE } from '../content/upgrades';
import { EQUIP_SLOTS, equipSlotOf, equippedBySlot, type EquipSlot } from '../content/gear';
import { NECRO_KIND_LABEL, isTwoHanded, type NecroKind } from '../content/necroWeapons';
import { STAT_KEYS, STAT_LABELS, computeStats, type StatKey } from './stats';
import {
  STAT_EFFECTS as E,
  deriveStats,
  describeStatDelta,
  formatDerived,
  type DerivedKey,
  type DerivedStats,
  type StatDeltaLine,
} from './characterStats';
import { resolveWeaponLoadout, type WeaponLoadout } from './weaponLine';
import { diffSetBonuses, effectRelevant, foldEffect, resolveSetBonuses, setDiffText, withSetBonuses, withoutSetBonuses, type SetDiff, type SetStatus, type SetTotals } from './setBonuses';
import { affixLines, type AffixLine } from './affixes';
import { affixEffect, type AffixStat } from './affixRules';

/**
 * Gear you can read: everything the Reliquary tooltips, the compare block and the Character sheet say about
 * stats is computed here by running deriveStats (never by re-deriving formulas), so the words follow the math.
 */

/** Who is looking: the character, what they wear, the (boon-adjusted) discipline and the Damage tier. */
export interface StatContext {
  character: Character;
  slots: readonly InventorySlot[];
  discipline: Discipline;
  damageTier: number;
}

/** Derived stats for `slots`: the discipline is re-based on the set bonuses those slots would give (gameplay/setBonuses.ts). */
const derive = (ctx: StatContext, slots: readonly InventorySlot[] = ctx.slots, character: Character = ctx.character) =>
  deriveStats(character, slots as InventorySlot[], withSetBonuses(ctx.discipline, slots), ctx.damageTier);

// --- 1. What a single stat line on an item does for THIS character -----------------------------

export interface ItemStatEffect {
  stat: StatKey;
  value: number;
  /** "+6 VIT" */
  head: string;
  /** The derived numbers it moves; empty when the stat does nothing for this character. */
  lines: StatDeltaLine[];
}

/** For every stat on the item: the derived numbers it moves (run through deriveStats, so multipliers count). */
export function itemStatEffects(ctx: StatContext, item: Pick<InventorySlot, 'stat_bonus'>): ItemStatEffect[] {
  const out: ItemStatEffect[] = [];
  const base = derive(ctx);
  for (const k of STAT_KEYS) {
    const v = item.stat_bonus?.[k] ?? 0;
    if (!v) continue;
    const bumped = { ...ctx.character, [k]: (ctx.character[k] ?? 0) + v } as Character;
    out.push({ stat: k, value: v, head: `${v > 0 ? '+' : ''}${v} ${STAT_LABELS[k]}`, lines: describeStatDelta(base, derive(ctx, ctx.slots, bumped)) });
  }
  return out;
}

export interface ItemAffixEffect extends AffixLine {
  /** The derived numbers this affix moves for THIS character (on top of what is worn now); empty when it does nothing for them. */
  lines: StatDeltaLine[];
  /** False for necromancer-only levers on another class. */
  relevant: boolean;
}

/** For every affix on a rolled piece: what it does for this character, run through deriveStats like the base stat lines. */
export function itemAffixEffects(ctx: StatContext, item: Pick<InventorySlot, 'inst'>): ItemAffixEffect[] {
  const base = derive(ctx);
  const disc = withSetBonuses(ctx.discipline, ctx.slots);
  return affixLines(item).map((l) => {
    const e = affixEffect(l.roll);
    let after: DerivedStats;
    if (e.stats) {
      const bumped = { ...ctx.character } as Character;
      for (const [k, v] of Object.entries(e.stats)) (bumped as unknown as Record<string, number>)[k] = (ctx.character[k as AffixStat] ?? 0) + (v as number);
      after = derive(ctx, ctx.slots, bumped);
    } else after = deriveStats(ctx.character, ctx.slots as InventorySlot[], { ...disc, mods: foldEffect(disc.mods, e) }, ctx.damageTier);
    return { ...l, lines: describeStatDelta(base, after), relevant: effectRelevant(e, ctx.discipline) };
  });
}

/** "+48 health (+22 thrall health)": thralls grouped in brackets so your own numbers lead. */
export function effectText(lines: StatDeltaLine[]): string {
  if (!lines.length) return 'no effect for you';
  const fmt = (l: StatDeltaLine) => `${l.text} ${l.label}`;
  const own = lines.filter((l) => !l.key.startsWith('thrall')).map(fmt).join(', ');
  const thralls = lines.filter((l) => l.key.startsWith('thrall')).map(fmt).join(', ');
  return [own, thralls && (own ? `(${thralls})` : thralls)].filter(Boolean).join(' ');
}

// --- 2. Compare with what you wear ---------------------------------------------------------------

/** The slots after equipping bag item `bagIndex`, by the server's rules (a two-hander displaces the off-hand and vice versa). */
export function simulateEquip(slots: readonly InventorySlot[], bagIndex: number): { slots: InventorySlot[]; displaced: InventorySlot[]; gearSlot: EquipSlot | null } {
  const copy = slots.map((s) => ({ ...s }));
  const item = copy.find((s) => s.slot_index === bagIndex);
  const gearSlot = item ? equipSlotOf(item) : null;
  if (!item || !gearSlot || item.equipped) return { slots: copy, displaced: [], gearSlot };
  const displaced = copy.filter((s) => {
    if (s === item || !s.equipped) return false;
    const at = equipSlotOf(s);
    if (at === gearSlot) return true;
    if (isTwoHanded(item.item_id) && at === 'off_hand') return true;
    return gearSlot === 'off_hand' && at === 'main_hand' && isTwoHanded(s.item_id);
  });
  for (const d of displaced) d.equipped = 0;
  item.equipped = 1;
  return { slots: copy, displaced, gearSlot };
}

/** One plain sentence per thing a weapon or off-hand changes about how you fight. */
export function loadoutEffects(l: WeaponLoadout): { id: string; text: string }[] {
  const pct = (x: number) => `${Math.round(Math.abs(x - 1) * 100)}%`;
  const out: { id: string; text: string }[] = [];
  if (l.reap) out.push({ id: 'reap', text: 'Left click becomes a reaping arc' });
  if (l.needleRangeMult > 1 || l.needlePierce) out.push({ id: 'pierce', text: `Left click reaches ${pct(l.needleRangeMult)} farther and pierces` });
  if (l.spellMult > 1) out.push({ id: 'spell', text: `+${pct(l.spellMult)} spell damage` });
  if (l.needleCadenceMult !== 1) out.push({ id: 'cadence', text: `Left click fires ${pct(l.needleCadenceMult)} faster but ${pct(l.needleDamageMult)} softer` });
  if (l.needleWithered) out.push({ id: 'withered', text: 'Left click leaves targets Withered' });
  if (l.exhumeRefund) out.push({ id: 'exhume', text: `Exhume refunds ${Math.round(l.exhumeRefund * 100)}% of its essence` });
  if (l.thrallBonus) out.push({ id: 'thrallcap', text: `+${l.thrallBonus} thrall cap` });
  if (l.riteCooldownMult !== 1) out.push({ id: 'rites', text: `Rites recover ${pct(l.riteCooldownMult)} sooner` });
  if (l.bellAllyHeal) out.push({ id: 'bell', text: `Wraith hits heal allies for ${Math.round(l.bellAllyHeal * 100)}% of their health` });
  return out;
}

export interface EquipComparison {
  gearSlot: EquipSlot;
  /** Worn items that go back to the bag (the same slot, plus the off-hand for a two-hander). */
  replaced: InventorySlot[];
  before: DerivedStats;
  after: DerivedStats;
  lines: StatDeltaLine[];
  /** Weapon-line effects the swap gains / loses, as text (necromancer disciplines only). */
  gained: string[];
  lost: string[];
  /** STR/AGI/INT/VIT totals that move. */
  statChanges: { stat: StatKey; before: number; after: number }[];
  /** Armor set bonuses the swap switches on or off (only ones that do something for this discipline). */
  sets: SetDiff;
}

/** What would change if you equipped this bag item now; null when it is already worn, or is not gear. */
export function compareEquip(ctx: StatContext, item: InventorySlot): EquipComparison | null {
  if (item.equipped) return null;
  const sim = simulateEquip(ctx.slots, item.slot_index);
  if (!sim.gearSlot) return null;
  const before = derive(ctx);
  const after = derive(ctx, sim.slots);
  const eb = loadoutEffects(resolveWeaponLoadout(equippedBySlot(ctx.slots), ctx.discipline.id));
  const ea = loadoutEffects(resolveWeaponLoadout(equippedBySlot(sim.slots), ctx.discipline.id));
  const idsB = new Set(eb.map((e) => e.id));
  const idsA = new Set(ea.map((e) => e.id));
  const tb = computeStats(ctx.character, ctx.slots as InventorySlot[]).total;
  const ta = computeStats(ctx.character, sim.slots).total;
  return {
    gearSlot: sim.gearSlot,
    replaced: sim.displaced.map((d) => ctx.slots.find((s) => s.slot_index === d.slot_index)).filter((s): s is InventorySlot => !!s),
    before,
    after,
    lines: describeStatDelta(before, after),
    gained: ea.filter((e) => !idsB.has(e.id)).map((e) => e.text),
    lost: eb.filter((e) => !idsA.has(e.id)).map((e) => e.text),
    statChanges: STAT_KEYS.filter((k) => tb[k] !== ta[k]).map((k) => ({ stat: k, before: tb[k], after: ta[k] })),
    sets: diffSetBonuses(ctx.slots, sim.slots, ctx.discipline),
  };
}

// --- 3. The Character sheet ----------------------------------------------------------------------

export interface SheetRow {
  label: string;
  value: string;
  tone?: 'up' | 'down';
  /** The closing line of a breakdown. */
  total?: boolean;
}
export interface SheetLine {
  id: string;
  label: string;
  value: string;
  /** What this number is for, one sentence. */
  help: string;
  rows: SheetRow[];
}
/** A titled block of lines. */
export interface SheetSection {
  id: string;
  title: string;
  lines: SheetLine[];
}

export const STAT_PRIMER = 'VIT: health. INT: spell power and essence. STR: a little spell power. AGI: move speed and a little spell power.';

const mult = (x: number) => `×${+x.toFixed(3)}`;
const signed = (x: number, digits = 1) => `${x >= 0 ? '+' : '-'}${Math.abs(x).toFixed(digits).replace(/\.0+$/, '')}`;

/** Worn items that carry stats, with the stat's raw contribution computed by `per`. */
function gearRows(slots: readonly InventorySlot[], per: (bonus: Record<string, number>) => number, digits = 1, unit = ''): SheetRow[] {
  const rows: SheetRow[] = [];
  const worn = equippedBySlot(slots);
  for (const { id } of EQUIP_SLOTS) {
    const s = worn[id];
    if (!s?.stat_bonus) continue;
    const v = per(s.stat_bonus);
    if (v) rows.push({ label: s.name, value: signed(v, digits) + unit, tone: v > 0 ? 'up' : 'down' });
  }
  return rows;
}

/** The share of the discipline's multipliers that came from Covenant boons (folded into `discipline.mods` by the scene). */
export function boonShare(discipline: Discipline): { maxHpMult: number; essenceRegenMult: number } {
  const base = DISCIPLINES[discipline.id]?.mods ?? discipline.mods;
  const mine = withoutSetBonuses(discipline).mods; // armor sets are listed on their own row
  return {
    maxHpMult: mine.maxHpMult / base.maxHpMult,
    essenceRegenMult: mine.essenceRegenMult / base.essenceRegenMult,
  };
}

/** Set bonuses for the Character sheet: one line per set you wear, every bonus listed, active ones green. */
export function setSheetLines(sets: SetStatus[], discipline: Pick<Discipline, 'family'>): SheetLine[] {
  if (!sets.length) {
    return [{
      id: 'set:none', label: 'No set worn', value: '0 / 5',
      help: 'Wear 2, 4 or 5 pieces of one armor set for a bonus. Crowns and grips of the first sets drop in the Hollow Graves.', rows: [],
    }];
  }
  return sets.map((s) => {
    const rows: SheetRow[] = s.bonuses.map((b) => {
      const note = effectRelevant(b.effect, discipline) ? '' : ' (no effect for your class)';
      return {
        label: `${b.pieces} pieces${b.name ? ` \u00B7 ${b.name}` : ''}: ${b.lines.join(' \u00B7 ')}${note}`,
        value: b.active ? 'Active' : `${b.pieces - s.worn} more`,
        tone: b.active ? 'up' : undefined,
      };
    });
    if (s.next) for (const m of s.missing) rows.push({ label: `Need: ${m.name}`, value: m.where });
    const left = s.next ? s.next - s.worn : 0;
    return {
      id: `set:${s.setId}`, label: s.setName, value: `${s.worn} / 5`,
      help: s.next ? `${left} more ${left === 1 ? 'piece' : 'pieces'} for the ${s.next}-piece bonus.` : 'Full set worn: every bonus is active.',
      rows,
    };
  });
}

/** Item affixes for the Character sheet: one line per worn rolled piece, every affix listed; necromancer levers marked. */
export function affixSheetLines(slots: readonly InventorySlot[], discipline: Pick<Discipline, 'family'>): SheetLine[] {
  const worn = EQUIP_SLOTS.map((e) => equippedBySlot(slots)[e.id]).filter((w): w is InventorySlot => !!w?.inst);
  if (!worn.length) {
    return [{ id: 'affix:none', label: 'No affixes worn', value: '0', help: 'Gear can drop with an item level and up to three affixes. Hover a piece in your bag to see what each would do for you.', rows: [] }];
  }
  return worn.map((w) => ({
    id: `affix:${w.item_id}:${w.slot_index}`,
    label: w.name,
    value: `ilvl ${w.inst!.ilvl}`,
    help: `${w.inst!.affixes.length} ${w.inst!.affixes.length === 1 ? 'affix' : 'affixes'}. Their numbers are inside the lines above (marked "Item affixes").`,
    rows: affixLines(w).map((l) => ({
      label: `${l.necro ? '\u2020 ' : ''}${l.text}${effectRelevant(affixEffect(l.roll), discipline) ? '' : ' (no effect for your class)'}`,
      value: `roll ${Math.round(l.quality * 100)}%`,
      tone: 'up' as const,
    })),
  }));
}

export function statSheet(ctx: StatContext): SheetSection[] {
  const { character, slots, discipline, damageTier } = ctx;
  const d = derive(ctx);
  const { base, total } = computeStats(character, slots as InventorySlot[]);
  const level = d.level;
  const baseMods = DISCIPLINES[discipline.id]?.mods ?? discipline.mods;
  const boons = boonShare(discipline);
  const setRes = resolveSetBonuses(slots);
  const setMult = setRes.setTotals.mult;
  const setStats = setRes.setTotals.stats as Record<string, number>;
  const affMult = setRes.affixTotals.mult;
  /** What the worn set bonuses add through one stat formula ("Set bonuses  +24"). */
  const setRow = (per: (b: Record<string, number>) => number, digits = 1, unit = ''): SheetRow | null => {
    const v = per(setStats);
    return v ? { label: 'Set bonuses', value: signed(v, digits) + unit, tone: v > 0 ? 'up' : 'down' } : null;
  };
  /** What the affixes on each worn piece add through one stat formula (one row per piece, so you can see which item gave it). */
  const affixRows = (per: (b: Record<string, number>) => number, digits = 1, unit = ''): SheetRow[] => {
    const rows: SheetRow[] = [];
    for (const { id } of EQUIP_SLOTS) {
      const w = equippedBySlot(slots)[id];
      if (!w?.inst) continue;
      const stats: Record<string, number> = {};
      for (const a of w.inst.affixes) for (const [k, v] of Object.entries(affixEffect(a).stats ?? {})) stats[k] = (stats[k] ?? 0) + (v as number);
      const v = per(stats);
      if (v) rows.push({ label: `${w.name} (affixes)`, value: signed(v, digits) + unit, tone: v > 0 ? 'up' : 'down' });
    }
    return rows;
  };
  const dmgMult = 1 + DAMAGE_UPGRADE.perTier * damageTier;
  const loadout = resolveWeaponLoadout(equippedBySlot(slots), discipline.id);
  const num = (k: StatKey) => character[k] ?? 0;
  const rowsOf = (...parts: (SheetRow | SheetRow[] | null)[]) => parts.flat().filter((r): r is SheetRow => !!r);
  const multRow = (label: string, m: number): SheetRow | null => (Math.abs(m - 1) < 1e-9 ? null : { label, value: mult(m), tone: m > 1 ? 'up' : 'down' });
  const final = (label: string, v: string): SheetRow => ({ label, value: v, total: true });
  const tiers = `${damageTier} ${damageTier === 1 ? 'tier' : 'tiers'}`;

  const health: SheetLine = {
    id: 'maxHp', label: 'Health', value: formatDerived('maxHp', d.maxHp), help: 'How much you can take before you fall. Comes from VIT and level.',
    rows: rowsOf(
      { label: 'Base', value: String(E.health.base) },
      { label: `Level ${level}`, value: signed((level - 1) * E.health.perLevel) },
      { label: `Your VIT ${num('stat_vit')}`, value: signed(num('stat_vit') * E.health.perVit) },
      gearRows(slots, (b) => (b.stat_vit ?? 0) * E.health.perVit),
      affixRows((b) => (b.stat_vit ?? 0) * E.health.perVit),
      setRow((b) => (b.stat_vit ?? 0) * E.health.perVit),
      multRow(`${discipline.name}`, baseMods.maxHpMult),
      multRow('Covenant boons', boons.maxHpMult),
      multRow('Set bonuses', setMult.maxHpMult ?? 1),
      multRow('Item affixes', affMult.maxHpMult ?? 1),
      final('Health', formatDerived('maxHp', d.maxHp)),
    ),
  };
  const spell: SheetLine = {
    id: 'spellPower', label: 'Spell power', value: formatDerived('spellPower', d.spellPower), help: 'Scales the damage of every rite. Mostly INT; STR and AGI add a little.',
    rows: rowsOf(
      { label: 'Base', value: String(E.spell.base) },
      { label: `Level ${level}`, value: signed((level - 1) * E.spell.perLevel) },
      { label: `Your INT ${num('stat_int')}, STR ${num('stat_str')}, AGI ${num('stat_agi')}`, value: signed(num('stat_int') * E.spell.perInt + num('stat_str') * E.spell.perStr + num('stat_agi') * E.spell.perAgi) },
      gearRows(slots, (b) => (b.stat_int ?? 0) * E.spell.perInt + (b.stat_str ?? 0) * E.spell.perStr + (b.stat_agi ?? 0) * E.spell.perAgi),
      affixRows((b) => (b.stat_int ?? 0) * E.spell.perInt + (b.stat_str ?? 0) * E.spell.perStr + (b.stat_agi ?? 0) * E.spell.perAgi),
      setRow((b) => (b.stat_int ?? 0) * E.spell.perInt + (b.stat_str ?? 0) * E.spell.perStr + (b.stat_agi ?? 0) * E.spell.perAgi),
      multRow(`Damage upgrades (${tiers})`, dmgMult),
      multRow('Weapon line (staff)', loadout.spellMult),
      final('Spell power', formatDerived('spellPower', d.spellPower)),
    ),
  };
  const essence: SheetLine = {
    id: 'maxEssence', label: 'Max essence', value: formatDerived('maxEssence', d.maxEssence), help: 'The pool your rites draw from. INT raises it.',
    rows: rowsOf(
      { label: 'Base', value: String(E.essence.base) },
      { label: `Level ${level}`, value: signed(level * E.essence.perLevel) },
      { label: `Your INT ${num('stat_int')}`, value: signed(num('stat_int') * E.essence.perInt) },
      gearRows(slots, (b) => (b.stat_int ?? 0) * E.essence.perInt),
      affixRows((b) => (b.stat_int ?? 0) * E.essence.perInt),
      setRow((b) => (b.stat_int ?? 0) * E.essence.perInt),
      final('Max essence', formatDerived('maxEssence', d.maxEssence)),
    ),
  };
  const regen: SheetLine = {
    id: 'essenceRegen', label: 'Essence/s', value: formatDerived('essenceRegen', d.essenceRegen), help: 'How fast essence returns each second. INT helps a little.',
    rows: rowsOf(
      { label: 'Base', value: String(E.essenceRegen.base) },
      { label: `Your INT ${num('stat_int')}`, value: signed(num('stat_int') * E.essenceRegen.perInt) },
      gearRows(slots, (b) => (b.stat_int ?? 0) * E.essenceRegen.perInt),
      affixRows((b) => (b.stat_int ?? 0) * E.essenceRegen.perInt),
      setRow((b) => (b.stat_int ?? 0) * E.essenceRegen.perInt),
      multRow(`${discipline.name}`, baseMods.essenceRegenMult),
      multRow('Covenant boons', boons.essenceRegenMult),
      multRow('Set bonuses', setMult.essenceRegenMult ?? 1),
      multRow('Item affixes', affMult.essenceRegenMult ?? 1),
      final('Essence/s', formatDerived('essenceRegen', d.essenceRegen)),
    ),
  };
  const move: SheetLine = {
    id: 'moveSpeed', label: 'Move speed', value: `${formatDerived('moveSpeed', d.moveSpeed)} m/s`, help: `How fast you walk. Every AGI adds ${+(E.moveSpeed.perAgi * 100).toFixed(2)}%.`,
    rows: rowsOf(
      { label: 'Base', value: `${E.moveSpeed.base} m/s` },
      { label: `Your AGI ${num('stat_agi')}`, value: `${signed(num('stat_agi') * E.moveSpeed.perAgi * 100)}%` },
      gearRows(slots, (b) => (b.stat_agi ?? 0) * E.moveSpeed.perAgi * 100, 1, '%'),
      affixRows((b) => (b.stat_agi ?? 0) * E.moveSpeed.perAgi * 100, 1, '%'),
      setRow((b) => (b.stat_agi ?? 0) * E.moveSpeed.perAgi * 100, 1, '%'),
      final('Move speed', `${formatDerived('moveSpeed', d.moveSpeed)} m/s`),
    ),
  };
  const thrallHp: SheetLine = {
    id: 'thrallHp', label: 'Thrall health', value: formatDerived('thrallHp', d.thrallHp), help: `Each thrall has ${Math.round(E.thrall.hpShare * 100)}% of your health, so VIT feeds your army too.`,
    rows: rowsOf(
      { label: 'Your health', value: formatDerived('maxHp', d.maxHp) },
      { label: 'Thrall share', value: mult(E.thrall.hpShare) },
      multRow(`${discipline.name} thralls`, baseMods.thrallHpMult),
      multRow('Set bonuses', setMult.thrallHpMult ?? 1),
      multRow('Item affixes', affMult.thrallHpMult ?? 1),
      final('Thrall health', formatDerived('thrallHp', d.thrallHp)),
    ),
  };
  const thrallDmg: SheetLine = {
    id: 'thrallDamage', label: 'Thrall damage', value: formatDerived('thrallDamage', d.thrallDamage), help: `Each thrall hits for ${Math.round(E.thrall.damageShare * 100)}% of your spell power (before a staff boost).`,
    rows: rowsOf(
      { label: 'Your spell power (no staff)', value: formatDerived('spellPower', d.spellPower / loadout.spellMult) },
      { label: 'Thrall share', value: mult(E.thrall.damageShare) },
      multRow(`${discipline.name} thralls`, baseMods.thrallDamageMult),
      multRow('Set bonuses', setMult.thrallDamageMult ?? 1),
      multRow('Item affixes', affMult.thrallDamageMult ?? 1),
      final('Thrall damage', formatDerived('thrallDamage', d.thrallDamage)),
    ),
  };
  const dmgUp: SheetLine = {
    id: 'damageBonus', label: 'Damage upgrade', value: `+${d.damageBonusPct}%`, help: 'Bought with gold from the HUD: each tier adds spell power.',
    rows: [{ label: `${tiers} × ${Math.round(DAMAGE_UPGRADE.perTier * 100)}%`, value: `+${d.damageBonusPct}%`, total: true }],
  };

  const statLine = (k: StatKey, help: string): SheetLine => ({
    id: k, label: STAT_LABELS[k], value: String(total[k]), help,
    rows: rowsOf({ label: 'Character', value: String(base[k]) }, gearRows(slots, (b) => b[k] ?? 0, 0), affixRows((b) => b[k] ?? 0, 0), setRow((b) => b[k] ?? 0, 0), final(STAT_LABELS[k], String(total[k]))),
  });

  return [
    { id: 'derived', title: 'What you can do', lines: [health, spell, essence, regen, move, thrallHp, thrallDmg, dmgUp] },
    { id: 'sets', title: 'Set bonuses', lines: setSheetLines(setRes.sets, discipline) },
    { id: 'affixes', title: 'Item affixes', lines: affixSheetLines(slots, discipline) },
    {
      id: 'stats', title: 'Stats',
      lines: [
        statLine('stat_str', 'A little spell power.'),
        statLine('stat_agi', 'Move speed and a little spell power.'),
        statLine('stat_int', 'Spell power, essence and essence regeneration.'),
        statLine('stat_vit', 'Health, and through it thrall health.'),
      ],
    },
  ];
}

// --- 4. Gear score: what is good for THIS discipline ---------------------------------------------
//
// One "power" number per discipline, built only from deriveStats outputs (so it follows the real math):
//
//   damage    = spell power + thralls x thrall damage x thrall attack speed
//   toughness = health + thralls x thrall health x THRALL_TOUGH_SHARE   (thralls soak hits, but only partly for you)
//   sustain   = max essence and essence/s (half each)
//   move      = move speed
//
// Each part is divided by its value for a reference hero of the same discipline (REFERENCE) so they share a
// scale, then weighted by the discipline's role (ROLE_WEIGHTS, summing to 1). "Thralls" is the discipline's
// thrall cap for necromancers and 0 for every other class. Item scores and stat priorities are both
// percent changes of this one number, so the arrows and the priority list can never disagree.

export type PowerPart = 'damage' | 'toughness' | 'sustain' | 'move';
export type RoleWeights = Record<PowerPart, number>;

/** Thralls count for a quarter of their health when judging how tough you are. */
export const THRALL_TOUGH_SHARE = 0.25;

/** The hero the weights are measured on: mid-game, every stat at 10, no gear. */
export const REFERENCE = { level: 20, stat: 10 } as const;

const NECRO_ROLE: RoleWeights = { damage: 0.5, toughness: 0.3, sustain: 0.15, move: 0.05 };
/** What each discipline cares about. Ossuary is the shield-wall (thralls draw aggression, bonus health). */
export const ROLE_WEIGHTS: Record<DisciplineId, RoleWeights> = {
  ossuary: { damage: 0.35, toughness: 0.5, sustain: 0.1, move: 0.05 },
  gravecaller: { ...NECRO_ROLE },
  mourner: { damage: 0.45, toughness: 0.3, sustain: 0.2, move: 0.05 },
  rotweaver: { damage: 0.55, toughness: 0.25, sustain: 0.15, move: 0.05 },
  grave_warden: { damage: 0.4, toughness: 0.4, sustain: 0.1, move: 0.1 },
  bell_monk: { damage: 0.4, toughness: 0.3, sustain: 0.15, move: 0.15 },
  carrion_witch: { damage: 0.5, toughness: 0.25, sustain: 0.15, move: 0.1 },
  hollow_knight: { damage: 0.4, toughness: 0.45, sustain: 0.05, move: 0.1 },
  veilwalker: { damage: 0.45, toughness: 0.2, sustain: 0.15, move: 0.2 },
};

type Parts = Record<PowerPart, number>;

/** How many thralls the discipline fights with (necromancer family only). */
function thrallCount(d: Discipline, bonus = 0) {
  return d.family === 'necromancer' ? d.mods.thrallCap + bonus : 0;
}

function partsOf(d: DerivedStats, disc: Discipline, count: number): Parts {
  return {
    damage: d.spellPower + count * d.thrallDamage * disc.mods.thrallAttackSpeedMult,
    toughness: d.maxHp + count * d.thrallHp * THRALL_TOUGH_SHARE,
    sustain: 0.5 * d.maxEssence + 0.5 * d.essenceRegen,
    move: d.moveSpeed,
  };
}

const refCache = new Map<string, Parts>();
function referenceParts(disc: Discipline): Parts {
  const key = `${disc.id}:${disc.mods.thrallCap}`;
  let r = refCache.get(key);
  if (!r) {
    const c = refCharacter();
    const d = deriveStats(c, [], disc, 0);
    // Reference energy terms use the same halves, scaled so each part is ~1 at the reference hero.
    const p = partsOf(d, disc, thrallCount(disc));
    r = { damage: p.damage, toughness: p.toughness, sustain: 0.5 * d.maxEssence + 0.5 * d.essenceRegen, move: p.move };
    refCache.set(key, r);
  }
  return r;
}

const refCharacter = (over: Partial<Character> = {}): Character => ({
  id: 0, class_index: 1, class_name: '', level: REFERENCE.level, experience: 0, gold: 0,
  stat_str: REFERENCE.stat, stat_agi: REFERENCE.stat, stat_int: REFERENCE.stat, stat_vit: REFERENCE.stat, ...over,
});

/** Percent of power each part is worth, keyed by the derived number it comes from (for "why" text). */
export type ScoreTerm = DerivedKey | 'weapon' | 'set';

function powerTerms(d: DerivedStats, disc: Discipline, count: number, extraPct: number, refDisc: Discipline = disc, setPct = 0): Record<ScoreTerm, number> {
  const w = ROLE_WEIGHTS[disc.id] ?? NECRO_ROLE;
  // The yardstick never includes armor sets, so gaining or losing a set bonus moves the score instead of cancelling out.
  const ref = referenceParts(withoutSetBonuses(refDisc));
  const t: Record<ScoreTerm, number> = {
    spellPower: (w.damage * d.spellPower) / ref.damage,
    thrallDamage: (w.damage * count * d.thrallDamage * disc.mods.thrallAttackSpeedMult) / ref.damage,
    maxHp: (w.toughness * d.maxHp) / ref.toughness,
    thrallHp: (w.toughness * count * d.thrallHp * THRALL_TOUGH_SHARE) / ref.toughness,
    maxEssence: (w.sustain * 0.5 * d.maxEssence) / ref.sustain,
    essenceRegen: (w.sustain * 0.5 * d.essenceRegen) / ref.sustain,
    moveSpeed: (w.move * d.moveSpeed) / ref.move,
    weapon: 0,
    set: 0,
  };
  const base = Object.values(t).reduce((a, b) => a + b, 0);
  t.weapon = (base * extraPct) / 100;
  t.set = (base * setPct) / 100;
  return t;
}

/**
 * Value of the weapon-line effects that deriveStats cannot see, in percent of power. These are judgment
 * calls, stated here so they can be tuned: (the staff's +10% spell damage and a skull focus's thrall cap are
 * already counted by the maths above and are NOT repeated here.)
 */
export const LOADOUT_VALUE = {
  /** Reaping arc: hits 3, pays souls and essence. */
  reap: 6,
  /** Staff: the needle reaches farther and pierces. */
  pierce: 3,
  /** Wand: share of your damage that is the left click, times its net speed-up. */
  primaryShare: 0.4,
  /** Sickle: Withered stacks; Exhume refund. */
  withered: 3,
  exhume: 2,
  /** Grimoire: rites are about 45% of your output, and recover 1/0.9 as often. */
  riteShare: 0.45,
  /** Mourning bell (Mourner): heals the party. */
  bell: 2,
} as const;

export function loadoutExtraPct(l: WeaponLoadout): number {
  let x = 0;
  if (l.reap) x += LOADOUT_VALUE.reap;
  if (l.needlePierce) x += LOADOUT_VALUE.pierce;
  if (l.needleCadenceMult !== 1) x += (l.needleCadenceMult * l.needleDamageMult - 1) * 100 * LOADOUT_VALUE.primaryShare;
  if (l.needleWithered) x += LOADOUT_VALUE.withered;
  if (l.exhumeRefund) x += LOADOUT_VALUE.exhume;
  if (l.riteCooldownMult !== 1) x += (1 / l.riteCooldownMult - 1) * 100 * LOADOUT_VALUE.riteShare;
  if (l.bellAllyHeal) x += LOADOUT_VALUE.bell;
  return x;
}

/**
 * Value of the set-bonus effects that deriveStats cannot see, in percent of power (judgment calls, tunable like
 * LOADOUT_VALUE). Thrall health / damage / attack speed / cap, health, essence regen and flat stats are already
 * in the maths above and are NOT repeated here. Rite effects only count for necromancers.
 */
export const SET_VALUE = {
  /** "Less damage per thrall" multiplies the toughness part by 1 / (1 - ward x thralls), capped at this much reduction. */
  wardCap: 0.6,
  /** Percent of power per 1% of max health a Black Litany barrier grants per corpse. */
  litanyPer1pct: 0.4,
  /** Percent of power per 1% of max health a consumed corpse heals. */
  corpseHealPer1pct: 0.5,
  /** Percent of power per extra Withered stack. */
  witheredPerStack: 1.5,
  /** Percent of power per 1% wider Miasma. */
  miasmaPer1pct: 0.4,
} as const;

/** The value of the worn sets' mods-only effects, for a discipline that fights with `count` thralls. */
export function setExtraPct(totals: SetTotals, disc: Discipline, count: number): number {
  if (disc.family !== 'necromancer') return 0;
  const w = ROLE_WEIGHTS[disc.id] ?? NECRO_ROLE;
  const V = SET_VALUE;
  let x = 0;
  const ward = totals.add.wardPerThrall ?? 0;
  if (ward) x += w.toughness * 100 * (1 / (1 - Math.min(V.wardCap, ward * count)) - 1);
  x += (totals.add.litanyBarrier ?? 0) * 100 * V.litanyPer1pct;
  x += (totals.add.corpseHeal ?? 0) * 100 * V.corpseHealPer1pct;
  x += (totals.add.witheredMaxStacks ?? 0) * V.witheredPerStack;
  x += ((totals.mult.miasmaRadiusMult ?? 1) - 1) * 100 * V.miasmaPer1pct;
  return x;
}

export interface Power {
  total: number;
  terms: Record<ScoreTerm, number>;
}

/** Power of this character wearing `slots` (the scene's discipline already carries the worn skull focus's thrall bonus). */
export function gearPower(ctx: StatContext, slots: readonly InventorySlot[] = ctx.slots): Power {
  const now = resolveWeaponLoadout(equippedBySlot(ctx.slots), ctx.discipline.id);
  const then = resolveWeaponLoadout(equippedBySlot(slots), ctx.discipline.id);
  // The discipline as `slots` would leave it: set bonuses can change the thrall cap and thrall attack speed too.
  const disc = withSetBonuses(ctx.discipline, slots);
  const count = thrallCount(disc, then.thrallBonus - now.thrallBonus);
  const terms = powerTerms(derive(ctx, slots), disc, count, loadoutExtraPct(then), ctx.discipline, setExtraPct(resolveSetBonuses(slots).totals, disc, count));
  return { total: Object.values(terms).reduce((a, b) => a + b, 0), terms };
}

// --- stat priority --------------------------------------------------------------------------------

export interface StatPriority {
  /** Best first. */
  order: StatKey[];
  /** Percent of power one point is worth for the reference hero. */
  weights: Record<StatKey, number>;
}

/** Percent of power one more point of each stat is worth, measured through deriveStats. */
export function statWeights(disc: Discipline): Record<StatKey, number> {
  const count = thrallCount(disc);
  const base = Object.values(powerTerms(deriveStats(refCharacter(), [], disc, 0), disc, count, 0)).reduce((a, b) => a + b, 0);
  const out = {} as Record<StatKey, number>;
  for (const k of STAT_KEYS) {
    const more = deriveStats(refCharacter({ [k]: REFERENCE.stat + 1 } as Partial<Character>), [], disc, 0);
    const p = Object.values(powerTerms(more, disc, count, 0)).reduce((a, b) => a + b, 0);
    out[k] = ((p - base) / base) * 100;
  }
  return out;
}

const PRIORITY_TIE: StatKey[] = ['stat_int', 'stat_vit', 'stat_str', 'stat_agi'];
export const STAT_PRIORITY = Object.fromEntries(
  (Object.keys(DISCIPLINES) as DisciplineId[]).map((id) => {
    const weights = statWeights(DISCIPLINES[id]);
    const order = [...STAT_KEYS].sort((a, b) => weights[b] - weights[a] || PRIORITY_TIE.indexOf(a) - PRIORITY_TIE.indexOf(b));
    return [id, { order, weights } satisfies StatPriority];
  }),
) as Record<DisciplineId, StatPriority>;

// --- item verdicts --------------------------------------------------------------------------------

export type VerdictKind = 'upgrade' | 'downgrade' | 'same';
export interface ItemVerdict {
  kind: VerdictKind;
  /** Percent change of power (rounded to 0.1). */
  pct: number;
  empty: boolean;
  replaced: InventorySlot[];
  /** "more thrall damage" */
  reason: string;
  /** The full one-liner. */
  text: string;
  /** Set bonuses the swap switches on / off, and the phrase for them ("completes Ivory Reliquary 4-piece"). */
  sets: SetDiff;
  setNote: string;
}

const REASON: Record<ScoreTerm, [string, string]> = {
  spellPower: ['more spell power', 'less spell power'],
  thrallDamage: ['more thrall damage', 'less thrall damage'],
  maxHp: ['more health', 'less health'],
  thrallHp: ['tougher thralls', 'frailer thralls'],
  maxEssence: ['more essence', 'less essence'],
  essenceRegen: ['faster essence regen', 'slower essence regen'],
  moveSpeed: ['faster movement', 'slower movement'],
  weapon: ['a better weapon effect', 'a worse weapon effect'],
  set: ['a set bonus', 'a lost set bonus'],
};

/** The reason for a swing in mods-only value when no set bonus changed (item affixes: ward, Miasma, Withered stacks, corpse healing). */
const REASON_AFFIX: [string, string] = ['stronger ward or rite effects', 'weaker ward or rite effects'];

const SAME_AT = 1;
const num = (x: number) => `${Math.round(Math.abs(x))}%`;

/** Upgrade or downgrade for this discipline, versus whatever the item would replace. Null for worn items and non-gear. */
export function itemVerdict(ctx: StatContext, item: InventorySlot): ItemVerdict | null {
  if (item.equipped) return null;
  const sim = simulateEquip(ctx.slots, item.slot_index);
  if (!sim.gearSlot) return null;
  const a = gearPower(ctx);
  const b = gearPower(ctx, sim.slots);
  const raw = ((b.total - a.total) / a.total) * 100;
  const replaced = sim.displaced.map((d) => ctx.slots.find((s) => s.slot_index === d.slot_index)).filter((s): s is InventorySlot => !!s);
  const empty = replaced.length === 0;
  const kind: VerdictKind = empty || raw >= SAME_AT ? 'upgrade' : raw <= -SAME_AT ? 'downgrade' : 'same';
  const pct = Math.round((empty ? Math.max(raw, 0) : raw) * 10) / 10;
  // The biggest mover, in the direction of the verdict.
  const sign = raw >= 0 ? 1 : -1;
  let best: ScoreTerm = 'spellPower';
  let bestVal = 0;
  for (const k of Object.keys(a.terms) as ScoreTerm[]) {
    const dv = (b.terms[k] - a.terms[k]) * sign;
    if (dv > bestVal) { bestVal = dv; best = k; }
  }
  const sets = diffSetBonuses(ctx.slots, sim.slots, ctx.discipline);
  const setNote = setDiffText(sets);
  // The `set` term is every mods-only effect: a set bonus, or ward / Miasma / Withered affixes. Name what actually moved.
  const viaAffix = best === 'set' && !sets.gained.length && !sets.lost.length;
  const reason = bestVal > 0 ? (viaAffix ? REASON_AFFIX : REASON[best])[sign > 0 ? 0 : 1] : '';
  const names = replaced.map((r) => r.name).join(' and ');
  const slotLabel = EQUIP_SLOTS.find((e) => e.id === sim.gearSlot)?.label.toLowerCase() ?? 'gear';
  const tail = reason ? ` (${reason})` : '';
  const text =
    (kind === 'upgrade'
      ? empty
        ? `Upgrade for your ${ctx.discipline.name}: fills an empty ${slotLabel} slot${pct >= 1 ? ` (+${num(pct)}, ${reason})` : ''}`
        : `Upgrade for your ${ctx.discipline.name}: +${num(pct)}${tail}`
      : kind === 'downgrade'
        ? `Worse than your ${names}: \u2212${num(pct)}${tail}`
        : `About the same as your ${names}`) + (setNote ? ` \u2014 ${setNote}` : '');
  return { kind, pct, empty, replaced, reason, text, sets, setNote };
}

// --- "What you're looking for" ----------------------------------------------------------------------

const STAT_NAME: Record<StatKey, string> = { stat_str: 'STR', stat_agi: 'AGI', stat_int: 'INT', stat_vit: 'VIT' };
const NECRO_WHY: Record<StatKey, string> = {
  stat_int: 'INT makes your spells and your legion hit harder',
  stat_vit: 'VIT keeps you and your thralls alive',
  stat_str: 'STR adds a little spell power',
  stat_agi: 'AGI makes you faster',
};
const OTHER_WHY: Record<StatKey, string> = {
  stat_int: 'INT raises spell power and essence',
  stat_vit: 'VIT raises your health',
  stat_str: 'STR adds a little spell power',
  stat_agi: 'AGI makes you faster',
};

/** Weapon kinds worth carrying, by necromancer discipline (the reasons match the Codex Weapons tab). */
export const RECOMMENDED_WEAPONS: Partial<Record<DisciplineId, { kinds: NecroKind[]; why: string }>> = {
  ossuary: { kinds: ['staff', 'grimoire'], why: 'the staff adds spell damage, the grimoire speeds your rites' },
  gravecaller: { kinds: ['scythe', 'skull_focus'], why: 'fight beside your legion; a gold or better skull adds a thrall' },
  mourner: { kinds: ['staff', 'mourning_bell'], why: 'the bell heals the party each time your wraiths hit' },
  rotweaver: { kinds: ['sickle', 'grimoire'], why: 'Withered ticks on its own, and the grimoire speeds Miasma' },
};

export interface WeakSlot {
  slot: EquipSlot;
  text: string;
  empty: boolean;
}
export interface Looking {
  discipline: string;
  order: StatKey[];
  /** "INT > VIT > STR > AGI" */
  orderText: string;
  /** Two short reasons. */
  why: string;
  weapons: string | null;
  weakest: WeakSlot[];
}

/** Worn pieces' share of your power, lowest first, plus empty slots; with the best bag upgrade named when there is one. */
export function weakestSlots(ctx: StatContext, limit = 5): WeakSlot[] {
  const worn = equippedBySlot(ctx.slots);
  const total = gearPower(ctx).total;
  const bag = ctx.slots.filter((s) => !s.equipped && equipSlotOf(s));
  const bestBag = (slot: EquipSlot) => {
    let best: { item: InventorySlot; pct: number } | null = null;
    for (const b of bag) {
      if (equipSlotOf(b) !== slot) continue;
      const v = itemVerdict(ctx, b);
      if (v && v.kind === 'upgrade' && v.pct > (best?.pct ?? 0)) best = { item: b, pct: v.pct };
    }
    return best ? ` Your ${best.item.name} in the bag is +${num(best.pct)}.` : '';
  };
  const twoHander = worn.main_hand && isTwoHanded(worn.main_hand.item_id);
  const out: { w: WeakSlot; rank: number }[] = [];
  for (const { id, label } of EQUIP_SLOTS) {
    const it = worn[id];
    if (!it) {
      if (id === 'off_hand' && twoHander) continue;
      out.push({ rank: -1, w: { slot: id, empty: true, text: `${label}: empty. ${/s$|^Feet$/.test(label) ? 'Anything' : `Any ${label.toLowerCase()}`} is an upgrade.${bestBag(id)}` } });
      continue;
    }
    const without = gearPower(ctx, ctx.slots.map((s) => (s === it ? { ...s, equipped: 0 as const } : s))).total;
    const share = ((total - without) / total) * 100;
    out.push({ rank: share, w: { slot: id, empty: false, text: `${label}: ${it.name} adds only ${num(Math.max(share, 0))}.${bestBag(id)}` } });
  }
  return out.sort((a, b) => a.rank - b.rank).slice(0, limit).map((x) => x.w);
}

export function lookingFor(ctx: StatContext): Looking {
  const pr = STAT_PRIORITY[ctx.discipline.id] ?? STAT_PRIORITY.gravecaller;
  const why = ctx.discipline.family === 'necromancer' ? NECRO_WHY : OTHER_WHY;
  const rec = RECOMMENDED_WEAPONS[ctx.discipline.id];
  return {
    discipline: ctx.discipline.name,
    order: pr.order,
    orderText: pr.order.map((k) => STAT_NAME[k]).join(' > '),
    why: `${why[pr.order[0]]}; ${why[pr.order[1]]}.`,
    weapons: rec ? `${rec.kinds.map((k) => NECRO_KIND_LABEL[k]).join(' and ')}: ${rec.why}.` : null,
    weakest: weakestSlots(ctx),
  };
}
