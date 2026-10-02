import { readFileSync } from 'node:fs';
import { beforeEach, describe, expect, it } from 'vitest';
import { DISCIPLINES } from '../../content/disciplines';
import type { Character, InventorySlot } from '../../net/types';
import {
  AFFIXES, DROP_SOURCES, ILVL_MAX, ILVL_REACH, MAX_AFFIXES, addInstanceTotals, affixEffect, affixQuality, affixRange, affixText, affixedName, clampDropLevel,
  cleanInstance, effectiveRarity, emptyAffixTotals, instancePower, instanceProblem, instanceSellValue, itemLevelFor, rollAffixCount, rollInstance, type AffixRoll, type DropSource,
} from '../affixRules';
import { affixLines, affixSignature, decorateSlot, rollOf, wornAffixTotals } from '../affixes';
import { computeStats } from '../stats';
import { deriveStats } from '../characterStats';
import { affixSheetLines, gearPower, itemAffixEffects, itemVerdict, statSheet, type StatContext } from '../gearStats';
import { outfitSignature, resolveSetBonuses, withSetBonuses } from '../setBonuses';
import { toSavePayload, addToSlots } from '../loot';
import { LootRoller } from '../lootRoll';
import { depositMany, depositStack, sortVault, withdrawStack, type VaultInfo, type VaultRow } from '../vaultRules';
import { salvageYield, salvagePreview } from '../salvageRules';
import { itemLevelHtml, itemStatsHtml } from '../../ui/gearText';
import { junkSlots } from '../itemLocks';
import { CODEX_AFFIX_COUNSEL, codexAffixRows } from '../../content/codex';
import { TIPS } from '../../ui/Onboarding';

/** A seeded generator: the rules take any () => [0,1). */
const seeded = (seed = 1) => () => {
  seed = (seed * 1664525 + 1013904223) % 4294967296;
  return seed / 4294967296;
};
const character = (over: Partial<Character> = {}): Character => ({ id: 1, class_index: 2, class_name: '', level: 20, experience: 0, gold: 0, stat_str: 10, stat_agi: 10, stat_int: 10, stat_vit: 10, ...over });
let nextId = 1;
const row = (item_id: string, slot_index: number, item_type: InventorySlot['item_type'], stat_bonus: Record<string, number> | null, equipped: 0 | 1 = 0, rarity: InventorySlot['rarity'] = 'common'): InventorySlot => ({
  id: nextId++, slot_index, quantity: 1, equipped, item_id, name: item_id, rarity, item_type, stat_bonus, icon_id: null, sell_value: 20, crafted: 0,
});
/** A rolled row exactly as the server sends it: raw columns, then read in by decorateSlot. */
const rolled = (base: InventorySlot, id: number, ilvl: number, affixes: AffixRoll[]): InventorySlot => decorateSlot({ ...base, instance_id: id, ilvl, affixes });
const ctx = (slots: InventorySlot[], disc: keyof typeof DISCIPLINES = 'gravecaller'): StatContext => ({ character: character(), slots, discipline: DISCIPLINES[disc], damageTier: 0 });

const A = (id: string, v: number): AffixRoll => ({ id, v });

describe('the affix pool', () => {
  it('has unique ids and names, a legal kind, and every effect is one the game already reads', () => {
    expect(new Set(AFFIXES.map((a) => a.id)).size).toBe(AFFIXES.length);
    expect(new Set(AFFIXES.map((a) => a.word)).size).toBe(AFFIXES.length);
    const mult = new Set(['thrallHpMult', 'thrallDamageMult', 'essenceRegenMult', 'miasmaRadiusMult']);
    const add = new Set(['witheredMaxStacks', 'wardPerThrall']);
    for (const a of AFFIXES) {
      expect(['prefix', 'suffix']).toContain(a.kind);
      const e = a.effect(a.range(10)[0]);
      for (const k of Object.keys(e.mult ?? {})) expect(mult.has(k)).toBe(true);
      for (const k of Object.keys(e.add ?? {})) expect(add.has(k)).toBe(true);
      for (const k of Object.keys(e.stats ?? {})) expect(['stat_str', 'stat_agi', 'stat_int', 'stat_vit']).toContain(k);
    }
  });

  it('covers the four stats as prefix and suffix, and every necromancer lever the brief names', () => {
    for (const s of ['str', 'agi', 'int', 'vit']) {
      expect(AFFIXES.filter((a) => a.group === `stat_${s}`).map((a) => a.kind).sort()).toEqual(['prefix', 'suffix']);
    }
    const necro = AFFIXES.filter((a) => a.necro).map((a) => Object.keys({ ...affixEffect({ id: a.id, v: a.range(20)[1] }).mult, ...affixEffect({ id: a.id, v: a.range(20)[1] }).add }).join()).sort();
    expect(necro).toEqual(['essenceRegenMult', 'miasmaRadiusMult', 'thrallDamageMult', 'thrallHpMult', 'wardPerThrall', 'witheredMaxStacks']);
  });

  it('has a sane range at every item level, growing with it and never inverted', () => {
    for (const a of AFFIXES) {
      let lastHi = 0;
      for (let L = 1; L <= ILVL_MAX; L++) {
        const [lo, hi] = a.range(L);
        expect(lo).toBeGreaterThanOrEqual(1);
        expect(hi).toBeGreaterThanOrEqual(lo);
        expect(hi).toBeGreaterThanOrEqual(lastHi);
        lastHi = hi;
      }
    }
  });
});

describe('rolling', () => {
  it('every roll is a legal one, whatever the item, level, source or seed', () => {
    const rand = seeded(42);
    for (let i = 0; i < 3000; i++) {
      const source = DROP_SOURCES[i % DROP_SOURCES.length] as DropSource;
      const inst = rollInstance({ rarity: ['common', 'uncommon', 'rare', 'epic'][i % 4] }, 1 + (i % 60), source, rand);
      expect(instanceProblem(inst, 'armor_head')).toBeNull();
      expect(inst.affixes.length).toBeLessThanOrEqual(MAX_AFFIXES);
      expect(new Set(inst.affixes.map((a) => AFFIXES.find((d) => d.id === a.id)!.group)).size).toBe(inst.affixes.length);
    }
  });

  it('item level is the dropper\'s level plus the source, clamped; the server clamps the claimed level to the character', () => {
    expect(itemLevelFor(10, 'kill')).toBe(10);
    expect(itemLevelFor(10, 'elite')).toBe(12);
    expect(itemLevelFor(10, 'boss')).toBe(14);
    expect(itemLevelFor(10, 'first_kill')).toBe(15);
    expect(itemLevelFor(0, 'kill')).toBe(1);
    expect(itemLevelFor(500, 'boss')).toBe(ILVL_MAX);
    expect(clampDropLevel(99, 5)).toBe(5 + ILVL_REACH);
    expect(clampDropLevel(7, 5)).toBe(7);
    expect(clampDropLevel(-3, 5)).toBe(1);
  });

  it('richer bases and bigger sources roll more affixes; bosses and first kills guarantee some', () => {
    const avg = (rarity: string, source: DropSource) => {
      const rand = seeded(9);
      let n = 0;
      for (let i = 0; i < 4000; i++) n += rollAffixCount(rarity, source, rand);
      return n / 4000;
    };
    expect(avg('common', 'kill')).toBeLessThan(avg('rare', 'kill'));
    expect(avg('rare', 'kill')).toBeLessThan(avg('epic', 'kill'));
    expect(avg('rare', 'kill')).toBeLessThan(avg('rare', 'elite'));
    expect(avg('rare', 'elite')).toBeLessThan(avg('rare', 'boss'));
    const rand = seeded(5);
    for (let i = 0; i < 1000; i++) {
      expect(rollAffixCount('common', 'boss', rand)).toBeGreaterThanOrEqual(1);
      expect(rollAffixCount('common', 'first_kill', rand)).toBeGreaterThanOrEqual(2);
    }
  });

  it('is deterministic for a given sequence', () => {
    expect(rollInstance({ rarity: 'rare' }, 14, 'elite', seeded(77))).toEqual(rollInstance({ rarity: 'rare' }, 14, 'elite', seeded(77)));
  });
});

describe('validation (what an offline-sync import may claim)', () => {
  const mid = (id: string, L: number) => { const [lo, hi] = affixRange(id, L)!; return Math.round((lo + hi) / 2); };
  const ok = { ilvl: 12, affixes: [A('p_thrall_dmg', mid('p_thrall_dmg', 12)), A('s_thrall_hp', mid('s_thrall_hp', 12))] };
  it('accepts a legal roll and rejects each way of cheating', () => {
    expect(instanceProblem(ok, 'weapon')).toBeNull();
    const [lo, hi] = affixRange('p_thrall_dmg', 12)!;
    expect(instanceProblem({ ilvl: 12, affixes: [A('p_thrall_dmg', hi + 1)] }, 'ring')).not.toBeNull();
    expect(instanceProblem({ ilvl: 12, affixes: [A('p_thrall_dmg', lo - 1)] }, 'ring')).not.toBeNull();
    expect(instanceProblem({ ilvl: 12, affixes: [A('p_nonsense', 3)] }, 'ring')).not.toBeNull();
    expect(instanceProblem({ ilvl: 12, affixes: [A('p_thrall_dmg', 40), A('p_thrall_dmg', 40)] }, 'ring')).not.toBeNull();
    expect(instanceProblem({ ilvl: 12, affixes: [A('p_str', 3), A('s_str', 3), A('p_agi', 3), A('s_agi', 3)] }, 'ring')).not.toBeNull();
    expect(instanceProblem({ ilvl: 0, affixes: [] }, 'ring')).not.toBeNull();
    expect(instanceProblem({ ilvl: ILVL_MAX + 1, affixes: [] }, 'ring')).not.toBeNull();
    expect(instanceProblem({ ilvl: 12, affixes: [A('p_thrall_dmg', 40.5)] }, 'ring')).not.toBeNull();
    expect(instanceProblem(ok, 'material')).not.toBeNull();
    expect(instanceProblem(null, 'ring')).not.toBeNull();
  });
  it('a value that is legal at a higher item level is not legal at a lower one', () => {
    const [, hi] = affixRange('p_thrall_dmg', 40)!;
    expect(instanceProblem({ ilvl: 40, affixes: [A('p_thrall_dmg', hi)] }, 'ring')).toBeNull();
    expect(instanceProblem({ ilvl: 3, affixes: [A('p_thrall_dmg', hi)] }, 'ring')).not.toBeNull();
  });
  it('cleanInstance keeps only id and value', () => {
    expect(cleanInstance({ ilvl: 5, affixes: [{ id: 'p_str', v: 2, extra: 1 } as AffixRoll] })).toEqual({ ilvl: 5, affixes: [{ id: 'p_str', v: 2 }] });
  });
});

describe('names, rarity, value', () => {
  it('names a piece with its first prefix and first suffix', () => {
    expect(affixedName('Iron Helm', [A('p_thrall_dmg', 40), A('s_thrall_hp', 55)])).toBe('Gravebound Iron Helm of the Legion');
    expect(affixedName('Iron Helm', [A('s_thrall_hp', 55)])).toBe('Iron Helm of the Legion');
    expect(affixedName('Iron Helm', [A('p_withered', 1), A('p_thrall_dmg', 40), A('s_miasma', 50)])).toBe('Blighted Iron Helm of the Rotting Mist');
    expect(affixedName('Iron Helm', [])).toBe('Iron Helm');
  });
  it('rarity follows the affix count and never drops below the base', () => {
    expect([0, 1, 2, 3].map((n) => effectiveRarity('common', n))).toEqual(['common', 'uncommon', 'rare', 'epic']);
    expect([0, 1, 2, 3].map((n) => effectiveRarity('rare', n))).toEqual(['rare', 'rare', 'rare', 'epic']);
    expect(effectiveRarity('epic', 0)).toBe('epic');
    expect(effectiveRarity('relic', 3)).toBe('relic');
  });
  it('sells for more with item level and with every affix, never less than the base', () => {
    const base = 20;
    expect(instanceSellValue(base, null)).toBe(20);
    const v = (ilvl: number, n: number) => instanceSellValue(base, { ilvl, affixes: Array.from({ length: n }, () => A('p_str', 1)) });
    expect(v(1, 0)).toBeGreaterThanOrEqual(base);
    expect(v(20, 0)).toBeGreaterThan(v(1, 0));
    expect(v(20, 2)).toBeGreaterThan(v(20, 1));
    expect(v(20, 3)).toBeGreaterThan(v(20, 2));
  });
  it('power sorts by affixes, then level', () => {
    expect(instancePower({ ilvl: 99, affixes: [A('p_str', 1)] })).toBeLessThan(instancePower({ ilvl: 1, affixes: [A('p_str', 1), A('s_agi', 1)] }));
    expect(instancePower(null)).toBe(0);
  });
});

describe('reading a row', () => {
  const base = row('helm_iron', 0, 'armor_head', { stat_vit: 5 }, 0, 'uncommon');
  it('decorates a rolled row: full name, rarity by affix count, price, and is idempotent', () => {
    const r = decorateSlot({ ...base, name: 'Iron Helm', instance_id: 7, ilvl: 12, affixes: [A('p_thrall_dmg', 40), A('s_thrall_hp', 55), A('p_withered', 2)] });
    expect(r.name).toBe('Gravebound Iron Helm of the Legion');
    expect(r.rarity).toBe('epic');
    expect(r.base_name).toBe('Iron Helm');
    expect(r.base_rarity).toBe('uncommon');
    expect(r.sell_value).toBeGreaterThan(20);
    expect(r.inst).toEqual({ id: 7, ilvl: 12, affixes: [A('p_thrall_dmg', 40), A('s_thrall_hp', 55), A('p_withered', 2)] });
    expect(decorateSlot(r)).toBe(r);
  });
  it('reads a JSON string (a text driver) and leaves plain rows alone', () => {
    const r = decorateSlot({ ...base, instance_id: 3, ilvl: 5, affixes: JSON.stringify([A('p_str', 2)]) });
    expect(r.inst?.affixes).toEqual([A('p_str', 2)]);
    expect(decorateSlot(base)).toBe(base);
    expect(decorateSlot({ ...base, instance_id: null, ilvl: null, affixes: null })).toEqual({ ...base, instance_id: null, ilvl: null, affixes: null });
  });
  it('survives a damaged affixes column', () => {
    expect(decorateSlot({ ...base, instance_id: 3, ilvl: 5, affixes: '{not json' }).inst?.affixes).toEqual([]);
  });
});

describe('the stat pipeline', () => {
  const head = row('helm_iron', 100, 'armor_head', { stat_vit: 5 }, 1);
  const rolledHead = (affixes: AffixRoll[]) => rolled(head, 1, 12, affixes);

  it('flat stat affixes of WORN gear add to computeStats; bag gear adds nothing', () => {
    const worn = rolledHead([A('p_int', 6)]);
    expect(computeStats(character(), [worn]).bonus.stat_int).toBe(6);
    expect(computeStats(character(), [worn]).bonus.stat_vit).toBe(5);
    const bagged = { ...worn, equipped: 0 as const, slot_index: 3 };
    expect(computeStats(character(), [bagged]).bonus.stat_int).toBe(0);
    expect(wornAffixTotals([bagged]).stats).toEqual({});
  });

  it('necromancer affixes fold into the discipline mods (the same path as set bonuses)', () => {
    const worn = rolledHead([A('p_thrall_dmg', 100), A('s_ward', 5), A('p_withered', 2)]);
    const bare = withSetBonuses(DISCIPLINES.rotweaver, []);
    const d = withSetBonuses(DISCIPLINES.rotweaver, [worn]);
    expect(d.mods.thrallDamageMult).toBeCloseTo(bare.mods.thrallDamageMult * 1.1, 6);
    expect(d.mods.wardPerThrall).toBeCloseTo(bare.mods.wardPerThrall + 0.005, 6);
    expect(d.mods.witheredMaxStacks).toBe(bare.mods.witheredMaxStacks + 2);
    const stats = deriveStats(character(), [worn], d, 0);
    expect(stats.thrallDamage).toBeGreaterThan(deriveStats(character(), [head], bare, 0).thrallDamage);
  });

  it('SetResolution keeps sets and affixes apart but the engine total has both', () => {
    const worn = rolledHead([A('p_thrall_hp', 0)].slice(0, 0).concat([A('s_thrall_hp', 50)]));
    const res = resolveSetBonuses([worn]);
    expect(res.setTotals.mult).toEqual({});
    expect(res.affixTotals.mult.thrallHpMult).toBeCloseTo(1.05, 6);
    expect(res.totals.mult.thrallHpMult).toBeCloseTo(1.05, 6);
  });

  it('the outfit signature changes when a worn roll changes, so the scene rebuilds the discipline', () => {
    const a = outfitSignature([rolledHead([A('p_str', 3)])]);
    expect(outfitSignature([rolledHead([A('p_str', 4)])])).not.toBe(a);
    expect(outfitSignature([head])).not.toBe(a);
    expect(affixSignature([head])).toBe('');
  });

  it('totals multiply and add as documented', () => {
    const t = addInstanceTotals(emptyAffixTotals(), [A('p_thrall_dmg', 100), A('p_thrall_dmg', 100)]);
    expect(t.mult.thrallDamageMult).toBeCloseTo(1.21, 6);
    expect(addInstanceTotals(emptyAffixTotals(), [A('p_str', 3), A('s_str', 4)]).stats.stat_str).toBe(7);
  });
});

describe('readable gear', () => {
  it('a rolled piece beats a plain one of the same base, in the power score and the verdict', () => {
    const plainWorn = row('helm_copper', 100, 'armor_head', { stat_vit: 3 }, 1);
    const plainBag = row('helm_copper', 1, 'armor_head', { stat_vit: 3 });
    const rolledBag = rolled({ ...plainBag, slot_index: 2 }, 5, 20, [A('p_thrall_dmg', 70), A('s_thrall_hp', 80)]);
    const c = ctx([plainWorn, plainBag, rolledBag]);
    expect(itemVerdict(c, plainBag)?.kind).toBe('same');
    const v = itemVerdict(c, rolledBag)!;
    expect(v.kind).toBe('upgrade');
    expect(v.pct).toBeGreaterThan(1);
    expect(gearPower(c, [{ ...plainWorn, equipped: 0 }, { ...rolledBag, equipped: 1, slot_index: 100 }]).total).toBeGreaterThan(gearPower(c).total);
  });

  it('a stat affix worth more than the stat it replaces flips the verdict', () => {
    const worn = rolled(row('helm_a', 100, 'armor_head', { stat_vit: 8 }, 1), 1, 5, []);
    const bag = rolled(row('helm_b', 1, 'armor_head', { stat_vit: 1 }), 2, 30, [A('p_int', 14), A('s_vit', 14)]);
    expect(itemVerdict(ctx([worn, bag]), bag)?.kind).toBe('upgrade');
    const weak = rolled(row('helm_b', 1, 'armor_head', { stat_vit: 1 }), 3, 2, [A('p_agi', 1)]);
    expect(itemVerdict(ctx([worn, weak]), weak)?.kind).toBe('downgrade');
  });

  it('itemAffixEffects says what each line does for THIS character, and flags idle necro lines on another class', () => {
    const bag = rolled(row('helm_b', 1, 'armor_head', null), 2, 20, [A('p_int', 8), A('p_thrall_dmg', 80), A('s_miasma', 60)]);
    const gc = itemAffixEffects(ctx([bag], 'gravecaller'), bag);
    expect(gc[0].lines.some((l) => l.key === 'spellPower')).toBe(true);
    expect(gc[1].lines.some((l) => l.key === 'thrallDamage')).toBe(true);
    expect(gc[1].necro).toBe(true);
    expect(gc[0].necro).toBe(false);
    expect(gc.every((e) => e.relevant)).toBe(true);
    const knight = itemAffixEffects(ctx([bag], 'hollow_knight'), bag);
    expect(knight[1].relevant).toBe(false);
    expect(knight[0].relevant).toBe(true);
  });

  it('the tooltip HTML shows the item level, each affix, and marks necromancer lines', () => {
    const bag = rolled(row('helm_b', 1, 'armor_head', { stat_vit: 2 }), 2, 22, [A('p_int', 8), A('p_thrall_dmg', 80)]);
    const html = itemStatsHtml(ctx([bag]), bag);
    expect(itemLevelHtml(bag)).toContain('Item level <b>22</b>');
    expect(itemLevelHtml(bag)).toContain('2 affixes');
    expect(html).toContain('+8 INT');
    expect(html).toContain('Thralls hit +8% harder');
    expect(html).toMatch(/gs-affix necro/);
    expect(itemLevelHtml(row('x', 0, 'ring', null))).toBe('');
    // without a character context the lines are still readable
    expect(itemStatsHtml(null, bag)).toContain('Thralls hit +8% harder');
  });

  it('the Character sheet attributes affixes: an Item affixes section, per-piece rows, and an affix row in the formulas', () => {
    const head = rolled(row('helm_iron', 100, 'armor_head', { stat_vit: 5 }, 1), 1, 12, [A('p_int', 6), A('s_thrall_hp', 50)]);
    const sheet = statSheet(ctx([head]));
    const section = sheet.find((s) => s.id === 'affixes')!;
    expect(section.lines).toHaveLength(1);
    expect(section.lines[0].label).toBe('Occult helm_iron of the Legion');
    expect(section.lines[0].value).toBe('ilvl 12');
    expect(section.lines[0].rows.map((r) => r.label).join('|')).toContain('Thralls have +5% health');
    const spell = sheet.find((s) => s.id === 'derived')!.lines.find((l) => l.id === 'spellPower')!;
    expect(spell.rows.some((r) => /affixes/.test(r.label))).toBe(true);
    const thrallHp = sheet.find((s) => s.id === 'derived')!.lines.find((l) => l.id === 'thrallHp')!;
    expect(thrallHp.rows.some((r) => r.label === 'Item affixes')).toBe(true);
    const intLine = sheet.find((s) => s.id === 'stats')!.lines.find((l) => l.id === 'stat_int')!;
    expect(intLine.rows.some((r) => /affixes/.test(r.label) && r.value === '+6')).toBe(true);
    expect(affixSheetLines([], DISCIPLINES.gravecaller)[0].id).toBe('affix:none');
  });

  it('Covenant boons are not blamed for affixes (the sheet separates them)', () => {
    const head = rolled(row('helm_iron', 100, 'armor_head', null, 1), 1, 12, [A('s_thrall_hp', 50)]);
    const c = ctx([head]);
    const d = withSetBonuses(DISCIPLINES.gravecaller, [head]);
    const sheet = statSheet({ ...c, discipline: d });
    const hp = sheet.find((s) => s.id === 'derived')!.lines.find((l) => l.id === 'maxHp')!;
    expect(hp.rows.some((r) => r.label === 'Covenant boons')).toBe(false);
  });

  it('affix lines carry roll quality', () => {
    const [lo, hi] = affixRange('p_str', 20)!;
    expect(affixQuality(A('p_str', lo), 20)).toBe(0);
    expect(affixQuality(A('p_str', hi), 20)).toBe(1);
    const bag = rolled(row('helm_b', 1, 'armor_head', null), 2, 20, [A('p_str', hi)]);
    expect(affixLines(bag)[0].quality).toBe(1);
    expect(affixText(A('p_str', 7))).toBe('+7 STR');
  });
});

describe('loot, bag and save payload', () => {
  it('the save payload names an instance by id and never carries affixes', () => {
    const slots = addToSlots([], { item_id: 'helm_iron', quantity: 1, instance: { id: 9, ilvl: 11, affixes: [A('p_str', 3)] } })!;
    const payload = toSavePayload(slots);
    expect(payload).toEqual([{ slot_index: 0, item_id: 'helm_iron', quantity: 1, equipped: 0, instance_id: 9 }]);
    expect(JSON.stringify(payload)).not.toMatch(/affix|ilvl/);
    expect(slots[0].name).toBe('Brutal Iron Helm');
    expect(addToSlots([], { item_id: 'helm_iron', quantity: 1 })![0].inst).toBeUndefined();
    expect(toSavePayload(addToSlots([], { item_id: 'ore_copper', quantity: 3 })!)[0].instance_id).toBeNull();
  });

  it('LootRoller attaches the server\'s rolls to gear drops only, in order, and never rejects', async () => {
    const calls: unknown[] = [];
    const roller = new LootRoller(7, async (id, drops) => {
      calls.push([id, drops]);
      return drops.map((d, i) => ({ item_id: d.item_id, instance_id: 100 + i, ilvl: 9, affixes: [A('p_str', 2)] }));
    });
    const drops = [{ item_id: 'helm_iron', quantity: 1 }, { item_id: 'ore_copper', quantity: 2 }, { item_id: 'staff_oak', quantity: 1 }];
    await roller.attach(drops, 8, 'elite');
    expect(calls).toEqual([[7, [{ item_id: 'helm_iron', level: 8, source: 'elite' }, { item_id: 'staff_oak', level: 8, source: 'elite' }]]]);
    expect(drops[0]).toMatchObject({ instance: { id: 100, ilvl: 9 } });
    expect(drops[1]).not.toHaveProperty('instance');
    expect(drops[2]).toMatchObject({ instance: { id: 101 } });
    const failing = new LootRoller(7, async () => { throw new Error('offline'); });
    const plain = [{ item_id: 'helm_iron', quantity: 1 }];
    await expect(failing.attach(plain, 3, 'kill')).resolves.toBeUndefined();
    expect(plain[0]).not.toHaveProperty('instance');
    expect(failing.pending).toBe(0);
  });

  it('batches more than twelve drops and ignores an answer for the wrong item', async () => {
    let calls = 0;
    const roller = new LootRoller(1, async (_id, drops) => {
      calls++;
      return drops.map((d) => ({ item_id: calls === 2 ? 'wrong_item' : d.item_id, instance_id: 5, ilvl: 1, affixes: [] }));
    });
    const drops = Array.from({ length: 14 }, () => ({ item_id: 'helm_iron', quantity: 1 }));
    await roller.attach(drops, 3, 'kill');
    expect(calls).toBe(2);
    expect(drops.filter((d) => 'instance' in d)).toHaveLength(12);
  });

  it('junk selling and Salvage-all skip pieces with a necromancer affix', () => {
    const a = rolled(row('helm_copper', 1, 'armor_head', { stat_vit: 3 }), 1, 4, [A('p_int', 2)]);
    const b = rolled(row('helm_copper', 2, 'armor_head', { stat_vit: 3 }), 2, 4, [A('p_thrall_dmg', 15)]);
    expect(a.rarity).toBe('uncommon');
    expect(junkSlots([a, b], { isLocked: () => false }).map((s) => s.slot_index)).toEqual([1]);
  });
});

describe('Vault and Salvage rules with rolls', () => {
  const info: VaultInfo = (id) => ({ maxStack: id === 'ore' ? 250 : 1, itemType: id === 'ore' ? 'material' : 'armor_head', rarity: 'common' });
  const gearRow = (slot: number, inst: number, power = 2012): VaultRow => ({ slot, itemId: 'helm', qty: 1, inst, power });

  it('moves carry the instance, never stack, and keep gear apart from plain duplicates', () => {
    const bag: VaultRow[] = [gearRow(0, 11), { slot: 1, itemId: 'helm', qty: 1 }];
    const dep = depositStack(bag, [], 0, undefined, info);
    expect(dep.ok && dep.vault).toEqual([{ slot: 0, itemId: 'helm', qty: 1, inst: 11, power: 2012 }]);
    const again = depositStack(dep.ok ? dep.bag : [], dep.ok ? dep.vault : [], 1, undefined, info);
    expect(again.ok && again.vault.map((r) => [r.slot, r.inst ?? null])).toEqual([[0, 11], [1, null]]);
    const back = withdrawStack([], [gearRow(3, 12)], 3, undefined, info);
    expect(back.ok && back.bag).toEqual([{ slot: 0, itemId: 'helm', qty: 1, inst: 12, power: 2012 }]);
  });

  it('deposit-all and sort keep every instance; sort puts more affixes first', () => {
    const all = depositMany([gearRow(0, 1, 1010), gearRow(1, 2, 3010), gearRow(2, 3, 2050)], [], 'all', [], info);
    expect(all.ok && all.vault.map((r) => r.inst).sort()).toEqual([1, 2, 3]);
    const sorted = sortVault([gearRow(0, 1, 1010), gearRow(1, 2, 3010), gearRow(2, 3, 2050), { slot: 3, itemId: 'ore', qty: 4 }, { slot: 4, itemId: 'ore', qty: 6 }], info);
    expect(sorted.filter((r) => r.itemId === 'helm').map((r) => r.inst)).toEqual([2, 3, 1]);
    expect(sorted.filter((r) => r.itemId === 'ore')).toEqual([{ slot: 3, itemId: 'ore', qty: 10 }]);
  });

  it('salvage: plain gear\'s random sequence and yield are unchanged; a rolled piece pays more XP and gets one more chance at a material', () => {
    const plain = { id: 'helm_iron', item_type: 'armor_head', rarity: 'uncommon' };
    const seq = () => { const s = [0.5, 0.99, 0.5, 0.99, 0.99, 0.99, 0.99]; let i = 0; return { rand: () => s[i++ % s.length], used: () => i }; };
    const p = seq();
    const base = salvageYield(plain, 1, p.rand);
    const used = p.used();
    expect(base.xp).toBe(9);
    expect(salvageYield({ ...plain, ilvl: undefined }, 1, seq().rand)).toEqual(base);
    const r = seq();
    const rich = salvageYield({ ...plain, ilvl: 30, affixes: 3 }, 1, () => (r.used() < used ? r.rand() : 0));
    expect(rich.xp).toBeGreaterThan(base.xp);
    const ingots = (y: { items: { item_id: string; quantity: number }[] }) => y.items.find((g) => g.item_id === 'ingot_iron')!.quantity;
    expect(ingots(rich)).toBeGreaterThan(ingots(base));
    const prev = salvagePreview({ ...plain, ilvl: 30, affixes: 3 });
    expect(prev.extraChance).toBeGreaterThan(0.3);
    expect(salvagePreview(plain).extraChance).toBe(0);
    expect(rollOf(rolled(row('helm_iron', 1, 'armor_head', null), 1, 7, [A('p_str', 2)]))).toEqual({ ilvl: 7, affixes: 1 });
  });
});

describe('server bundle', () => {
  it('the affix, salvage and vault bundles are fresh', async () => {
    const { bundleRulesFor } = await import('../../../tools/build-server-rules.mjs');
    const lf = (s: string) => s.replace(/\r\n/g, '\n');
    for (const key of ['affix', 'salvage', 'vault']) {
      const { out, text } = await bundleRulesFor(key);
      expect(lf(readFileSync(out, 'utf8')), `run npm run build:server-rules (${key})`).toBe(lf(text));
    }
  });
});

describe('the offline mock backend carries rolls on every path', () => {
  beforeEach(() => {
    const store = new Map<string, string>();
    (globalThis as { localStorage?: unknown }).localStorage = {
      getItem: (k: string) => store.get(k) ?? null,
      setItem: (k: string, v: string) => void store.set(k, v),
      removeItem: (k: string) => void store.delete(k),
    };
  });

  async function session() {
    const { handleMock } = await import('../../net/mockBackend');
    let n = 0;
    const call = async (method: string, path: string, body?: unknown, token: string | null = 'offline:tester') => {
      n++;
      void n;
      return handleMock(path, { method, body: body ? JSON.stringify(body) : undefined }, token);
    };
    await call('POST', '/register', { username: 'tester', password: 'secret1' }, null);
    const ch = await call('POST', '/character', { class_index: 2 });
    return { call, cid: ch.id as number };
  }

  it('roll -> save -> equip -> vault -> salvage, with the save unable to forge', async () => {
    const { call, cid } = await session();
    // Level the character so the roll level is not clamped to 1 + reach.
    const r = await call('POST', '/api/loot/roll-gear', { characterId: cid, drops: [{ item_id: 'helm_iron', level: 8, source: 'boss' }, { item_id: 'ring_copper', level: 8, source: 'first_kill' }, { item_id: 'ore_copper', level: 8, source: 'kill' }] });
    expect(r.success).toBe(true);
    const [a, b, ore] = r.data;
    expect(a.instance_id && b.instance_id).toBeTruthy();
    expect(ore.instance_id).toBeNull();
    expect(a.ilvl).toBe(12);
    expect(b.affixes.length).toBeGreaterThanOrEqual(2);

    const saved = await call('POST', '/api/inventory/save', { characterId: cid, bagSize: 48, slots: [{ slot_index: 0, item_id: 'helm_iron', quantity: 1, equipped: 0, instance_id: a.instance_id }, { slot_index: 1, item_id: 'ring_copper', quantity: 1, equipped: 0, instance_id: b.instance_id }] });
    expect(saved.success).toBe(true);
    expect(saved.data.find((s: InventorySlot) => s.slot_index === 0)).toMatchObject({ instance_id: a.instance_id, ilvl: 12 });

    // forged, foreign and duplicated names are refused and change nothing
    for (const slots of [
      [{ slot_index: 0, item_id: 'helm_iron', quantity: 1, instance_id: 424242 }],
      [{ slot_index: 0, item_id: 'staff_moon', quantity: 1, instance_id: a.instance_id }],
      [{ slot_index: 0, item_id: 'helm_iron', quantity: 1, instance_id: a.instance_id }, { slot_index: 4, item_id: 'helm_iron', quantity: 1, instance_id: a.instance_id }],
    ]) {
      const bad = await call('POST', '/api/inventory/save', { characterId: cid, bagSize: 48, slots });
      expect(bad.success).toBe(false);
      expect(bad.error).toMatch(/could not be verified/);
    }
    const unchanged = await call('GET', `/api/inventory/${cid}`);
    expect(unchanged.data.filter((s: InventorySlot) => s.instance_id)).toHaveLength(2);

    const eq = await call('POST', '/api/inventory/equip', { characterId: cid, slot_index: 0, equipped: 1 });
    expect(eq.data.find((s: InventorySlot) => s.slot_index === 100)).toMatchObject({ instance_id: a.instance_id });
    const worn = await call('POST', '/api/inventory/save', { characterId: cid, bagSize: 48, slots: [{ slot_index: 1, item_id: 'ring_copper', quantity: 1, equipped: 0, instance_id: b.instance_id }] });
    expect(worn.data.find((s: InventorySlot) => s.slot_index === 100)).toMatchObject({ instance_id: a.instance_id });
    const steal = await call('POST', '/api/inventory/save', { characterId: cid, bagSize: 48, slots: [{ slot_index: 1, item_id: 'ring_copper', quantity: 1, equipped: 0, instance_id: b.instance_id }, { slot_index: 2, item_id: 'helm_iron', quantity: 1, equipped: 0, instance_id: a.instance_id }] });
    expect(steal.success).toBe(false);

    const dep = await call('POST', '/api/vault/deposit', { characterId: cid, bagSlot: 1 });
    expect(dep.data.vault[0]).toMatchObject({ instance_id: b.instance_id, item_id: 'ring_copper' });
    const wd = await call('POST', '/api/vault/withdraw', { characterId: cid, vaultSlot: 0 });
    expect(wd.data.bag.find((s: InventorySlot) => s.item_id === 'ring_copper')).toMatchObject({ instance_id: b.instance_id });
    const sorted = await call('POST', '/api/vault/sort', { characterId: cid });
    expect(sorted.success).toBe(true);

    const slot = wd.data.bag.find((s: InventorySlot) => s.item_id === 'ring_copper').slot_index;
    const sv = await call('POST', '/api/salvage', { characterId: cid, slots: [slot] });
    expect(sv.success).toBe(true);
    const after = await call('GET', `/api/inventory/${cid}`);
    expect(after.data.some((s: InventorySlot) => s.instance_id === b.instance_id)).toBe(false);
  });

  it('a save without a piece (a sale) deletes its roll; it cannot come back', async () => {
    const { call, cid } = await session();
    const r = await call('POST', '/api/loot/roll-gear', { characterId: cid, drops: [{ item_id: 'helm_iron', level: 3, source: 'kill' }] });
    const id = r.data[0].instance_id;
    await call('POST', '/api/inventory/save', { characterId: cid, bagSize: 48, slots: [{ slot_index: 0, item_id: 'helm_iron', quantity: 1, instance_id: id }] });
    await call('POST', '/api/inventory/save', { characterId: cid, bagSize: 48, slots: [] });
    const back = await call('POST', '/api/inventory/save', { characterId: cid, bagSize: 48, slots: [{ slot_index: 0, item_id: 'helm_iron', quantity: 1, instance_id: id }] });
    expect(back.success).toBe(false);
  });

  it('the portable save carries rolls inline and an online save imports them as fresh local instances', async () => {
    const { call, cid } = await session();
    const { exportLocalSave, importOnlineSave } = await import('../../net/mockBackend');
    const r = await call('POST', '/api/loot/roll-gear', { characterId: cid, drops: [{ item_id: 'helm_iron', level: 3, source: 'boss' }] });
    await call('POST', '/api/inventory/save', { characterId: cid, bagSize: 48, slots: [{ slot_index: 0, item_id: 'helm_iron', quantity: 1, instance_id: r.data[0].instance_id }] });
    const snap = exportLocalSave('offline:tester');
    const piece = snap.slots.find((s) => s.item_id === 'helm_iron')!;
    expect(piece.inst).toEqual({ ilvl: r.data[0].ilvl, affixes: r.data[0].affixes });
    expect(piece.instance_id).toBeUndefined();
    expect(JSON.stringify(snap)).not.toMatch(/nextInstance|"instances"/);
    const token = importOnlineSave({ ...snap, username: 'fromonline' });
    const again = exportLocalSave(token);
    expect(again.slots.find((s) => s.item_id === 'helm_iron')?.inst).toEqual(piece.inst);
    // an illegal roll in an online snapshot is not imported as a roll (the piece stays plain)
    const forged = JSON.parse(JSON.stringify(snap));
    forged.slots.find((s: { item_id: string }) => s.item_id === 'helm_iron').inst = { ilvl: 3, affixes: [{ id: 'p_thrall_dmg', v: 9999 }] };
    const t2 = importOnlineSave({ ...forged, username: 'forged' });
    expect(exportLocalSave(t2).slots.find((s) => s.item_id === 'helm_iron')?.inst).toBeUndefined();
  });
});

describe('help', () => {
  it('the Codex lists every affix with its ranges at two item levels, from the pool itself', () => {
    const rows = codexAffixRows();
    expect(rows).toHaveLength(AFFIXES.length);
    expect(rows.filter((r) => r.necro)).toHaveLength(6);
    for (const r of rows) {
      expect(r.low.length).toBeGreaterThan(3);
      expect(r.high).not.toBe('');
    }
    expect(rows.find((r) => r.word.startsWith('Gravebound'))!.low).toMatch(/Thralls hit \+[\d.]+% harder \(up to Thralls hit \+[\d.]+% harder\)/);
    expect(CODEX_AFFIX_COUNSEL).toContain(`${MAX_AFFIXES} affixes`);
  });

  it('there is a counsel tip for the first rolled drop, in the trusted markup', () => {
    expect(TIPS.affix.title).toBe('A rolled relic');
    expect(TIPS.affix.body).toMatch(/item level/);
    expect(TIPS.affix.body).toMatch(/three affixes/);
  });
});
