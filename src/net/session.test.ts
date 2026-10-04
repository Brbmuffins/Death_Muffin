import { afterEach, describe, expect, it, vi } from 'vitest';

afterEach(() => {
  vi.unstubAllGlobals();
  vi.resetModules();
});

const progress = { characterId: 1, level: 258, xp: 0, gold: 0, stat_str: 5, stat_agi: 5, stat_int: 5, stat_vit: 10 };

describe('replaced session', () => {
  it('a 409 session_replaced reply fires the overlay once and then blocks further writes without calling the server', async () => {
    const fetch = vi.fn(async () => ({ ok: false, status: 409, json: async () => ({ success: false, code: 'session_replaced', error: 'This account was opened somewhere else.' }) }));
    vi.stubGlobal('fetch', fetch);
    const { saveProgress, setToken } = await import('./api');
    const { onSessionReplaced, isSessionReplaced } = await import('./session');
    const seen = vi.fn();
    onSessionReplaced(seen);
    setToken('t');
    await expect(saveProgress(progress)).rejects.toMatchObject({ status: 409 });
    expect(seen).toHaveBeenCalledTimes(1);
    expect(isSessionReplaced()).toBe(true);
    await expect(saveProgress(progress)).rejects.toMatchObject({ status: 409 });
    expect(fetch).toHaveBeenCalledTimes(1);
    setToken(null);
  });

  it('another 409 (e.g. an implausible offline save) is not a replaced session', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => ({ ok: false, status: 409, json: async () => ({ error: 'implausible', implausible: true }) })));
    const { saveProgress, setToken } = await import('./api');
    const { isSessionReplaced } = await import('./session');
    setToken('t');
    await expect(saveProgress(progress)).rejects.toMatchObject({ status: 409 });
    expect(isSessionReplaced()).toBe(false);
    setToken(null);
  });

  it('claimSession returns the fresh token, or null when refused or unreachable', async () => {
    const { claimSession } = await import('./session');
    vi.stubGlobal('fetch', vi.fn(async () => ({ ok: true, json: async () => ({ token: 'fresh' }) })));
    expect(await claimSession('old')).toBe('fresh');
    vi.stubGlobal('fetch', vi.fn(async () => ({ ok: false, json: async () => ({ error: 'invalid or expired token' }) })));
    expect(await claimSession('old')).toBeNull();
    vi.stubGlobal('fetch', vi.fn(async () => { throw new Error('down'); }));
    expect(await claimSession('old')).toBeNull();
  });
});

describe('automatic reloads', () => {
  it('the flag is consumed exactly once, and absent for a fresh open', async () => {
    const store = new Map<string, string>();
    vi.stubGlobal('sessionStorage', { getItem: (k: string) => store.get(k) ?? null, setItem: (k: string, v: string) => void store.set(k, v), removeItem: (k: string) => void store.delete(k) });
    const { markAutoReload, consumeAutoReload } = await import('./session');
    expect(consumeAutoReload()).toBe(false);
    markAutoReload();
    expect(consumeAutoReload()).toBe(true);
    expect(consumeAutoReload()).toBe(false);
  });

  it('probeSessionNow raises the overlay for a replaced session and stays quiet for the active one', async () => {
    const { probeSessionNow, onSessionReplaced, isSessionReplaced } = await import('./session');
    const seen = vi.fn();
    onSessionReplaced(seen);
    vi.stubGlobal('fetch', vi.fn(async () => ({ ok: true, json: async () => ({ active: true }) })));
    await probeSessionNow('t');
    expect(isSessionReplaced()).toBe(false);
    vi.stubGlobal('fetch', vi.fn(async () => ({ ok: true, json: async () => ({ active: false }) })));
    await probeSessionNow('t');
    expect(seen).toHaveBeenCalledTimes(1);
  });
});
