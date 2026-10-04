import { describe, expect, it } from 'vitest';
import { LOADOUT_ACTIONS, RESERVED_KEYS, actionForKey, checkBind, loadBinds, nextSlot, saveBinds, KEYBIND_STORAGE_KEY } from '../keybinds';

const store = () => { const m = new Map<string, string>(); return { getItem: (k: string) => m.get(k) ?? null, setItem: (k: string, v: string) => void m.set(k, v), m }; };

describe('loadout keybinds', () => {
  it('seven actions, unbound by default', () => {
    expect(LOADOUT_ACTIONS).toEqual(['loadout_next', 'loadout_1', 'loadout_2', 'loadout_3', 'loadout_4', 'loadout_5', 'loadout_6']);
    expect(loadBinds(store())).toEqual({});
    expect(actionForKey({}, 'f')).toBeNull();
  });
  it('refuses every key the game uses, with a readable reason', () => {
    for (const k of Object.keys(RESERVED_KEYS)) {
      const r = checkBind({}, 'loadout_next', k);
      expect(r.ok, k).toBe(false);
    }
    const r = checkBind({}, 'loadout_next', 'L');
    expect(!r.ok && r.error).toMatch(/L is already used for the Grimoire/);
  });
  it('refuses modifiers, browser keys and a key another loadout action holds', () => {
    expect(checkBind({}, 'loadout_1', 'Shift').ok).toBe(false);
    expect(checkBind({}, 'loadout_1', 'F5').ok).toBe(false);
    expect(checkBind({ loadout_2: 'f' }, 'loadout_1', 'F')).toMatchObject({ ok: false });
    expect(checkBind({ loadout_1: 'f' }, 'loadout_1', 'F')).toEqual({ ok: true, key: 'f' });
  });
  it('accepts free letters, digits above the rite keys, punctuation and function keys', () => {
    for (const k of ['f', 'x2', '7', '[', 'F7', ';']) void k;
    expect(checkBind({}, 'loadout_1', 'f')).toEqual({ ok: true, key: 'f' });
    expect(checkBind({}, 'loadout_1', '7')).toEqual({ ok: true, key: '7' });
    expect(checkBind({}, 'loadout_1', 'F7')).toEqual({ ok: true, key: 'f7' });
    expect(checkBind({}, 'loadout_1', '[')).toEqual({ ok: true, key: '[' });
  });
  it('round-trips through storage and drops anything that became reserved or doubled', () => {
    const s = store();
    saveBinds(s, { loadout_next: 'f', loadout_1: 'f7' });
    expect(loadBinds(s)).toEqual({ loadout_next: 'f', loadout_1: 'f7' });
    s.m.set(KEYBIND_STORAGE_KEY, JSON.stringify({ loadout_next: 'l', loadout_1: 'f', loadout_2: 'f' }));
    expect(loadBinds(s)).toEqual({ loadout_1: 'f' });
    s.m.set(KEYBIND_STORAGE_KEY, '{nope');
    expect(loadBinds(s)).toEqual({});
  });
  it('finds the action for a key', () => expect(actionForKey({ loadout_3: 'f7' }, 'F7')).toBe('loadout_3'));
  it('nextSlot cycles through the saved slots and wraps', () => {
    expect(nextSlot([], null, null)).toBeNull();
    expect(nextSlot([0, 2, 5], null, null)).toBe(0);
    expect(nextSlot([0, 2, 5], 0, null)).toBe(2);
    expect(nextSlot([0, 2, 5], 5, null)).toBe(0);
    expect(nextSlot([0, 2, 5], null, 2)).toBe(5);
    expect(nextSlot([3], 3, null)).toBe(3);
  });
});
