import { OFFLINE, getAccountPrefs, setAccountPrefs } from './api';

/**
 * Account preferences: small UI settings that follow the account to any browser or device (server: backend/prefs.cjs, table account_prefs).
 * Every one keeps a browser copy too (localStorage), which is what the UI reads first and what remains when the server cannot be reached
 * or in the offline edition, where nothing here talks to a server at all. The keys must match DEFS in the server's prefs.cjs.
 */
export const PREF_ONLY_CRAFTABLE = 'only_craftable';

/** The account's saved preferences, or null when they cannot be had (offline edition, not signed in, server down): keep the browser copy. */
export async function fetchAccountPrefs(): Promise<Record<string, unknown> | null> {
  if (OFFLINE) return null;
  try {
    return await getAccountPrefs();
  } catch {
    return null;
  }
}

/** Save one preference to the account. Never throws: a failed save leaves the browser copy, and the next change tries again. */
export async function saveAccountPref(key: string, value: boolean | number | string): Promise<void> {
  if (OFFLINE) return;
  try {
    await setAccountPrefs({ [key]: value });
  } catch {
    /* offline, replaced window or server trouble: the browser copy stands */
  }
}

/**
 * Settle a boolean preference between the browser copy and the account. The account wins when it has a value; when it has none yet
 * and this browser has the setting on, that choice is sent up (so the box a player already ticked is not lost to the new store).
 * `value` is what to show; `pushUp` says whether to write it to the account.
 */
export function reconcileBoolPref(local: boolean, remote: Record<string, unknown> | null, key: string): { value: boolean; pushUp: boolean } {
  if (!remote) return { value: local, pushUp: false };
  const saved = remote[key];
  if (typeof saved === 'boolean') return { value: saved, pushUp: false };
  return { value: local, pushUp: local };
}
