/**
 * Offline edition: one identity. Sign in with the Death Muffin account, keep this device's copy of that character,
 * and sync it with the online save (GET /api/offline/snapshot, POST /api/offline/load, server-side version history).
 *
 * Nothing here deletes a save: a replaced local copy is first kept as an ordinary local player, and the server keeps
 * both sides as restorable versions on every load.
 */
import * as store from './accountStore';
import * as mock from '../net/mockBackend';

export const CONNECT_ONCE = 'Connect once to sign in with your account; after that you can play offline.';
export const WRONG_OFFLINE_PASSWORD = 'Wrong password. Offline, the password is checked against the one you used the last time you signed in on this device.';

export class Unreachable extends Error {}
export class HttpError extends Error {
  constructor(message: string, public status: number, public implausible = false) { super(message); }
}

export interface Deps {
  fetch?: typeof fetch;
  /** Plain yes/no question (the plausibility confirmation). Defaults to window.confirm. */
  confirm?: (message: string) => boolean;
  base?: string;
  timeoutMs?: number;
}

export interface Summary { level: number; experience: number; gold: number; items: number; professions: number; ascension: number; discipline?: string }
export interface OnlineSave { snapshot: any; fingerprint: string; summary: Summary }
export interface OnlineSession { account: string; token: string; deps: Deps }

export const describeSave = (s: Summary) => `Level ${s.level}, ${s.experience} XP, ${s.gold} gold, ${s.items} inventory slots, ${s.professions} professions, Ascension ${s.ascension}`;

const baseOf = (d: Deps) => d.base ?? `${location.origin}/death-muffin/api`;

async function http(d: Deps, path: string, init: RequestInit): Promise<{ status: number; ok: boolean; body: any }> {
  const ctl = typeof AbortController !== 'undefined' ? new AbortController() : null;
  const timer = ctl ? setTimeout(() => ctl.abort(), d.timeoutMs ?? 10000) : null;
  let res: Response;
  try {
    res = await (d.fetch ?? fetch)(`${baseOf(d)}${path}`, { ...init, signal: ctl?.signal });
  } catch {
    throw new Unreachable('Could not reach the Death Muffin server.');
  } finally { if (timer) clearTimeout(timer); }
  const body = await res.json().catch(() => null);
  // A gateway error or an HTML page is "server unreachable", not a verdict on the player's request.
  if (res.status >= 502 || (!res.ok && body === null && res.status >= 500)) throw new Unreachable('The Death Muffin server is not answering right now.');
  return { status: res.status, ok: res.ok, body };
}

/** Online login. Throws Unreachable (no network / server down) or Error with the server's own string. */
export async function onlineLogin(username: string, password: string, deps: Deps = {}): Promise<OnlineSession> {
  const r = await http(deps, '/login', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ username: username.trim(), password }) });
  if (!r.ok || !r.body?.token) throw new Error(r.body?.error || 'Online login failed.');
  return { account: username.trim(), token: r.body.token, deps };
}

export async function onlineJson(session: OnlineSession, path: string, init: { method?: string; body?: unknown } = {}): Promise<any> {
  const r = await http(session.deps, path, {
    method: init.method ?? 'GET',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${session.token}` },
    body: init.body === undefined ? undefined : JSON.stringify(init.body),
  });
  if (!r.ok) {
    if (r.status === 401) { if (current === session) current = null; }
    throw new HttpError(r.body?.error || `Online request failed (${r.status}).`, r.status, r.body?.implausible === true);
  }
  return r.body;
}

/** The online save, or null when the account has no character yet. */
export async function fetchOnlineSave(session: OnlineSession): Promise<OnlineSave | null> {
  try {
    const r = await onlineJson(session, '/api/offline/snapshot');
    return { snapshot: r.snapshot, fingerprint: r.fingerprint, summary: r.summary };
  } catch (e) {
    if (e instanceof HttpError && e.status === 404) return null;
    throw e;
  }
}

/** The signed-in session of this page (memory only: a reload asks for the password again). */
let current: OnlineSession | null = null;
export const currentSession = () => current;
export const setCurrentSession = (s: OnlineSession | null) => { current = s; };

export function localSummary(key: string): Summary | null {
  try {
    const s = mock.exportLocalSave(`offline:${key}`);
    return {
      level: s.character!.level, experience: s.character!.experience, gold: s.character!.gold,
      items: s.slots.length, professions: s.professions.length, ascension: (s as any).necro?.ascension ?? 0,
    };
  } catch { return null; }
}

export interface Done { key: string; notice: string; /** the local copy was replaced: a running game must reload */ replaced: boolean }
export interface Choice {
  account: string;
  localKey: string;
  online: Summary;
  local: Summary | null;
  /** Pushing needs the same discipline online and here. */
  canPush: boolean;
  pushBlockedReason?: string;
  useOnline(): Promise<Done>;
  useLocal(): Promise<Done>;
}
export type Outcome = { kind: 'ready'; done: Done } | { kind: 'choose'; choice: Choice };

export type Plan = 'adopt' | 'push' | 'noop' | 'choose';
/** What to do for a copy that is already linked to this account. Pure, so it is easy to test. */
export function planSync(i: { hasCharacter: boolean; onlineChanged: boolean; localChanged: boolean }): Plan {
  if (!i.hasCharacter) return 'adopt';
  if (i.onlineChanged && i.localChanged) return 'choose';
  if (i.onlineChanged) return 'adopt';
  if (i.localChanged) return 'push';
  return 'noop';
}

async function push(session: OnlineSession, key: string, save: OnlineSave): Promise<void> {
  const confirm = session.deps.confirm ?? ((m: string) => window.confirm(m));
  const digest = mock.localDigest(key) ?? undefined;
  const snapshot = mock.exportLocalSave(`offline:${key}`);
  const load = (confirmImplausible: boolean) => onlineJson(session, '/api/offline/load', { method: 'POST', body: { snapshot, expectedFingerprint: save.fingerprint, confirmImplausible } });
  let result;
  try { result = await load(false); }
  catch (e) {
    // Server authority: a save far ahead of the online one for the time it claims needs an explicit yes (the online save is kept either way).
    if (!(e instanceof HttpError) || !e.implausible || !confirm(e.message)) throw e;
    result = await load(true);
  }
  mock.markSynced(key, session.account, result.fingerprint, digest);
}

/**
 * Bring the device copy and the online save together after a successful online sign-in (or "Sync now").
 * `localKey` is the local player to sync; without it the device's copy of this account is used.
 */
export async function reconcile(session: OnlineSession, save: OnlineSave | null, localKey: string | null): Promise<Outcome> {
  const account = session.account;
  const linkedCopy = mock.findLinkedPlayer(account);
  const local = localKey ? mock.localPlayer(localKey) : linkedCopy ? mock.localPlayer(linkedCopy.key) : null;
  const done = (key: string, notice: string, replaced = false): Outcome => ({ kind: 'ready', done: { key, notice, replaced } });

  if (!save) {
    if (local && local.info.linkedAccount?.toLowerCase() === account.toLowerCase()) {
      return done(local.info.key, 'Your online account has no character yet, so there is nothing to sync. Create it in the online game when you want your progress to follow you.');
    }
    if (localKey) throw new Error('Your online account has no character yet. Create one in the online game first, then link this player.');
    return done(mock.createLinkedPlayer(account), 'Your online account has no character yet. You can start one here; create your character online to sync it later.');
  }
  if (!local) {
    const { key } = mock.adoptOnlineSave(account, save.snapshot, save.fingerprint);
    return done(key, 'Your online character is now on this device.', true);
  }

  const key = local.info.key;
  const linkedHere = local.info.linkedAccount?.toLowerCase() === account.toLowerCase();
  const onlineClass = save.snapshot.character.class_index;
  const localClass = local.account.character?.class_index;
  const canPush = local.info.hasCharacter && localClass === onlineClass;

  const makeChoice = (): Outcome => ({
    kind: 'choose',
    choice: {
      account, localKey: key, online: save.summary, local: localSummary(key), canPush,
      pushBlockedReason: canPush ? undefined : 'The saves use different disciplines, so this device\'s save cannot replace the online one.',
      async useOnline() {
        const target = linkedHere ? key : linkedCopy?.key;
        const r = mock.adoptOnlineSave(account, save.snapshot, save.fingerprint, { key: target, backup: true });
        return { key: r.key, replaced: true, notice: r.backupKey ? `Online save loaded on this device. Your earlier device save is kept as the local player "${r.backupKey}".` : 'Online save loaded on this device.' };
      },
      async useLocal() {
        if (!canPush) throw new Error('The saves use different disciplines, so this device\'s save cannot replace the online one.');
        await push(session, key, save);
        return { key, replaced: false, notice: 'This device\'s save is now your online character. The previous online save is kept as a version you can restore.' };
      },
    },
  });

  if (!linkedHere) return makeChoice();   // an unlinked local player: always compare first

  const plan = planSync({ hasCharacter: local.info.hasCharacter, onlineChanged: local.account.linked!.fingerprint !== save.fingerprint, localChanged: local.info.changedSinceSync });
  switch (plan) {
    case 'noop': return done(key, 'Your save is up to date with your online character.');
    case 'adopt': {
      const r = mock.adoptOnlineSave(account, save.snapshot, save.fingerprint, { key });
      return done(r.key, 'Loaded your latest online progress on this device.', true);
    }
    case 'push':
      if (!canPush) return makeChoice();
      try { await push(session, key, save); return done(key, 'Your offline progress is now saved online.'); }
      catch (e) {
        return done(key, `Playing your device save; it could not be sent online yet (${e instanceof Error ? e.message : 'unknown error'}). Use Sync now to try again.`);
      }
    case 'choose': return makeChoice();
  }
}

/** Offline sign-in against the verifier stored at the last online sign-in. */
export async function offlineSignIn(username: string, password: string): Promise<{ key: string; account: string }> {
  const known = store.knownAccount(username);
  if (!known) throw new Error(CONNECT_ONCE);
  const rec = await store.verifyOffline(username, password);
  if (!rec) throw new Error(WRONG_OFFLINE_PASSWORD);
  if (!mock.localPlayer(rec.key)) throw new Error('This device no longer has that account\'s save. Connect to sign in again and load it from your online character.');
  return { key: rec.key, account: rec.account };
}

export type SignIn =
  | { kind: 'ready'; key: string; account: string; offline: boolean; notice: string; replaced: boolean }
  | { kind: 'choose'; choice: Choice; password: string };

/**
 * The login form. Online when the server answers (server error strings are shown as sent, a wrong password is final);
 * offline only when the server cannot be reached at all. `linkKey` links that existing local player to the account.
 */
export async function signIn(username: string, password: string, deps: Deps = {}, linkKey: string | null = null): Promise<SignIn> {
  let session: OnlineSession;
  try {
    session = await onlineLogin(username, password, deps);
  } catch (e) {
    if (!(e instanceof Unreachable)) throw e;
    if (linkKey) throw new Error('Linking needs a connection to the Death Muffin server. Try again when you are online.');
    const r = await offlineSignIn(username, password);
    return { kind: 'ready', key: r.key, account: r.account, offline: true, replaced: false, notice: 'Signed in without a network. Your progress syncs the next time you sign in online.' };
  }
  setCurrentSession(session);

  let save: OnlineSave | null;
  try { save = await fetchOnlineSave(session); }
  catch (e) {
    // The password was right but the save could not be read: play this device's copy if there is one.
    const copy = mock.findLinkedPlayer(username);
    if (!copy || linkKey) throw e;
    await store.rememberAccount(copy.linkedAccount!, password, copy.key);
    return { kind: 'ready', key: copy.key, account: copy.linkedAccount!, offline: true, replaced: false, notice: `Signed in, but your online save could not be read (${e instanceof Error ? e.message : 'unknown error'}). Playing this device's copy.` };
  }
  if (save?.snapshot?.username) session.account = String(save.snapshot.username);

  const outcome = await reconcile(session, save, linkKey);
  const finish = async (key: string) => { await store.rememberAccount(session.account, password, key); };
  if (outcome.kind === 'ready') {
    await finish(outcome.done.key);
    return { kind: 'ready', key: outcome.done.key, account: session.account, offline: false, notice: outcome.done.notice, replaced: outcome.done.replaced };
  }
  const choice = outcome.choice;
  const wrap = (fn: () => Promise<Done>) => async () => { const d = await fn(); await finish(d.key); return d; };
  return { kind: 'choose', password, choice: { ...choice, useOnline: wrap(choice.useOnline), useLocal: wrap(choice.useLocal) } };
}

// A short status line the offline panel shows (set at sign-in, after Sync now).
let lastNotice = '';
const noticeListeners = new Set<(text: string) => void>();
export const getNotice = () => lastNotice;
export function setNotice(text: string) { lastNotice = text; for (const fn of noticeListeners) fn(text); }
export function onNotice(fn: (text: string) => void) { noticeListeners.add(fn); return () => noticeListeners.delete(fn); }
