import type { Character } from '../net/types';
import type { StorageLike } from './codexJournal';

/**
 * Dev access: the owner's account sees and uses everything (every rite, every
 * area, every gathering tier) WITHOUT changing its saved level, progress or
 * leaderboard entry. It is a runtime overlay only: gates ask `riteLevel()` /
 * `devAccess.active`, and nothing here is ever written to a save.
 *
 * A dev account is either flagged by the server (`gm_enabled` on the Death
 * Muffin /character response) or named in DEV_ACCOUNTS (checked against the
 * JWT's `username`, decoded without verification — the server still decides
 * rewards; this only opens client-side gates).
 */
export const DEV_ACCOUNTS = ['brbmuffins'];

/** The username a session token names: a JWT's `username` claim, or the DEV mock's `offline:<name>`. */
export function tokenUsername(token: string | null | undefined): string | null {
  if (!token || typeof token !== 'string') return null;
  if (token.startsWith('offline:')) return token.slice('offline:'.length) || null;
  const parts = token.split('.');
  if (parts.length !== 3) return null;
  try {
    const b64 = parts[1].replace(/-/g, '+').replace(/_/g, '/');
    const json = typeof atob === 'function' ? atob(b64 + '='.repeat((4 - (b64.length % 4)) % 4)) : Buffer.from(b64, 'base64').toString('utf8');
    const payload = JSON.parse(json) as { username?: unknown };
    return typeof payload.username === 'string' ? payload.username : null;
  } catch {
    return null;
  }
}

export function isDevAccount(character: Pick<Character, 'gm_enabled'> | null | undefined, token: string | null | undefined): boolean {
  if (character?.gm_enabled === true) return true;
  const name = tokenUsername(token)?.toLowerCase();
  return !!name && DEV_ACCOUNTS.includes(name);
}

const prefKey = (characterId: number) => `dm_dev_access_v1_${characterId}`;

/** The Settings toggle ("preview as a normal player when off"); defaults on. */
export function devPreference(storage: StorageLike | null, characterId: number): boolean {
  try {
    return storage?.getItem(prefKey(characterId)) !== '0';
  } catch {
    return true;
  }
}

export function setDevPreference(storage: StorageLike | null, characterId: number, on: boolean) {
  try {
    storage?.setItem(prefKey(characterId), on ? '1' : '0');
  } catch {
    /* storage unavailable: the choice holds for this session */
  }
}

/** The live overlay. WorldScene sets it on mount (account + preference) and clears it on leave. */
export const devAccess = { active: false };

/** The level every rite / tier gate should compare against. */
export function riteLevel(level: number): number {
  return devAccess.active ? Infinity : level;
}
