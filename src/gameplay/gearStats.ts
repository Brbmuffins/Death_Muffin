import type { Character, InventorySlot } from '../net/types';
import { DISCIPLINES, type Discipline } from '../content/disciplines';
import { DAMAGE_UPGRADE } from '../content/upgrades';
import { EQUIP_SLOTS, equipSlotOf, equippedBySlot, type EquipSlot } from '../content/gear';
import { isTwoHanded } from '../content/necroWeapons';
import { STAT_KEYS, STAT_LABELS, computeStats, type StatKey } from './stats';
import {
  STAT_EFFECTS as E,
  deriveStats,
  describeStatDelta,
  formatDerived,
  type DerivedStats,
  type StatDeltaLine,
} from './characterStats';
import { resolveWeaponLoadout, type WeaponLoadout } from './weaponLine';

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

const derive = (ctx: StatContext, slots: readonly InventorySlot[] = ctx.slots, character: Character = ctx.character) =>
  deriveStats(character, slots as InventorySlot[], ctx.discipline, ctx.damageTier);

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
/** A titled block of lines. A later "Set bonuses" section is one more entry here. */
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
  return {
    maxHpMult: discipline.mods.maxHpMult / base.maxHpMult,
    essenceRegenMult: discipline.mods.essenceRegenMult / base.essenceRegenMult,
  };
}

export function statSheet(ctx: StatContext): SheetSection[] {
  const { character, slots, discipline, damageTier } = ctx;
  const d = derive(ctx);
  const { base, total } = computeStats(character, slots as InventorySlot[]);
  const level = d.level;
  const baseMods = DISCIPLINES[discipline.id]?.mods ?? discipline.mods;
  const boons = boonShare(discipline);
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
      multRow(`${discipline.name}`, baseMods.maxHpMult),
      multRow('Covenant boons', boons.maxHpMult),
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
      final('Max essence', formatDerived('maxEssence', d.maxEssence)),
    ),
  };
  const regen: SheetLine = {
    id: 'essenceRegen', label: 'Essence/s', value: formatDerived('essenceRegen', d.essenceRegen), help: 'How fast essence returns each second. INT helps a little.',
    rows: rowsOf(
      { label: 'Base', value: String(E.essenceRegen.base) },
      { label: `Your INT ${num('stat_int')}`, value: signed(num('stat_int') * E.essenceRegen.perInt) },
      gearRows(slots, (b) => (b.stat_int ?? 0) * E.essenceRegen.perInt),
      multRow(`${discipline.name}`, baseMods.essenceRegenMult),
      multRow('Covenant boons', boons.essenceRegenMult),
      final('Essence/s', formatDerived('essenceRegen', d.essenceRegen)),
    ),
  };
  const move: SheetLine = {
    id: 'moveSpeed', label: 'Move speed', value: `${formatDerived('moveSpeed', d.moveSpeed)} m/s`, help: `How fast you walk. Every AGI adds ${+(E.moveSpeed.perAgi * 100).toFixed(2)}%.`,
    rows: rowsOf(
      { label: 'Base', value: `${E.moveSpeed.base} m/s` },
      { label: `Your AGI ${num('stat_agi')}`, value: `${signed(num('stat_agi') * E.moveSpeed.perAgi * 100)}%` },
      gearRows(slots, (b) => (b.stat_agi ?? 0) * E.moveSpeed.perAgi * 100, 1, '%'),
      final('Move speed', `${formatDerived('moveSpeed', d.moveSpeed)} m/s`),
    ),
  };
  const thrallHp: SheetLine = {
    id: 'thrallHp', label: 'Thrall health', value: formatDerived('thrallHp', d.thrallHp), help: `Each thrall has ${Math.round(E.thrall.hpShare * 100)}% of your health, so VIT feeds your army too.`,
    rows: rowsOf(
      { label: 'Your health', value: formatDerived('maxHp', d.maxHp) },
      { label: 'Thrall share', value: mult(E.thrall.hpShare) },
      multRow(`${discipline.name} thralls`, baseMods.thrallHpMult),
      final('Thrall health', formatDerived('thrallHp', d.thrallHp)),
    ),
  };
  const thrallDmg: SheetLine = {
    id: 'thrallDamage', label: 'Thrall damage', value: formatDerived('thrallDamage', d.thrallDamage), help: `Each thrall hits for ${Math.round(E.thrall.damageShare * 100)}% of your spell power (before a staff boost).`,
    rows: rowsOf(
      { label: 'Your spell power (no staff)', value: formatDerived('spellPower', d.spellPower / loadout.spellMult) },
      { label: 'Thrall share', value: mult(E.thrall.damageShare) },
      multRow(`${discipline.name} thralls`, baseMods.thrallDamageMult),
      final('Thrall damage', formatDerived('thrallDamage', d.thrallDamage)),
    ),
  };
  const dmgUp: SheetLine = {
    id: 'damageBonus', label: 'Damage upgrade', value: `+${d.damageBonusPct}%`, help: 'Bought with gold from the HUD: each tier adds spell power.',
    rows: [{ label: `${tiers} × ${Math.round(DAMAGE_UPGRADE.perTier * 100)}%`, value: `+${d.damageBonusPct}%`, total: true }],
  };

  const statLine = (k: StatKey, help: string): SheetLine => ({
    id: k, label: STAT_LABELS[k], value: String(total[k]), help,
    rows: rowsOf({ label: 'Character', value: String(base[k]) }, gearRows(slots, (b) => b[k] ?? 0, 0), final(STAT_LABELS[k], String(total[k]))),
  });

  return [
    { id: 'derived', title: 'What you can do', lines: [health, spell, essence, regen, move, thrallHp, thrallDmg, dmgUp] },
    {
      id: 'stats', title: 'Stats',
      lines: [
        statLine('stat_str', 'A little spell power.'),
        statLine('stat_agi', 'Move speed and a little spell power.'),
        statLine('stat_int', 'Spell power, essence and essence regeneration.'),
        statLine('stat_vit', 'Health, and through it thrall health.'),
      ],
    },
    // Set bonuses (a later step) will be appended here as one more SheetSection.
  ];
}
