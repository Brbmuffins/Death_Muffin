import { API_BASE } from './config';

/**
 * One active session per account, newest login wins (server: session.cjs). A window that was replaced is told by a 409
 * `session_replaced` on any write, by the 60 s probe below, or by the realtime relay; it then stops writing until the player
 * presses "Play here". No DOM in here except the visibility check: the overlay lives in ui/SessionOverlay.ts.
 */
let replaced = false;
const listeners = new Set<() => void>();

export function isSessionReplaced() {
  return replaced;
}

export function onSessionReplaced(fn: () => void) {
  listeners.add(fn);
  return () => listeners.delete(fn);
}

export function notifySessionReplaced() {
  if (replaced) return;
  replaced = true;
  for (const fn of listeners) fn();
}

/** True for the error body the server sends when a write comes from a replaced session. */
export function isReplacedReply(status: number, body: unknown) {
  return status === 409 && !!body && typeof body === 'object' && (body as { code?: unknown }).code === 'session_replaced';
}

export const SESSION_REPLACED_MESSAGE = 'This account was opened somewhere else. This window stopped saving.';

/**
 * Take the account back for this window: trade the current token for one on a new session. Resolves to the new token, or null when the
 * server could not be reached or refused (an expired token means: log in again).
 */
export async function claimSession(token: string): Promise<string | null> {
  try {
    const res = await fetch(`${API_BASE}/api/session/claim`, { method: 'POST', headers: { Authorization: `Bearer ${token}` } });
    const body = await res.json().catch(() => null);
    return res.ok && body && typeof body.token === 'string' ? body.token : null;
  } catch {
    return null;
  }
}

/** Ask the server whether this window is still the active one; a stale window that has nothing to save would otherwise never find out. */
export function startSessionProbe(getToken: () => string | null, intervalMs = 60_000) {
  const probe = async () => {
    const token = getToken();
    if (!token || replaced || (typeof document !== 'undefined' && document.hidden)) return;
    try {
      const res = await fetch(`${API_BASE}/api/session`, { headers: { Authorization: `Bearer ${token}` } });
      const body = await res.json().catch(() => null);
      if (res.ok && body && body.active === false) notifySessionReplaced();
    } catch {
      /* offline blip: the next write or probe finds out */
    }
  };
  return setInterval(() => void probe(), intervalMs);
}

const AUTO_RELOAD_KEY = 'dm_auto_reload';

/** Call right before a programmatic reload (release auto-refresh, update notice): the next boot must not claim the session. */
export function markAutoReload() {
  try { sessionStorage.setItem(AUTO_RELOAD_KEY, '1'); } catch { /* storage unavailable: that reload will claim */ }
}

/** True once after a programmatic reload. A fresh open, manual refresh, login or "Play here" never set the flag, so they claim. */
export function consumeAutoReload(): boolean {
  try {
    const set = sessionStorage.getItem(AUTO_RELOAD_KEY) === '1';
    if (set) sessionStorage.removeItem(AUTO_RELOAD_KEY);
    return set;
  } catch {
    return false;
  }
}

/** One immediate "am I still the active window?" check; fires the replaced notice when not. */
export async function probeSessionNow(token: string): Promise<void> {
  try {
    const res = await fetch(`${API_BASE}/api/session`, { headers: { Authorization: `Bearer ${token}` } });
    const body = await res.json().catch(() => null);
    if (res.ok && body && body.active === false) notifySessionReplaced();
  } catch { /* the next write or probe finds out */ }
}
