import { API_BASE } from './config';

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

let jwt: string | null = null;

export function setToken(token: string | null) {
  jwt = token;
  if (token) sessionStorage.setItem('cw_jwt', token);
  else sessionStorage.removeItem('cw_jwt');
}

export function getToken(): string | null {
  return jwt ?? sessionStorage.getItem('cw_jwt');
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
    if (!token) throw new Error('Not authenticated');
    headers.Authorization = `Bearer ${token}`;
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
  return request<any>(
    '/character',
    { method: 'POST', body: JSON.stringify({ class_index: classIndex }) },
    true,
  );
}

export function getCharacter() {
  return request<any>('/character', {}, true);
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
  return unwrap<import('./types').InventorySlot[]>(
    request(`/api/inventory/${characterId}`, {}, true),
  );
}

export function saveInventory(characterId: number, slots: unknown[]) {
  return unwrap<import('./types').InventorySlot[]>(
    request(
      '/api/inventory/save',
      { method: 'POST', body: JSON.stringify({ characterId, slots }) },
      true,
    ),
  );
}

export function equipItem(characterId: number, slotIndex: number, equipped: 0 | 1) {
  return unwrap<import('./types').InventorySlot[]>(
    request(
      '/api/inventory/equip',
      { method: 'POST', body: JSON.stringify({ characterId, slot_index: slotIndex, equipped }) },
      true,
    ),
  );
}

// --- Professions & crafting ---
export function getProfessions(characterId: number) {
  return unwrap<import('./types').Profession[]>(
    request(`/api/professions/${characterId}`, {}, true),
  );
}

export function getRecipes(profession: string) {
  return unwrap<import('./types').Recipe[]>(
    request(`/api/recipes?profession=${encodeURIComponent(profession)}`),
  );
}

// Recipe ids are strings (e.g. "recipe_copper_bar") — verified live.
export function craft(characterId: number, recipeId: string) {
  return unwrap<{
    updatedInventory: import('./types').InventorySlot[];
    updatedProfession: import('./types').Profession;
  }>(
    request(
      '/api/craft',
      { method: 'POST', body: JSON.stringify({ characterId, recipeId }) },
      true,
    ),
  );
}

// --- Progression ---
export function saveProgress(payload: {
  characterId: number;
  level: number;
  xp: number;
  gold: number;
  stat_str: number;
  stat_agi: number;
  stat_int: number;
  stat_vit: number;
}) {
  return request<ApiResponse<unknown>>(
    '/api/character/save-progress',
    { method: 'POST', body: JSON.stringify(payload) },
    true,
  );
}
