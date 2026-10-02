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
 * The standalone offline edition routes calls to its in-browser store. The
 * ordinary production game never includes that store. Development `?offline`
 * keeps the same local QA path.
 */
export const OFFLINE =
  import.meta.env.VITE_OFFLINE_BUILD === '1' ||
  (import.meta.env.DEV && typeof window !== 'undefined' && new URLSearchParams(window.location.search).has('offline'));
const TOKEN_KEY = import.meta.env.VITE_OFFLINE_BUILD === '1' ? 'dm_offline_token' : 'dm_jwt';

let jwt: string | null = null;

export function setToken(token: string | null) {
  jwt = token;
  try {
    if (token) {
      sessionStorage.setItem(TOKEN_KEY, token);
      if (localStorage.getItem(TOKEN_KEY)) localStorage.setItem(TOKEN_KEY, token);
    } else {
      sessionStorage.removeItem(TOKEN_KEY);
      localStorage.removeItem(TOKEN_KEY);
    }
  } catch {
    /* storage unavailable — token lives in memory for this page only */
  }
}

export function getToken(): string | null {
  if (jwt) return jwt;
  try {
    return sessionStorage.getItem(TOKEN_KEY) || localStorage.getItem(TOKEN_KEY);
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
export async function loadOrCreateCharacter(classIndex?: number) {
  // Character creation still takes a legacy class index. New families are
  // stored as a discipline override on the same character/save.
  const character = await request<Character>(
    '/character',
    { method: 'POST', body: JSON.stringify({ class_index: classIndex != null && classIndex > 4 ? 5 : classIndex }) },
    true,
  );
  return classIndex != null && classIndex > 4
    ? changeDiscipline(character.id, classIndex)
    : character;
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

/** `bagSize` tells the server which bag slots this save speaks for; without it a server assumes the old 24-slot bag. */
export function saveInventory(characterId: number, slots: unknown[], bagSize?: number) {
  return unwrap<InventorySlot[]>(
    request(
      '/api/inventory/save',
      { method: 'POST', body: JSON.stringify({ characterId, slots, bagSize }) },
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
  return unwrap<unknown>(request<ApiResponse<unknown>>(
    '/api/character/save-progress',
    { method: 'POST', body: JSON.stringify(payload), keepalive },
    true,
  ));
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
  summonBoss: (characterId: number, boss: string) => necroPost('summon-boss', { characterId, boss }),
  ascend: (characterId: number) => necroPost('ascend', { characterId }),
  boon: (characterId: number, boonId: string) => necroPost('boon', { characterId, boonId }),
  importLocal: (characterId: number, record: object) => necroPost('import', { characterId, record }),
};

// --- Chronicle: lifetime stats + archived runs (server/death-muffin/backend/chronicle.cjs) ---

export interface ChronicleRun {
  runNo: number;
  startedAt: string;
  endedAt: string;
  ascensionAfter: number;
  stats: Record<string, number>;
}

export interface ChronicleData {
  life: Record<string, number>;
  run: Record<string, number>;
  runNo: number;
  runStartedAt: string | null;
  runs: ChronicleRun[];
}

export function getChronicle(characterId: number) {
  return unwrap<ChronicleData>(request(`/api/chronicle/${characterId}`, {}, true));
}

export function addChronicle(characterId: number, deltas: Record<string, number>, maxes: Record<string, number>) {
  return unwrap<unknown>(request('/api/chronicle/add', { method: 'POST', body: JSON.stringify({ characterId, deltas, maxes }) }, true));
}

export function ascendChronicle(characterId: number, ascension: number) {
  return unwrap<{ archived: boolean }>(request('/api/chronicle/ascend', { method: 'POST', body: JSON.stringify({ characterId, ascension }) }, true));
}

// --- Sexton's Contracts: the daily delivery board (server/death-muffin/backend/contracts.cjs) ---

export interface ContractView {
  slot: number;
  itemId: string;
  name: string;
  rarity: 'common' | 'uncommon' | 'rare' | 'epic';
  qty: number;
  skill: string;
  rewardGold: number;
  rewardItem: { itemId: string; qty: number; name: string } | null;
  done: boolean;
}

export interface ContractBoard {
  day: string;
  resetsAt: string;
  contracts: ContractView[];
  bonus: { gold: number; item: { itemId: string; qty: number; name: string }; claimed: boolean };
  streak: number;
}

export interface ContractDelivery extends ContractBoard {
  /** Gold to credit (the client owns the gold total). */
  gold: number;
  items: { itemId: string; qty: number }[];
  paidBonus: { gold: number; item: { itemId: string; qty: number } } | null;
}

export function getContracts(characterId: number) {
  return unwrap<ContractBoard>(request(`/api/contracts/${characterId}`, {}, true));
}

export function deliverContract(characterId: number, slot: number) {
  return unwrap<ContractDelivery>(request('/api/contracts/deliver', { method: 'POST', body: JSON.stringify({ characterId, slot }) }, true));
}

// --- Grave Gardening: plots that grow in real time (server/death-muffin/backend/garden.cjs) ---

export interface GardenPlot {
  plot: string;
  kind: 'herb' | 'tree';
  label: string;
  seedId: string | null;
  plantedAt: number;
  readyAt: number;
  composted: boolean;
  state: 'empty' | 'growing' | 'ready';
}

export interface GardenView {
  /** The server's clock, so countdowns don't depend on the player's. */
  now: number;
  level: number;
  xp: number;
  xpToNext: number;
  plots: GardenPlot[];
}

export interface GardenResult extends GardenView {
  gainedXp: number;
  leveledUp: boolean;
  /** Harvest only: what went into the bag (the crop, and a seed if one came back). */
  items?: { itemId: string; qty: number }[];
}

export function getGarden(characterId: number) {
  return unwrap<GardenView>(request(`/api/garden/${characterId}`, {}, true));
}

export function plantGarden(characterId: number, plot: string, seedId: string, compost: boolean) {
  return unwrap<GardenResult>(request('/api/garden/plant', { method: 'POST', body: JSON.stringify({ characterId, plot, seedId, compost }) }, true));
}

export function harvestGarden(characterId: number, plot: string) {
  return unwrap<GardenResult>(request('/api/garden/harvest', { method: 'POST', body: JSON.stringify({ characterId, plot }) }, true));
}

// --- Grave Laborers: thrall labour that works on the server clock (server/death-muffin/backend/labor.cjs) ---

export interface LaborSlot {
  slot: number;
  unlocked: boolean;
  nodeType: string | null;
  nodeName: string | null;
  skill: string | null;
  item: string | null;
  startedAt: number;
  elapsedMs: number;
  capped: boolean;
  pendingActions: number;
  estItems: number;
  estXp: number;
}

export interface LaborView {
  now: number;
  capMs: number;
  totalLevel: number;
  levelsPerSlot: number;
  slots: LaborSlot[];
}

export interface LaborCollected {
  slot: number;
  node: string;
  skill: string;
  hours: number;
  actions: number;
  items: { itemId: string; qty: number }[];
  gold: number;
  xp: number;
  leveledUp: boolean;
}

export interface LaborResult extends LaborView {
  collected?: LaborCollected;
}

export function getLabor(characterId: number) {
  return unwrap<LaborView>(request(`/api/labor/${characterId}`, {}, true));
}

export function assignLabor(characterId: number, slot: number, nodeType: string | null) {
  return unwrap<LaborResult>(request('/api/labor/assign', { method: 'POST', body: JSON.stringify({ characterId, slot, nodeType }) }, true));
}

export function collectLabor(characterId: number, slot: number) {
  return unwrap<LaborResult>(request('/api/labor/collect', { method: 'POST', body: JSON.stringify({ characterId, slot }) }, true));
}

// --- Capes and pets (server/death-muffin/backend/cosmetics.cjs) ---

export interface CosmeticsView {
  totalLevel: number;
  capes: { id: string; name: string; lore: string; color: number; trim: number; unlocked: boolean; have: number; need: number }[];
  pets: { id: string; name: string; charm: string; skill: string; lore: string; adopted: boolean }[];
  selected: { cape: string | null; pet: string | null };
}

export interface CosmeticsResult extends CosmeticsView {
  /** Adopt only: the pet that just joined you. */
  adopted?: string;
}

export function getCosmetics(characterId: number) {
  return unwrap<CosmeticsView>(request(`/api/cosmetics/${characterId}`, {}, true));
}

/** Only the fields present change: `{ cape: null }` puts the cape away and leaves the pet as it was. */
export function selectCosmetics(characterId: number, patch: { cape?: string | null; pet?: string | null }) {
  return unwrap<CosmeticsResult>(request('/api/cosmetics/select', { method: 'POST', body: JSON.stringify({ characterId, ...patch }) }, true));
}

export function adoptPet(characterId: number, petId: string) {
  return unwrap<CosmeticsResult>(request('/api/cosmetics/adopt', { method: 'POST', body: JSON.stringify({ characterId, petId }) }, true));
}

// --- The Ossuary Vault (shared stash) and Salvaging (server/death-muffin/backend/vault.cjs, salvage.cjs) ---

export interface VaultState {
  /** The bag, as GET /api/inventory/:id. */
  bag: InventorySlot[];
  /** The 120 vault slots in the same row shape (slot_index 0-119). */
  vault: InventorySlot[];
}

export function getVault(characterId: number) {
  return unwrap<VaultState>(request(`/api/vault/${characterId}`, {}, true));
}

export function vaultDeposit(characterId: number, bagSlot: number, quantity?: number) {
  return unwrap<VaultState>(request('/api/vault/deposit', { method: 'POST', body: JSON.stringify({ characterId, bagSlot, quantity }) }, true));
}

export function vaultWithdraw(characterId: number, vaultSlot: number, quantity?: number) {
  return unwrap<VaultState>(request('/api/vault/withdraw', { method: 'POST', body: JSON.stringify({ characterId, vaultSlot, quantity }) }, true));
}

export function vaultDepositAll(characterId: number, kind: 'materials' | 'all', exceptSlots: number[]) {
  return unwrap<VaultState>(request('/api/vault/deposit-all', { method: 'POST', body: JSON.stringify({ characterId, kind, exceptSlots }) }, true));
}

export function vaultSort(characterId: number) {
  return unwrap<VaultState>(request('/api/vault/sort', { method: 'POST', body: JSON.stringify({ characterId }) }, true));
}

export interface SalvageReply {
  bag: InventorySlot[];
  salvaged: { item_id: string }[];
  gained: { item_id: string; quantity: number }[];
  /** Salvaging XP gained by this request. */
  xp: number;
  level: number;
  leveledUp: boolean;
  /** XP into the current level, and what that level needs. */
  skillXp: number;
  xpToNext: number;
}

export function salvageGear(characterId: number, slots: number[]) {
  return unwrap<SalvageReply>(request('/api/salvage', { method: 'POST', body: JSON.stringify({ characterId, slots }) }, true));
}
