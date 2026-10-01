import { afterEach, describe, expect, it } from 'vitest';
import { DEV_ACCOUNTS, devAccess, devPreference, isDevAccount, riteLevel, setDevPreference, tokenUsername } from '../devAccess';
import { sanitizeLoadout } from '../loadout';
import { GRIMOIRE, unlockLevel } from '../../content/abilities';
import { Progression } from '../progression';

const b64url = (o: object) => Buffer.from(JSON.stringify(o)).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const jwt = (payload: object) => `${b64url({ alg: 'HS256' })}.${b64url(payload)}.sig`;

function memoryStorage() {
  const m = new Map<string, string>();
  return { getItem: (k: string) => m.get(k) ?? null, setItem: (k: string, v: string) => void m.set(k, v), removeItem: (k: string) => void m.delete(k) };
}

afterEach(() => {
  devAccess.active = false;
});

describe('dev access', () => {
  it('reads the username from a JWT and from the offline token', () => {
    expect(tokenUsername(jwt({ accountId: 1, username: 'BrbMuffins' }))).toBe('BrbMuffins');
    expect(tokenUsername('offline:brbmuffins')).toBe('brbmuffins');
    expect(tokenUsername('not.a.jwt')).toBeNull();
    expect(tokenUsername('abc')).toBeNull();
    expect(tokenUsername(null)).toBeNull();
    expect(tokenUsername(`${b64url({})}.%%%.x`)).toBeNull();
  });

  it('recognises dev accounts by name (any case) or the server GM flag, and nobody else', () => {
    expect(DEV_ACCOUNTS).toContain('brbmuffins');
    expect(isDevAccount(null, jwt({ username: 'BRBMUFFINS' }))).toBe(true);
    expect(isDevAccount(null, 'offline:brbmuffins')).toBe(true);
    expect(isDevAccount({ gm_enabled: true }, jwt({ username: 'someone' }))).toBe(true);
    expect(isDevAccount({ gm_enabled: false }, jwt({ username: 'someone' }))).toBe(false);
    expect(isDevAccount(null, 'offline:brbmuffins2')).toBe(false);
    expect(isDevAccount(null, null)).toBe(false);
  });

  it('the preference defaults on and is stored per character', () => {
    const s = memoryStorage();
    expect(devPreference(s, 7)).toBe(true);
    setDevPreference(s, 7, false);
    expect(devPreference(s, 7)).toBe(false);
    expect(devPreference(s, 8)).toBe(true);
  });

  it('a dev loadout may hold every rite; a normal level-1 loadout stays gated', () => {
    const late = GRIMOIRE.filter((id) => unlockLevel(id) > 1).slice(0, 4);
    devAccess.active = true;
    expect(sanitizeLoadout(late, riteLevel(1))).toEqual([...late, 'corpse_explosion']);
    devAccess.active = false;
    const normal = sanitizeLoadout(late, riteLevel(1));
    for (const id of normal) expect(unlockLevel(id)).toBeLessThanOrEqual(1);
  });

  it('opens every area as an overlay without touching the save or banking kills there', () => {
    (globalThis as unknown as { window: unknown }).window ??= { setTimeout: () => 0, clearTimeout: () => undefined };
    const p = new Progression({ id: 99, class_index: 1, class_name: '', level: 1, experience: 0, gold: 0, stat_str: 5, stat_agi: 5, stat_int: 5, stat_vit: 5 });
    expect(p.isUnlocked('sanctum')).toBe(false);
    devAccess.active = true;
    expect(p.isUnlocked('sanctum')).toBe(true);
    expect(p.local.unlocked).not.toContain('sanctum');
    p.recordKill('sanctum');
    expect(p.kills('sanctum')).toBe(0);
    p.recordKill('graves');
    expect(p.kills('graves')).toBe(1);
    devAccess.active = false;
    expect(p.isUnlocked('sanctum')).toBe(false);
    p.dispose();
  });
});
