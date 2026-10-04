/**
 * Which Death Muffin accounts this device has signed in to, so the offline edition can sign in again without a network.
 *
 * Only a salted PBKDF2 verifier is kept (never the password, never the server token). It is checked against what the player
 * types; a match opens that account's save on this device and nothing else: the server is never involved.
 */

const REGISTRY_KEY = 'dm_offline_accounts_v1';
export const PBKDF2_ITERATIONS = 200_000;

export interface KnownAccount {
  /** The account name as the server spells it. */
  account: string;
  /** Key of this account's save in the local store. */
  key: string;
  salt: string;
  iterations: number;
  hash: string;
  lastUsed: number;
}

interface Registry { last: string | null; accounts: Record<string, KnownAccount> }

const lc = (name: string) => name.trim().toLowerCase();

function readRegistry(): Registry {
  try {
    const raw = JSON.parse(localStorage.getItem(REGISTRY_KEY) ?? 'null');
    if (raw && typeof raw === 'object' && raw.accounts && typeof raw.accounts === 'object') return raw as Registry;
  } catch { /* empty registry */ }
  return { last: null, accounts: {} };
}

function writeRegistry(reg: Registry) {
  try { localStorage.setItem(REGISTRY_KEY, JSON.stringify(reg)); } catch { /* storage unavailable: offline sign-in just will not be offered */ }
}

const toHex = (bytes: Uint8Array) => Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
const fromHex = (hex: string) => Uint8Array.from(hex.match(/.{2}/g) ?? [], (h) => parseInt(h, 16));

async function derive(password: string, salt: Uint8Array, iterations: number): Promise<string> {
  const material = await crypto.subtle.importKey('raw', new TextEncoder().encode(password), 'PBKDF2', false, ['deriveBits']);
  const bits = await crypto.subtle.deriveBits({ name: 'PBKDF2', hash: 'SHA-256', salt: salt as BufferSource, iterations }, material, 256);
  return toHex(new Uint8Array(bits));
}

function sameHex(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

/** Remember (or refresh, after a password change) the verifier for an account that just signed in online. */
export async function rememberAccount(account: string, password: string, key: string): Promise<void> {
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const hash = await derive(password, salt, PBKDF2_ITERATIONS);
  const reg = readRegistry();
  reg.accounts[lc(account)] = { account, key, salt: toHex(salt), iterations: PBKDF2_ITERATIONS, hash, lastUsed: Date.now() };
  reg.last = lc(account);
  writeRegistry(reg);
}

/** Point an already-known account at a different local save (after a link) without touching its verifier. */
export function setAccountKey(account: string, key: string) {
  const reg = readRegistry();
  const rec = reg.accounts[lc(account)];
  if (!rec) return;
  rec.key = key;
  writeRegistry(reg);
}

export function knownAccount(account: string): KnownAccount | null {
  return readRegistry().accounts[lc(account)] ?? null;
}

/** True when the password matches what this device stored at the last online sign-in. */
export async function verifyOffline(account: string, password: string): Promise<KnownAccount | null> {
  const rec = knownAccount(account);
  if (!rec) return null;
  const hash = await derive(password, fromHex(rec.salt), rec.iterations);
  if (!sameHex(hash, rec.hash)) return null;
  touch(rec.account);
  return rec;
}

function touch(account: string) {
  const reg = readRegistry();
  const rec = reg.accounts[lc(account)];
  if (!rec) return;
  rec.lastUsed = Date.now();
  reg.last = lc(account);
  writeRegistry(reg);
}

/** The account most recently used on this device (for "Continue as ..."). */
export function lastAccount(): KnownAccount | null {
  const reg = readRegistry();
  return (reg.last && reg.accounts[reg.last]) || null;
}

export function noteSignedIn(account: string) { touch(account); }
