import { afterEach, describe, expect, it, vi } from 'vitest';
import { handleMock } from '../mockBackend';

/** The DEV mock must refuse what the live server refuses, or a client bug (stacks past the server's cap) hides until it ships. */
function bag(slots: object[]) {
  const records = new Map<string, string>();
  vi.stubGlobal('localStorage', { getItem: (k: string) => records.get(k) ?? null, setItem: (k: string, v: string) => records.set(k, v) });
  records.set('cw_offline_db_v1', JSON.stringify({ nextCharacterId: 2, accounts: { t: { username: 't', character: { id: 1, level: 5 }, professions: [], slots } } }));
  return (path: string, body: object) => handleMock(path, { method: 'POST', body: JSON.stringify({ characterId: 1, ...body }) }, 'offline:t');
}

describe('offline mock bag rules match the server', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('refuses a save with a stack over the item cap, like POST /api/inventory/save', async () => {
    const post = bag([]);
    const save = (item_id: string, quantity: number) => post('/api/inventory/save', { bagSize: 48, slots: [{ slot_index: 0, item_id, quantity }] });
    expect(await save('flask_hp_minor', 100)).toMatchObject({ success: false, error: 'flask_hp_minor exceeds its maximum stack size of 99' });
    expect(await save('flask_hp_minor', 99)).toMatchObject({ success: true });
    expect(await save('sword_copper', 2)).toMatchObject({ success: false, error: 'sword_copper exceeds its maximum stack size of 1' });
  });

  it('a craft tops stacks up to the cap and spills the rest into a new slot', async () => {
    const post = bag([
      { slot_index: 0, item_id: 'flask_hp_minor', quantity: 98, equipped: 0 },
      { slot_index: 1, item_id: 'herb_mourning_moss', quantity: 3, equipped: 0 },
    ]);
    const res = await post('/api/craft', { recipeId: 'brew_moss_tonic' });
    expect(res.success).toBe(true);
    const rows = (await handleMock('/api/inventory/1', { method: 'GET' }, 'offline:t')).data as { item_id: string; quantity: number }[];
    const flasks = rows.filter((r) => r.item_id === 'flask_hp_minor').map((r) => r.quantity).sort((a, b) => b - a);
    expect(flasks).toEqual([99, 2]);
  });
});
