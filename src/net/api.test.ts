import { afterEach, describe, expect, it, vi } from 'vitest';
import { loadOrCreateCharacter, setToken } from './api';

const character = { id: 42, class_index: 5, class_name: 'Necromancer', level: 1,
  experience: 0, gold: 0, stat_str: 5, stat_agi: 5, stat_int: 5, stat_vit: 10 };

afterEach(() => {
  setToken(null);
  vi.unstubAllGlobals();
});

describe('first-time class selection', () => {
  it('creates a new family in the separate legacy slot, then sets its discipline', async () => {
    const calls: Array<{ path: string; body: unknown }> = [];
    vi.stubGlobal('fetch', vi.fn(async (path: string, options: RequestInit) => {
      calls.push({ path, body: JSON.parse(String(options.body)) });
      return { ok: true, json: async () => calls.length === 1 ? character : { ...character, class_index: 8, class_name: 'Hollow Knight' } };
    }));
    setToken('test-token');
    const selected = await loadOrCreateCharacter(8);
    expect(calls[0]).toEqual({ path: expect.stringMatching(/\/character$/), body: { class_index: 5 } });
    expect(calls[1]).toEqual({ path: expect.stringMatching(/\/character\/discipline$/), body: { characterId: 42, class_index: 8 } });
    expect(selected.class_name).toBe('Hollow Knight');
  });

  it('keeps legacy disciplines on their existing creation path', async () => {
    const fetch = vi.fn(async (_path: string, _options: RequestInit) => ({ ok: true, json: async () => ({ ...character, class_index: 2, class_name: 'Shadowblade' }) }));
    vi.stubGlobal('fetch', fetch);
    setToken('test-token');
    await loadOrCreateCharacter(2);
    expect(fetch).toHaveBeenCalledTimes(1);
    expect(JSON.parse(String(fetch.mock.calls[0][1].body))).toEqual({ class_index: 2 });
  });
});
