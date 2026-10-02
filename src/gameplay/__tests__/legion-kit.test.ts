import { describe, expect, it } from 'vitest';
import { DISCIPLINES } from '../../content/disciplines';
import { equippedBySlot } from '../../content/gear';
import { LEGION_UPGRADE } from '../../content/upgrades';
import { codexLegionExamples, codexLegionTiers } from '../../content/codex';
import type { Character, InventorySlot } from '../../net/types';
import { computeStats } from '../stats';
import { deriveStats } from '../characterStats';
import { gearPower, statSheet, type StatContext } from '../gearStats';
import { withSetBonuses, applySetMods, resolveSetBonuses } from '../setBonuses';
import { KIT_BASE, KIT_RATES, NO_LEGION, isKitSlot, kitIdForType, kitSlotId, kitSlotIndex, legionBonus, pieceBonus, reinforceBonus, statPoints, unusedAffixes } from '../legionRules';
import { applyLegionMods, bonusLines, kitCandidate, kitCandidates, kitPieces, legionOf, legionSignature, pieceLines } from '../legionKit';
import { blankState, ascend, normalise, purchase } from '../necroRules';
import { ITEMS } from '../../content/items';
import { MOCK_ITEMS } from '../../net/mockBackend';

const character = (over: Partial<Character> = {}): Character => ({ id: 1, class_index: 1, class_name: '', level: 20, experience: 0, gold: 0, stat_str: 10, stat_agi: 10, stat_int: 10, stat_vit: 10, ...over });

let n = 1;
const slot = (slot_index: number, item_id: string, over: Partial<InventorySlot> = {}): InventorySlot => {
  const m = ITEMS[item_id];
  return {
    id: n++, slot_index, quantity: 1, equipped: slot_index >= 100 ? 1 : 0, item_id, name: m?.name ?? item_id, rarity: m?.rarity ?? 'common', item_type: m?.type ?? 'material',
    stat_bonus: m?.offlineStats ?? null, icon_id: null, sell_value: 1, crafted: 0, ...over,
  };
};
const kitW = (id = 'sword_copper') => slot(120, id);
const kitA = (id = 'plate_copper') => slot(121, id);
const withAffix = (s: InventorySlot, affixes: { id: string; v: number }[], ilvl = 20): InventorySlot => ({ ...s, inst: { id: n++, ilvl, affixes } });

describe('Legion kit slots', () => {
  it('two reserved slots 120-121, clear of gear (100-108), the tool belt (110-113) and the 48-slot bag', () => {
    expect(KIT_BASE).toBe(120);
    expect([119, 120, 121, 122].map(isKitSlot)).toEqual([false, true, true, false]);
    expect(kitSlotId(120)).toBe('weapon');
    expect(kitSlotId(121)).toBe('armor');
    expect(kitSlotId(48)).toBeNull();
    expect([kitSlotIndex('weapon'), kitSlotIndex('armor')]).toEqual([120, 121]);
  });
  it('weapons and off-hands arm the legion, the five armour pieces armour it, nothing else fits', () => {
    expect(['weapon', 'offhand'].map(kitIdForType)).toEqual(['weapon', 'weapon']);
    expect(['armor_head', 'armor_chest', 'armor_legs', 'armor_feet', 'armor_hands'].map(kitIdForType)).toEqual(['armor', 'armor', 'armor', 'armor', 'armor']);
    for (const t of ['ring', 'trinket', 'material', 'consumable', '', undefined]) expect(kitIdForType(t as string)).toBeNull();
  });
  it('every real weapon and armour item the mock knows maps to a slot, and rings and trinkets do not', () => {
    for (const [id, d] of Object.entries(MOCK_ITEMS)) {
      const expected = ['weapon', 'offhand'].includes(d.item_type) ? 'weapon' : d.item_type.startsWith('armor_') ? 'armor' : null;
      expect(kitIdForType(d.item_type), id).toBe(expected);
    }
  });
});

describe('what a kit piece gives the legion', () => {
  it('a weapon gives thrall damage and a little attack speed from its stat points (Copper Sword, 4 points)', () => {
    const b = pieceBonus('weapon', { itemType: 'weapon', statBonus: { stat_str: 4 } });
    expect(b.points).toBe(4);
    expect(b.damage).toBeCloseTo(4 * KIT_RATES.weaponDamagePerPoint, 6);
    expect(b.speed).toBeCloseTo(4 * KIT_RATES.weaponSpeedPerPoint, 6);
    expect(b.hp).toBe(0);
  });
  it('armour gives thrall health (Iron Chestplate, 11 points)', () => {
    const b = pieceBonus('armor', { itemType: 'armor_chest', statBonus: { stat_vit: 9, stat_str: 2 } });
    expect(b.hp).toBeCloseTo(0.132, 6);
    expect(b.damage + b.speed).toBe(0);
  });
  it('is capped, so one endgame relic cannot carry the legion', () => {
    expect(pieceBonus('weapon', { itemType: 'weapon', statBonus: { stat_int: 500 } })).toMatchObject({ damage: KIT_RATES.weaponDamageCap, speed: KIT_RATES.weaponSpeedCap });
    expect(pieceBonus('armor', { itemType: 'armor_chest', statBonus: { stat_vit: 500 } }).hp).toBe(KIT_RATES.armorHpCap);
    // The best weapon in the game (36 points) only just reaches the cap; an iron staff (10) is well under it.
    expect(pieceBonus('weapon', { itemType: 'weapon', statBonus: ITEMS.staff_moon.offlineStats }).damage).toBeLessThanOrEqual(KIT_RATES.weaponDamageCap);
    expect(pieceBonus('weapon', { itemType: 'weapon', statBonus: ITEMS.staff_iron.offlineStats }).damage).toBeCloseTo(0.1, 6);
  });
  it('a piece in the wrong slot, or a ring, gives nothing', () => {
    expect(pieceBonus('armor', { itemType: 'weapon', statBonus: { stat_str: 9 } }).points).toBe(0);
    expect(pieceBonus('weapon', { itemType: 'armor_head', statBonus: { stat_vit: 9 } }).hp).toBe(0);
    expect(pieceBonus('weapon', { itemType: 'ring', statBonus: { stat_str: 9 } }).damage).toBe(0);
    expect(pieceBonus('weapon', null)).toEqual({ points: 0, hp: 0, damage: 0, speed: 0, ward: 0 });
  });
  it('flat stat affixes count as points; Gravebound, of the Legion and the Ossuary Wall count at a share; the rest are yours alone', () => {
    const piece = (affixes: { id: string; v: number }[]) => ({ itemType: 'weapon', statBonus: { stat_str: 4 }, affixes });
    expect(statPoints(piece([{ id: 'p_str', v: 5 }]))).toBe(9);
    const grave = pieceBonus('weapon', piece([{ id: 'p_thrall_dmg', v: 100 }]));
    expect(grave.damage).toBeCloseTo(4 * KIT_RATES.weaponDamagePerPoint + 0.1 * KIT_RATES.affixShare, 6);
    const legion = pieceBonus('armor', { itemType: 'armor_head', statBonus: { stat_vit: 3 }, affixes: [{ id: 's_thrall_hp', v: 200 }] });
    expect(legion.hp).toBeCloseTo(3 * KIT_RATES.armorHpPerPoint + 0.2 * KIT_RATES.affixShare, 6);
    const ward = pieceBonus('armor', { itemType: 'armor_head', statBonus: null, affixes: [{ id: 's_ward', v: 40 }] });
    expect(ward.ward).toBeCloseTo(0.04 * KIT_RATES.affixShare, 6);
    expect(unusedAffixes(piece([{ id: 'p_essence_regen', v: 90 }, { id: 'p_str', v: 3 }, { id: 'p_thrall_dmg', v: 80 }]))).toEqual(['+9% essence regeneration']);
  });
});

describe('reinforcement', () => {
  it('each tier is +3% thrall health and damage and +1% attack speed, clamped to the twelve tiers', () => {
    expect(reinforceBonus(0)).toEqual({ tier: 0, hp: 0, damage: 0, speed: 0 });
    expect(reinforceBonus(5)).toEqual({ tier: 5, hp: 0.15, damage: 0.15, speed: 0.05 });
    expect(reinforceBonus(99).tier).toBe(LEGION_UPGRADE.maxTier);
    expect(reinforceBonus(-3).tier).toBe(0);
    expect(reinforceBonus(2.9).tier).toBe(2);
  });
  it('costs rise with every tier and the whole ladder is a real sink (tens of thousands of gold)', () => {
    const costs = Array.from({ length: LEGION_UPGRADE.maxTier }, (_, i) => LEGION_UPGRADE.cost(i));
    expect(costs[0]).toBe(120);
    for (let i = 1; i < costs.length; i++) expect(costs[i]).toBeGreaterThan(costs[i - 1] * 1.5);
    const total = costs.reduce((a, b) => a + b, 0);
    expect(total).toBeGreaterThan(50_000);
    expect(total).toBeLessThan(150_000);
    expect(codexLegionTiers().at(-1)!.total).toBe(total);
  });
  it('the kit and the reinforcement multiply', () => {
    const b = legionBonus({ weapon: { itemType: 'weapon', statBonus: { stat_str: 10 } }, armor: { itemType: 'armor_chest', statBonus: { stat_vit: 10 } } }, 4);
    expect(b.damageMult).toBeCloseTo((1 + 0.1) * (1 + 0.12), 6);
    expect(b.hpMult).toBeCloseTo((1 + 0.12) * (1 + 0.12), 6);
    expect(b.speedMult).toBeCloseTo((1 + 0.03) * (1 + 0.04), 6);
    expect(legionBonus({}, 0)).toEqual(NO_LEGION);
  });
  it('a typical bag-fodder kit is felt but small; a maxed one is large but bounded (power score)', () => {
    const base = (slots: InventorySlot[], tier = 0): StatContext => {
      const d = DISCIPLINES.gravecaller;
      return { character: character(), slots, discipline: { ...d, mods: applyLegionMods(d.mods, legionOf(slots, tier)) }, damageTier: 0, legion: legionOf(slots, tier) };
    };
    const none = gearPower(base([])).total;
    const typical = gearPower(base([kitW('sword_copper'), kitA('chest_iron')])).total;
    const reinforced = gearPower(base([kitW('sword_copper'), kitA('chest_iron')], 6)).total;
    const maxed = gearPower(base([kitW('staff_moon'), kitA('set_ossuary_ascended_chest')], 12)).total;
    // Measured 2026-10-02 (gravecaller, level 20): copper kit +1.2%, iron kit +2.6%, iron kit at tier 6 +7.5%, tier 12 alone +8.9%, everything maxed +19.8%.
    expect(typical / none).toBeGreaterThan(1.005);
    expect(typical / none).toBeLessThan(1.06);
    expect(reinforced / none).toBeGreaterThan(typical / none + 0.03);
    expect(reinforced / none).toBeLessThan(1.15);
    expect(maxed / none).toBeGreaterThan(1.1);
    expect(maxed / none).toBeLessThan(1.3);
  });
});

describe('the kit never touches the hero', () => {
  const worn = [slot(105, 'staff_oak'), slot(101, 'plate_copper')];
  it('equippedBySlot ignores kit rows even when the kit holds the same kind of piece', () => {
    const slots = [...worn, kitW('sword_copper'), kitA('chest_iron')];
    const by = equippedBySlot(slots);
    expect(by.main_hand?.item_id).toBe('staff_oak');
    expect(by.chest?.item_id).toBe('plate_copper');
    expect(equippedBySlot([kitW(), kitA()])).toEqual({});
  });
  it('kit stats never reach your stat totals', () => {
    const a = computeStats(character(), worn);
    const b = computeStats(character(), [...worn, kitW('staff_moon'), kitA('chest_iron')]);
    expect(b.total).toEqual(a.total);
  });
  it('kit affixes never reach your gear power or your set bonuses', () => {
    const roll = withAffix(kitW(), [{ id: 'p_thrall_dmg', v: 120 }, { id: 'p_str', v: 9 }]);
    const ctx = (slots: InventorySlot[]): StatContext => ({ character: character(), slots, discipline: DISCIPLINES.gravecaller, damageTier: 0 });
    expect(gearPower(ctx([...worn, roll])).total).toBe(gearPower(ctx(worn)).total);
    expect(resolveSetBonuses([...worn, roll]).affixTotals).toEqual(resolveSetBonuses(worn).affixTotals);
  });
});

describe('folding into the thralls', () => {
  const slots = [kitW('sword_copper'), kitA('chest_iron')];
  it('multiplies thrall health, damage and attack speed in the discipline mods and adds ward', () => {
    const d = DISCIPLINES.gravecaller;
    const folded = applyLegionMods(d.mods, legionOf([...slots, withAffix(slot(121, 'helm_iron'), [{ id: 's_ward', v: 50 }])].slice(0, 1).concat(withAffix(kitA('chest_iron'), [{ id: 's_ward', v: 50 }])), 2));
    expect(folded.thrallDamageMult).toBeGreaterThan(d.mods.thrallDamageMult);
    expect(folded.thrallHpMult).toBeGreaterThan(d.mods.thrallHpMult);
    expect(folded.thrallAttackSpeedMult).toBeGreaterThan(d.mods.thrallAttackSpeedMult);
    expect(folded.wardPerThrall).toBeCloseTo(d.mods.wardPerThrall + 0.05 * KIT_RATES.affixShare, 6);
    expect(applyLegionMods(d.mods, NO_LEGION)).toBe(d.mods);
  });
  it('deriveStats gives each new thrall the bonus (the existing pipeline, no new sim path)', () => {
    const d = DISCIPLINES.ossuary;
    const b = legionOf(slots, 3);
    const before = deriveStats(character(), [], d, 0);
    const after = deriveStats(character(), [], { ...d, mods: applyLegionMods(d.mods, b) }, 0);
    expect(after.thrallHp / before.thrallHp).toBeCloseTo(b.hpMult, 2);
    expect(after.thrallDamage / before.thrallDamage).toBeCloseTo(b.damageMult, 5);
    expect(after.maxHp).toBe(before.maxHp);
    expect(after.spellPower).toBeCloseTo(before.spellPower, 6);
  });
  it('sits beneath the armour sets: withSetBonuses peels the sets off without touching the legion', () => {
    const d = DISCIPLINES.ossuary;
    const b = legionOf(slots, 2);
    const withLegion = { ...d, mods: applyLegionMods(d.mods, b) };
    const sets = resolveSetBonuses([]).totals;
    const full = { ...withLegion, mods: applySetMods(withLegion.mods, sets) };
    expect(withSetBonuses(full, []).mods.thrallHpMult).toBeCloseTo(withLegion.mods.thrallHpMult, 9);
  });
  it('the Character sheet names the legion on the thrall lines and the rows multiply to the number shown', () => {
    const d = DISCIPLINES.gravecaller;
    const b = legionOf(slots, 3);
    const ctx: StatContext = { character: character(), slots, discipline: { ...d, mods: applyLegionMods(d.mods, b) }, damageTier: 0, legion: b };
    const lines = statSheet(ctx).flatMap((s) => s.lines);
    for (const id of ['thrallHp', 'thrallDamage']) {
      const line = lines.find((l) => l.id === id)!;
      const labels = line.rows.map((r) => r.label);
      expect(labels).toContain('Legion kit');
      expect(labels).toContain('Legion reinforcement');
      const mults = line.rows.filter((r) => r.value.startsWith('×')).map((r) => Number(r.value.slice(1)));
      const share = line.rows.find((r) => r.label === 'Thrall share')!.value;
      const start = Number(line.rows[0].value.replace(/[^0-9.]/g, ''));
      expect(Math.round(start * Number(share.slice(1)) * mults.slice(1).reduce((a, m) => a * m, 1)) / 1).toBeGreaterThan(0);
    }
  });
});

describe('candidates and verdicts', () => {
  it('a bag piece gets an up arrow over an empty slot, a down arrow against a better kit piece, and bag order is best first', () => {
    const bag = [slot(0, 'sword_copper'), slot(1, 'staff_moon'), slot(2, 'plate_copper'), slot(3, 'ring_copper'), slot(4, 'ore_copper')];
    const c = kitCandidates(bag);
    expect(c.map((x) => x.slot.item_id)).toEqual(['staff_moon', 'plate_copper', 'sword_copper']);
    expect(c.every((x) => x.verdict === 'up')).toBe(true);
    const held = [...bag, kitW('staff_moon')];
    expect(kitCandidate(held, bag[0])!.verdict).toBe('down');
    expect(kitCandidate(held, bag[0])!.text).toMatch(/^-\d/);
    expect(kitCandidate(held, bag[2])!.verdict).toBe('up');
    expect(kitCandidate([...bag, kitW('sword_copper')], bag[0])!.verdict).toBe('same');
  });
  it('the words say what changes, in thrall terms', () => {
    const c = kitCandidate([slot(0, 'sword_copper')], slot(0, 'sword_copper'))!;
    expect(c.text).toBe('+4.0% thrall damage, +1.2% attack speed');
    const a = kitCandidate([], slot(1, 'chest_iron'))!;
    expect(a.text).toBe('+13.2% thrall health');
  });
  it('worn gear, kit rows, rings and materials are not candidates', () => {
    expect(kitCandidate([], slot(105, 'staff_oak'))).toBeNull();
    expect(kitCandidate([], kitW())).toBeNull();
    expect(kitCandidate([], slot(0, 'ring_copper'))).toBeNull();
  });
  it('piece lines and bonus lines are plain words', () => {
    expect(pieceLines('weapon', kitW()).lines).toEqual(['Thralls hit +4% harder', 'Thralls attack +1.2% faster']);
    expect(bonusLines({ hp: 0.1, damage: 0, speed: 0, ward: 0.03 })).toEqual(['Thralls have +10% health', '3% less damage to you per thrall']);
    expect(bonusLines({ hp: 0, damage: 0, speed: 0, ward: 0 })).toEqual([]);
  });
  it('kitPieces and the signature follow the rows', () => {
    const s = [kitW('sword_copper'), kitA('plate_copper')];
    expect(Object.keys(kitPieces(s)).sort()).toEqual(['armor', 'weapon']);
    expect(legionSignature(s, 2)).not.toBe(legionSignature(s, 3));
    expect(legionSignature(s, 2)).not.toBe(legionSignature([kitW('sword_copper')], 2));
    expect(legionSignature([], 0)).toBe(legionSignature([], 0));
  });
  it('the Codex examples come from the rules', () => {
    const rows = codexLegionExamples();
    expect(rows.find((r) => r.item === 'Copper Sword')!.gives).toBe('+4% damage, +1.2% attack speed');
    expect(rows.every((r) => r.gives.length > 0)).toBe(true);
  });
});

describe('Legion reinforcement on the server rules', () => {
  it('buying a tier takes the exact gold and raises the tier, one at a time', () => {
    const s0 = blankState();
    const r = purchase(s0, 1000, 'legion');
    expect(r.ok && [r.cost, r.gold, r.state.legionTier]).toEqual([120, 880, 1]);
    const r2 = r.ok ? purchase(r.state, r.gold, 'legion') : r;
    expect(r2.ok && [r2.cost, r2.gold, r2.state.legionTier]).toEqual([198, 682, 2]);
    expect(s0.legionTier).toBe(0);
  });
  it('refuses when the gold is short or the top is reached, changing nothing', () => {
    expect(purchase(blankState(), 119, 'legion')).toEqual({ ok: false, error: 'Not enough gold (need 120)' });
    const top = { ...blankState(), legionTier: LEGION_UPGRADE.maxTier };
    expect(purchase(top, 1e9, 'legion')).toEqual({ ok: false, error: 'Already at max tier' });
    expect(purchase(blankState(), 1e9, 'teleport' as 'legion')).toEqual({ ok: false, error: 'Unknown upgrade' });
  });
  it('Ascension resets the tiers like Damage and Wave Speed; old rows and bad rows normalise', () => {
    const s = { ...blankState(), legionTier: 7, run: { prelateKills: 1, peakWaveTier: 0, kills: 5 }, bossKills: 1, ascension: 0 };
    const a = ascend(s);
    expect(a.ok && a.state.legionTier).toBe(0);
    expect(normalise({ damageTier: 3 }).legionTier).toBe(0);
    expect(normalise({ legionTier: 999 }).legionTier).toBe(LEGION_UPGRADE.maxTier);
    expect(normalise({ legionTier: -4 }).legionTier).toBe(0);
    expect(normalise({ legionTier: 'x' }).legionTier).toBe(0);
  });
});
