/** The co-op world code, kept in sessionStorage so a reload (e.g. after a deploy) rejoins the same world. */
const KEY = 'dm_coop_rejoin_v1';
export const REJOIN_WINDOW_MS = 10 * 60 * 1000;

export interface Storage2 { getItem(k: string): string | null; setItem(k: string, v: string): void; removeItem(k: string): void }

const store = (): Storage2 | null => {
  try {
    return typeof sessionStorage === 'undefined' ? null : sessionStorage;
  } catch {
    return null;
  }
};

export function saveRejoin(code: string, now = Date.now(), s: Storage2 | null = store()) {
  try { s?.setItem(KEY, JSON.stringify({ code, t: now })); } catch { /* private mode: no rejoin, nothing breaks */ }
}

/** The code saved within the last 10 minutes, or null. */
export function loadRejoin(now = Date.now(), s: Storage2 | null = store()): string | null {
  try {
    const v = JSON.parse(s?.getItem(KEY) ?? 'null') as { code?: unknown; t?: unknown } | null;
    if (v && typeof v.code === 'string' && v.code && typeof v.t === 'number' && now - v.t >= 0 && now - v.t <= REJOIN_WINDOW_MS) return v.code;
  } catch { /* corrupt entry */ }
  return null;
}

export function clearRejoin(s: Storage2 | null = store()) {
  try { s?.removeItem(KEY); } catch { /* ignore */ }
}
