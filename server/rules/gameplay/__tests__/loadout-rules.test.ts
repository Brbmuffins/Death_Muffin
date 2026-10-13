import { describe, expect, it } from 'vitest';
import { applyLoadout, captureGear, normalizePreset, BAG_SLOTS, type ItemInfo, type Row } from '../loadoutRules';

const INFO: Record<string, ItemInfo> = {
  staff: { maxStack: 1, equipSlot: 'main_hand', twoHanded: true },
  wand: { maxStack: 1, equipSlot: 'main_hand', twoHanded: false },
  sickle: { maxStack: 1, equipSlot: 'main_hand', twoHanded: false },
  skull: { maxStack: 1, equipSlot: 'off_hand', twoHanded: false },
  bell: { maxStack: 1, equipSlot: 'off_hand', twoHanded: false },
  rune_volley: { maxStack: 99, equipSlot: null, twoHanded: false },
  rune_splinter: { maxStack: 99, equipSlot: null, twoHanded: false },
  rune_impale: { maxStack: 99, equipSlot: null, twoHanded: false },
  junk: { maxStack: 1, equipSlot: null, twoHanded: false },
};
const info = (id: string): ItemInfo => INFO[id] ?? { maxStack: 1, equipSlot: null, twoHanded: false };
const row = (slot_index: number, item_id: string, extra: Partial<Row> = {}): Row => ({ slot_index, item_id, quantity: 1, equipped: slot_index >= 100 ? 1 : 0, instance_id: null, ...extra });
const fullBag = (rows: Row[] = []): Row[] => {
  const taken = new Set(rows.map((r) => r.slot_index));
  const filler: Row[] = [];
  for (let i = 0; i < BAG_SLOTS; i++) if (!taken.has(i)) filler.push(row(i, 'junk'));
  return [...filler, ...rows.filter((r) => r.slot_index < 100), ...rows.filter((r) => r.slot_index >= 100)];
};
const at = (rows: Row[], slot: number) => rows.find((r) => r.slot_index === slot);
const units = (rows: Row[], id: string) => rows.filter((r) => r.item_id === id).reduce((n, r) => n + r.quantity, 0);
/** The learned runes the calls below pass (a rune outside it is skipped as missing). */
const L = new Set(['rune_volley', 'rune_splinter', 'rune_impale']);
const keys = ['bone_needle', 'marrow_spear', 'exhume', 'miasma', 'black_litany'];

describe('normalizePreset', () => {
  const good = { name: '  Colossus  ', rites: { primary: 'bone_needle', keys }, runes: { exhume: 'rune_bone_colossus' }, weapon: { itemId: 'staff', instanceId: 12 }, offhand: null };
  it('accepts a good preset and tidies the name', () => {
    const r = normalizePreset(good);
    expect(r.ok && r.preset.name).toBe('Colossus');
    expect(r.ok && r.preset.weapon).toEqual({ itemId: 'staff', instanceId: 12 });
  });
  it('refuses bad shapes with a readable error', () => {
    expect(normalizePreset({ ...good, name: '   ' })).toMatchObject({ ok: false });
    expect(normalizePreset({ ...good, rites: { primary: 'x', keys: keys.slice(0, 4) } })).toMatchObject({ ok: false });
    expect(normalizePreset({ ...good, rites: { primary: 'x', keys: [...keys.slice(0, 4), keys[0]] } })).toMatchObject({ ok: false });
    expect(normalizePreset({ ...good, runes: { exhume: 'rune_volley' } })).toMatchObject({ ok: false });
    expect(normalizePreset({ ...good, runes: { nope: 'rune_volley' } })).toMatchObject({ ok: false });
    expect(normalizePreset({ ...good, weapon: { itemId: 'Bad Id!', instanceId: null } })).toMatchObject({ ok: false });
    expect(normalizePreset({ ...good, weapon: { itemId: 'staff', instanceId: -3 } })).toMatchObject({ ok: false });
    expect(normalizePreset(null)).toMatchObject({ ok: false });
  });
  it('clips a long name and strips markup characters', () => {
    const r = normalizePreset({ ...good, name: '<b>' + 'x'.repeat(60) });
    expect(r.ok && r.preset.name.length).toBeLessThanOrEqual(24);
    expect(r.ok && r.preset.name).not.toContain('<');
  });
});

describe('captureGear', () => {
  it('reads the worn weapon, off-hand and sockets, with rolls', () => {
    const rows = [row(105, 'staff', { instance_id: 4 }), row(106, 'skull'), row(130, 'rune_volley'), row(132, 'rune_bone_colossus'), row(3, 'wand')];
    expect(captureGear(rows)).toEqual({ weapon: { itemId: 'staff', instanceId: 4 }, offhand: { itemId: 'skull', instanceId: null }, runes: { bone_needle: 'rune_volley', exhume: 'rune_bone_colossus' } });
  });
});

describe('applyLoadout', () => {
  it('swaps weapon and off-hand from the bag; the old pieces go to the bag', () => {
    const rows = [row(0, 'sickle'), row(1, 'bell'), row(105, 'wand'), row(106, 'skull')];
    const { rows: out, report } = applyLoadout(rows, info, { weapon: { itemId: 'sickle', instanceId: null }, offhand: { itemId: 'bell', instanceId: null }, runes: {} }, L);
    expect(at(out, 105)!.item_id).toBe('sickle');
    expect(at(out, 106)!.item_id).toBe('bell');
    expect(at(out, 105)!.equipped_slot).toBe('main_hand');
    expect(out.filter((r) => r.slot_index < 48).map((r) => r.item_id).sort()).toEqual(['skull', 'wand']);
    expect(report.skipped).toEqual([]);
    expect(report.applied).toHaveLength(2);
  });
  it('does not mutate its input', () => {
    const rows = [row(0, 'sickle'), row(105, 'wand')];
    const copy = JSON.parse(JSON.stringify(rows));
    applyLoadout(rows, info, { weapon: { itemId: 'sickle', instanceId: null }, offhand: null, runes: {} }, L);
    expect(rows).toEqual(copy);
  });
  it('a two-handed weapon returns the off-hand to the bag', () => {
    const rows = [row(0, 'staff'), row(105, 'wand'), row(106, 'skull')];
    const { rows: out } = applyLoadout(rows, info, { weapon: { itemId: 'staff', instanceId: null }, offhand: null, runes: {} }, L);
    expect(at(out, 105)!.item_id).toBe('staff');
    expect(at(out, 106)).toBeUndefined();
    expect(units(out, 'skull')).toBe(1);
    expect(units(out, 'wand')).toBe(1);
  });
  it('matches the exact roll, never another copy of the same item', () => {
    const rows = [row(0, 'wand', { instance_id: 9 }), row(105, 'staff')];
    const { rows: out, report } = applyLoadout(rows, info, { weapon: { itemId: 'wand', instanceId: 5 }, offhand: null, runes: {} }, L);
    expect(report.skipped).toEqual([{ part: 'weapon', rite: null, itemId: 'wand', reason: 'missing' }]);
    expect(at(out, 105)!.item_id).toBe('staff');
  });
  it('applies the rest when a piece is missing (sold, salvaged, in the Vault, a rune not learned) and names what it skipped', () => {
    const rows = [row(0, 'rune_volley', { quantity: 2 }), row(105, 'wand')];
    const { rows: out, report } = applyLoadout(rows, info, { weapon: { itemId: 'sickle', instanceId: null }, offhand: { itemId: 'bell', instanceId: null }, runes: { bone_needle: 'rune_volley', exhume: 'rune_bone_colossus' } }, L);
    expect(report.applied).toEqual([{ part: 'rune', rite: 'bone_needle', itemId: 'rune_volley' }]);
    expect(report.skipped.map((s) => [s.part, s.itemId, s.reason])).toEqual([['weapon', 'sickle', 'missing'], ['offhand', 'bell', 'missing'], ['rune', 'rune_bone_colossus', 'missing']]);
    expect(at(out, 105)!.item_id).toBe('wand');
    expect(at(out, 130)!.item_id).toBe('rune_volley');
    expect(at(out, 0)!.quantity).toBe(2); // a socket never takes from the bag
  });
  it('a rune not learned leaves the current rune in its socket, even with a copy in the bag', () => {
    const rows = [row(130, 'rune_splinter'), row(0, 'rune_volley')];
    const { rows: out, report } = applyLoadout(rows, info, { weapon: null, offhand: null, runes: { bone_needle: 'rune_volley' } }, new Set(['rune_splinter']));
    expect(at(out, 130)!.item_id).toBe('rune_splinter');
    expect(report.skipped).toEqual([{ part: 'rune', rite: 'bone_needle', itemId: 'rune_volley', reason: 'missing' }]);
  });
  it('a full bag: rune swaps and emptied sockets need no room and leave the bag as it was', () => {
    const rows = fullBag([row(130, 'rune_splinter'), row(131, 'rune_impale')]);
    const { rows: out, report } = applyLoadout(rows, info, { weapon: null, offhand: null, runes: { bone_needle: 'rune_volley' } }, L);
    expect(report.skipped).toEqual([]);
    expect(report.applied).toEqual([{ part: 'rune', rite: 'bone_needle', itemId: 'rune_volley' }, { part: 'rune', rite: 'marrow_spear', itemId: null }]);
    expect(at(out, 130)!.item_id).toBe('rune_volley');
    expect(at(out, 131)).toBeUndefined();
    expect(units(out, 'rune_splinter')).toBe(0);
    expect(out.filter((r) => r.slot_index < 48).every((r) => r.item_id === 'junk')).toBe(true);
  });
  it('a full bag: a two-handed swap that displaces two pieces needs two places and is refused with only the vacated one', () => {
    const rows = fullBag([row(3, 'staff'), row(105, 'wand'), row(106, 'skull')]);
    const { rows: out, report } = applyLoadout(rows, info, { weapon: { itemId: 'staff', instanceId: null }, offhand: null, runes: {} }, L);
    expect(report.skipped).toEqual([{ part: 'weapon', rite: null, itemId: 'staff', reason: 'no_room' }]);
    expect(at(out, 105)!.item_id).toBe('wand');
    expect(at(out, 106)!.item_id).toBe('skull');
    expect(at(out, 3)!.item_id).toBe('staff');
  });
  it('a full bag: a plain one-for-one weapon swap works (the weapon vacates its own slot)', () => {
    const rows = fullBag([row(3, 'sickle'), row(105, 'wand')]);
    const { rows: out, report } = applyLoadout(rows, info, { weapon: { itemId: 'sickle', instanceId: null }, offhand: null, runes: {} }, L);
    expect(report.skipped).toEqual([]);
    expect(at(out, 105)!.item_id).toBe('sickle');
    expect(at(out, 3)!.item_id).toBe('wand');
  });
  it('is a no-op (unchanged) when everything already stands as saved', () => {
    const rows = [row(105, 'wand'), row(106, 'skull'), row(130, 'rune_volley')];
    const { report } = applyLoadout(rows, info, { weapon: { itemId: 'wand', instanceId: null }, offhand: { itemId: 'skull', instanceId: null }, runes: { bone_needle: 'rune_volley' } }, L);
    expect(report).toEqual({ applied: [], skipped: [], unchanged: true });
  });
  it('refuses a weapon preset naming something that is not a main-hand piece', () => {
    const rows = [row(0, 'junk')];
    const { report } = applyLoadout(rows, info, { weapon: { itemId: 'junk', instanceId: null }, offhand: null, runes: {} }, L);
    expect(report.skipped[0].reason).toBe('wrong_slot');
  });
  it('never creates or destroys bag or worn items across a mixed apply (socket rows are choices, not items)', () => {
    const rows = [row(0, 'sickle'), row(1, 'bell'), row(2, 'rune_volley'), row(3, 'rune_impale', { quantity: 5 }), row(105, 'wand'), row(106, 'skull'), row(130, 'rune_splinter'), row(131, 'rune_impale')];
    const total = (rs: Row[]) => rs.filter((r) => r.slot_index < 130).reduce((n, r) => n + r.quantity, 0);
    const { rows: out } = applyLoadout(rows, info, { weapon: { itemId: 'sickle', instanceId: null }, offhand: { itemId: 'bell', instanceId: null }, runes: { bone_needle: 'rune_volley', marrow_spear: 'rune_impale' } }, L);
    expect(total(out)).toBe(total(rows));
  });
});
