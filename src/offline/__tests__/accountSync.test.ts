import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { CONNECT_ONCE, WRONG_OFFLINE_PASSWORD, planSync, signIn, setCurrentSession, type Deps } from '../accountSync';
import { handleMock, listLocalPlayers, localPlayer, exportLocalSave } from '../../net/mockBackend';

const records = new Map<string, string>();

function snapshot(level: number, extra: Record<string, unknown> = {}) {
  return {
    username: 'Tyler',
    character: { id: 5, class_index: 2, class_name: 'Gravecaller', level, experience: 10, gold: 50, stat_str: 5, stat_agi: 5, stat_int: 5, stat_vit: 5, pos_x: 0, pos_y: 0, pos_z: 0, pos_map: 'x', orientation: 0 },
    slots: [], professions: [{ profession_id: 'mining', skill_level: 1, skill_xp: 0 }], ...extra,
  };
}

/** A stand-in for the live server: login, snapshot, load. Records every request. */
function fakeServer(opts: { password?: string; level?: number; hasCharacter?: boolean } = {}) {
  const state = { level: opts.level ?? 12, rev: 1, calls: [] as { path: string; body?: any }[], down: false, implausible: false, loaded: null as any };
  const fingerprint = () => `${state.rev}`.padStart(64, 'a');
  const fetchFn = (async (url: string, init: RequestInit = {}) => {
    if (state.down) throw new TypeError('Failed to fetch');
    const path = url.replace('https://t.test/death-muffin/api', '');
    const body = init.body ? JSON.parse(String(init.body)) : undefined;
    state.calls.push({ path, body });
    const reply = (status: number, data: unknown) => ({ ok: status < 400, status, json: async () => data }) as Response;
    if (path === '/login') return body.password === (opts.password ?? 'hunter2') ? reply(200, { token: 'tok-secret' }) : reply(401, { error: 'invalid credentials' });
    if (path === '/api/offline/snapshot') {
      if (opts.hasCharacter === false) return reply(404, { error: 'Create an online character before syncing.' });
      const snap = snapshot(state.level);
      return reply(200, { snapshot: snap, fingerprint: fingerprint(), summary: { level: state.level, experience: 10, gold: 50, items: 0, professions: 1, ascension: 0 } });
    }
    if (path === '/api/offline/load') {
      if (body.expectedFingerprint !== fingerprint()) return reply(409, { error: 'The online save changed. Compare the saves again before choosing.' });
      if (state.implausible && !body.confirmImplausible) return reply(409, { error: 'That save is far ahead. Confirm?', implausible: true });
      state.loaded = body.snapshot; state.level = body.snapshot.character.level; state.rev++;
      return reply(200, { fingerprint: fingerprint(), summary: { level: state.level } });
    }
    return reply(404, { error: 'nope' });
  }) as unknown as typeof fetch;
  const deps: Deps = { fetch: fetchFn, base: 'https://t.test/death-muffin/api', confirm: () => true };
  return { state, deps, fingerprint, bump: (level: number) => { state.level = level; state.rev++; } };
}

/** Pretend the player gained levels on this device. */
function playLocal(key: string, level: number) {
  const db = JSON.parse(records.get('dm_offline_db_v1')!);
  db.accounts[key].character.level = level;
  records.set('dm_offline_db_v1', JSON.stringify(db));
}

beforeEach(() => {
  records.clear();
  vi.stubGlobal('localStorage', { getItem: (k: string) => records.get(k) ?? null, setItem: (k: string, v: string) => void records.set(k, v), removeItem: (k: string) => void records.delete(k) });
  setCurrentSession(null);
});
afterEach(() => vi.unstubAllGlobals());

describe('sign in with the online account', () => {
  it('first sign-in on a device pulls the online save into the local store', async () => {
    const srv = fakeServer();
    const r = await signIn('tyler', 'hunter2', srv.deps);
    expect(r).toMatchObject({ kind: 'ready', account: 'Tyler', offline: false, replaced: true });
    if (r.kind !== 'ready') throw new Error();
    const p = localPlayer(r.key)!;
    expect(p.account.character!.level).toBe(12);
    expect(p.info.linkedAccount).toBe('Tyler');
    expect(p.info.changedSinceSync).toBe(false);
    expect(srv.state.calls.map((c) => c.path)).toEqual(['/login', '/api/offline/snapshot']);
    // The portable save is playable through the local backend.
    const me = await handleMock('/character', { method: 'GET' }, `offline:${r.key}`);
    expect(me).toMatchObject({ level: 12 });
  });

  it('a wrong password shows the server string and signs nobody in', async () => {
    const srv = fakeServer();
    await expect(signIn('Tyler', 'nope', srv.deps)).rejects.toThrow('invalid credentials');
    expect(listLocalPlayers()).toHaveLength(0);
  });

  it('stores a salted hash, never the password or the server token', async () => {
    const srv = fakeServer({ password: 'correct horse battery' });
    await signIn('Tyler', 'correct horse battery', srv.deps);
    const all = [...records.values()].join('\n');
    expect(all).not.toContain('correct horse battery');
    expect(all).not.toContain('tok-secret');
    const reg = JSON.parse(records.get('dm_offline_accounts_v1')!);
    expect(reg.accounts.tyler.hash).toMatch(/^[0-9a-f]{64}$/);
    expect(reg.accounts.tyler.salt).toMatch(/^[0-9a-f]{32}$/);
    expect(reg.accounts.tyler.iterations).toBeGreaterThanOrEqual(100000);
  });

  it('no data yet and no account online: a local copy to create the character in', async () => {
    const srv = fakeServer({ hasCharacter: false });
    const r = await signIn('Tyler', 'hunter2', srv.deps);
    expect(r.kind).toBe('ready');
    if (r.kind === 'ready') expect(localPlayer(r.key)!.account.character).toBeNull();
  });
});

describe('signing in without a network', () => {
  it('works with the same name and password once the device has signed in before', async () => {
    const srv = fakeServer();
    await signIn('Tyler', 'hunter2', srv.deps);
    srv.state.down = true;
    const r = await signIn('TYLER', 'hunter2', srv.deps);
    expect(r).toMatchObject({ kind: 'ready', offline: true, account: 'Tyler' });
    if (r.kind === 'ready') expect(localPlayer(r.key)!.account.character!.level).toBe(12);
  });

  it('a wrong password fails offline', async () => {
    const srv = fakeServer();
    await signIn('Tyler', 'hunter2', srv.deps);
    srv.state.down = true;
    await expect(signIn('Tyler', 'hunter3', srv.deps)).rejects.toThrow(WRONG_OFFLINE_PASSWORD);
  });

  it('an account this device never signed in explains how to start', async () => {
    const srv = fakeServer();
    srv.state.down = true;
    await expect(signIn('Tyler', 'hunter2', srv.deps)).rejects.toThrow(CONNECT_ONCE);
  });

  it('a server that errors (bad gateway) counts as unreachable, not as a wrong password', async () => {
    const srv = fakeServer();
    await signIn('Tyler', 'hunter2', srv.deps);
    const bad = { ...srv.deps, fetch: (async () => ({ ok: false, status: 502, json: async () => { throw new Error('html'); } })) as unknown as typeof fetch };
    expect(await signIn('Tyler', 'hunter2', bad)).toMatchObject({ kind: 'ready', offline: true });
  });
});

describe('sync back', () => {
  it('pushes local progress with /api/offline/load and the online fingerprint', async () => {
    const srv = fakeServer();
    const first = await signIn('Tyler', 'hunter2', srv.deps);
    if (first.kind !== 'ready') throw new Error();
    playLocal(first.key, 30);
    srv.state.calls.length = 0;
    const r = await signIn('Tyler', 'hunter2', srv.deps);
    expect(r).toMatchObject({ kind: 'ready', notice: expect.stringContaining('saved online') });
    const load = srv.state.calls.find((c) => c.path === '/api/offline/load')!;
    expect(load.body.expectedFingerprint).toBe('1'.padStart(64, 'a'));
    expect(load.body.snapshot.character.level).toBe(30);
    expect(srv.state.level).toBe(30);
    expect(localPlayer(first.key)!.info.changedSinceSync).toBe(false);
  });

  it('asks before sending an implausible save, and keeps the device save if declined', async () => {
    const srv = fakeServer();
    srv.state.implausible = true;
    const first = await signIn('Tyler', 'hunter2', srv.deps);
    if (first.kind !== 'ready') throw new Error();
    playLocal(first.key, 400);
    const confirm = vi.fn(() => false);
    const r = await signIn('Tyler', 'hunter2', { ...srv.deps, confirm });
    expect(confirm).toHaveBeenCalledOnce();
    expect(r).toMatchObject({ kind: 'ready', notice: expect.stringContaining('could not be sent online yet') });
    expect(localPlayer(first.key)!.account.character!.level).toBe(400);
    expect(srv.state.level).toBe(12);
    const yes = vi.fn(() => true);
    await signIn('Tyler', 'hunter2', { ...srv.deps, confirm: yes });
    expect(srv.state.calls.filter((c) => c.path === '/api/offline/load').slice(-1)[0].body.confirmImplausible).toBe(true);
    expect(srv.state.level).toBe(400);
  });

  it('online-only progress arrives on the device without a prompt', async () => {
    const srv = fakeServer();
    const first = await signIn('Tyler', 'hunter2', srv.deps);
    if (first.kind !== 'ready') throw new Error();
    srv.bump(50);
    const r = await signIn('Tyler', 'hunter2', srv.deps);
    expect(r).toMatchObject({ kind: 'ready', replaced: true });
    expect(localPlayer(first.key)!.account.character!.level).toBe(50);
    expect(listLocalPlayers()).toHaveLength(1);
  });

  it('both sides changed: shows the chooser, and "online" keeps the device save as a local player', async () => {
    const srv = fakeServer();
    const first = await signIn('Tyler', 'hunter2', srv.deps);
    if (first.kind !== 'ready') throw new Error();
    playLocal(first.key, 30);
    srv.bump(50);
    const r = await signIn('Tyler', 'hunter2', srv.deps);
    expect(r.kind).toBe('choose');
    if (r.kind !== 'choose') throw new Error();
    expect(r.choice.online.level).toBe(50);
    expect(r.choice.local!.level).toBe(30);
    expect(srv.state.calls.some((c) => c.path === '/api/offline/load')).toBe(false);
    const done = await r.choice.useOnline();
    expect(done.notice).toContain('kept as the local player');
    expect(localPlayer(first.key)!.account.character!.level).toBe(50);
    const backups = listLocalPlayers().filter((p) => !p.linkedAccount);
    expect(backups).toHaveLength(1);
    expect(backups[0].level).toBe(30);
  });

  it('both sides changed: "this device" pushes it online', async () => {
    const srv = fakeServer();
    const first = await signIn('Tyler', 'hunter2', srv.deps);
    if (first.kind !== 'ready') throw new Error();
    playLocal(first.key, 30);
    srv.bump(50);
    const r = await signIn('Tyler', 'hunter2', srv.deps);
    if (r.kind !== 'choose') throw new Error();
    await r.choice.useLocal();
    expect(srv.state.level).toBe(30);
    expect(localPlayer(first.key)!.info.changedSinceSync).toBe(false);
  });

  it('a device save with a different discipline cannot replace the online one', async () => {
    const srv = fakeServer();
    const first = await signIn('Tyler', 'hunter2', srv.deps);
    if (first.kind !== 'ready') throw new Error();
    const db = JSON.parse(records.get('dm_offline_db_v1')!);
    db.accounts[first.key].character.class_index = 4;
    records.set('dm_offline_db_v1', JSON.stringify(db));
    const r = await signIn('Tyler', 'hunter2', srv.deps);
    expect(r.kind).toBe('choose');
    if (r.kind === 'choose') { expect(r.choice.canPush).toBe(false); await expect(r.choice.useLocal()).rejects.toThrow(/different disciplines/); }
  });
});

describe('local players from before', () => {
  async function legacy() {
    await handleMock('/register', { method: 'POST', body: JSON.stringify({ username: 'Old', email: '', password: 'local-only' }) }, null);
    const db = JSON.parse(records.get('dm_offline_db_v1')!);
    db.accounts.Old.character = snapshot(7).character;
    records.set('dm_offline_db_v1', JSON.stringify(db));
  }

  it('still open by name, and are listed as unlinked', async () => {
    await legacy();
    expect(await handleMock('/login', { method: 'POST', body: JSON.stringify({ username: 'Old', password: 'local-only' }) }, null)).toEqual({ token: 'offline:Old' });
    expect(listLocalPlayers()).toEqual([expect.objectContaining({ key: 'Old', linkedAccount: null, level: 7 })]);
  });

  it('link to my account compares first; choosing the local player sends it online and links it', async () => {
    await legacy();
    const srv = fakeServer();
    const r = await signIn('Tyler', 'hunter2', srv.deps, 'Old');
    expect(r.kind).toBe('choose');
    if (r.kind !== 'choose') throw new Error();
    expect(srv.state.calls.some((c) => c.path === '/api/offline/load')).toBe(false);
    const done = await r.choice.useLocal();
    expect(done.key).toBe('Old');
    expect(srv.state.level).toBe(7);
    expect(localPlayer('Old')!.info.linkedAccount).toBe('Tyler');
    srv.state.down = true;
    expect(await signIn('Tyler', 'hunter2', srv.deps)).toMatchObject({ kind: 'ready', key: 'Old', offline: true });
  });

  it('choosing the online save leaves the local player untouched', async () => {
    await legacy();
    const srv = fakeServer();
    const r = await signIn('Tyler', 'hunter2', srv.deps, 'Old');
    if (r.kind !== 'choose') throw new Error();
    const done = await r.choice.useOnline();
    expect(done.key).toBe('Tyler');
    expect(localPlayer('Old')!.account.character!.level).toBe(7);
    expect(localPlayer('Old')!.info.linkedAccount).toBeNull();
    expect(localPlayer('Tyler')!.account.character!.level).toBe(12);
  });

  it('a local player named like the account does not get overwritten by the first sign-in', async () => {
    await handleMock('/register', { method: 'POST', body: JSON.stringify({ username: 'Tyler', email: '', password: 'local-only' }) }, null);
    const srv = fakeServer();
    const r = await signIn('Tyler', 'hunter2', srv.deps);
    if (r.kind !== 'ready') throw new Error();
    expect(r.key).not.toBe('Tyler');
    expect(listLocalPlayers().map((p) => p.key).sort()).toEqual(['Tyler', r.key].sort());
  });
});

describe('pieces', () => {
  it('planSync', () => {
    expect(planSync({ hasCharacter: true, onlineChanged: false, localChanged: false })).toBe('noop');
    expect(planSync({ hasCharacter: true, onlineChanged: true, localChanged: false })).toBe('adopt');
    expect(planSync({ hasCharacter: true, onlineChanged: false, localChanged: true })).toBe('push');
    expect(planSync({ hasCharacter: true, onlineChanged: true, localChanged: true })).toBe('choose');
    expect(planSync({ hasCharacter: false, onlineChanged: true, localChanged: true })).toBe('adopt');
  });

  it('exports the linked save without sync bookkeeping', async () => {
    const srv = fakeServer();
    const r = await signIn('Tyler', 'hunter2', srv.deps);
    if (r.kind !== 'ready') throw new Error();
    expect((exportLocalSave(`offline:${r.key}`) as any).linked).toBeUndefined();
  });
});
