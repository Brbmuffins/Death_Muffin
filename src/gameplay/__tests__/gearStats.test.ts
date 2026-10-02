import { describe, expect, it } from 'vitest';
import { DISCIPLINES } from '../../content/disciplines';
import { DAMAGE_UPGRADE } from '../../content/upgrades';
import type { Character, InventorySlot } from '../../net/types';
import { STAT_EFFECTS, deriveStats, describeStatDelta } from '../characterStats';
import { compareEquip, effectText, itemStatEffects, simulateEquip, statSheet, boonShare, STAT_PRIORITY, ROLE_WEIGHTS, itemVerdict, lookingFor, weakestSlots, loadoutExtraPct, LOADOUT_VALUE, type StatContext } from '../gearStats';
import { resolveWeaponLoadout } from '../weaponLine';

const character = (over: Partial<Character> = {}): Character => ({
  id: 1, class_index: 1, class_name: '', level: 10, experience: 0, gold: 0, stat_str: 5, stat_agi: 5, stat_int: 5, stat_vit: 5, ...over,
});

let nextId = 1;
const item = (item_id: string, slot_index: number, item_type: InventorySlot['item_type'], stat_bonus: Record<string, number> | null, equipped: 0 | 1 = 0): InventorySlot => ({
  id: nextId++, slot_index, quantity: 1, equipped, item_id, name: item_id, rarity: 'common', item_type, stat_bonus, icon_id: null, sell_value: 1, crafted: 0,
});
const worn = (id: string, type: InventorySlot['item_type'], idx: number, bonus: Record<string, number> | null) => item(id, idx, type, bonus, 1);

const ctx = (slots: InventorySlot[], disc: keyof typeof DISCIPLINES = 'gravecaller', over: Partial<StatContext> = {}): StatContext =>
  ({ character: character(), slots, discipline: DISCIPLINES[disc], damageTier: 0, ...over });

describe('deriveStats uses STAT_EFFECTS', () => {
  it('matches the published coefficients exactly', () => {
    const c = character({ level: 1, stat_str: 0, stat_agi: 0, stat_int: 0, stat_vit: 10 });
    const d = deriveStats(c, [], DISCIPLINES.gravecaller, 0);
    expect(d.maxHp).toBe(Math.round((STAT_EFFECTS.health.base + 10 * STAT_EFFECTS.health.perVit) * DISCIPLINES.gravecaller.mods.maxHpMult));
  });
});

describe('describeStatDelta', () => {
  it('lists only the numbers that move, with signs and tone', () => {
    const a = deriveStats(character(), [], DISCIPLINES.gravecaller, 0);
    const b = deriveStats(character({ stat_vit: 11 }), [], DISCIPLINES.gravecaller, 0);
    const lines = describeStatDelta(a, b);
    expect(lines.map((l) => l.key)).toEqual(['maxHp', 'thrallHp']);
    expect(lines[0]).toMatchObject({ text: '+48', tone: 'up', label: 'health' });
  });
  it('reports losses and hides changes that round to nothing', () => {
    const a = deriveStats(character(), [], DISCIPLINES.gravecaller, 0);
    const worse = deriveStats(character({ stat_int: 0 }), [], DISCIPLINES.gravecaller, 0);
    const lines = describeStatDelta(a, worse);
    expect(lines.find((l) => l.key === 'spellPower')).toMatchObject({ tone: 'down', text: '-6.5' });
    expect(describeStatDelta(a, a)).toEqual([]);
    // 0.0001 of spell power is invisible: no "+0.0" line.
    expect(describeStatDelta(a, { ...a, spellPower: a.spellPower + 0.0001 })).toEqual([]);
  });
  it('shows move speed as a percent', () => {
    const a = deriveStats(character(), [], DISCIPLINES.gravecaller, 0);
    const b = deriveStats(character({ stat_agi: 15 }), [], DISCIPLINES.gravecaller, 0);
    expect(describeStatDelta(a, b).find((l) => l.key === 'moveSpeed')!.text).toMatch(/^\+\d+\.\d%$/);
  });
});

describe('itemStatEffects (discipline multipliers)', () => {
  it('+6 VIT is worth more health to an Ossuary necromancer (x1.2) than to a Gravecaller', () => {
    const helm = item('helm_x', 0, 'armor_head', { stat_vit: 6 });
    const oss = itemStatEffects(ctx([helm], 'ossuary'), helm)[0];
    const grave = itemStatEffects(ctx([helm], 'gravecaller'), helm)[0];
    const hp = (e: typeof oss) => e.lines.find((l) => l.key === 'maxHp')!.diff;
    expect(hp(grave)).toBeCloseTo(48 * DISCIPLINES.gravecaller.mods.maxHpMult, 0);
    expect(hp(oss)).toBeCloseTo(48 * 1.2, 0);
    expect(hp(oss)).toBeGreaterThan(hp(grave));
    expect(effectText(oss.lines)).toMatch(/^\+58 health \(\+\d+ thrall health\)$/);
  });
  it('INT moves spell power, essence and essence/s; STR does not move essence', () => {
    const ring = item('ring_x', 0, 'ring', { stat_int: 4, stat_str: 2 });
    const fx = itemStatEffects(ctx([ring]), ring);
    const int = fx.find((e) => e.stat === 'stat_int')!;
    const str = fx.find((e) => e.stat === 'stat_str')!;
    expect(int.lines.map((l) => l.key)).toEqual(expect.arrayContaining(['spellPower', 'maxEssence', 'essenceRegen']));
    expect(str.lines.map((l) => l.key)).not.toContain('maxEssence');
  });
});

describe('compareEquip', () => {
  it('compares a bag piece with the worn piece in the same slot', () => {
    const old = worn('helm_a', 'armor_head', 100, { stat_vit: 2 });
    const next = item('helm_b', 0, 'armor_head', { stat_vit: 6 });
    const c = compareEquip(ctx([old, next]), next)!;
    expect(c.replaced.map((r) => r.item_id)).toEqual(['helm_a']);
    const hp = c.lines.find((l) => l.key === 'maxHp')!;
    expect(hp.tone).toBe('up');
    expect(hp.after - hp.before).toBeCloseTo(32 * DISCIPLINES.gravecaller.mods.maxHpMult, 0);
  });
  it('shows red for a downgrade and nothing for a worn item', () => {
    const old = worn('helm_a', 'armor_head', 100, { stat_vit: 6 });
    const next = item('helm_b', 0, 'armor_head', { stat_vit: 1 });
    expect(compareEquip(ctx([old, next]), next)!.lines.find((l) => l.key === 'maxHp')!.tone).toBe('down');
    expect(compareEquip(ctx([old, next]), old)).toBeNull();
  });
  it('treats an empty slot as a pure gain', () => {
    const next = item('helm_b', 0, 'armor_head', { stat_vit: 3 });
    const c = compareEquip(ctx([next]), next)!;
    expect(c.replaced).toEqual([]);
    expect(c.lines[0].tone).toBe('up');
  });
  it('returns null for materials', () => {
    const ore = item('ore', 0, 'material', null);
    expect(compareEquip(ctx([ore]), ore)).toBeNull();
  });
  it('a two-handed staff displaces main hand AND off-hand, and the off-hand stats are lost', () => {
    const sword = worn('sword_copper', 'weapon', 105, { stat_str: 4 });
    const tome = worn('grimoire_bone', 'offhand', 106, { stat_int: 6 });
    const staff = item('staff_gold', 0, 'weapon', { stat_int: 8 });
    const c = compareEquip(ctx([sword, tome, staff]), staff)!;
    expect(c.replaced.map((r) => r.item_id).sort()).toEqual(['grimoire_bone', 'sword_copper']);
    expect(c.statChanges).toEqual(expect.arrayContaining([{ stat: 'stat_int', before: 11, after: 13 }, { stat: 'stat_str', before: 9, after: 5 }]));
    // The grimoire's passive is lost and the staff's spell bonus is gained, spoken in plain text.
    expect(c.lost.join(' ')).toMatch(/Rites recover 10% sooner/);
    expect(c.gained.join(' ')).toMatch(/\+10% spell damage/);
    // Spell power: +2 INT net (+2.6), -4 STR (-1.6), then the staff's x1.1.
    const base = deriveStats(character({ stat_int: 5 }), [], DISCIPLINES.gravecaller, 0);
    expect(c.after.spellPower).toBeGreaterThan(base.spellPower);
  });
  it('a one-handed main hand leaves the off-hand alone', () => {
    const tome = worn('grimoire_bone', 'offhand', 106, { stat_int: 6 });
    const wand = item('wand_bone', 0, 'weapon', { stat_int: 1 });
    expect(simulateEquip([tome, wand], 0).displaced).toEqual([]);
  });
  it('an off-hand displaces a worn two-hander', () => {
    const staff = worn('staff_bone', 'weapon', 105, { stat_int: 3 });
    const bell = item('mourning_bell_bone', 0, 'offhand', { stat_vit: 2 });
    expect(simulateEquip([staff, bell], 0).displaced.map((s) => s.item_id)).toEqual(['staff_bone']);
  });
  it('names the left click change when the weapon kind changes (necromancers only)', () => {
    const staff = worn('staff_bone', 'weapon', 105, { stat_int: 3 });
    const scythe = item('scythe_bone', 0, 'weapon', { stat_int: 3 });
    const mine = compareEquip(ctx([staff, scythe], 'mourner'), scythe)!;
    expect(mine.gained).toContain('Left click becomes a reaping arc');
    expect(mine.lost.join(' ')).toMatch(/pierces/);
    const knight = compareEquip(ctx([staff, scythe], 'hollow_knight'), scythe)!;
    expect(knight.gained).toEqual([]);
  });
  it('does not mutate the real slots', () => {
    const old = worn('helm_a', 'armor_head', 100, { stat_vit: 2 });
    const next = item('helm_b', 0, 'armor_head', { stat_vit: 6 });
    compareEquip(ctx([old, next]), next);
    expect([old.equipped, next.equipped]).toEqual([1, 0]);
  });
});

describe('statSheet', () => {
  const rowsOf = (s: ReturnType<typeof statSheet>, id: string) => s.flatMap((x) => x.lines).find((l) => l.id === id)!;

  it('every line shows the same number deriveStats produces', () => {
    const helm = worn('helm_a', 'armor_head', 100, { stat_vit: 6, stat_int: 2 });
    const staff = worn('staff_bone', 'weapon', 105, { stat_int: 3 });
    const c = ctx([helm, staff], 'mourner', { damageTier: 3 });
    const d = deriveStats(c.character, c.slots as InventorySlot[], c.discipline, 3);
    const sheet = statSheet(c);
    expect(rowsOf(sheet, 'maxHp').value).toBe(String(d.maxHp));
    expect(rowsOf(sheet, 'spellPower').value).toBe(d.spellPower.toFixed(1));
    expect(rowsOf(sheet, 'damageBonus').value).toBe(`+${d.damageBonusPct}%`);
    expect(rowsOf(sheet, 'stat_vit').value).toBe('11');
    // The breakdown names the worn item, the damage tiers and the staff.
    const spellRows = rowsOf(sheet, 'spellPower').rows.map((r) => r.label).join('|');
    expect(spellRows).toContain('helm_a');
    expect(spellRows).toContain('Damage upgrades (3 tiers)');
    expect(spellRows).toContain('Weapon line (staff)');
  });

  it('the health breakdown multiplies out to the real Health (no drift)', () => {
    const helm = worn('helm_a', 'armor_head', 100, { stat_vit: 6 });
    const c = ctx([helm], 'ossuary');
    const l = rowsOf(statSheet(c), 'maxHp');
    const num = (v: string) => Number(v.replace('+', '').replace('×', ''));
    const adds = l.rows.filter((r) => !r.value.startsWith('×') && !r.total).reduce((a, r) => a + num(r.value), 0);
    const mults = l.rows.filter((r) => r.value.startsWith('×')).reduce((a, r) => a * num(r.value), 1);
    expect(Math.round(adds * mults)).toBe(Number(l.value));
  });

  it('separates Covenant boons from the discipline multiplier', () => {
    const boosted = { ...DISCIPLINES.gravecaller, mods: { ...DISCIPLINES.gravecaller.mods, maxHpMult: DISCIPLINES.gravecaller.mods.maxHpMult * 1.16, essenceRegenMult: 1.24 } };
    expect(boonShare(boosted).maxHpMult).toBeCloseTo(1.16);
    const sheet = statSheet({ character: character(), slots: [], discipline: boosted, damageTier: 0 });
    expect(rowsOf(sheet, 'maxHp').rows.map((r) => r.label)).toContain('Covenant boons');
    expect(DAMAGE_UPGRADE.perTier).toBeGreaterThan(0);
  });
});

describe('stat priority', () => {
  it('role weights sum to 1 for every discipline', () => {
    for (const [id, w] of Object.entries(ROLE_WEIGHTS)) expect(w.damage + w.toughness + w.sustain + w.move, id).toBeCloseTo(1, 6);
  });
  it('necromancers want INT or VIT first and AGI last; Ossuary leans VIT', () => {
    for (const id of ['ossuary', 'gravecaller', 'mourner', 'rotweaver'] as const) {
      const o = STAT_PRIORITY[id].order;
      expect(['stat_int', 'stat_vit'], id).toContain(o[0]);
      expect(o[3], id).toBe('stat_agi');
    }
    expect(STAT_PRIORITY.ossuary.order[0]).toBe('stat_vit');
    expect(STAT_PRIORITY.gravecaller.order.slice(0, 2)).toEqual(['stat_int', 'stat_vit']);
    expect(STAT_PRIORITY.rotweaver.weights.stat_int).toBeGreaterThan(STAT_PRIORITY.gravecaller.weights.stat_int);
  });
  it('a bigger legion makes INT worth more (thrall damage scales with spell power)', () => {
    expect(STAT_PRIORITY.gravecaller.weights.stat_int).toBeGreaterThan(STAT_PRIORITY.mourner.weights.stat_int);
  });
});

describe('itemVerdict', () => {
  it('empty slot is always an upgrade, even for a stat-less piece', () => {
    const ring = item('ring_plain', 0, 'ring', null);
    const v = itemVerdict(ctx([ring]), ring)!;
    expect(v.kind).toBe('upgrade');
    expect(v.text).toMatch(/^Upgrade for your Gravecaller: fills an empty ring slot/);
  });
  it('INT gear beats VIT gear for a Gravecaller, with a reason, and the reverse reads as worse', () => {
    const vitHelm = worn('helm_vit', 'armor_head', 100, { stat_vit: 6 });
    const intHelm = item('helm_int', 0, 'armor_head', { stat_int: 6 });
    const up = itemVerdict(ctx([vitHelm, intHelm]), intHelm)!;
    expect(up.kind).toBe('upgrade');
    expect(up.text).toMatch(/^Upgrade for your Gravecaller: \+\d+% \(more (spell power|thrall damage)\)$/);
    const intWorn = worn('helm_int', 'armor_head', 100, { stat_int: 6 });
    const vitBag = item('helm_vit', 0, 'armor_head', { stat_vit: 6 });
    const down = itemVerdict(ctx([intWorn, vitBag]), vitBag)!;
    expect(down.kind).toBe('downgrade');
    expect(down.text).toMatch(/^Worse than your helm_int: \u2212\d+%/);
  });
  it('the same piece is worth more health-wise to an Ossuary than a Rotweaver', () => {
    const old = worn('helm_a', 'armor_head', 100, { stat_int: 3 });
    const vit = item('helm_vit', 0, 'armor_head', { stat_vit: 4 });
    expect(itemVerdict(ctx([old, vit], 'ossuary'), vit)!.pct).toBeGreaterThan(itemVerdict(ctx([old, vit], 'rotweaver'), vit)!.pct);
  });
  it('is null for worn items and materials', () => {
    const w = worn('helm_a', 'armor_head', 100, { stat_vit: 1 });
    expect(itemVerdict(ctx([w]), w)).toBeNull();
    const ore = item('ore', 0, 'material', null);
    expect(itemVerdict(ctx([ore]), ore)).toBeNull();
  });
  it('scores weapon-line effects: a scythe over a stat-equal plain weapon gains the (small) arc value', () => {
    const sword = worn('sword_copper', 'weapon', 105, { stat_int: 3 });
    const scythe = item('scythe_bone', 0, 'weapon', { stat_int: 3 });
    const v = itemVerdict(ctx([sword, scythe], 'gravecaller'), scythe)!;
    expect(v.pct).toBeGreaterThan(0);
    expect(loadoutExtraPct(resolveWeaponLoadout({ main_hand: { item_id: 'scythe_bone' } }, 'gravecaller'))).toBe(LOADOUT_VALUE.reap);
    // Other classes get no weapon-line score.
    expect(loadoutExtraPct(resolveWeaponLoadout({ main_hand: { item_id: 'scythe_bone' } }, 'hollow_knight'))).toBe(0);
  });
  it('a wand beats a stat-equal scythe: the bot clears with the left click, and the harness found a scythe costs it kills (2026-10-02 gear pass)', () => {
    const wand = worn('wand_bone', 'weapon', 105, { stat_int: 3 });
    const scythe = item('scythe_bone', 0, 'weapon', { stat_int: 3 });
    expect(itemVerdict(ctx([wand, scythe], 'gravecaller'), scythe)!.kind).toBe('downgrade');
  });
  it('a two-hander is judged against main hand plus off-hand together', () => {
    const sword = worn('sword_copper', 'weapon', 105, { stat_int: 4 });
    const tome = worn('grimoire_bone', 'offhand', 106, { stat_int: 6 });
    const staff = item('staff_bone', 0, 'weapon', { stat_int: 5 });
    const v = itemVerdict(ctx([sword, tome, staff]), staff)!;
    expect(v.replaced).toHaveLength(2);
    expect(v.kind).toBe('downgrade');
    expect(v.text).toContain('sword_copper and grimoire_bone');
  });
});

describe('lookingFor', () => {
  it('names the priority, weapons and the weakest slots (empty first, bag upgrade named)', () => {
    const helm = worn('helm_a', 'armor_head', 100, { stat_vit: 1 });
    const better = item('Iron Helm', 0, 'armor_head', { stat_vit: 6, stat_int: 3 });
    better.name = 'Iron Helm';
    const l = lookingFor(ctx([helm, better], 'gravecaller'));
    expect(l.orderText).toBe('INT > VIT > STR > AGI');
    expect(l.why).toContain('legion hit harder');
    expect(l.weapons).toMatch(/Scythe/);
    expect(l.weakest[0].empty).toBe(true);
    expect(weakestSlots(ctx([helm, better]), 9).some((w) => w.text.includes('Any ring is an upgrade'))).toBe(true);
    expect(weakestSlots(ctx([helm, better]), 9).find((w) => w.slot === 'head')!.text).toContain('Iron Helm in the bag is +');
  });
  it('does not call the off-hand empty behind a two-hander', () => {
    const staff = worn('staff_bone', 'weapon', 105, { stat_int: 3 });
    expect(weakestSlots(ctx([staff]), 9).some((w) => w.slot === 'off_hand')).toBe(false);
  });
  it('other classes get a priority but no necromancer weapons', () => {
    expect(lookingFor(ctx([], 'hollow_knight')).weapons).toBeNull();
  });
});
