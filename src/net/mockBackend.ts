/**
 * DEV-ONLY offline backend (`?offline` in the dev URL). Serves every REST call
 * the client makes from localStorage, with the same request/response shapes
 * as the live auth server, so the full loop can be QA'd without touching
 * production. Never bundled into production builds: api.ts only imports this
 * module behind `import.meta.env.DEV`.
 *
 * Item ids and recipes mirror what the live server exposes via
 * /api/recipes (fetched 2026-09-26). Item stats here are invented for offline
 * play — the live server's items table is the source of truth.
 */
import type { InventorySlot, Profession, Recipe, Rarity } from './types';
import { ITEMS } from '../content/items';
import * as necro from '../gameplay/necroRules';
import type { NecroState } from '../gameplay/necroRules';

class MockError extends Error {
  constructor(message: string, public status: number) {
    super(message);
  }
}

interface ItemDef {
  name: string;
  item_type: InventorySlot['item_type'];
  rarity: Rarity;
  stat_bonus?: Record<string, number>;
  sell_value: number;
}

// Offline catalog derived from the shared client item metadata (content/items.ts).
export const MOCK_ITEMS: Record<string, ItemDef> = Object.fromEntries(
  Object.entries(ITEMS).map(([id, meta]) => [
    id,
    { name: meta.name, item_type: meta.type, rarity: meta.rarity, stat_bonus: meta.offlineStats, sell_value: meta.sell },
  ]),
);

type R = [string, string, string, number, string, number, [string, number][]];
// [id, name, profession, level, result, qty, ingredients]
const RECIPE_ROWS: R[] = [
  ['recipe_copper_bar', 'Smelt Copper Bar', 'mining', 1, 'material_copper_bar', 1, [['material_copper_shard', 3]]],
  ['smelt_copper_ingot', 'Smelt Copper Ingot', 'mining', 1, 'ingot_copper', 1, [['ore_copper', 3]]],
  ['craft_copper_helm', 'Copper Helm', 'mining', 3, 'helm_copper', 1, [['ingot_copper', 2]]],
  ['recipe_copper_ring', 'Forge Copper Ring', 'mining', 3, 'ring_copper', 1, [['material_copper_bar', 2]]],
  ['smelt_tin_ingot', 'Smelt Tin Ingot', 'mining', 3, 'ingot_tin', 1, [['ore_tin', 3]]],
  ['craft_copper_augment', 'Copper Augment', 'mining', 5, 'augment_copper', 1, [['ingot_copper', 1]]],
  ['recipe_copper_plate', 'Forge Copper Plate', 'mining', 5, 'plate_copper', 1, [['material_copper_bar', 4]]],
  ['recipe_copper_sword', 'Forge Copper Sword', 'mining', 5, 'sword_copper', 1, [['material_copper_bar', 3]]],
  ['smelt_iron_ingot', 'Smelt Iron Ingot', 'mining', 5, 'ingot_iron', 1, [['ore_iron', 3]]],
  ['craft_iron_helm', 'Iron Helm', 'mining', 8, 'helm_iron', 1, [['ingot_iron', 2]]],
  ['smelt_bronze_ingot', 'Smelt Bronze Ingot', 'mining', 8, 'ingot_bronze', 1, [['ore_bronze', 3]]],
  ['craft_forge_tempered_flask', 'Forge-Tempered Flask', 'mining', 10, 'flask_damage', 1, [['fish_fillet', 3], ['ingot_iron', 2]]],
  ['craft_iron_chestplate', 'Iron Chestplate', 'mining', 10, 'chest_iron', 1, [['ingot_copper', 1], ['ingot_iron', 3]]],
  ['craft_iron_augment', 'Iron Augment', 'mining', 12, 'augment_iron', 1, [['ingot_iron', 1]]],
  ['craft_iron_warden_kit', 'Iron Warden Kit', 'mining', 12, 'kit_iron_warden', 1, [['ingot_iron', 3], ['plank_oak', 2]]],
  ['smelt_silver_ingot', 'Smelt Silver Ingot', 'mining', 12, 'ingot_silver', 1, [['ore_silver', 3]]],
  ['smelt_gold_ingot', 'Smelt Gold Ingot', 'mining', 15, 'ingot_gold', 1, [['ore_gold', 3]]],
  ['craft_gold_tempered_helm', 'Gold-Tempered Helm', 'mining', 18, 'helm_gold', 1, [['ingot_gold', 2], ['ingot_iron', 1]]],
  ['smelt_steel_ingot', 'Smelt Steel Ingot', 'mining', 20, 'ingot_steel', 1, [['ore_steel', 3]]],
  ['smelt_hell_ingot', 'Smelt Hell Ingot', 'mining', 35, 'ingot_hell', 1, [['ore_hell', 3]]],
  ['smelt_moon_ingot', 'Smelt Moon Ingot', 'mining', 50, 'ingot_moon', 1, [['ore_moon', 3]]],
  ['craft_minor_healing_potion', 'Minor Healing Potion', 'fishing', 1, 'flask_hp_minor', 1, [['fish_fillet', 2]]],
  ['prepare_river_fillet', 'Prepare River Fillet', 'fishing', 1, 'fish_fillet', 1, [['fish_river', 2]]],
  ['craft_swiftness_flask', 'Swiftness Flask', 'fishing', 3, 'flask_speed', 1, [['fish_fillet', 2], ['ingot_copper', 1]]],
  ['craft_void_resist_flask', 'Void Resist Flask', 'fishing', 5, 'flask_void_resist', 1, [['fish_fillet', 3], ['ingot_copper', 2]]],
  ['craft_major_healing_flask', 'Major Healing Flask', 'fishing', 8, 'flask_hp_major', 1, [['fish_fillet', 4], ['ingot_iron', 1]]],
  ['mill_oak_plank', 'Mill Oak Plank', 'woodcutting', 1, 'plank_oak', 1, [['log_oak', 3]]],
  ['craft_oak_shortbow', 'Oak Shortbow', 'woodcutting', 3, 'bow_oak', 1, [['plank_oak', 3]]],
  ['craft_oak_staff', 'Oak Staff', 'woodcutting', 3, 'staff_oak', 1, [['plank_oak', 3]]],
];

const RECIPES: Recipe[] = RECIPE_ROWS.map(([id, name, profession_id, lvl, result, qty, ings]) => ({
  id,
  name,
  profession_id,
  skill_level_required: lvl,
  result_item_id: result,
  result_quantity: qty,
  ingredients: ings.map(([item_id, quantity]) => ({ item_id, quantity, name: MOCK_ITEMS[item_id]?.name ?? item_id })),
}));

const CLASS_NAMES = ['Engineer', 'Guardian', 'Shadowblade', 'Cleric', 'Arcanist'];

interface StoredSlot {
  slot_index: number;
  item_id: string;
  quantity: number;
  equipped: 0 | 1;
}

interface MockAccount {
  /** Server-side necromancer progression (mirrors character_necro_progress). */
  necro?: NecroState;
  username: string;
  character: Record<string, any> | null;
  slots: StoredSlot[];
  professions: Profession[];
}

interface MockDb {
  nextCharacterId: number;
  accounts: Record<string, MockAccount>;
}

const DB_KEY = 'cw_offline_db_v1';

function loadDb(): MockDb {
  try {
    const raw = localStorage.getItem(DB_KEY);
    if (raw) return JSON.parse(raw);
  } catch {
    /* fresh db */
  }
  return { nextCharacterId: 9000, accounts: {} };
}

function saveDb(db: MockDb) {
  try {
    localStorage.setItem(DB_KEY, JSON.stringify(db));
  } catch {
    /* storage unavailable — offline session becomes ephemeral */
  }
}

function joinSlot(s: StoredSlot, i: number): InventorySlot {
  const def = MOCK_ITEMS[s.item_id];
  return {
    id: i + 1,
    slot_index: s.slot_index,
    quantity: s.quantity,
    equipped: s.equipped,
    item_id: s.item_id,
    name: def?.name ?? s.item_id,
    rarity: def?.rarity ?? 'common',
    item_type: def?.item_type ?? 'material',
    stat_bonus: def?.stat_bonus ?? null,
    icon_id: null,
    sell_value: def?.sell_value ?? 0,
    crafted: 0,
  };
}

function accountFor(db: MockDb, token: string | null): MockAccount {
  if (!token || !token.startsWith('offline:')) throw new MockError('Invalid token', 401);
  const acc = db.accounts[token.slice('offline:'.length)];
  if (!acc) throw new MockError('Invalid token', 401);
  return acc;
}

function ok<T>(data: T) {
  return { success: true, data };
}

function fail(error: string) {
  return { success: false, error };
}

function ownCharacter(acc: MockAccount, characterId: unknown) {
  if (!acc.character || Number(characterId) !== acc.character.id) {
    throw new MockError('Character not found', 404);
  }
}

/** Mirrors fetch() + JSON parse in api.ts: returns the body or throws. */
export async function handleMock(
  path: string,
  options: RequestInit,
  token: string | null,
): Promise<any> {
  await new Promise((r) => setTimeout(r, 40 + Math.random() * 80));
  const method = (options.method ?? 'GET').toUpperCase();
  const body = options.body ? JSON.parse(String(options.body)) : {};
  const url = new URL(path, 'http://offline.local');
  const db = loadDb();

  try {
    const result = route(db, method, url, body, token);
    saveDb(db);
    return result;
  } catch (err) {
    if (err instanceof MockError) throw err;
    throw new MockError(err instanceof Error ? err.message : 'Offline backend error', 500);
  }
}

function route(db: MockDb, method: string, url: URL, body: any, token: string | null): any {
  const p = url.pathname;

  if (p === '/api/health') return { status: 'ok', uptime: 1, db: 'offline' };

  if (p === '/login' && method === 'POST') {
    const username = String(body.username ?? '').trim();
    if (!username || !body.password) throw new MockError('invalid credentials', 401);
    const acc = db.accounts[username];
    if (!acc) throw new MockError('invalid credentials', 401);
    return { token: `offline:${username}` };
  }

  if (p === '/register' && method === 'POST') {
    const username = String(body.username ?? '').trim();
    if (username.length < 3) throw new MockError('username must be at least 3 characters', 400);
    if (!body.password || String(body.password).length < 4) {
      throw new MockError('password must be at least 4 characters', 400);
    }
    if (db.accounts[username]) throw new MockError('username already taken', 409);
    db.accounts[username] = {
      username,
      character: null,
      slots: [],
      professions: [
        { profession_id: 'mining', skill_level: 1, skill_xp: 0 },
        { profession_id: 'fishing', skill_level: 1, skill_xp: 0 },
        { profession_id: 'woodcutting', skill_level: 1, skill_xp: 0 },
      ],
    };
    return { token: `offline:${username}` };
  }

  const acc = accountFor(db, token);

  if (p === '/character' && method === 'GET') {
    if (!acc.character) throw new MockError('No character', 404);
    return acc.character;
  }

  if (p === '/character' && method === 'POST') {
    if (acc.character) return acc.character;
    const idx = Number(body.class_index);
    if (!Number.isInteger(idx) || idx < 0 || idx > 4) throw new MockError('class_index must be 0–4', 400);
    acc.character = {
      id: db.nextCharacterId++,
      class_index: idx,
      class_name: CLASS_NAMES[idx],
      level: 1,
      experience: 0,
      gold: 0,
      stat_str: idx === 1 ? 7 : 5,
      stat_agi: idx === 2 ? 7 : 5,
      stat_int: idx === 3 || idx === 4 ? 7 : 5,
      stat_vit: idx === 1 ? 7 : 5,
    };
    // Starter kit so the reliquary isn't empty offline.
    acc.slots = [
      { slot_index: 0, item_id: 'staff_oak', quantity: 1, equipped: 0 },
      { slot_index: 1, item_id: 'flask_hp_minor', quantity: 3, equipped: 0 },
    ];
    return acc.character;
  }

  let m: RegExpMatchArray | null;
  if ((m = p.match(/^\/api\/inventory\/(\d+)$/)) && method === 'GET') {
    ownCharacter(acc, m[1]);
    return ok(acc.slots.map(joinSlot));
  }

  if (p === '/api/inventory/save' && method === 'POST') {
    ownCharacter(acc, body.characterId);
    const next: StoredSlot[] = [];
    for (const s of body.slots ?? []) {
      if (!MOCK_ITEMS[s.item_id]) return fail(`Unknown item: ${s.item_id}`);
      const qty = Math.floor(Number(s.quantity));
      if (qty <= 0) continue;
      next.push({ slot_index: Number(s.slot_index), item_id: s.item_id, quantity: qty, equipped: s.equipped ? 1 : 0 });
    }
    acc.slots = next;
    return ok(acc.slots.map(joinSlot));
  }

  if (p === '/api/inventory/equip' && method === 'POST') {
    ownCharacter(acc, body.characterId);
    const slot = acc.slots.find((s) => s.slot_index === Number(body.slot_index));
    if (!slot) return fail('Slot is empty');
    if (MOCK_ITEMS[slot.item_id]?.item_type === 'material') return fail('That item cannot be equipped');
    slot.equipped = body.equipped ? 1 : 0;
    return ok(acc.slots.map(joinSlot));
  }

  if ((m = p.match(/^\/api\/professions\/(\d+)$/)) && method === 'GET') {
    ownCharacter(acc, m[1]);
    return ok(acc.professions);
  }

  if (p === '/api/recipes' && method === 'GET') {
    const prof = url.searchParams.get('profession');
    return ok(RECIPES.filter((r) => !prof || r.profession_id === prof));
  }

  if (p === '/api/craft' && method === 'POST') {
    ownCharacter(acc, body.characterId);
    const recipe = RECIPES.find((r) => r.id === body.recipeId);
    if (!recipe) return fail('Unknown recipe');
    const prof = acc.professions.find((x) => x.profession_id === recipe.profession_id);
    const lvl = prof?.skill_level ?? 0;
    if (lvl < recipe.skill_level_required) {
      return fail(`requires ${recipe.profession_id} level ${recipe.skill_level_required} (you have ${lvl})`);
    }
    for (const ing of recipe.ingredients) {
      const have = acc.slots.filter((s) => s.item_id === ing.item_id).reduce((n, s) => n + s.quantity, 0);
      if (have < ing.quantity) return fail(`not enough ${ing.name} (${have}/${ing.quantity})`);
    }
    for (const ing of recipe.ingredients) {
      let left = ing.quantity;
      for (const s of acc.slots) {
        if (s.item_id !== ing.item_id || left <= 0) continue;
        const take = Math.min(left, s.quantity);
        s.quantity -= take;
        left -= take;
      }
    }
    acc.slots = acc.slots.filter((s) => s.quantity > 0);
    const stack = acc.slots.find((s) => s.item_id === recipe.result_item_id && MOCK_ITEMS[s.item_id]?.item_type === 'material');
    if (stack) stack.quantity += recipe.result_quantity;
    else {
      const used = new Set(acc.slots.map((s) => s.slot_index));
      let free = 0;
      while (used.has(free)) free++;
      if (free >= 24) return fail('Inventory full');
      acc.slots.push({ slot_index: free, item_id: recipe.result_item_id, quantity: recipe.result_quantity, equipped: 0 });
    }
    if (prof) {
      prof.skill_xp += 10;
      while (prof.skill_xp >= prof.skill_level * 50) {
        prof.skill_xp -= prof.skill_level * 50;
        prof.skill_level += 1;
      }
    }
    return ok({ updatedInventory: acc.slots.map(joinSlot), updatedProfession: prof });
  }

  if (p === '/api/character/save-progress' && method === 'POST') {
    ownCharacter(acc, body.characterId);
    const c = acc.character!;
    c.level = Number(body.level) || c.level;
    c.experience = Number(body.xp) || 0;
    c.gold = Math.max(0, Number(body.gold) || 0);
    for (const k of ['stat_str', 'stat_agi', 'stat_int', 'stat_vit']) {
      if (body[k] !== undefined) c[k] = Number(body[k]);
    }
    return ok({ saved: true });
  }

  // --- Necromancer progression: same shared rules the VPS runs (server/vps-handoff). ---
  if ((m = p.match(/^\/api\/necro-progress\/(\d+)$/)) && method === 'GET') {
    ownCharacter(acc, m[1]);
    acc.necro = necro.normalise(acc.necro ?? necro.blankState());
    return ok({ progress: acc.necro, gold: acc.character!.gold });
  }
  if ((m = p.match(/^\/api\/necro-progress\/(save|purchase|summon-prelate|ascend|boon|import)$/)) && method === 'POST') {
    ownCharacter(acc, body.characterId);
    const c = acc.character!;
    const state = necro.normalise(acc.necro ?? necro.blankState());
    const r =
      m[1] === 'save'
        ? necro.applySave(state, body)
        : m[1] === 'purchase'
          ? necro.purchase(state, Number(c.gold) || 0, body.upgrade)
          : m[1] === 'summon-prelate'
            ? necro.summonPrelate(state)
            : m[1] === 'ascend'
              ? necro.ascend(state)
              : m[1] === 'boon'
                ? necro.buyBoon(state, body.boonId)
                : necro.importLocal(state, body.record);
    if (!r.ok) throw new MockError(r.error, 400);
    acc.necro = r.state;
    const extra = r as { gold?: number; earned?: number; cost?: number };
    if (extra.gold !== undefined) c.gold = extra.gold;
    return ok({ progress: r.state, ...(extra.gold !== undefined ? { gold: extra.gold } : {}), ...(extra.earned !== undefined ? { earned: extra.earned } : {}), ...(extra.cost !== undefined ? { cost: extra.cost } : {}) });
  }

  throw new MockError(`Offline backend: no route for ${method} ${p}`, 404);
}
