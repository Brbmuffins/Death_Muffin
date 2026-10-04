import { afterEach, describe, expect, it, vi } from 'vitest';
import { handleMock } from '../mockBackend';
import { isTwoHanded } from '../../content/necroWeapons';

const KEYS = ['bone_needle', 'marrow_spear', 'exhume', 'miasma', 'black_litany'];
function account(slots: object[]) {
  const records = new Map<string, string>();
  vi.stubGlobal('localStorage', { getItem: (k: string) => records.get(k) ?? null, setItem: (k: string, v: string) => records.set(k, v) });
  records.set('cw_offline_db_v1', JSON.stringify({ nextCharacterId: 2, accounts: { t: { username: 't', character: { id: 1, level: 5 }, professions: [], slots } } }));
  return (path: string, body?: object) => handleMock(path, body ? { method: 'POST', body: JSON.stringify({ characterId: 1, ...body }) } : { method: 'GET' }, 'offline:t') as Promise<any>;
}
const preset = (over: object = {}) => ({ name: 'Plague', rites: { primary: 'bone_needle', keys: KEYS }, runes: {}, weapon: null, offhand: null, ...over });

describe('offline mock loadouts match the server', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('saves, lists, validates, overwrites and deletes', async () => {
    const call = account([]);
    expect((await call('/api/loadouts/save', { slot: 0, preset: preset() })).data[0].preset.name).toBe('Plague');
    expect(await call('/api/loadouts/save', { slot: 1, preset: preset({ name: '' }) })).toMatchObject({ success: false });
    await call('/api/loadouts/save', { slot: 0, preset: preset({ name: 'Renamed' }) });
    expect((await call('/api/loadouts/1')).data.map((r: any) => r.preset.name)).toEqual(['Renamed']);
    expect((await call('/api/loadouts/delete', { slot: 0 })).data).toEqual([]);
    await expect(call('/api/loadouts/save', { slot: 6, preset: preset() })).rejects.toThrow(/slot/);
  });

  it('applies runes and a weapon from the bag, returning the old pieces, and reports what is missing', async () => {
    const call = account([
      { slot_index: 0, item_id: 'rune_volley', quantity: 2, equipped: 0 },
      { slot_index: 105, item_id: 'wand_bone', quantity: 1, equipped: 1 },
    ]);
    await call('/api/loadouts/save', { slot: 0, preset: preset({ runes: { bone_needle: 'rune_volley', exhume: 'rune_bone_colossus' }, weapon: { itemId: 'staff_missing', instanceId: null } }) });
    const r = await call('/api/loadouts/apply', { slot: 0 });
    expect(r.success).toBe(true);
    expect(r.report.skipped.map((s: any) => [s.part, s.reason])).toEqual([['weapon', 'missing'], ['rune', 'missing']]);
    const rows = (await call('/api/inventory/1')).data as { slot_index: number; item_id: string; quantity: number }[];
    expect(rows.find((x) => x.slot_index === 130)?.item_id).toBe('rune_volley');
    expect(rows.find((x) => x.slot_index === 0)?.quantity).toBe(1);
    expect(rows.find((x) => x.slot_index === 105)?.item_id).toBe('wand_bone');
    expect(await call('/api/loadouts/apply', { slot: 3 })).toMatchObject({ success: false, error: 'That loadout is empty.' });
  });

  it('a two-handed weapon from the bag sends the off-hand back', async () => {
    expect(isTwoHanded('scythe_bone')).toBe(true);
    const call = account([
      { slot_index: 4, item_id: 'scythe_bone', quantity: 1, equipped: 0 },
      { slot_index: 105, item_id: 'wand_bone', quantity: 1, equipped: 1 },
      { slot_index: 106, item_id: 'skull_focus_bone', quantity: 1, equipped: 1 },
    ]);
    await call('/api/loadouts/save', { slot: 0, preset: preset({ weapon: { itemId: 'scythe_bone', instanceId: null } }) });
    const r = await call('/api/loadouts/apply', { slot: 0 });
    expect(r.report.skipped).toEqual([]);
    const rows = r.data as { slot_index: number; item_id: string }[];
    expect(rows.find((x) => x.slot_index === 105)?.item_id).toBe('scythe_bone');
    expect(rows.find((x) => x.slot_index === 106)).toBeUndefined();
    expect(rows.filter((x) => x.slot_index < 48).map((x) => x.item_id).sort()).toEqual(['skull_focus_bone', 'wand_bone']);
  });
});
