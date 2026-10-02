import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { firstConnectDelayMs, isRetryableError, Reconnector, rejoinDelayMs } from './reconnect';
import { loadRejoin, REJOIN_WINDOW_MS, saveRejoin, clearRejoin } from './rejoinStore';
import { parseRelease, ReleaseWatch } from './releaseWatch';

describe('backoff schedule', () => {
  it('rejoin: 1, 2, 4, 8, then capped at 15 s', () => {
    expect([0, 1, 2, 3, 4, 5, 50].map(rejoinDelayMs)).toEqual([1000, 2000, 4000, 8000, 15000, 15000, 15000]);
  });
  it('first connect: 10, 20, then 30 s', () => {
    expect([0, 1, 2, 3, 9].map(firstConnectDelayMs)).toEqual([10000, 20000, 30000, 30000, 30000]);
  });
});

describe('which errors are retryable', () => {
  it('service down / unreachable is retryable in both modes', () => {
    for (const m of ['first', 'rejoin'] as const) {
      expect(isRetryableError(new Error('Co-op service unreachable — playing solo'), m)).toBe(true);
      expect(isRetryableError(new Error('timeout'), m)).toBe(true);
    }
  });
  it('config, auth and player-readable rejections are final', () => {
    for (const m of ['first', 'rejoin'] as const) {
      expect(isRetryableError(new Error('Realtime service not configured'), m)).toBe(false);
      expect(isRetryableError(new Error('Not authenticated'), m)).toBe(false);
      expect(isRetryableError(new Error('That world is full (10 players)'), m)).toBe(false);
    }
  });
  it('"already in this world" is only retried when rejoining (the old socket is still being reaped)', () => {
    expect(isRetryableError(new Error('You are already in this world'), 'rejoin')).toBe(true);
    expect(isRetryableError(new Error('You are already in this world'), 'first')).toBe(false);
  });
});

describe('Reconnector', () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());
  const flush = async () => { for (let i = 0; i < 5; i++) await Promise.resolve(); };

  it('retries with backoff until it succeeds, then stops', async () => {
    let calls = 0;
    const delays: number[] = [];
    const r = new Reconnector({ mode: 'rejoin', attempt: async () => { if (++calls < 4) throw new Error('Co-op service unreachable'); }, onRetry: (_n, ms) => delays.push(ms) });
    r.start();
    await vi.advanceTimersByTimeAsync(1000 + 2000 + 4000 + 8000 + 1);
    expect(calls).toBe(4);
    expect(delays).toEqual([1000, 2000, 4000, 8000]);
    expect(r.active).toBe(false);
    await vi.advanceTimersByTimeAsync(60000);
    expect(calls).toBe(4);
  });

  it('gives up on a player-readable rejection', async () => {
    const giveUp = vi.fn();
    const r = new Reconnector({ mode: 'rejoin', attempt: async () => { throw new Error('That world is full (10 players)'); }, onGiveUp: giveUp });
    r.start();
    await vi.advanceTimersByTimeAsync(1001);
    expect(giveUp).toHaveBeenCalledOnce();
    expect(r.active).toBe(false);
  });

  it('stop() cancels the pending try and ignores an in-flight result', async () => {
    const attempt = vi.fn(async () => { throw new Error('timeout'); });
    const r = new Reconnector({ mode: 'rejoin', attempt });
    r.start();
    r.stop();
    await vi.advanceTimersByTimeAsync(60000);
    expect(attempt).not.toHaveBeenCalled();

    let resolveIt!: () => void;
    const slow = new Reconnector({ mode: 'first', attempt: () => new Promise<void>((res) => { resolveIt = res; }) });
    slow.kick();
    slow.stop();
    resolveIt();
    await flush();
    expect(slow.active).toBe(false);
  });

  it('kick() tries immediately, never overlaps a running try, and keeps counting the backoff', async () => {
    let calls = 0;
    const delays: number[] = [];
    const r = new Reconnector({ mode: 'rejoin', attempt: async () => { calls++; throw new Error('timeout'); }, onRetry: (_n, ms) => delays.push(ms) });
    r.start();
    r.kick();
    r.kick();
    await flush();
    expect(calls).toBe(1);
    expect(delays).toEqual([1000, 2000]);
    r.stop();
  });
});

describe('rejoin store', () => {
  const mem = () => { const m = new Map<string, string>(); return { getItem: (k: string) => m.get(k) ?? null, setItem: (k: string, v: string) => void m.set(k, v), removeItem: (k: string) => void m.delete(k) }; };
  it('returns the code only within 10 minutes', () => {
    const s = mem();
    saveRejoin('abc123', 1000, s);
    expect(loadRejoin(1000 + REJOIN_WINDOW_MS, s)).toBe('abc123');
    expect(loadRejoin(1001 + REJOIN_WINDOW_MS, s)).toBeNull();
    clearRejoin(s);
    expect(loadRejoin(1000, s)).toBeNull();
  });
  it('ignores junk', () => {
    const s = mem();
    s.setItem('dm_coop_rejoin_v1', '{nope');
    expect(loadRejoin(0, s)).toBeNull();
  });
});

describe('ReleaseWatch', () => {
  const resp = (text: string, ok = true) => ({ ok, text: async () => text }) as Response;
  it('parses "<sha> <iso>"', () => {
    expect(parseRelease('7bbe0e8 2026-10-02T10:00:00Z\n')).toBe('7bbe0e8');
    expect(parseRelease('<html>')).toBeNull();
  });
  it('reports a change only when the sha differs', async () => {
    let body = 'aaaaaaa 2026-10-02T10:00:00Z';
    const urls: string[] = [];
    const w = new ReleaseWatch({ url: '/play/release.txt', fetchImpl: (async (u: string, init: RequestInit) => { urls.push(u); expect(init.cache).toBe('no-store'); return resp(body); }) as unknown as typeof fetch });
    await w.init();
    expect(await w.changed()).toBe(false);
    body = 'aaaaaaa 2026-10-02T11:00:00Z';
    expect(await w.changed()).toBe(false);
    body = 'bbbbbbb 2026-10-02T12:00:00Z';
    expect(await w.changed()).toBe(true);
    expect(urls[0]).toMatch(/^\/play\/release\.txt\?t=\d+$/);
  });
  it('missing or failing release.txt means do nothing', async () => {
    const w = new ReleaseWatch({ url: '/r.txt', fetchImpl: (async () => { throw new Error('offline'); }) as unknown as typeof fetch });
    await w.init();
    expect(await w.changed()).toBe(false);
    const w2 = new ReleaseWatch({ url: '/r.txt', fetchImpl: (async () => resp('', false)) as unknown as typeof fetch });
    expect(await w2.changed()).toBe(false);
  });
});
