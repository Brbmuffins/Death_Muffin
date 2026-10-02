import { describe, expect, it } from 'vitest';
import { DISCIPLINES, type DisciplineId } from '../../content/disciplines';
import { ARMOR_BY_ID, ARMOR_PARTS, ARMOR_PIECES, type ArmorPart } from '../../content/armorSets';
import { LEGENDARY_SET_IDS } from '../../content/legendarySets';
import { SET_BONUSES, SET_IDS, SET_TIERS, describeEffect, type SetEffect } from '../../content/setBonuses';
import type { Character, InventorySlot } from '../../net/types';
import { computeStats } from '../stats';
import { deriveStats } from '../characterStats';
import { compareEquip, gearPower, itemVerdict, setSheetLines, statSheet, type StatContext } from '../gearStats';
import { applySetMods, diffSetBonuses, effectRelevant, resolveSetBonuses, setDiffText, setSignature, withSetBonuses, withoutSetBonuses } from '../setBonuses';
import { codexSetRows } from '../../content/codex';

const character = (over: Partial<Character> = {}): Character => ({
  id: 1, class_index: 1, class_name: '', level: 20, experience: 0, gold: 0, stat_str: 10, stat_agi: 10, stat_int: 10, stat_vit: 10, ...over,
});

let nextId = 1;
let bag = 0;
/** A catalog armor piece as an inventory slot: worn (slot 100+) or in the bag. */
const piece = (setId: string, part: ArmorPart, equipped: 0 | 1 = 0): InventorySlot => {
  const p = ARMOR_PIECES.find((x) => x.setId === setId && x.part === part)!;
  return { id: nextId++, slot_index: equipped ? 100 + ARMOR_PARTS.indexOf(part) : bag++, quantity: 1, equipped, item_id: p.id, name: p.name, rarity: p.rarity, item_type: p.type, stat_bonus: p.stats, icon_id: null, sell_value: 1, crafted: 0 };
};
const wear = (setId: string, parts: ArmorPart[]) => parts.map((p) => piece(setId, p, 1));
const ctx = (slots: InventorySlot[], disc: DisciplineId = 'ossuary'): StatContext => ({ character: character(), slots, discipline: DISCIPLINES[disc], damageTier: 0 });
const NORMAL_IDS = SET_IDS.filter((id) => !LEGENDARY_SET_IDS.includes(id));
const FIVE: ArmorPart[] = ['head', 'chest', 'hands', 'legs', 'feet'];

describe('set bonus table', () => {
  it('every set has exactly a 2, 4 and 5 piece bonus with plain text', () => {
    expect(SET_IDS).toHaveLength(22);
    for (const id of SET_IDS) {
      expect(SET_BONUSES[id].map((b) => b.pieces)).toEqual(SET_TIERS);
      for (const b of SET_BONUSES[id]) expect(describeEffect(b.effect).length).toBeGreaterThan(0);
      expect(SET_BONUSES[id][2].name, `${id} 5-piece is named`).toBeTruthy();
    }
  });
  it('the ascended set is a step up from the first, tier by tier', () => {
    const SET_IDS = NORMAL_IDS;
    const size = (e: SetEffect) =>
      Object.values(e.mult ?? {}).reduce((a, m) => a + (m - 1), 0) + Object.values(e.add ?? {}).reduce((a, v) => a + (v >= 1 ? v * 0.05 : v), 0) + Object.values(e.stats ?? {}).reduce((a, v) => a + v * 0.01, 0);
    for (const id of SET_IDS.filter((s) => !s.endsWith('_ascended'))) {
      SET_TIERS.forEach((_, i) => expect(size(SET_BONUSES[`${id}_ascended`][i].effect), `${id} tier ${i}`).toBeGreaterThanOrEqual(size(SET_BONUSES[id][i].effect)));
    }
  });
  it('keeps every line inside its budget (2026-10-02 gear pass): thrall and health lines at most +30%, essence regeneration at most +45%', () => {
    for (const id of NORMAL_IDS) {
      for (const b of SET_BONUSES[id]) {
        for (const [k, m] of Object.entries(b.effect.mult ?? {})) expect(m, `${id} ${b.pieces}pc ${k}`).toBeLessThanOrEqual(k === 'essenceRegenMult' ? 1.45 : 1.3);
      }
    }
  });
  it('a whole first set stays under +60% on any one lever, an ascended one under +90% (levers multiply across the lines)', () => {
    for (const id of NORMAL_IDS) {
      const total = new Map<string, number>();
      for (const b of SET_BONUSES[id]) for (const [k, m] of Object.entries(b.effect.mult ?? {})) total.set(k, (total.get(k) ?? 1) * m);
      for (const [k, m] of total) expect(m, `${id} ${k}`).toBeLessThanOrEqual(id.endsWith('_ascended') ? 1.9 : 1.6);
    }
  });
  it('the Codex lists all 22 sets with three bonuses each, the legendary ones last', () => {
    const rows = codexSetRows();
    expect(rows).toHaveLength(22);
    expect(rows.slice(-4).map((r) => r.collection)).toEqual([3, 3, 3, 3]);
    for (const r of rows) expect(r.bonuses).toHaveLength(3);
  });
});

describe('legendary sets (docs/LEGENDARY-SETS.md)', () => {
  const at = (id: string, n: number) => SET_BONUSES[id].filter((b) => b.pieces <= n);
  const totals = (id: string, n: number) => at(id, n).reduce((t, b) => ({ mult: { ...t.mult, ...Object.fromEntries(Object.entries(b.effect.mult ?? {}).map(([k, v]) => [k, (t.mult[k] ?? 1) * v])) }, add: { ...t.add, ...Object.fromEntries(Object.entries(b.effect.add ?? {}).map(([k, v]) => [k, (t.add[k] ?? 0) + v])) } }), { mult: {} as Record<string, number>, add: {} as Record<string, number> });
  it('carries exactly the numbers of the design doc', () => {
    expect(totals('legion_unburied', 5)).toEqual({ mult: { thrallDamageMult: 1.25, thrallAttackSpeedMult: 1.1 }, add: { thrallDeathBurst: 0.8, thrallCap: 2, championEvery: 4, spearRally: 1 } });
    expect(totals('colossus_mantle', 5)).toEqual({ mult: { thrallHpMult: 1.35, thrallDamageMult: 1.15 }, add: { wardReflect: 0.6, colossusGuard: 0.3, litanyShatter: 4 } });
    expect(totals('requiem_wraiths', 5)).toEqual({ mult: { essenceRegenMult: 1.4, maxHpMult: 1.1, soulHarvestRateMult: 2, thrallAttackSpeedMult: 1.15 }, add: { corpseWisp: 10, corpseHeal: 0.02, wraithNova: 1.2 } });
    expect(totals('plague_choir', 5)).toEqual({ mult: { miasmaRadiusMult: 1.25, maxHpMult: 1.08 }, add: { miasmaSpreadsWithered: 1, witheredBurstAt: 8 } });
    expect(LEGENDARY_SET_IDS.map((id) => SET_BONUSES[id].slice(1).map((b) => b.name))).toEqual([['Bursting Dead', 'Legion Champion'], ['Reflecting Ward', 'Colossus'], ['Wisps', 'Requiem'], ['Contagion', 'Chain Plague']]);
  });
  it('says every mechanic plainly', () => {
    const text = LEGENDARY_SET_IDS.flatMap((id) => SET_BONUSES[id].flatMap((b) => describeEffect(b.effect))).join('\n');
    for (const needle of ['Thralls burst when they die (80% of their health', 'Every 4th thrall', 'Marrow Spear rallies', 'Bone Ward reflects 60%', '30% less damage taken while 3 or more thralls', 'shatters into bone shards for 4x', 'healing wisp for 10 s', 'Soul Harvest fills 2x faster', 'every wraith and wisp releases a nova (120%', 'spread their Withered stacks', 'reaches 8 Withered stacks bursts into a new Miasma']) expect(text).toContain(needle);
  });
  it('shows in the set tracker, with its own pieces listed as dropping from bosses', () => {
    const worn = ['head', 'chest', 'hands'] as ArmorPart[];
    const r = resolveSetBonuses(wear('legion_unburied', worn));
    expect(r.sets[0]).toMatchObject({ setId: 'legion_unburied', worn: 3, collection: 3 });
    expect(r.sets[0].missing.map((m) => m.where)).toEqual(['Area bosses', 'Area bosses']);
    expect(r.totals.mult.thrallDamageMult).toBe(1.25);
  });
});

describe('resolveSetBonuses', () => {
  it('counts 0 to 5 pieces and switches tiers at 2, 4 and 5', () => {
    const states = [0, 1, 2, 3, 4, 5].map((n) => resolveSetBonuses(wear('ossuary', FIVE.slice(0, n))));
    expect(states[0].sets).toEqual([]);
    expect(states.map((s) => s.sets[0]?.worn ?? 0)).toEqual([0, 1, 2, 3, 4, 5]);
    expect(states.map((s) => s.active.map((b) => b.pieces))).toEqual([[], [], [2], [2], [2, 4], [2, 4, 5]]);
    expect(states[1].sets[0].next).toBe(2);
    expect(states[5].sets[0].next).toBeNull();
    expect(states[3].sets[0].missing.map((m) => m.part)).toEqual(['legs', 'feet']);
    expect(states[3].sets[0].missing[0].where).toBe('The Drowned Nave');
  });
  it('bonuses stack: five pieces gives all three lines', () => {
    const t = resolveSetBonuses(wear('gravecaller', FIVE)).totals;
    expect(t.add.thrallCap).toBe(1);
    expect(t.mult.thrallDamageMult).toBeCloseTo(1.08 * 1.14, 6);
    expect(t.mult.thrallAttackSpeedMult).toBeCloseTo(1.1, 6);
  });
  it('mixed collections count separately', () => {
    const slots = [...wear('ossuary', ['head', 'chest', 'hands']), ...wear('ossuary_ascended', ['legs', 'feet'])];
    const r = resolveSetBonuses(slots);
    expect(r.sets.map((s) => [s.setId, s.worn])).toEqual([['ossuary', 3], ['ossuary_ascended', 2]]);
    expect(r.active.map((b) => `${b.setId}:${b.pieces}`).sort()).toEqual(['ossuary:2', 'ossuary_ascended:2']);
  });
  it('two different sets at two pieces each give both first bonuses', () => {
    const r = resolveSetBonuses([...wear('ossuary', ['head', 'chest']), ...wear('mourner', ['hands', 'legs'])]);
    expect(r.active).toHaveLength(2);
    expect(r.totals.mult.thrallHpMult).toBeCloseTo(1.2, 6);
    expect(r.totals.mult.essenceRegenMult).toBeCloseTo(1.3, 6);
  });
  it('ignores bag pieces and non-armor', () => {
    expect(resolveSetBonuses([piece('ossuary', 'head'), piece('ossuary', 'chest')]).sets).toEqual([]);
  });
  it('signature changes only when the active bonuses do', () => {
    expect(setSignature(wear('ossuary', FIVE.slice(0, 2)))).toBe(setSignature(wear('ossuary', FIVE.slice(0, 3))));
    expect(setSignature(wear('ossuary', FIVE.slice(0, 4)))).not.toBe(setSignature(wear('ossuary', FIVE.slice(0, 3))));
  });
});

describe('plugging into the pipeline', () => {
  it('flat stats go through computeStats like gear', () => {
    const slots = wear('monk', ['head', 'chest']);
    const gear = slots.reduce((a, s) => a + (s.stat_bonus?.stat_agi ?? 0), 0);
    expect(computeStats(character(), slots).bonus.stat_agi).toBe(gear + 3);
    expect(computeStats(character(), wear('monk', ['head'])).bonus.stat_agi).toBe(ARMOR_BY_ID.set_monk_head.stats.stat_agi ?? 0);
  });
  it('mult and add fold into the discipline mods (thrall cap, damage, attack speed)', () => {
    const slots = wear('gravecaller', FIVE);
    const base = DISCIPLINES.gravecaller;
    const mods = applySetMods(base.mods, resolveSetBonuses(slots).totals);
    expect(mods.thrallCap).toBe(base.mods.thrallCap + 1);
    expect(mods.thrallAttackSpeedMult).toBeCloseTo(base.mods.thrallAttackSpeedMult * 1.1, 6);
    const plain = deriveStats(character(), slots, base, 0);
    const withSets = deriveStats(character(), slots, { ...base, mods }, 0);
    expect(withSets.thrallDamage).toBeCloseTo(plain.thrallDamage * 1.08 * 1.14, 6);
  });
  it('withSetBonuses re-bases a discipline and is idempotent', () => {
    const base = DISCIPLINES.rotweaver;
    const five = wear('rotweaver', FIVE);
    const d = withSetBonuses(base, five);
    expect(d.mods.witheredMaxStacks).toBe(base.mods.witheredMaxStacks + 2 + 1);
    expect(d.mods.miasmaRadiusMult).toBeCloseTo(base.mods.miasmaRadiusMult * 1.12 * 1.08 * 1.12, 6);
    expect(withSetBonuses(d, five)).toBe(d);
    expect(withSetBonuses(d, wear('rotweaver', FIVE.slice(0, 3))).mods.witheredMaxStacks).toBe(base.mods.witheredMaxStacks);
    expect(withoutSetBonuses(d).mods.witheredMaxStacks).toBe(base.mods.witheredMaxStacks);
    expect(withSetBonuses(withSetBonuses(d, []), five).mods.witheredMaxStacks).toBe(d.mods.witheredMaxStacks);
    expect(withSetBonuses(base, [])).toBe(base);
  });
  it('relevance: a Hollow Knight gets stat and health lines, not thrall lines', () => {
    const k = DISCIPLINES.hollow_knight;
    expect(effectRelevant({ mult: { thrallHpMult: 1.05 } }, k)).toBe(false);
    expect(effectRelevant({ mult: { maxHpMult: 1.05 } }, k)).toBe(true);
    expect(effectRelevant({ stats: { stat_str: 3 } }, k)).toBe(true);
    expect(effectRelevant({ mult: { thrallHpMult: 1.05 } }, DISCIPLINES.mourner)).toBe(true);
  });
});

describe('gear score and verdict', () => {
  it('completing a 4-piece lifts the upgrade above the same piece without the bonus', () => {
    const worn = wear('ossuary', ['head', 'chest', 'hands']);
    const legs = piece('ossuary', 'legs');
    const alien = { ...piece('mourner', 'legs'), stat_bonus: legs.stat_bonus };
    const withSet = itemVerdict(ctx([...worn, legs]), legs)!;
    const without = itemVerdict(ctx([...worn, alien]), alien)!;
    expect(withSet.setNote).toBe('completes Ivory Reliquary 4-piece');
    expect(withSet.text).toMatch(/^Upgrade for your Ossuary: .*— completes Ivory Reliquary 4-piece$/);
    expect(without.setNote).toBe('');
    expect(withSet.pct).toBeGreaterThan(without.pct + 0.5);
  });
  it('starting a 2-piece says so', () => {
    const worn = wear('gravecaller', ['head']);
    const chest = piece('gravecaller', 'chest');
    expect(itemVerdict(ctx([...worn, chest], 'gravecaller'), chest)!.setNote).toBe('completes Gravecall 2-piece');
  });
  it('breaking a set makes a slightly better-statted piece Worse and says what breaks', () => {
    const worn = wear('gravecaller', ['head', 'chest', 'hands', 'legs']);
    const rival = { ...piece('mourner', 'legs'), stat_bonus: { stat_int: 3, stat_vit: 2 } };
    const c = ctx([...worn, rival], 'gravecaller');
    // same stats as the worn legguards, nothing else changes: only the set bonus is lost
    const same = { ...rival, stat_bonus: worn[3].stat_bonus };
    const v = itemVerdict(ctx([...worn, same], 'gravecaller'), same)!;
    expect(v.kind).toBe('downgrade');
    expect(v.text).toMatch(/^Worse than your .*— breaks your Gravecall 4-piece$/);
    expect(c.slots).toHaveLength(5);
  });
  it('a swap between pieces of the same set leaves the set note empty', () => {
    const worn = wear('ossuary', ['head', 'chest']);
    const better = { ...piece('ossuary', 'head'), stat_bonus: { stat_int: 9, stat_vit: 9 } };
    const v = itemVerdict(ctx([...worn, better]), better)!;
    expect(v.setNote).toBe('');
    expect(v.kind).toBe('upgrade');
  });
  it('a necromancer set means nothing to a Hollow Knight: no note, same score as a plain piece', () => {
    const worn = wear('ossuary', ['head', 'chest', 'hands']);
    const legs = piece('ossuary', 'legs');
    const alien = { ...piece('mourner', 'legs'), stat_bonus: legs.stat_bonus };
    expect(itemVerdict(ctx([...worn, legs], 'hollow_knight'), legs)!.setNote).toBe('');
    const base = ctx(worn, 'hollow_knight');
    expect(gearPower(base, [...worn, { ...legs, equipped: 1 as const }]).total).toBeCloseTo(gearPower(base, [...worn, { ...alien, equipped: 1 as const }]).total, 9);
  });
  it('values effects deriveStats cannot see: a Rotweaver 4-piece (Withered stacks, Miasma) is worth power', () => {
    const worn = wear('rotweaver', ['head', 'chest', 'hands']);
    const legs = piece('rotweaver', 'legs');
    const alien = { ...piece('mourner', 'legs'), stat_bonus: legs.stat_bonus };
    const c = ctx([...worn, legs], 'rotweaver');
    const gain = gearPower(c, [...worn, { ...legs, equipped: 1 as const }]);
    expect(gain.terms.set).toBeGreaterThan(0);
    expect(gain.total).toBeGreaterThan(gearPower(c, [...worn, { ...alien, equipped: 1 as const }]).total);
    expect(itemVerdict(c, legs)!.setNote).toBe('completes Blightweave 4-piece');
  });
  it('gearPower follows the re-based discipline (thrall cap at 5 pieces)', () => {
    const worn = wear('gravecaller', FIVE.slice(0, 4));
    const feet = piece('gravecaller', 'feet');
    const c = ctx([...worn, feet], 'gravecaller');
    const sim = [...worn, { ...feet, equipped: 1 as const }];
    const bare = gearPower(c, [...worn, { ...feet, equipped: 1 as const, stat_bonus: null }]);
    const withBonus = gearPower(c, [...worn, { ...feet, equipped: 1 as const, stat_bonus: null }]);
    expect(withBonus.total).toBe(bare.total);
    expect(gearPower(c, sim).total).toBeGreaterThan(gearPower(c, worn).total);
    expect(compareEquip(c, feet)!.sets.gained.map((g) => g.pieces)).toEqual([5]);
  });
  it('verdict is stable when the scene discipline already carries the sets', () => {
    const worn = wear('gravecaller', FIVE.slice(0, 4));
    const feet = piece('gravecaller', 'feet');
    const slots = [...worn, feet];
    const plain = ctx(slots, 'gravecaller');
    const carried = { ...plain, discipline: withSetBonuses(plain.discipline, worn) };
    expect(itemVerdict(carried, feet)!.pct).toBeCloseTo(itemVerdict(plain, feet)!.pct, 6);
  });
});

describe('Character sheet', () => {
  it('lists each worn set with its bonuses, status and what is still needed', () => {
    const sections = statSheet(ctx(wear('ossuary', ['head', 'chest', 'hands'])));
    const sets = sections.find((s) => s.id === 'sets')!;
    expect(sets.title).toBe('Set bonuses');
    const line = sets.lines[0];
    expect(line.label).toBe('Ivory Reliquary');
    expect(line.value).toBe('3 / 5');
    expect(line.help).toMatch(/1 more piece for the 4-piece bonus/);
    expect(line.rows.filter((r) => r.tone === 'up')).toHaveLength(1);
    expect(line.rows.map((r) => r.label).join('\n')).toMatch(/Need: Ivory Reliquary Legguards/);
    expect(line.rows.find((r) => r.label.startsWith('Need: Ivory Reliquary Legguards'))!.value).toBe('The Drowned Nave');
  });
  it('says so when no set is worn', () => {
    expect(setSheetLines([], DISCIPLINES.ossuary)[0].label).toBe('No set worn');
  });
  it('separates set health from Covenant boons and sums to the same total', () => {
    const slots = wear('ossuary', FIVE);
    const scene = { ...ctx(slots), discipline: withSetBonuses(DISCIPLINES.ossuary, slots) };
    const hp = statSheet(scene).find((s) => s.id === 'derived')!.lines.find((l) => l.id === 'maxHp')!;
    expect(hp.rows.find((r) => r.label === 'Set bonuses' && r.value.startsWith('×'))?.value).toBe(`×${+(1.02 * 1.1).toFixed(3)}`);
    expect(hp.rows.find((r) => r.label === 'Covenant boons')).toBeUndefined();
    expect(hp.rows.at(-1)!.value).toBe(String(deriveStats(character(), slots, scene.discipline, 0).maxHp));
  });
});

describe('diff text', () => {
  it('names the highest tier of a set and joins gains and losses', () => {
    expect(setDiffText({ gained: [{ setName: 'A', pieces: 2 }, { setName: 'A', pieces: 4 }], lost: [{ setName: 'B', pieces: 2 }] })).toBe('completes A 4-piece, breaks your B 2-piece');
    expect(diffSetBonuses([], [], DISCIPLINES.ossuary)).toEqual({ gained: [], lost: [] });
  });
});
