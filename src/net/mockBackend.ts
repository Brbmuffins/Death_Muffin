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
import { equipSlotOf } from '../content/gear';
import * as necro from '../gameplay/necroRules';
import type { NecroState } from '../gameplay/necroRules';
import * as contractRules from '../gameplay/contractRules';
import * as gardenRules from '../gameplay/gardeningRules';
import * as laborRules from '../gameplay/laborRules';
import * as cosmeticRules from '../gameplay/cosmeticRules';
import { itemMeta } from '../content/items';
import * as gather from '../gameplay/gatheringRules';
import * as legion from '../gameplay/legionRules';
import { PROCESSING_RECIPES } from '../content/processing';
import { ALCHEMY_RECIPES } from '../content/alchemy';
import { NECRO_RECIPES, isTwoHanded } from '../content/necroWeapons';
import { REAGENT_RECIPES } from '../content/reagents';
import { FEN_RECIPES } from '../content/fenItems';
import { isDevAccount } from '../gameplay/devAccess';
import * as vaultRules from '../gameplay/vaultRules';
import * as salvageRules from '../gameplay/salvageRules';
import * as affixRules from '../gameplay/affixRules';

const BAG = gather.BAG_SLOTS;
/** Mirrors inventory-save.cjs CANT_VERIFY. */
const CANT_VERIFY = 'One of your relics could not be verified. Reload the game to refresh your Reliquary.';

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

// Professions G6: the same rows the server migration is generated from.
RECIPE_ROWS.push(...PROCESSING_RECIPES);
RECIPE_ROWS.push(...ALCHEMY_RECIPES, ...NECRO_RECIPES, ...REAGENT_RECIPES, ...FEN_RECIPES);

const RECIPES: Recipe[] = RECIPE_ROWS.map(([id, name, profession_id, lvl, result, qty, ings]) => ({
  id,
  name,
  profession_id,
  skill_level_required: lvl,
  result_item_id: result,
  result_quantity: qty,
  ingredients: ings.map(([item_id, quantity]) => ({ item_id, quantity, name: MOCK_ITEMS[item_id]?.name ?? item_id })),
}));

const CLASS_NAMES = ['Engineer', 'Guardian', 'Shadowblade', 'Cleric', 'Arcanist', 'Necromancer'];
/** Mirrors the Death Muffin backend's DISCIPLINE_NAMES (discipline_index 5-9). */
const DISCIPLINE_NAMES: Record<number, string> = { 5: 'Grave Warden', 6: 'Bell Monk', 7: 'Carrion Witch', 8: 'Hollow Knight', 9: 'Veilwalker' };
const MAX_DISCIPLINE_INDEX = 9;

interface StoredSlot {
  slot_index: number;
  item_id: string;
  quantity: number;
  equipped: 0 | 1;
  /** A rolled piece (mirrors inventory.instance_id): the roll itself lives in MockAccount.instances, never on the row. */
  instance_id?: number;
  /** Only in the portable save (exportLocalSave / importOnlineSave): the roll inline, as offline-full-sync.cjs expects. */
  inst?: affixRules.ItemInstanceData;
}

interface MockAccount {
  /** Server-side necromancer progression (mirrors character_necro_progress). */
  necro?: NecroState;
  /** Capes and pets (mirrors character_cosmetics + character_pets). */
  cosmetics?: { cape: string | null; pet: string | null; pets: string[] };
  /** Grave Laborers' posts (mirrors character_labor). */
  labor?: Record<number, { nodeType: string | null; startedAt: number }>;
  /** Grave Gardening plots (mirrors garden_plots). */
  garden?: Record<string, gardenRules.PlotRow>;
  /** Sexton's Contracts: which of today's orders are filled (mirrors character_contracts). */
  contracts?: { day: string; done: number[]; bonus: boolean; days: string[] };
  /** The Chronicle (mirrors character_chronicle + character_runs). */
  chronicle?: { life: Record<string, number>; run: Record<string, number>; runNo: number; runStartedAt: string; runs: { runNo: number; startedAt: string; endedAt: string; ascensionAfter: number; stats: Record<string, number> }[] };
  /** The Ossuary Vault (mirrors account_vault; the mock has one account per character). */
  vault?: { slot_index: number; item_id: string; quantity: number; instance_id?: number }[];
  /** Rolled loot (mirrors loot_instances) and the next id. Only POST /api/loot/roll-gear writes it. */
  instances?: Record<string, { item_id: string; ilvl: number; affixes: affixRules.AffixRoll[] }>;
  nextInstance?: number;
  /** POST /api/gather time budget (mirrors gather_ledger). */
  gatherLedger?: gather.GatherLedger;
  username: string;
  character: Record<string, any> | null;
  slots: StoredSlot[];
  professions: Profession[];
}

interface MockDb {
  nextCharacterId: number;
  accounts: Record<string, MockAccount>;
}

const DB_KEY = 'dm_offline_db_v1';
const LEGACY_DEV_KEY = 'cw_offline_db_v1';

function loadDb(): MockDb {
  try {
    const raw = localStorage.getItem(DB_KEY) ?? (import.meta.env.DEV ? localStorage.getItem(LEGACY_DEV_KEY) : null);
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

/** Full portable account state for the offline save chooser. */
export function exportLocalSave(token: string): MockAccount {
  const account = accountFor(loadDb(), token);
  if (!account.character) throw new MockError('Create a local character before syncing.', 400);
  const copy = JSON.parse(JSON.stringify(account)) as MockAccount;
  // The portable save carries each roll inline (the online server mints fresh instances from it), not our local ids.
  for (const slot of copy.slots) {
    const inst = slot.instance_id ? copy.instances?.[slot.instance_id] : undefined;
    delete slot.instance_id;
    if (inst) slot.inst = { ilvl: inst.ilvl, affixes: inst.affixes };
  }
  delete copy.instances;
  delete copy.nextInstance;
  delete copy.vault;
  return copy;
}

/** Keep the current local player; import an online save as another local player. */
export function importOnlineSave(snapshot: MockAccount): string {
  if (!snapshot?.character || !Array.isArray(snapshot.slots) || !Array.isArray(snapshot.professions))
    throw new MockError('Invalid online save.', 400);
  const db = loadDb();
  const stem = `online_${String(snapshot.username || 'player').replace(/[^a-zA-Z0-9_]/g, '_').slice(0, 20)}`;
  let username = stem;
  for (let n = 2; db.accounts[username]; n++) username = `${stem}_${n}`;
  const copy = JSON.parse(JSON.stringify(snapshot)) as MockAccount;
  copy.username = username;
  // Online rolls arrive inline; give each a local instance id.
  copy.instances = {};
  copy.nextInstance = 1;
  for (const slot of copy.slots) {
    const inst = slot.inst;
    delete slot.inst;
    if (inst && affixRules.instanceProblem(inst, MOCK_ITEMS[slot.item_id]?.item_type ?? 'material') === null) {
      copy.instances[copy.nextInstance] = { item_id: slot.item_id, ilvl: inst.ilvl, affixes: affixRules.cleanInstance(inst).affixes };
      slot.instance_id = copy.nextInstance++;
    }
  }
  if (Object.values(db.accounts).some((a) => a.character?.id === copy.character!.id)) {
    copy.character!.id = db.nextCharacterId++;
  }
  db.nextCharacterId = Math.max(db.nextCharacterId, Number(copy.character!.id) + 1);
  db.accounts[username] = copy;
  saveDb(db);
  return `offline:${username}`;
}

function joinSlot(s: StoredSlot, i: number, acc?: MockAccount): InventorySlot {
  const def = MOCK_ITEMS[s.item_id];
  const roll = s.instance_id && acc?.instances ? acc.instances[s.instance_id] : undefined;
  return {
    ...(roll && s.instance_id ? { instance_id: s.instance_id, ilvl: roll.ilvl, affixes: roll.affixes } : {}),
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

  // Public on the live server (no JWT): the Workbench and stations read recipes before auth.
  if (p === '/api/recipes' && method === 'GET') {
    const prof = url.searchParams.get('profession');
    return ok(RECIPES.filter((r) => !prof || r.profession_id === prof));
  }

  const acc = accountFor(db, token);
  const join = (s: StoredSlot, i: number) => joinSlot(s, i, acc);
  const characterResponse = () => ({ ...acc.character, auto_combat_allowed: import.meta.env.DEV && acc.username.toLowerCase() === 'brbmuffins' });

  if (p === '/character' && method === 'GET') {
    if (!acc.character) throw new MockError('No character', 404);
    return characterResponse();
  }

  if (p === '/character/discipline' && method === 'POST') {
    const index = body.class_index;
    if (!Number.isInteger(index) || index < 1 || index > MAX_DISCIPLINE_INDEX) throw new MockError(`Choose one of the ${MAX_DISCIPLINE_INDEX} classes.`, 400);
    ownCharacter(acc, body.characterId);
    acc.character!.class_index = index;
    acc.character!.class_name = DISCIPLINE_NAMES[index] ?? CLASS_NAMES[index] ?? acc.character!.class_name;
    return characterResponse();
  }

  if (p === '/character' && method === 'POST') {
    if (acc.character) return characterResponse();
    const idx = Number(body.class_index);
    if (!Number.isInteger(idx) || idx < 0 || idx >= CLASS_NAMES.length) throw new MockError('class_index must be 0–5', 400);
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
    return characterResponse();
  }

  let m: RegExpMatchArray | null;
  if ((m = p.match(/^\/api\/inventory\/(\d+)$/)) && method === 'GET') {
    ownCharacter(acc, m[1]);
    return ok(acc.slots.map(join));
  }

  if (p === '/api/inventory/save' && method === 'POST') {
    ownCharacter(acc, body.characterId);
    // Same rule as the server (inventory-save.cjs): a save only speaks for slots 0..bagSize-1, 24 when bagSize is absent.
    const bagSize = body.bagSize === undefined || body.bagSize === null ? 24 : Number(body.bagSize);
    if (!Number.isInteger(bagSize) || bagSize < 1 || bagSize > BAG) return fail(`bagSize must be a whole number from 1 to ${BAG}`);
    const next: StoredSlot[] = [];
    const claimed = new Set<number>();
    const instances = acc.instances ?? (acc.instances = {});
    const held = (id: number) => acc.slots.some((x) => x.instance_id === id && !(x.slot_index >= 0 && x.slot_index < bagSize)) || (acc.vault ?? []).some((x) => x.instance_id === id);
    for (const s of body.slots ?? []) {
      if (Number(s.slot_index) >= 100) continue;
      if (!MOCK_ITEMS[s.item_id]) return fail(`Unknown item: ${s.item_id}`);
      const index = Number(s.slot_index);
      if (!Number.isInteger(index) || index < 0 || index >= bagSize) return fail(`each slot_index must be between 0 and ${bagSize - 1}`);
      const qty = Math.floor(Number(s.quantity));
      if (qty <= 0) continue;
      // A save may only NAME a roll the mock minted for this account (same rule as inventory-save.cjs); an omitted id keeps the slot's own.
      let instance_id: number | undefined;
      if (s.instance_id === undefined) {
        const before = acc.slots.find((x) => x.slot_index === index && x.item_id === s.item_id);
        instance_id = before?.instance_id;
      } else if (s.instance_id !== null) {
        instance_id = Number(s.instance_id);
        if (!Number.isInteger(instance_id) || qty !== 1 || claimed.has(instance_id) || instances[instance_id]?.item_id !== s.item_id || held(instance_id)) return fail(CANT_VERIFY);
      }
      if (instance_id !== undefined) claimed.add(instance_id);
      next.push({ slot_index: index, item_id: s.item_id, quantity: qty, equipped: s.equipped ? 1 : 0, ...(instance_id !== undefined ? { instance_id } : {}) });
    }
    // A relic the save no longer names is gone (sold, thrown away).
    for (const x of acc.slots) if (x.instance_id && x.slot_index >= 0 && x.slot_index < bagSize && !claimed.has(x.instance_id)) delete instances[x.instance_id];
    acc.slots = [...acc.slots.filter((s) => s.slot_index >= 100 || s.slot_index >= bagSize), ...next];
    return ok(acc.slots.map(join));
  }

  // Item level and affixes: the only place loot is rolled (the same rules as server/death-muffin/backend/loot.cjs, with Math.random).
  if (p === '/api/loot/roll-gear' && method === 'POST') {
    ownCharacter(acc, body.characterId);
    const drops = body.drops;
    if (!Array.isArray(drops) || !drops.length || drops.length > 12) return fail('Roll between 1 and 12 drops at a time.');
    const instances = acc.instances ?? (acc.instances = {});
    const out: { item_id: string; instance_id: number | null; ilvl: number; affixes: affixRules.AffixRoll[] }[] = [];
    for (const d of drops) {
      const def = d && MOCK_ITEMS[d.item_id];
      if (!def || !affixRules.DROP_SOURCES.includes(d.source)) return fail(def ? 'That drop could not be rolled.' : 'Unknown item.');
      if (!affixRules.isAffixGear(def.item_type)) {
        out.push({ item_id: d.item_id, instance_id: null, ilvl: 0, affixes: [] });
        continue;
      }
      const level = affixRules.clampDropLevel(d.level, Number(acc.character?.level) || 1);
      const inst = affixRules.rollInstance({ rarity: def.rarity }, level, d.source, Math.random);
      const id = acc.nextInstance ?? 1;
      acc.nextInstance = id + 1;
      instances[id] = { item_id: d.item_id, ilvl: inst.ilvl, affixes: inst.affixes };
      out.push({ item_id: d.item_id, instance_id: id, ilvl: inst.ilvl, affixes: inst.affixes });
    }
    return ok(out);
  }

  if (p === '/api/inventory/equip' && method === 'POST') {
    ownCharacter(acc, body.characterId);
    const slot = acc.slots.find((s) => s.slot_index === Number(body.slot_index));
    if (!slot) return fail('Slot is empty');
    const type = MOCK_ITEMS[slot.item_id]?.item_type;
    const gearSlot = type && equipSlotOf({ item_type: type, equipped_slot: null, item_equipment_slot: null });
    if (!gearSlot) return fail('That item cannot be equipped');
    const reserved = { head: 100, chest: 101, legs: 102, feet: 103, hands: 104, main_hand: 105, off_hand: 106, ring: 107, trinket: 108 }[gearSlot];
    const free = () => Array.from({ length: BAG }, (_, i) => i).find((i) => !acc.slots.some((s) => s !== slot && s.slot_index === i));
    if (body.equipped) {
      // Same rules as the server: a two-handed weapon displaces the off-hand, and an off-hand displaces a two-handed weapon.
      const displaced = acc.slots.filter((s) => s !== slot && (s.slot_index === reserved
        || (isTwoHanded(slot.item_id) && s.slot_index === 106)
        || (gearSlot === 'off_hand' && s.slot_index === 105 && isTwoHanded(s.item_id))));
      const freeBag = Array.from({ length: BAG }, (_, i) => i).filter((i) => !acc.slots.some((s) => s !== slot && !displaced.includes(s) && s.slot_index === i));
      // The equipped item's own bag slot is vacated, so it can hold the first displaced piece.
      if (displaced.length > freeBag.length + 1) return fail('Not enough inventory space to swap equipment');
      const bagIndex = slot.slot_index;
      slot.slot_index = reserved;
      slot.equipped = 1;
      displaced.forEach((d, i) => { d.slot_index = i === 0 ? bagIndex : freeBag[i - 1]; d.equipped = 0; });
    } else {
      const bagIndex = free();
      if (bagIndex === undefined) return fail('Inventory full');
      slot.slot_index = bagIndex;
      slot.equipped = 0;
    }
    return ok(acc.slots.map(join));
  }

  // The gathering tool belt: the same moves as server/death-muffin/backend/tool-belt.cjs.
  if (p === '/api/inventory/belt' && method === 'POST') {
    ownCharacter(acc, body.characterId);
    const index = Number(body.slot_index);
    const slot = acc.slots.find((s) => s.slot_index === index);
    if (body.equipped) {
      if (!slot || !(index >= 0 && index < BAG)) return fail('There is nothing in that slot.');
      const target = gather.beltSlotOf(slot.item_id);
      if (target < 0) return fail('Only gathering tools fit on the belt.');
      const other = acc.slots.find((s) => s.slot_index === target);
      slot.slot_index = target;
      slot.equipped = 1;
      if (other) { other.slot_index = index; other.equipped = 0; }
    } else {
      if (!gather.isBeltSlot(index)) return fail('That is not a belt slot.');
      if (!slot) return fail('The belt slot is empty.');
      const bagIndex = Array.from({ length: BAG }, (_, i) => i).find((i) => !acc.slots.some((s) => s.slot_index === i));
      if (bagIndex === undefined) return fail('Your bag is full. Make room, then take the tool off the belt.');
      slot.slot_index = bagIndex;
      slot.equipped = 0;
    }
    return ok(acc.slots.map(join));
  }

  // The Legion kit (thrall gear): the same moves as server/death-muffin/backend/thrall-kit.cjs.
  if (p === '/api/inventory/kit' && method === 'POST') {
    ownCharacter(acc, body.characterId);
    const index = Number(body.slot_index);
    const slot = acc.slots.find((s) => s.slot_index === index);
    if (body.equipped) {
      if (!(index >= 0 && index < BAG)) return fail('Pick a piece from your bag.');
      if (!slot) return fail('There is nothing in that slot.');
      const kitId = legion.kitIdForType(MOCK_ITEMS[slot.item_id]?.item_type);
      if (!kitId) return fail('The legion wears weapons and armour only.');
      const target = legion.kitSlotIndex(kitId);
      const other = acc.slots.find((s) => s.slot_index === target);
      slot.slot_index = target;
      slot.equipped = 1;
      if (other) { other.slot_index = index; other.equipped = 0; }
    } else {
      if (!legion.isKitSlot(index)) return fail('That is not a legion slot.');
      if (!slot) return fail('The legion slot is empty.');
      const bagIndex = Array.from({ length: BAG }, (_, i) => i).find((i) => !acc.slots.some((s) => s.slot_index === i));
      if (bagIndex === undefined) return fail('Your bag is full. Make room, then take the piece off the legion.');
      slot.slot_index = bagIndex;
      slot.equipped = 0;
    }
    return ok(acc.slots.map(join));
  }

  // --- The Ossuary Vault and Salvaging: the same pure rules the Death Muffin backend uses (vault-rules, salvage-rules). ---
  const mockInfo: vaultRules.VaultInfo = (id) => {
    const d = MOCK_ITEMS[id];
    const gear = !!d && salvageRules.isSalvageGear(d.item_type);
    return { maxStack: gear ? 1 : (ITEMS[id]?.stack ?? 9999), itemType: d?.item_type ?? 'material', rarity: d?.rarity ?? 'common' };
  };
  const instRow = (id: number | undefined) => {
    const roll = id !== undefined && id !== null ? acc.instances?.[id] : undefined;
    return roll && id !== undefined ? { inst: id, power: affixRules.instancePower(roll), ilvl: roll.ilvl, nAffix: roll.affixes.length } : {};
  };
  const bagRows = (): (vaultRules.VaultRow & { ilvl?: number; nAffix?: number })[] => acc.slots.filter((x) => x.slot_index < BAG).map((x) => ({ slot: x.slot_index, itemId: x.item_id, qty: x.quantity, ...(x.equipped ? { fixed: true } : {}), ...instRow(x.instance_id) }));
  const vaultRows = (): vaultRules.VaultRow[] => (acc.vault ?? []).map((x) => ({ slot: x.slot_index, itemId: x.item_id, qty: x.quantity, ...instRow(x.instance_id) }));
  const storeBag = (rows: vaultRules.VaultRow[]) => {
    const equippedKept = new Map(acc.slots.filter((x) => x.slot_index < BAG && x.equipped).map((x) => [x.slot_index, x]));
    acc.slots = [...acc.slots.filter((x) => x.slot_index >= BAG), ...rows.map((r): StoredSlot => equippedKept.get(r.slot) ?? { slot_index: r.slot, item_id: r.itemId, quantity: r.qty, equipped: 0, ...(r.inst !== undefined ? { instance_id: r.inst } : {}) })];
  };
  const vaultView = () => ({
    bag: acc.slots.map(join),
    vault: (acc.vault ?? []).slice().sort((a, b) => a.slot_index - b.slot_index).map((v, i) => joinSlot({ ...v, equipped: 0 }, i, acc)),
  });
  const applyVault = (r: vaultRules.VaultResult) => {
    if (!r.ok) return fail(r.error);
    storeBag(r.bag);
    acc.vault = r.vault.map((x) => ({ slot_index: x.slot, item_id: x.itemId, quantity: x.qty, ...(x.inst !== undefined ? { instance_id: x.inst } : {}) }));
    return ok(vaultView());
  };
  if ((m = p.match(/^\/api\/vault\/(\d+)$/)) && method === 'GET') {
    ownCharacter(acc, m[1]);
    return ok(vaultView());
  }
  if (p === '/api/vault/deposit' && method === 'POST') {
    ownCharacter(acc, body.characterId);
    const slot = Number(body.bagSlot);
    if (!Number.isInteger(slot) || slot < 0 || slot >= BAG) return fail(`Choose a bag slot between 0 and ${BAG - 1}.`);
    return applyVault(vaultRules.depositStack(bagRows(), vaultRows(), slot, body.quantity == null ? undefined : Number(body.quantity), mockInfo));
  }
  if (p === '/api/vault/withdraw' && method === 'POST') {
    ownCharacter(acc, body.characterId);
    const slot = Number(body.vaultSlot);
    if (!Number.isInteger(slot) || slot < 0 || slot >= vaultRules.VAULT_SLOTS) return fail(`Choose a Vault slot between 0 and ${vaultRules.VAULT_SLOTS - 1}.`);
    return applyVault(vaultRules.withdrawStack(bagRows(), vaultRows(), slot, body.quantity == null ? undefined : Number(body.quantity), mockInfo));
  }
  if (p === '/api/vault/deposit-all' && method === 'POST') {
    ownCharacter(acc, body.characterId);
    if (body.kind !== 'materials' && body.kind !== 'all') return fail('Choose what to deposit: materials or everything.');
    const except = Array.isArray(body.exceptSlots) ? body.exceptSlots.map(Number).filter((n: number) => Number.isInteger(n)) : [];
    return applyVault(vaultRules.depositMany(bagRows(), vaultRows(), body.kind, except, mockInfo));
  }
  if (p === '/api/vault/sort' && method === 'POST') {
    ownCharacter(acc, body.characterId);
    acc.vault = vaultRules.sortVault(vaultRows(), mockInfo).map((x) => ({ slot_index: x.slot, item_id: x.itemId, quantity: x.qty, ...(x.inst !== undefined ? { instance_id: x.inst } : {}) }));
    return ok(vaultView());
  }
  if (p === '/api/salvage' && method === 'POST') {
    ownCharacter(acc, body.characterId);
    const slots: number[] = Array.isArray(body.slots) ? body.slots.map(Number) : [];
    if (!slots.length) return fail('Choose some gear to salvage.');
    if (slots.length > BAG || slots.some((n) => !Number.isInteger(n) || n < 0 || n >= BAG) || new Set(slots).size !== slots.length) return fail(`Choose gear in your bag (slots 0 to ${BAG - 1}), each once.`);
    const bag = bagRows();
    let prof = acc.professions.find((x) => x.profession_id === salvageRules.SALVAGE_SKILL);
    const level = prof?.skill_level ?? 1;
    const salvaged: { item_id: string }[] = [];
    const yields: salvageRules.SalvageGrant[][] = [];
    const spent: number[] = [];
    let xp = 0;
    for (const slot of slots) {
      const row = bag.find((r) => r.slot === slot);
      if (!row) return fail('One of those slots is empty. Nothing was salvaged.');
      if (row.fixed) return fail('Equipped gear cannot be salvaged. Unequip it first.');
      const info = mockInfo(row.itemId);
      if (!salvageRules.isSalvageGear(info.itemType)) return fail('Only weapons, armor, rings and trinkets can be salvaged.');
      if (row.inst !== undefined) spent.push(row.inst);
      for (let n = 0; n < row.qty; n++) {
        const out = salvageRules.salvageYield({ id: row.itemId, item_type: info.itemType, rarity: info.rarity, ...(row.inst !== undefined ? { ilvl: row.ilvl, affixes: row.nAffix } : {}) }, level, Math.random);
        salvaged.push({ item_id: row.itemId });
        yields.push(out.items);
        xp += out.xp;
      }
    }
    const gained = salvageRules.mergeGrants(yields);
    const taken = new Set(slots);
    const after = vaultRules.addGrants(bag.filter((r) => !taken.has(r.slot)), gained.map((g) => ({ itemId: g.item_id, qty: g.quantity })), mockInfo);
    if (!after) return fail('Make room in your bag first: the salvage will not fit. Nothing was salvaged.');
    storeBag(after);
    for (const id of spent) delete acc.instances?.[id];
    if (!prof) acc.professions.push((prof = { profession_id: salvageRules.SALVAGE_SKILL, skill_level: 1, skill_xp: 0 }));
    const next = gather.addSkillXp({ level: prof.skill_level, xp: prof.skill_xp }, xp);
    prof.skill_level = next.level;
    prof.skill_xp = next.xp;
    return ok({ bag: acc.slots.map(join), salvaged, gained, xp, level: next.level, leveledUp: next.leveled > 0, skillXp: next.xp, xpToNext: gather.xpToNext(next.level) });
  }

  if ((m = p.match(/^\/api\/professions\/(\d+)$/)) && method === 'GET') {
    ownCharacter(acc, m[1]);
    return ok(acc.professions);
  }

  // --- Gathering: same shared rules and time budget as the Death Muffin backend. ---
  if (p === '/api/gather/afk-start' && method === 'POST') {
    ownCharacter(acc, body.characterId);
    const def = gather.NODES[String(body.nodeType ?? '')];
    if (!def) throw new MockError('Unknown gathering node', 400);
    const level = acc.professions.find(x => x.profession_id === def.skill)?.skill_level ?? 1;
    if (level < def.level && !isDevAccount(null, `offline:${acc.username}`)) throw new MockError(`Requires ${gather.SKILLS[def.skill].name} level ${def.level}`, 400);
    acc.gatherLedger = { ...(acc.gatherLedger ?? gather.blankLedger()), lastAt: Date.now() };
    return ok({ node: def.id });
  }
  if (p === '/api/gather' && method === 'POST') {
    ownCharacter(acc, body.characterId);
    const def = gather.NODES[String(body.nodeType ?? '')];
    if (!def) throw new MockError('Unknown gathering node', 400);
    let prof = acc.professions.find((x) => x.profession_id === def.skill);
    if (!prof) acc.professions.push((prof = { profession_id: def.skill, skill_level: 1, skill_xp: 0 }));
    // Offline, the DEV_ACCOUNTS names stand in for the server's staff flag.
    const staff = isDevAccount(null, `offline:${acc.username}`);
    if (prof.skill_level < def.level && !staff) throw new MockError(`Requires ${gather.SKILLS[def.skill].name} level ${def.level}`, 400);
    const budget = gather.checkBudget(def, acc.gatherLedger ?? gather.blankLedger(), body.actions, Date.now(), body.afk === true);
    if (!budget.ok) throw new MockError(budget.error, 400);
    const bag = acc.slots
      .filter((x) => x.slot_index < BAG)
      .map((x) => ({ slot: x.slot_index, itemId: x.equipped ? '' : x.item_id, qty: x.quantity }));
    // The tool belt (slots 110-113) counts like the bag, as on the server.
    const belt = acc.slots.filter((x) => gather.isBeltSlot(x.slot_index)).map((x) => x.item_id);
    const toolTier = gather.toolTierFor(def.skill, [...bag.map((s) => s.itemId), ...belt]);
    const batch = gather.rollBatch(def, { level: prof.skill_level, xp: prof.skill_xp }, budget.accepted, Math.random, toolTier, staff ? def.level : 0);
    const placed = gather.placeItems(bag, batch.items, (id) => (MOCK_ITEMS[id]?.item_type === 'material' ? (ITEMS[id]?.stack ?? 9999) : 1));
    for (const u of placed.updates) acc.slots.find((x) => x.slot_index === u.slot)!.quantity = u.qty;
    for (const r of placed.inserts) acc.slots.push({ slot_index: r.slot, item_id: r.itemId, quantity: r.qty, equipped: 0 });
    prof.skill_level = batch.progress.level;
    prof.skill_xp = batch.progress.xp;
    if (batch.gold > 0) acc.character!.gold = (Number(acc.character!.gold) || 0) + batch.gold;
    acc.gatherLedger = budget.ledger;
    return ok({
      node: def.id,
      skill: def.skill,
      accepted: budget.accepted,
      successes: batch.successes,
      xp: batch.xp,
      gold: batch.gold,
      items: placed.stored,
      rejected: placed.rejected,
      leveledUp: batch.leveled > 0,
      toolTier,
      skills: [{ ...prof }],
    });
  }

  if (p === '/api/professions/award-xp' && method === 'POST') {
    throw new MockError('Skill XP is earned by gathering and crafting now.', 410);
  }

  if (p === '/api/craft' && method === 'POST') {
    ownCharacter(acc, body.characterId);
    const recipe = RECIPES.find((r) => r.id === body.recipeId);
    if (!recipe) return fail('Unknown recipe');
    const prof = acc.professions.find((x) => x.profession_id === recipe.profession_id);
    const lvl = prof?.skill_level ?? 1; // the live server treats a missing row as level 1
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
      if (free >= BAG) return fail('Inventory full');
      acc.slots.push({ slot_index: free, item_id: recipe.result_item_id, quantity: recipe.result_quantity, equipped: 0 });
    }
    // Like the live server: a missing profession row is created on the first craft, and XP is 5 per required level.
    let earner = prof;
    if (!earner) {
      earner = { profession_id: recipe.profession_id, skill_level: 1, skill_xp: 0 };
      acc.professions.push(earner);
    }
    earner.skill_xp += Math.max(1, recipe.skill_level_required) * 5;
    while (earner.skill_xp >= earner.skill_level * 50) {
      earner.skill_xp -= earner.skill_level * 50;
      earner.skill_level += 1;
    }
    return ok({ updatedInventory: acc.slots.map(join), updatedProfession: earner });
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

  // --- Grave Laborers: the same shared rules the server runs; work accrues on the clock. ---
  const laborLevels = () => Object.fromEntries(acc.professions.map((pr) => [pr.profession_id, pr.skill_level]));
  const laborPosts = () => (acc.labor ??= {});
  const laborView = (now: number) => {
    const levels = laborLevels();
    const total = laborRules.totalGatherLevel(levels);
    const unlocked = laborRules.laborSlots(total);
    return {
      now, capMs: laborRules.LABOR.capMs, totalLevel: total, levelsPerSlot: laborRules.LABOR.levelsPerSlot,
      slots: Array.from({ length: laborRules.LABOR.maxSlots }, (_, slot) => {
        const row = laborPosts()[slot];
        const def = row?.nodeType ? gather.NODES[row.nodeType] : null;
        const elapsed = def ? Math.max(0, Math.min(now - row!.startedAt, laborRules.LABOR.capMs)) : 0;
        const est = def ? laborRules.estimate(def, levels[def.skill] ?? 1, elapsed) : null;
        return { slot, unlocked: slot < unlocked, nodeType: def?.id ?? null, nodeName: def?.name ?? null, skill: def?.skill ?? null, item: def?.item ?? null, startedAt: def ? row!.startedAt : 0, elapsedMs: elapsed, capped: !!def && now - row!.startedAt >= laborRules.LABOR.capMs, pendingActions: est?.actions ?? 0, estItems: est?.items ?? 0, estXp: est?.xp ?? 0 };
      }),
    };
  };
  if ((m = p.match(/^\/api\/labor\/(\d+)$/)) && method === 'GET') {
    ownCharacter(acc, m[1]);
    return ok(laborView(Date.now()));
  }
  if (p === '/api/labor/assign' && method === 'POST') {
    ownCharacter(acc, body.characterId);
    const now = Date.now();
    const slot = Number(body.slot);
    const levels = laborLevels();
    if (!(slot >= 0 && slot < laborRules.laborSlots(laborRules.totalGatherLevel(levels)))) return fail('You do not command that many laborers yet.');
    const row = laborPosts()[slot];
    const cur = row?.nodeType ? gather.NODES[row.nodeType] : null;
    if (cur && laborRules.laborActions(cur, now - row!.startedAt) >= 1) return fail('Collect what they have gathered first.');
    if (body.nodeType) {
      const blocked = laborRules.assignBlocker(body.nodeType, levels);
      if (blocked) return fail(blocked);
    }
    laborPosts()[slot] = { nodeType: body.nodeType || null, startedAt: body.nodeType ? now : 0 };
    return ok(laborView(now));
  }
  if (p === '/api/labor/collect' && method === 'POST') {
    ownCharacter(acc, body.characterId);
    const now = Date.now();
    const slot = Number(body.slot);
    const row = laborPosts()[slot];
    const def = row?.nodeType ? gather.NODES[row.nodeType] : null;
    if (!def) return fail('That laborer has no post.');
    const elapsed = Math.min(now - row!.startedAt, laborRules.LABOR.capMs);
    const actions = laborRules.laborActions(def, elapsed);
    if (actions < 1) return fail('They have barely started.');
    let pr = acc.professions.find((x) => x.profession_id === def.skill);
    if (!pr) { pr = { profession_id: def.skill, skill_level: 1, skill_xp: 0 }; acc.professions.push(pr); }
    const roll = laborRules.rollLabor(def, { level: pr.skill_level, xp: pr.skill_xp }, elapsed, laborRules.claimRng(laborRules.hashSeed(acc.character!.id, slot, row!.startedAt, actions)));
    const placed = gather.placeItems(acc.slots.map((s) => ({ slot: s.slot_index, itemId: s.equipped ? '' : s.item_id, qty: s.quantity })), roll.items, () => 250);
    if (placed.rejected.length) return fail(`Make room in your bag: ${placed.rejected.reduce((n, g) => n + g.qty, 0)} of their finds would not fit.`);
    for (const u of placed.updates) acc.slots.find((s) => s.slot_index === u.slot)!.quantity = u.qty;
    for (const r of placed.inserts) acc.slots.push({ slot_index: r.slot, item_id: r.itemId, quantity: r.qty, equipped: 0 });
    pr.skill_level = roll.progress.level;
    pr.skill_xp = roll.progress.xp;
    row!.startedAt = now;
    return ok({ ...laborView(now), collected: { slot, node: def.id, skill: def.skill, hours: elapsed / 3_600_000, actions, items: placed.stored, gold: roll.gold, xp: roll.xp, leveledUp: roll.leveled > 0 } });
  }

  // --- Grave Gardening: the same shared rules the server runs; growth is timestamp-based. ---
  const plotsOf = () => (acc.garden ??= {});
  const gardenView = (now: number) => {
    const lvl = acc.professions.find((pr) => pr.profession_id === 'gardening');
    const level = lvl?.skill_level ?? 1;
    return {
      now, level, xp: lvl?.skill_xp ?? 0, xpToNext: gather.xpToNext(level),
      plots: gardenRules.PLOTS.map((d) => { const row = plotsOf()[d.id]; return { plot: d.id, kind: d.kind, label: d.label, seedId: row?.seedId ?? null, plantedAt: row?.plantedAt ?? 0, readyAt: row?.readyAt ?? 0, composted: !!row?.composted, state: gardenRules.stateOf(row, now) }; }),
    };
  };
  const gardenXp = (xp: number) => {
    let pr = acc.professions.find((x) => x.profession_id === 'gardening');
    if (!pr) { pr = { profession_id: 'gardening', skill_level: 1, skill_xp: 0 }; acc.professions.push(pr); }
    const next = gather.addSkillXp({ level: pr.skill_level, xp: pr.skill_xp }, xp);
    pr.skill_level = next.level;
    pr.skill_xp = next.xp;
    return next.leveled > 0;
  };
  const takeFromBag = (itemId: string, n: number) => {
    const have = acc.slots.filter((s) => s.item_id === itemId && !s.equipped && s.slot_index < BAG).reduce((t, s) => t + s.quantity, 0);
    if (have < n) return false;
    let left = n;
    for (const s of acc.slots.filter((x) => x.item_id === itemId && !x.equipped && x.slot_index < BAG)) { const t = Math.min(left, s.quantity); s.quantity -= t; left -= t; }
    acc.slots = acc.slots.filter((s) => s.quantity > 0);
    return true;
  };
  if ((m = p.match(/^\/api\/garden\/(\d+)$/)) && method === 'GET') {
    ownCharacter(acc, m[1]);
    return ok(gardenView(Date.now()));
  }
  if (p === '/api/garden/plant' && method === 'POST') {
    ownCharacter(acc, body.characterId);
    const now = Date.now();
    const view = gardenView(now);
    const blocked = gardenRules.plantBlocker(gardenRules.plotDef(body.plot), body.seedId, view.level, plotsOf()[body.plot], now);
    if (blocked) return fail(blocked);
    if (!takeFromBag(body.seedId, 1)) return fail('You have no such seed in your bag.');
    if (body.compost && !takeFromBag(gardenRules.COMPOST_ITEM, 1)) return fail('You have no bone meal in your bag.');
    const seed = gardenRules.seedDef(body.seedId)!;
    plotsOf()[body.plot] = { plot: body.plot, seedId: seed.id, plantedAt: now, readyAt: now + gardenRules.growMs(seed, !!body.compost), composted: !!body.compost };
    const leveledUp = gardenXp(seed.plantXp);
    return ok({ ...gardenView(now), gainedXp: seed.plantXp, leveledUp });
  }
  if (p === '/api/garden/harvest' && method === 'POST') {
    ownCharacter(acc, body.characterId);
    const now = Date.now();
    const row = plotsOf()[body.plot];
    if (gardenRules.stateOf(row, now) === 'empty') return fail('Nothing is growing there.');
    if (gardenRules.stateOf(row, now) !== 'ready') return fail('It is not ready yet.');
    const crop = gardenRules.rollHarvest(gardenRules.seedDef(row.seedId!)!, Math.random);
    const grants = [{ itemId: crop.itemId, qty: crop.qty }, ...(crop.seedBack ? [{ itemId: crop.seedBack, qty: 1 }] : [])];
    const placed = gather.placeItems(acc.slots.map((s) => ({ slot: s.slot_index, itemId: s.equipped ? '' : s.item_id, qty: s.quantity })), grants, () => 250);
    if (placed.rejected.length) return fail('Make room in your bag before you harvest.');
    for (const u of placed.updates) acc.slots.find((s) => s.slot_index === u.slot)!.quantity = u.qty;
    for (const r of placed.inserts) acc.slots.push({ slot_index: r.slot, item_id: r.itemId, quantity: r.qty, equipped: 0 });
    delete plotsOf()[body.plot];
    const leveledUp = gardenXp(crop.xp);
    return ok({ ...gardenView(now), items: grants, gainedXp: crop.xp, leveledUp });
  }

  // --- Capes and pets: unlocks come from the same shared rules the server runs. ---
  const cosOf = () => (acc.cosmetics ??= { cape: null, pet: null, pets: [] });
  const cosLevels = () => Object.fromEntries(acc.professions.map((pr) => [pr.profession_id, pr.skill_level]));
  const cosView = () => {
    const levels = cosLevels();
    const c = cosOf();
    return {
      totalLevel: cosmeticRules.totalLevel(levels),
      capes: cosmeticRules.CAPES.map((cape) => ({ id: cape.id, name: cape.name, lore: cape.lore, color: cape.color, trim: cape.trim, ...cosmeticRules.capeProgress(cape, levels) })),
      pets: cosmeticRules.PETS.map((p) => ({ id: p.id, name: p.name, charm: p.charm, skill: p.skill, lore: p.lore, adopted: c.pets.includes(p.id) })),
      selected: { cape: c.cape, pet: c.pet },
    };
  };
  if ((m = p.match(/^\/api\/cosmetics\/(\d+)$/)) && method === 'GET') {
    ownCharacter(acc, m[1]);
    return ok(cosView());
  }
  if (p === '/api/cosmetics/select' && method === 'POST') {
    ownCharacter(acc, body.characterId);
    const c = cosOf();
    if ('cape' in body) {
      if (body.cape === null) c.cape = null;
      else if (!cosmeticRules.capeUnlocked(String(body.cape), cosLevels())) return fail('You have not earned that cape yet.');
      else c.cape = String(body.cape);
    }
    if ('pet' in body) {
      if (body.pet === null) c.pet = null;
      else if (!c.pets.includes(String(body.pet))) return fail('You have not adopted that companion.');
      else c.pet = String(body.pet);
    }
    return ok(cosView());
  }
  if (p === '/api/cosmetics/adopt' && method === 'POST') {
    ownCharacter(acc, body.characterId);
    const def = cosmeticRules.petDef(String(body.petId ?? ''));
    if (!def) return fail('There is no such companion.');
    const c = cosOf();
    if (c.pets.includes(def.id)) return fail(`The ${def.name} is already yours. Keep the charm for someone else, or sell it.`);
    if (!takeFromBag(def.charm, 1)) return fail(`You have no ${def.name} Charm in your bag.`);
    c.pets.push(def.id);
    if (!c.pet) c.pet = def.id;
    return ok({ ...cosView(), adopted: def.id });
  }

  // --- Sexton's Contracts: the same shared board rules the server runs. ---
  const contractsFor = () => {
    const day = contractRules.dayKey(Date.now());
    if (!acc.contracts || acc.contracts.day !== day) acc.contracts = { day, done: [], bonus: false, days: acc.contracts?.days ?? [] };
    return acc.contracts;
  };
  const contractView = () => {
    const st = contractsFor();
    const levels = Object.fromEntries(acc.professions.map((pr) => [pr.profession_id, pr.skill_level]));
    const board = contractRules.generateBoard(acc.character!.id, st.day, levels);
    const nm = (id: string) => itemMeta(id).name;
    const bonus = contractRules.bonusFor(board);
    return {
      board,
      view: {
        day: st.day,
        resetsAt: new Date(contractRules.nextResetMs(Date.now())).toISOString(),
        contracts: board.map((c) => ({ ...c, name: nm(c.itemId), rarity: itemMeta(c.itemId).rarity, done: st.done.includes(c.slot), rewardItem: c.rewardItem && { ...c.rewardItem, name: nm(c.rewardItem.itemId) } })),
        bonus: { gold: bonus.gold, item: { ...bonus.item, name: nm(bonus.item.itemId) }, claimed: st.bonus },
        streak: contractRules.streakOf(st.days, st.day),
      },
    };
  };
  if ((m = p.match(/^\/api\/contracts\/(\d+)$/)) && method === 'GET') {
    ownCharacter(acc, m[1]);
    return ok(contractView().view);
  }
  if (p === '/api/contracts/deliver' && method === 'POST') {
    ownCharacter(acc, body.characterId);
    const st = contractsFor();
    const { board } = contractView();
    const c = board[Number(body.slot)];
    if (!c) return fail('unknown contract');
    if (st.done.includes(c.slot)) return fail('That order is already filled.');
    const have = acc.slots.filter((s) => s.item_id === c.itemId && !s.equipped && s.slot_index < BAG).reduce((n, s) => n + s.quantity, 0);
    if (have < c.qty) return fail(`You need ${c.qty} of that in your bag.`);
    let left = c.qty;
    for (const s of acc.slots.filter((x) => x.item_id === c.itemId && !x.equipped && x.slot_index < BAG).sort((a, b) => a.slot_index - b.slot_index)) {
      const take = Math.min(left, s.quantity);
      s.quantity -= take;
      left -= take;
    }
    acc.slots = acc.slots.filter((s) => s.quantity > 0);
    const grant = (itemId: string, qty: number) => {
      const stack = acc.slots.find((s) => s.item_id === itemId && s.slot_index < BAG && !s.equipped);
      if (stack) stack.quantity += qty;
      else {
        const free = [...Array(BAG).keys()].find((i) => !acc.slots.some((s) => s.slot_index === i));
        if (free === undefined) return false;
        acc.slots.push({ slot_index: free, item_id: itemId, quantity: qty, equipped: 0 });
      }
      return true;
    };
    const items: { itemId: string; qty: number }[] = [];
    if (c.rewardItem) {
      if (!grant(c.rewardItem.itemId, c.rewardItem.qty)) return fail('Make room in your bag for the reward.');
      items.push(c.rewardItem);
    }
    st.done.push(c.slot);
    if (!st.days.includes(st.day)) st.days.push(st.day);
    let gold = c.rewardGold;
    let paidBonus: { gold: number; item: { itemId: string; qty: number } } | null = null;
    if (!st.bonus && board.every((o) => st.done.includes(o.slot))) {
      const b = contractRules.bonusFor(board);
      grant(b.item.itemId, b.item.qty);
      st.bonus = true;
      gold += b.gold;
      items.push(b.item);
      paidBonus = { gold: b.gold, item: b.item };
    }
    return ok({ ...contractView().view, gold, items, paidBonus });
  }

  // --- Chronicle: lifetime stats and archived runs (the real server whitelists keys; the mock trusts them). ---
  const chron = () => (acc.chronicle ??= { life: {}, run: {}, runNo: 1, runStartedAt: new Date().toISOString(), runs: [] });
  if ((m = p.match(/^\/api\/chronicle\/(\d+)$/)) && method === 'GET') {
    ownCharacter(acc, m[1]);
    const c = chron();
    return ok({ ...c, runs: [...c.runs].reverse() });
  }
  if (p === '/api/chronicle/add' && method === 'POST') {
    ownCharacter(acc, body.characterId);
    const c = chron();
    for (const [k, v] of Object.entries<number>(body.deltas ?? {})) for (const t of [c.life, c.run]) t[k] = (t[k] ?? 0) + Math.max(0, Math.floor(Number(v) || 0));
    for (const [k, v] of Object.entries<number>(body.maxes ?? {})) for (const t of [c.life, c.run]) t[k] = Math.max(t[k] ?? 0, Math.floor(Number(v) || 0));
    return ok({});
  }
  if (p === '/api/chronicle/ascend' && method === 'POST') {
    ownCharacter(acc, body.characterId);
    const c = chron();
    if (!Object.keys(c.run).length) return ok({ archived: false });
    c.runs.push({ runNo: c.runNo, startedAt: c.runStartedAt, endedAt: new Date().toISOString(), ascensionAfter: Number(body.ascension) || 0, stats: c.run });
    c.run = {};
    c.runNo++;
    c.runStartedAt = new Date().toISOString();
    return ok({ archived: true });
  }

  // --- Necromancer progression: same shared rules the VPS runs (server/vps-handoff). ---
  if ((m = p.match(/^\/api\/necro-progress\/(\d+)$/)) && method === 'GET') {
    ownCharacter(acc, m[1]);
    acc.necro = necro.normalise(acc.necro ?? necro.blankState());
    return ok({ progress: acc.necro, gold: acc.character!.gold });
  }
  if ((m = p.match(/^\/api\/necro-progress\/(save|purchase|summon-prelate|summon-boss|ascend|boon|import)$/)) && method === 'POST') {
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
            : m[1] === 'summon-boss'
              ? necro.summonAreaBoss(state, body.boss)
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
