import { API_BASE } from './config';
import type { Character, InventorySlot, Profession, Recipe } from './types';
import type { NecroState, SaveInput } from '../gameplay/necroRules';

/**
 * REST client for the existing Node/Express auth server.
 * Mirrors exactly what the Unity client calls today — same endpoints,
 * same request/response shapes, same JWT header. No server changes needed.
 */

export interface ApiResponse<T> {
  success: boolean;
  data?: T;
  error?: string;
}

export class ApiError extends Error {
  constructor(message: string, public status: number) {
    super(message);
    this.name = 'ApiError';
  }
}

/**
 * DEV-only offline mode: `?offline` in the dev-server URL routes every call to
 * an in-browser mock (src/net/mockBackend.ts). `import.meta.env.DEV` is
 * statically false in production builds, so the mock is dead-code-eliminated.
 */
export const OFFLINE =
  import.meta.env.DEV && typeof window !== 'undefined' && new URLSearchParams(window.location.search).has('offline');

let jwt: string | null = null;

export function setToken(token: string | null) {
  jwt = token;
  try {
    if (token) {
      sessionStorage.setItem('dm_jwt', token);
      if (localStorage.getItem('dm_jwt')) localStorage.setItem('dm_jwt', token);
    } else {
      sessionStorage.removeItem('dm_jwt');
      localStorage.removeItem('dm_jwt');
    }
  } catch {
    /* storage unavailable — token lives in memory for this page only */
  }
}

export function getToken(): string | null {
  if (jwt) return jwt;
  try {
    return sessionStorage.getItem('dm_jwt') || localStorage.getItem('dm_jwt');
  } catch {
    return null;
  }
}

async function request<T>(
  path: string,
  options: RequestInit = {},
  auth = false,
): Promise<T> {
  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
    ...(options.headers as Record<string, string> | undefined),
  };
  if (auth) {
    const token = getToken();
    if (!token) throw new ApiError('Not authenticated', 401);
    headers.Authorization = `Bearer ${token}`;
  }

  if (OFFLINE) {
    const { handleMock } = await import('./mockBackend');
    try {
      return await handleMock(path, options, auth ? getToken() : null);
    } catch (err: any) {
      throw new ApiError(err?.message ?? 'Offline backend error', err?.status ?? 500);
    }
  }

  let res: Response;
  try {
    res = await fetch(`${API_BASE}${path}`, { ...options, headers });
  } catch {
    throw new ApiError('Cannot reach server — check your connection', 0);
  }
  const body = await res.json().catch(() => null);
  if (!res.ok) {
    throw new ApiError(body?.error ?? `Request failed: ${res.status}`, res.status);
  }
  return body;
}

// --- Auth (no JWT) ---
export function login(username: string, password: string) {
  return request<{ token: string }>('/login', {
    method: 'POST',
    body: JSON.stringify({ username, password }),
  });
}

// Returns a session token directly (verified live) — no separate login needed.
export function register(username: string, email: string, password: string) {
  return request<{ token: string }>('/register', {
    method: 'POST',
    body: JSON.stringify({ username, email, password }),
  });
}

export function health() {
  return request<{ status: string; uptime: number; db: string }>('/api/health');
}

// --- Character — old system, read-mostly, do not change shape ---
// Server expects snake_case `class_index` (verified against the live endpoint).
export function loadOrCreateCharacter(classIndex?: number) {
  return request<Character>(
    '/character',
    { method: 'POST', body: JSON.stringify({ class_index: classIndex }) },
    true,
  );
}

export function getCharacter() {
  return request<Character>('/character', {}, true);
}

export function changeDiscipline(characterId: number, classIndex: number) {
  return request<Character>('/character/discipline', {
    method: 'POST', body: JSON.stringify({ characterId, class_index: classIndex }),
  }, true);
}

// New /api/* endpoints wrap payloads in { success, data } — unwrap and
// surface `error` verbatim (it's player-readable by server contract).
async function unwrap<T>(p: Promise<ApiResponse<T>>): Promise<T> {
  const body = await p;
  if (!body.success) throw new ApiError(body.error ?? 'Unknown server error', 200);
  return body.data as T;
}

// --- Inventory — new system ---
export function getInventory(characterId: number) {
  return unwrap<InventorySlot[]>(request(`/api/inventory/${characterId}`, {}, true));
}

export function saveInventory(characterId: number, slots: unknown[]) {
  return unwrap<InventorySlot[]>(
    request(
      '/api/inventory/save',
      { method: 'POST', body: JSON.stringify({ characterId, slots }) },
      true,
    ),
  );
}

export function equipItem(characterId: number, slotIndex: number, equipped: 0 | 1) {
  return unwrap<InventorySlot[]>(
    request(
      '/api/inventory/equip',
      { method: 'POST', body: JSON.stringify({ characterId, slot_index: slotIndex, equipped }) },
      true,
    ),
  );
}

// --- Professions & crafting ---
export function getProfessions(characterId: number) {
  return unwrap<Profession[]>(request(`/api/professions/${characterId}`, {}, true));
}

export function getRecipes(profession: string) {
  return unwrap<Recipe[]>(request(`/api/recipes?profession=${encodeURIComponent(profession)}`));
}

// Recipe ids are strings (e.g. "recipe_copper_bar") — verified live.
/** The live server replies with the result + XP (the DEV mock also sends the bag); re-read inventory after. */
export function craft(characterId: number, recipeId: string) {
  return unwrap<{ result_item_id?: string; xp_gained?: number; leveled_up?: boolean; skill_level?: number }>(
    request(
      '/api/craft',
      { method: 'POST', body: JSON.stringify({ characterId, recipeId }) },
      true,
    ),
  );
}

// --- Gathering (Death Muffin backend: server/death-muffin/backend/gathering/) ---
// The client only says which node and how many work cycles; the server rolls
// the items, XP and gold against a time budget and stores them.
export interface GatherReply {
  node: string;
  skill: string;
  accepted: number;
  successes: number;
  xp: number;
  gold: number;
  items: { itemId: string; qty: number }[];
  rejected: { itemId: string; qty: number }[];
  leveledUp: boolean;
  skills: Profession[];
}

export function gather(characterId: number, nodeType: string, actions: number, keepalive = false, afk = false) {
  return unwrap<GatherReply>(
    request('/api/gather', { method: 'POST', body: JSON.stringify({ characterId, nodeType, actions, afk }), keepalive }, true),
  );
}

export function beginAfkGather(characterId: number, nodeType: string) {
  return unwrap<{ node: string }>(request('/api/gather/afk-start', { method: 'POST', body: JSON.stringify({ characterId, nodeType }) }, true));
}

// --- Progression ---
export interface ProgressPayload {
  characterId: number;
  level: number;
  xp: number;
  gold: number;
  stat_str: number;
  stat_agi: number;
  stat_int: number;
  stat_vit: number;
}

/**
 * `keepalive` lets the final save on tab close/hide complete after the page
 * starts unloading (sendBeacon can't carry the Authorization header).
 */
export function saveProgress(payload: ProgressPayload, keepalive = false) {
  return request<ApiResponse<unknown>>(
    '/api/character/save-progress',
    { method: 'POST', body: JSON.stringify(payload), keepalive },
    true,
  );
}

// --- Necromancer progression (server storage; see server/VPS_HANDOFF.md) ---
// Older servers don't have these routes: a 404 on `necroGet` means "keep using
// browser storage".


/** What the server sends back (NecroState as the client may see it). */
export type NecroProgress = NecroState;

export interface NecroReply {
  progress: NecroProgress;
  gold?: number;
  earned?: number;
  cost?: number;
}

const necroPost = (path: string, body: object, keepalive = false) =>
  unwrap<NecroReply>(request(`/api/necro-progress/${path}`, { method: 'POST', body: JSON.stringify(body), keepalive }, true));

export const necroApi = {
  get: (characterId: number) => unwrap<NecroReply>(request(`/api/necro-progress/${characterId}`, {}, true)),
  save: (characterId: number, input: SaveInput, keepalive = false) => necroPost('save', { characterId, ...input }, keepalive),
  purchase: (characterId: number, upgrade: 'damage' | 'wave') => necroPost('purchase', { characterId, upgrade }),
  summonPrelate: (characterId: number) => necroPost('summon-prelate', { characterId }),
  ascend: (characterId: number) => necroPost('ascend', { characterId }),
  boon: (characterId: number, boonId: string) => necroPost('boon', { characterId, boonId }),
  importLocal: (characterId: number, record: object) => necroPost('import', { characterId, record }),
};
