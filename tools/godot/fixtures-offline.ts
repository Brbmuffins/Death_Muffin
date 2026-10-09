/**
 * Golden fixtures for the Godot offline backend (godot/net/dm_mock_backend.gd), generated FROM the real web mock (src/net/mockBackend.ts).
 * Each scenario drives handleMock() through a seeded sequence (Math.random = mulberry32(seed), a controlled clock) and records every request
 * with the reply the TS gave; the Godot test replays the same requests against DmMockBackend with the same seed and clock and compares replies.
 * Run:  npx vite-node tools/godot/fixtures-offline.ts   ->  godot/tests/offline/fixtures/offline.json
 */
import { mkdirSync, writeFileSync } from 'node:fs';
import { mulberry32 } from '../../src/gameplay/rng';
import { ITEMS } from '../../server/rules/content/items';
import { RUNES, RUNE_RITES } from '../../server/rules/content/runes';
import { isTwoHanded } from '../../server/rules/content/necroWeapons';
import { NODES } from '../../server/rules/gameplay/gatheringRules';
import { SEEDS, PLOTS } from '../../server/rules/content/gardening';
import { BOSSES } from '../../server/rules/content/bosses';
import { petForCharm, CAPES, PETS } from '../../server/rules/content/cosmetics';

// ── harness: storage, clock, Math.random ─────────────────────────────────────────────────────────────────────────────────────────
const store = new Map<string, string>();
(globalThis as any).localStorage = { getItem: (k: string) => store.get(k) ?? null, setItem: (k: string, v: string) => void store.set(k, v), removeItem: (k: string) => void store.delete(k) };
let nowMs = 0;
const RealDate = Date;
class FakeDate extends RealDate {
  constructor(...a: any[]) {
    if (a.length === 0) super(nowMs);
    else super(...(a as [any]));
  }
  static now() {
    return nowMs;
  }
}
(globalThis as any).Date = FakeDate;
let prng = mulberry32(1);
let armed = false;
Math.random = () => (armed ? prng() : 0.5);
const realSetTimeout = globalThis.setTimeout;

// The mock sleeps 40-120 ms per call (calling Math.random once, unarmed); that sleep is the arming point for the seeded stream.
const { handleMock } = await import('../../src/net/mockBackend');

type Step = { method: string; path: string; body?: unknown; token: boolean; now: number; thrown: boolean; status: number; res: unknown };
interface Ctx {
  steps: Step[];
  cid: number;
  now: () => number;
  advance: (ms: number) => void;
  call: (method: string, path: string, body?: unknown, token?: boolean) => Promise<any>;
  get: (path: string) => Promise<any>;
  post: (path: string, body?: Record<string, unknown>) => Promise<any>;
  /** POST with the character id filled in. */
  c: (path: string, body?: Record<string, unknown>) => Promise<any>;
  inv: () => Promise<any[]>;
  save: (slots: { slot_index: number; item_id: string; quantity: number; equipped?: number; instance_id?: number | null }[], bagSize?: number) => Promise<any>;
}
const scenarios: { name: string; seed: number; steps: Step[] }[] = [];

async function scenario(name: string, seed: number, startMs: number, fn: (x: Ctx) => Promise<void>) {
  store.clear();
  prng = mulberry32(seed);
  nowMs = startMs;
  const steps: Step[] = [];
  const x: Ctx = {
    steps,
    cid: 0,
    now: () => nowMs,
    advance: (ms) => void (nowMs += ms),
    call: async (method, path, body, token = true) => {
      armed = false;
      (globalThis as any).setTimeout = (fn: () => void) => {
        armed = true;
        queueMicrotask(fn);
        return 0;
      };
      let thrown = false;
      let status = 200;
      let res: any;
      try {
        res = JSON.parse(JSON.stringify(await handleMock(path, { method, body: body === undefined ? undefined : JSON.stringify(body) }, token ? 'offline:qa_player' : null)));
      } catch (e: any) {
        thrown = true;
        status = e.status;
        res = { success: false, error: e.message };
      } finally {
        (globalThis as any).setTimeout = realSetTimeout;
        armed = false;
      }
      steps.push({ method, path, body, token, now: nowMs, thrown, status, res });
      return res;
    },
    get: (path) => x.call('GET', path),
    post: (path, body) => x.call('POST', path, body ?? {}),
    c: (path, body) => x.call('POST', path, { characterId: x.cid, ...(body ?? {}) }),
    inv: async () => (await x.get(`/api/inventory/${x.cid}`)).data,
    save: (slots, bagSize = 48) => x.c('/api/inventory/save', { slots: slots.map((s) => ({ equipped: 0, ...s })), bagSize }),
  };
  await x.call('POST', '/register', { username: 'qa_player', password: 'pw1234' }, false);
  const ch = await x.call('POST', '/character', { class_index: 5 });
  x.cid = ch.id;
  await fn(x);
  scenarios.push({ name, seed, steps });
}

const ids = (type: string) => Object.entries(ITEMS).filter(([, m]) => m.type === type).map(([id]) => id);
const slotsOf = (ids_: string[], qty = 1) => ids_.map((item_id, i) => ({ slot_index: i, item_id, quantity: qty }));
const T0 = Date.UTC(2026, 9, 5, 12, 0, 0);

const weapons = ids('weapon');
const twoHanded = weapons.find((w) => isTwoHanded(w))!;
const oneHanded = weapons.find((w) => !isTwoHanded(w) && w !== 'staff_oak')!;
const offhand = ids('offhand')[0];
const offhand2 = ids('offhand')[1];
const head = ids('armor_head')[0];
const head2 = ids('armor_head')[1];
const chest = ids('armor_chest')[0];
const ring = ids('ring')[0];
const trinket = ids('trinket')[0];
const runeIds = Object.keys(RUNES);
const runeFor = (rite: string) => runeIds.filter((r) => (RUNES as any)[r].rite === rite);
const tools = ['tool_pickaxe_copper', 'tool_hatchet_iron', 'tool_rod_copper'];

// ── 1. inventory: save rules, equip, belt, legion kit, rune sockets, loot rolls ──────────────────────────────────────────────
await scenario('inventory', 101, T0, async (x) => {
  await x.get(`/api/inventory/${x.cid}`);
  await x.get(`/api/inventory/${x.cid + 1}`);
  await x.save([{ slot_index: 60, item_id: 'staff_oak', quantity: 1 }]);
  await x.c('/api/inventory/save', { slots: [], bagSize: 0 });
  await x.c('/api/inventory/save', { slots: [], bagSize: 49 });
  await x.c('/api/inventory/save', { slots: [], bagSize: 1.5 });
  await x.save([{ slot_index: 0, item_id: 'no_such_item', quantity: 1 }]);
  await x.save([{ slot_index: 30, item_id: 'staff_oak', quantity: 1 }], 24);
  await x.save([{ slot_index: 0, item_id: weapons[0], quantity: 2 }]);
  await x.save([{ slot_index: 0, item_id: 'ingot_copper', quantity: 100 }]);
  await x.save([{ slot_index: 0, item_id: 'ingot_copper', quantity: 0 }, { slot_index: 1, item_id: 'ingot_copper', quantity: 99 }]);
  const pieces = [twoHanded, oneHanded, offhand, offhand2, head, head2, chest, ring, trinket, 'ingot_copper', 'flask_hp_minor', tools[0], tools[1], tools[2], 'rune_splinter', 'rune_splinter', 'rune_volley'];
  await x.save(slotsOf(pieces).map((s, i) => ({ ...s, quantity: s.item_id === 'rune_splinter' ? 3 : s.item_id === 'ingot_copper' ? 40 : 1 })));
  // equip: weapon slots, displacement, errors
  await x.c('/api/inventory/equip', { slot_index: 0, equipped: 1 });
  await x.c('/api/inventory/equip', { slot_index: 2, equipped: 1 });
  await x.c('/api/inventory/equip', { slot_index: 1, equipped: 1 });
  await x.c('/api/inventory/equip', { slot_index: 0, equipped: 1 });
  await x.c('/api/inventory/equip', { slot_index: 4, equipped: 1 });
  await x.c('/api/inventory/equip', { slot_index: 5, equipped: 1 });
  await x.c('/api/inventory/equip', { slot_index: 6, equipped: 1 });
  await x.c('/api/inventory/equip', { slot_index: 7, equipped: 1 });
  await x.c('/api/inventory/equip', { slot_index: 9, equipped: 1 });
  await x.c('/api/inventory/equip', { slot_index: 47, equipped: 1 });
  await x.c('/api/inventory/equip', { slot_index: 105, equipped: 0 });
  await x.c('/api/inventory/equip', { slot_index: 100, equipped: 0 });
  await x.c('/api/inventory/equip', { slot_index: 0, equipped: 0 });
  // belt
  await x.c('/api/inventory/belt', { slot_index: 11, equipped: 1 });
  await x.c('/api/inventory/belt', { slot_index: 12, equipped: 1 });
  await x.c('/api/inventory/belt', { slot_index: 9, equipped: 1 });
  await x.c('/api/inventory/belt', { slot_index: 40, equipped: 1 });
  await x.c('/api/inventory/belt', { slot_index: 110, equipped: 0 });
  await x.c('/api/inventory/belt', { slot_index: 111, equipped: 0 });
  await x.c('/api/inventory/belt', { slot_index: 5, equipped: 0 });
  await x.c('/api/inventory/belt', { slot_index: 112, equipped: 0 });
  await x.c('/api/inventory/belt', { slot_index: 11, equipped: 1 });
  // legion kit
  await x.c('/api/inventory/kit', { slot_index: 0, equipped: 1 });
  await x.c('/api/inventory/kit', { slot_index: 4, equipped: 1 });
  await x.c('/api/inventory/kit', { slot_index: 5, equipped: 1 });
  await x.c('/api/inventory/kit', { slot_index: 9, equipped: 1 });
  await x.c('/api/inventory/kit', { slot_index: 40, equipped: 1 });
  await x.c('/api/inventory/kit', { slot_index: 120, equipped: 0 });
  await x.c('/api/inventory/kit', { slot_index: 121, equipped: 0 });
  await x.c('/api/inventory/kit', { slot_index: 3, equipped: 0 });
  await x.c('/api/inventory/kit', { slot_index: 123, equipped: 0 });
  // rune sockets
  const r0 = runeFor(RUNE_RITES[0])[0];
  const rEx = runeFor(RUNE_RITES[0]);
  await x.c('/api/inventory/rune', { rite: 'nonsense', itemId: r0 });
  await x.c('/api/inventory/rune', { rite: RUNE_RITES[0], itemId: 'ingot_copper' });
  await x.c('/api/inventory/rune', { rite: RUNE_RITES[1], itemId: 'rune_splinter' });
  await x.c('/api/inventory/rune', { rite: RUNE_RITES[0], itemId: null });
  await x.c('/api/inventory/rune', { rite: RUNE_RITES[0], itemId: 'rune_splinter' });
  await x.c('/api/inventory/rune', { rite: RUNE_RITES[0], itemId: 'rune_splinter' });
  if (rEx[1]) await x.c('/api/inventory/rune', { rite: RUNE_RITES[0], itemId: rEx[1] });
  await x.c('/api/inventory/rune', { rite: RUNE_RITES[0], itemId: 'rune_splinter' });
  await x.c('/api/inventory/rune', { rite: RUNE_RITES[0], itemId: null });
  await x.c('/api/inventory/rune', { rite: RUNE_RITES[0], itemId: null });
  await x.c('/api/inventory/rune', { rite: RUNE_RITES[2], itemId: 'rune_volley' });
  await x.get(`/api/inventory/${x.cid}`);
  // loot rolls (+ naming a roll in a save)
  await x.c('/api/loot/roll-gear', { drops: [] });
  await x.c('/api/loot/roll-gear', { drops: Array.from({ length: 13 }, () => ({ item_id: head, level: 5, source: 'kill' })) });
  await x.c('/api/loot/roll-gear', { drops: [{ item_id: 'nope', level: 5, source: 'kill' }] });
  await x.c('/api/loot/roll-gear', { drops: [{ item_id: head, level: 5, source: 'bogus' }] });
  const rolled = await x.c('/api/loot/roll-gear', { drops: [
    { item_id: head, level: 5, source: 'kill' }, { item_id: chest, level: 30, source: 'boss' }, { item_id: 'ingot_copper', level: 5, source: 'kill' },
    { item_id: twoHanded, level: 80, source: 'elite' }, { item_id: ring, level: 1, source: 'first_kill' }, { item_id: trinket, level: 12, source: 'surge' },
  ] });
  const r = rolled.data as { item_id: string; instance_id: number | null }[];
  await x.save(r.map((d, i) => ({ slot_index: i, item_id: d.item_id, quantity: 1, instance_id: d.instance_id })));
  await x.save(r.map((d, i) => ({ slot_index: i, item_id: d.item_id, quantity: 1, instance_id: d.instance_id })).map((s, i) => (i === 1 ? { ...s, instance_id: 999 } : s)));
  await x.save(r.map((d, i) => ({ slot_index: i, item_id: d.item_id, quantity: 1, instance_id: d.instance_id })).map((s, i) => (i === 1 ? { ...s, instance_id: r[0].instance_id } : s)));
  await x.save(r.map((d, i) => ({ slot_index: i, item_id: d.item_id, quantity: 1, instance_id: d.instance_id })).map((s, i) => (i === 1 ? { ...s, instance_id: r[0].instance_id } : s)).slice(0, 1));
  await x.save(r.slice(0, 3).map((d, i) => ({ slot_index: i, item_id: d.item_id, quantity: 1 })));
  await x.save(r.slice(0, 2).map((d, i) => ({ slot_index: i + 5, item_id: d.item_id, quantity: 1, instance_id: null })));
  await x.get(`/api/inventory/${x.cid}`);
});

// ── 2. craft + gather + professions ──────────────────────────────────────────────────────────────────────────────────────────────
await scenario('craft_gather', 202, T0, async (x) => {
  await x.get('/api/recipes');
  await x.call('GET', '/api/recipes?profession=smithing', undefined, false);
  await x.get(`/api/professions/${x.cid}`);
  await x.c('/api/craft', { recipeId: 'nope' });
  await x.c('/api/craft', { recipeId: 'recipe_copper_bar' });
  const recipes = (await x.get('/api/recipes')).data as any[];
  const easy = recipes.filter((r) => r.skill_level_required <= 1 && r.ingredients.every((i: any) => ITEMS[i.item_id]));
  const hard = recipes.find((r) => r.skill_level_required >= 20)!;
  await x.c('/api/craft', { recipeId: hard.id });
  for (const rec of easy.slice(0, 4)) {
    await x.c('/api/craft', { recipeId: rec.id });
    await x.save(rec.ingredients.map((i: any, n: number) => ({ slot_index: n, item_id: i.item_id, quantity: i.quantity * 3 })));
    await x.c('/api/craft', { recipeId: rec.id });
    await x.c('/api/craft', { recipeId: rec.id });
    await x.c('/api/craft', { recipeId: rec.id });
    await x.c('/api/craft', { recipeId: rec.id });
  }
  await x.get(`/api/professions/${x.cid}`);
  // gathering
  const nodes = Object.values(NODES);
  const l1 = (skill: string) => nodes.find((n) => n.skill === skill && n.level === 1)!;
  const high = nodes.find((n) => n.skill === 'mining' && n.level >= 20)!;
  await x.c('/api/gather', { nodeType: 'no_node', actions: 3 });
  await x.c('/api/gather', { nodeType: high.id, actions: 3 });
  await x.c('/api/gather', { nodeType: l1('mining').id, actions: 0 });
  await x.c('/api/gather', { nodeType: l1('mining').id, actions: 3, afk: true });
  await x.c('/api/gather/afk-start', { nodeType: 'no_node' });
  await x.c('/api/gather/afk-start', { nodeType: high.id });
  for (const skill of ['woodcutting', 'mining', 'fishing', 'gravedigging']) {
    const n = l1(skill);
    await x.c('/api/gather', { nodeType: n.id, actions: 12 });
    await x.c('/api/gather', { nodeType: n.id, actions: 12 });
    x.advance(40_000);
    await x.c('/api/gather', { nodeType: n.id, actions: 40 });
  }
  const m = l1('mining');
  await x.save([...slotsOf([tools[0]]), { slot_index: 5, item_id: 'ingot_copper', quantity: 99 }]);
  await x.c('/api/inventory/belt', { slot_index: 0, equipped: 1 });
  await x.c('/api/gather/afk-start', { nodeType: m.id });
  x.advance(60_000);
  await x.c('/api/gather', { nodeType: m.id, actions: 100, afk: true });
  x.advance(90_000);
  await x.c('/api/gather', { nodeType: m.id, actions: 100, afk: true });
  for (let i = 0; i < 30; i++) {
    x.advance(30_000);
    await x.c('/api/gather', { nodeType: m.id, actions: 40 });
  }
  await x.c('/api/gather', { nodeType: m.id, actions: 40 });
  await x.get(`/api/professions/${x.cid}`);
  await x.get(`/api/inventory/${x.cid}`);
  await x.post('/api/professions/award-xp', { characterId: x.cid, skill: 'mining', xp: 5 });
  await x.c('/api/character/save-progress', { level: 3, xp: 40, gold: 123.5, stat_str: 6, stat_agi: 5, stat_int: 5, stat_vit: 5 });
  await x.c('/api/character/save-progress', { level: 0, xp: 'x', gold: -4 });
  await x.call('GET', '/character');
  await x.post('/api/kills/report', { characterId: x.cid, reports: [] });
});

// ── 3. salvage, vault, reforge, boss key ─────────────────────────────────────────────────────────────────────────────────────────
await scenario('salvage_vault_reforge_bosskey', 303, T0, async (x) => {
  const rolled: { item_id: string; instance_id: number | null; affixes: any[] }[] = [];
  const gearIds = [head, chest, twoHanded, ring, trinket, offhand, head2, oneHanded];
  for (let i = 0; i < gearIds.length; i++) {
    const r = await x.c('/api/loot/roll-gear', { drops: [{ item_id: gearIds[i], level: 20 + i * 8, source: i % 2 ? 'boss' : 'elite' }] });
    rolled.push(...r.data);
  }
  await x.save([...rolled.map((d, i) => ({ slot_index: i, item_id: d.item_id, quantity: 1, instance_id: d.instance_id })),
    { slot_index: 10, item_id: 'rune_splinter', quantity: 4 }, { slot_index: 11, item_id: 'ingot_copper', quantity: 60 }, { slot_index: 12, item_id: 'bone_meal', quantity: 30 }, { slot_index: 13, item_id: 'sword_copper', quantity: 1 }]);
  await x.c('/api/inventory/equip', { slot_index: 0, equipped: 1 });
  // salvage errors
  await x.c('/api/salvage', { slots: [] });
  await x.c('/api/salvage', { slots: [1, 1] });
  await x.c('/api/salvage', { slots: [99] });
  await x.c('/api/salvage', { slots: [20] });
  await x.c('/api/salvage', { slots: [11] });
  await x.c('/api/salvage', { slots: [0] });
  await x.c('/api/salvage', { slots: [13, 10] });
  await x.c('/api/salvage', { slots: [1, 2, 3] });
  await x.c('/api/salvage', { slots: [10] });
  await x.c('/api/salvage', { slots: [10, 4, 5] });
  await x.get(`/api/professions/${x.cid}`);
  // vault
  await x.get(`/api/vault/${x.cid}`);
  await x.c('/api/vault/deposit', { bagSlot: 99 });
  await x.c('/api/vault/deposit', { bagSlot: 30 });
  await x.c('/api/vault/deposit', { bagSlot: 11, quantity: 0 });
  await x.c('/api/vault/deposit', { bagSlot: 11, quantity: 25 });
  await x.c('/api/vault/deposit', { bagSlot: 11 });
  await x.c('/api/vault/deposit', { bagSlot: 6 });
  await x.c('/api/vault/deposit', { bagSlot: 0 });
  await x.c('/api/vault/deposit-all', { kind: 'bogus' });
  await x.c('/api/vault/deposit-all', { kind: 'materials', exceptSlots: [12] });
  await x.c('/api/vault/deposit-all', { kind: 'all', exceptSlots: [0] });
  await x.get(`/api/vault/${x.cid}`);
  await x.c('/api/vault/sort');
  await x.c('/api/vault/withdraw', { vaultSlot: 500 });
  await x.c('/api/vault/withdraw', { vaultSlot: 100 });
  await x.c('/api/vault/withdraw', { vaultSlot: 0, quantity: 3 });
  await x.c('/api/vault/withdraw', { vaultSlot: 1 });
  await x.c('/api/vault/withdraw', { vaultSlot: 2 });
  await x.c('/api/vault/withdraw', { vaultSlot: 3 });
  await x.c('/api/vault/sort');
  await x.get(`/api/vault/${x.cid}`);
  // reforge
  const bag = await x.inv();
  const pieces = bag.filter((b: any) => b.instance_id !== undefined);
  await x.c('/api/reforge/quote');
  await x.c('/api/reforge', { slot_index: 'a', affix_index: 0 });
  await x.c('/api/reforge', { slot_index: 40, affix_index: 0 });
  await x.c('/api/reforge', { slot_index: bag.find((b: any) => b.instance_id === undefined)?.slot_index ?? 12, affix_index: 0 });
  await x.c('/api/character/save-progress', { level: 20, xp: 0, gold: 50, stat_str: 5, stat_agi: 5, stat_int: 5, stat_vit: 5 });
  for (const p of pieces) {
    await x.c('/api/reforge', { slot_index: p.slot_index, affix_index: 9 });
    await x.c('/api/reforge', { slot_index: p.slot_index, affix_index: 0 });
  }
  await x.c('/api/character/save-progress', { level: 20, xp: 0, gold: 5_000_000, stat_str: 5, stat_agi: 5, stat_int: 5, stat_vit: 5 });
  for (const p of pieces) {
    for (let i = 0; i < Math.max(1, p.affixes?.length ?? 0); i++) {
      await x.c('/api/reforge', { slot_index: p.slot_index, affix_index: i, expect_cost: 1 });
      await x.c('/api/reforge', { slot_index: p.slot_index, affix_index: i });
      await x.c('/api/reforge', { slot_index: p.slot_index, affix_index: i });
    }
  }
  await x.c('/api/reforge/quote');
  // boss key
  const emp = ['gravedigger', 'abbess', 'congregation', 'saint', 'regent', 'mire'];
  await x.c('/api/boss-key/status');
  await x.c('/api/boss-key/summon', { boss: 'prelate' });
  await x.c('/api/boss-key/summon', { boss: 'gravedigger' });
  await x.save([{ slot_index: 0, item_id: 'covenant_seal', quantity: 3 }, { slot_index: 1, item_id: 'ingot_copper', quantity: 5 }]);
  await x.c('/api/character/save-progress', { level: 20, xp: 0, gold: 10_000, stat_str: 5, stat_agi: 5, stat_int: 5, stat_vit: 5 });
  await x.c('/api/boss-key/summon', { boss: 'gravedigger' });
  await x.c('/api/character/save-progress', { level: 40, xp: 0, gold: 9_000_000, stat_str: 5, stat_agi: 5, stat_int: 5, stat_vit: 5 });
  await x.c('/api/boss-key/summon', { boss: 'gravedigger' });
  await x.c('/api/boss-key/status');
  await x.c('/api/boss-key/summon', { boss: 'gravedigger' });
  await x.c('/api/boss-key/claim', { boss: 'gravedigger', discipline: 'gravecaller', level: 30 });
  x.advance(11_000);
  await x.c('/api/boss-key/claim', { boss: 'abbess', discipline: 'gravecaller', level: 30 });
  await x.c('/api/boss-key/claim', { boss: 'gravedigger', discipline: 'gravecaller', level: 30 });
  await x.c('/api/boss-key/claim', { boss: 'gravedigger', discipline: 'gravecaller', level: 30 });
  await x.c('/api/boss-key/summon', { boss: 'abbess' });
  await x.c('/api/boss-key/refund', { boss: 'abbess' });
  await x.c('/api/boss-key/refund', { boss: 'abbess' });
  await x.c('/api/boss-key/summon', { boss: 'abbess' });
  x.advance(3 * 60_000);
  await x.c('/api/boss-key/refund', { boss: 'abbess' });
  x.advance(4 * 3600_000);
  await x.c('/api/boss-key/status');
  for (const boss of emp.slice(2)) {
    await x.save([{ slot_index: 0, item_id: 'covenant_seal', quantity: 3 }]);
    await x.c('/api/boss-key/summon', { boss });
    x.advance(12_000);
    await x.c('/api/boss-key/claim', { boss, discipline: ['gravecaller', 'warden', 'monk', 'mourner'][emp.indexOf(boss) % 4], level: 50 });
  }
  await x.get(`/api/inventory/${x.cid}`);
});

// ── 4. labor, garden, cosmetics, contracts ───────────────────────────────────────────────────────────────────────────────────────
await scenario('labor_garden_cosmetics_contracts', 404, T0 + 7 * 3600_000, async (x) => {
  const nodes = Object.values(NODES);
  const l1 = nodes.find((n) => n.skill === 'woodcutting' && n.level === 1)!;
  const l1m = nodes.find((n) => n.skill === 'mining' && n.level === 1)!;
  const high = nodes.find((n) => n.skill === 'mining' && n.level >= 20)!;
  const garden = nodes.find((n) => n.skill === 'gardening');
  await x.get(`/api/labor/${x.cid}`);
  await x.c('/api/labor/assign', { slot: 1, nodeType: l1.id });
  await x.c('/api/labor/assign', { slot: 0, nodeType: 'nope' });
  await x.c('/api/labor/assign', { slot: 0, nodeType: high.id });
  if (garden) await x.c('/api/labor/assign', { slot: 0, nodeType: garden.id });
  await x.c('/api/labor/collect', { slot: 0 });
  await x.c('/api/labor/assign', { slot: 0, nodeType: l1.id });
  await x.c('/api/labor/collect', { slot: 0 });
  x.advance(20 * 60_000);
  await x.c('/api/labor/collect', { slot: 0 });
  await x.c('/api/labor/assign', { slot: 0, nodeType: l1m.id });
  x.advance(3 * 3600_000);
  await x.get(`/api/labor/${x.cid}`);
  await x.c('/api/labor/assign', { slot: 0, nodeType: l1m.id });
  await x.c('/api/labor/collect', { slot: 0 });
  await x.c('/api/labor/collect', { slot: 0 });
  await x.c('/api/labor/collect', { slot: 3 });
  x.advance(12 * 3600_000);
  await x.get(`/api/labor/${x.cid}`);
  await x.save(Array.from({ length: 48 }, (_, i) => ({ slot_index: i, item_id: i % 2 ? 'sword_copper' : 'staff_oak', quantity: 1 })));
  await x.c('/api/labor/collect', { slot: 0 });
  await x.save([]);
  await x.c('/api/labor/collect', { slot: 0 });
  await x.c('/api/labor/assign', { slot: 0, nodeType: '' });
  await x.get(`/api/labor/${x.cid}`);
  // garden
  const herb = SEEDS.find((s) => s.kind === 'herb' && s.level === 1)!;
  const tree = SEEDS.find((s) => s.kind === 'tree')!;
  await x.get(`/api/garden/${x.cid}`);
  await x.c('/api/garden/plant', { plot: 'zz', seedId: herb.id });
  await x.c('/api/garden/plant', { plot: 'h0', seedId: 'nope' });
  await x.c('/api/garden/plant', { plot: 'h0', seedId: tree.id });
  await x.c('/api/garden/plant', { plot: 't0', seedId: herb.id });
  await x.c('/api/garden/plant', { plot: 'h0', seedId: herb.id });
  await x.save([{ slot_index: 0, item_id: herb.id, quantity: 5 }, { slot_index: 1, item_id: tree.id, quantity: 1 }, { slot_index: 2, item_id: 'bone_meal', quantity: 2 }]);
  await x.c('/api/garden/plant', { plot: 'h0', seedId: herb.id, compost: true });
  await x.c('/api/garden/plant', { plot: 'h0', seedId: herb.id });
  await x.c('/api/garden/plant', { plot: 'h1', seedId: herb.id });
  await x.c('/api/garden/plant', { plot: 'h2', seedId: herb.id, compost: true });
  await x.c('/api/garden/plant', { plot: 't0', seedId: tree.id });
  await x.c('/api/garden/harvest', { plot: 'h3' });
  await x.c('/api/garden/harvest', { plot: 'h0' });
  await x.get(`/api/garden/${x.cid}`);
  x.advance(16 * 60_000);
  await x.c('/api/garden/harvest', { plot: 'h0' });
  x.advance(10 * 3600_000);
  for (const plot of ['h0', 'h1', 'h2', 't0']) await x.c('/api/garden/harvest', { plot });
  await x.save(Array.from({ length: 48 }, (_, i) => ({ slot_index: i, item_id: i % 2 ? 'sword_copper' : 'staff_oak', quantity: 1 })).concat([]));
  await x.c('/api/garden/plant', { plot: 'h0', seedId: herb.id });
  await x.save([{ slot_index: 0, item_id: herb.id, quantity: 5 }, ...Array.from({ length: 47 }, (_, i) => ({ slot_index: i + 1, item_id: i % 2 ? 'sword_copper' : 'staff_oak', quantity: 1 }))]);
  await x.c('/api/garden/plant', { plot: 'h0', seedId: herb.id });
  x.advance(3600_000);
  await x.c('/api/garden/harvest', { plot: 'h0' });
  await x.get(`/api/garden/${x.cid}`);
  // cosmetics
  const capeSkill = CAPES.find((c) => (c as any).skill)!;
  await x.save([{ slot_index: 0, item_id: PETS[0].charm, quantity: 1 }, { slot_index: 1, item_id: PETS[0].charm, quantity: 1 }, { slot_index: 2, item_id: PETS[1].charm, quantity: 1 }]);
  await x.get(`/api/cosmetics/${x.cid}`);
  await x.c('/api/cosmetics/select', { cape: capeSkill.id });
  await x.c('/api/cosmetics/select', { cape: 'cape_nope' });
  await x.c('/api/cosmetics/select', { cape: null });
  await x.c('/api/cosmetics/select', { pet: PETS[0].id });
  await x.c('/api/cosmetics/adopt', { petId: 'pet_nope' });
  await x.c('/api/cosmetics/adopt', {});
  await x.c('/api/cosmetics/adopt', { petId: PETS[2].id });
  await x.c('/api/cosmetics/adopt', { petId: PETS[0].id });
  await x.c('/api/cosmetics/adopt', { petId: PETS[0].id });
  await x.c('/api/cosmetics/adopt', { petId: PETS[1].id });
  await x.c('/api/cosmetics/select', { pet: PETS[1].id });
  await x.c('/api/cosmetics/select', { pet: null, cape: null });
  await x.c('/api/cosmetics/select', {});
  await x.get(`/api/cosmetics/${x.cid}`);
  void petForCharm;
  // contracts
  const view = (await x.get(`/api/contracts/${x.cid}`)).data;
  await x.c('/api/contracts/deliver', { slot: 7 });
  await x.c('/api/contracts/deliver', { slot: 0 });
  await x.save(view.contracts.map((c: any, i: number) => ({ slot_index: i, item_id: c.itemId, quantity: Math.min(c.qty, ITEMS[c.itemId]?.stack ?? 99), })));
  const big = (c: any) => c.qty > (ITEMS[c.itemId]?.stack ?? 99);
  await x.c('/api/contracts/deliver', { slot: 0 });
  await x.c('/api/contracts/deliver', { slot: 0 });
  await x.save([...view.contracts.map((c: any, i: number) => ({ slot_index: i * 2, item_id: c.itemId, quantity: Math.min(c.qty, ITEMS[c.itemId]?.stack ?? 99) })), ...view.contracts.map((c: any, i: number) => ({ slot_index: i * 2 + 1, item_id: c.itemId, quantity: big(c) ? c.qty - (ITEMS[c.itemId]?.stack ?? 99) : 0 }))]);
  for (const slot of [1, 2, 0]) await x.c('/api/contracts/deliver', { slot });
  await x.get(`/api/contracts/${x.cid}`);
  x.advance(24 * 3600_000);
  const v2 = (await x.get(`/api/contracts/${x.cid}`)).data;
  await x.save(v2.contracts.map((c: any, i: number) => ({ slot_index: i * 2, item_id: c.itemId, quantity: Math.min(c.qty, ITEMS[c.itemId]?.stack ?? 99) })));
  await x.c('/api/contracts/deliver', { slot: 0 });
  x.advance(25 * 3600_000);
  await x.get(`/api/contracts/${x.cid}`);
  x.advance(5 * 24 * 3600_000);
  await x.get(`/api/contracts/${x.cid}`);
});

// ── 5. necromancer progression ───────────────────────────────────────────────────────────────────────────────────────────────────
await scenario('necro', 505, T0, async (x) => {
  const asc = await import('../../server/rules/content/ascension');
  const { AREAS } = await import('../../server/rules/content/areas');
  const progress = async () => (await x.get(`/api/necro-progress/${x.cid}`)).data.progress;
  const gold = (g: number) => x.c('/api/character/save-progress', { level: 30, xp: 0, gold: g, stat_str: 5, stat_agi: 5, stat_int: 5, stat_vit: 5 });
  await progress();
  await x.c('/api/necro-progress/purchase', { upgrade: 'damage' });
  await x.c('/api/necro-progress/purchase', { upgrade: 'nope' });
  await x.c('/api/necro-progress/purchase', {});
  await gold(400);
  await x.c('/api/necro-progress/purchase', { upgrade: 'damage' });
  await gold(50_000_000);
  for (const up of ['damage', 'wave', 'legion', 'damage', 'wave', 'legion', 'wave']) await x.c('/api/necro-progress/purchase', { upgrade: up });
  for (let i = 0; i < 14; i++) for (const up of ['damage', 'wave', 'legion']) await x.c('/api/necro-progress/purchase', { upgrade: up });
  await x.c('/api/necro-progress/summon-prelate');
  await x.c('/api/necro-progress/summon-boss', { boss: 'nope' });
  await x.c('/api/necro-progress/summon-boss', { boss: 'prelate' });
  await x.c('/api/necro-progress/summon-boss', { boss: 'gravedigger' });
  await x.c('/api/necro-progress/vows', { vows: { nope: 3 } });
  await x.c('/api/necro-progress/vows', { vows: 'x' });
  await x.c('/api/necro-progress/unlock', { key: 'nope' });
  await x.c('/api/necro-progress/unlock', {});
  await x.c('/api/necro-progress/unlock', { key: 'vow:nope' });
  await x.c('/api/necro-progress/boon', { boonId: 'nope' });
  await x.c('/api/necro-progress/boon', {});
  await x.c('/api/necro-progress/ascend');
  // earn kills so the seals open down the chain, and soul shards
  for (let i = 0; i < 40; i++) {
    const pr = await progress();
    if (pr.unlockedAreas.includes('sanctum') && pr.unlockedAreas.includes('pyre') && pr.unlockedAreas.includes('fen')) break;
    const kills: Record<string, number> = {};
    const open = pr.unlockedAreas.filter((a: string) => !(AREAS as any)[a].safe);
    kills[open[i % open.length]] = 900;
    await x.c('/api/necro-progress/save', { areaKills: kills, shards: 30, peakWaveTier: 3, waveTierActive: 2 });
  }
  await x.c('/api/necro-progress/save', { areaKills: { chapterhouse: 50, fen: 50 }, shards: 'many', prelateKills: 4, peakWaveTier: 99, waveTierActive: 99 });
  for (let i = 0; i < 140; i++) await x.c('/api/necro-progress/save', { shards: 30 });
  await progress();
  // the Altar: unlock vows and boons for shards
  const keys = [...asc.VOW_ORDER.map((v: string) => `vow:${v}`), ...asc.BOON_ORDER.map((b: string) => `boon:${b}`)];
  for (const k of keys) await x.c('/api/necro-progress/unlock', { key: k });
  for (const k of keys.slice(0, 4)) await x.c('/api/necro-progress/unlock', { key: k });
  // area bosses
  for (const b of Object.keys(BOSSES)) await x.c('/api/necro-progress/summon-boss', { boss: b });
  // vows, runs, ascensions, boons
  await x.c('/api/necro-progress/vows', { vows: { [asc.VOW_ORDER[0]]: 99 } });
  await x.c('/api/necro-progress/vows', { vows: Object.fromEntries(asc.VOW_ORDER.map((v: string) => [v, 1])) });
  await x.c('/api/necro-progress/vows', { vows: Object.fromEntries(asc.VOW_ORDER.slice(0, 3).map((v: string) => [v, 2])) });
  for (let run = 0; run < 7; run++) {
    await x.c('/api/necro-progress/summon-prelate');
    await x.c('/api/necro-progress/save', { prelateKills: 1, peakWaveTier: 1 + run, areaKills: { graves: 10 + run } });
    await x.c('/api/necro-progress/ascend');
    await x.c('/api/necro-progress/ascend');
    for (const id of asc.BOON_ORDER) await x.c('/api/necro-progress/boon', { boonId: id });
    await x.c('/api/necro-progress/vows', { vows: Object.fromEntries(asc.VOW_ORDER.slice(0, 1 + run).map((v: string) => [v, 1 + (run % 3)])) });
    await progress();
  }
  await x.c('/api/necro-progress/vows', { vows: {} });
  await progress();
  await x.c('/api/necro-progress/import', { record: { areaKills: { graves: 99999999 }, bossKills: 4, totalKills: 10, ascension: 2, damageTier: 9 } });
  await x.c('/api/necro-progress/import', { record: 'garbage' });
  await x.c('/api/necro-progress/save', { areaKills: { graves: 3 }, shards: 5, waveTierActive: 99 });
  await progress();
});

// ── 6. loadouts ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────
await scenario('loadouts', 606, T0, async (x) => {
  const rite0 = RUNE_RITES[0];
  const rite1 = RUNE_RITES[1];
  const rune0 = runeFor(rite0)[0];
  const rune1 = runeFor(rite1)[0];
  await x.save([{ slot_index: 0, item_id: twoHanded, quantity: 1 }, { slot_index: 1, item_id: oneHanded, quantity: 1 }, { slot_index: 2, item_id: offhand, quantity: 1 },
    { slot_index: 3, item_id: rune0, quantity: 2 }, { slot_index: 4, item_id: rune1, quantity: 1 }]);
  const keys = ['a', 'b', 'c', 'd', 'e'];
  const good = (name: string, extra: Record<string, unknown> = {}) => ({ name, rites: { primary: 'bone_needle', keys }, runes: { [rite0]: rune0 }, weapon: { itemId: twoHanded, instanceId: null }, offhand: null, ...extra });
  await x.get(`/api/loadouts/${x.cid}`);
  await x.c('/api/loadouts/save', { slot: 9, preset: good('x') });
  await x.c('/api/loadouts/save', { slot: '1', preset: good('x') });
  await x.c('/api/loadouts/save', { slot: 0, preset: null });
  await x.c('/api/loadouts/save', { slot: 0, preset: good('  \u0001 ') });
  await x.c('/api/loadouts/save', { slot: 0, preset: good('ok', { rites: { primary: 'Bad Id', keys } }) });
  await x.c('/api/loadouts/save', { slot: 0, preset: good('ok', { rites: { primary: 'bone_needle', keys: ['a', 'a', 'c', 'd', 'e'] } }) });
  await x.c('/api/loadouts/save', { slot: 0, preset: good('ok', { rites: { primary: 'bone_needle', keys: ['a', 'b'] } }) });
  await x.c('/api/loadouts/save', { slot: 0, preset: good('ok', { runes: [1] }) });
  await x.c('/api/loadouts/save', { slot: 0, preset: good('ok', { runes: { [rite0]: rune1 } }) });
  await x.c('/api/loadouts/save', { slot: 0, preset: good('ok', { runes: { nonsense: rune1 } }) });
  await x.c('/api/loadouts/save', { slot: 0, preset: good('ok', { weapon: 'sword' }) });
  await x.c('/api/loadouts/save', { slot: 0, preset: good('ok', { weapon: { itemId: 'Bad Id' } }) });
  await x.c('/api/loadouts/save', { slot: 0, preset: good('ok', { weapon: { itemId: twoHanded, instanceId: -3 } }) });
  await x.c('/api/loadouts/save', { slot: 0, preset: good('  The   <Grave>\tWarden of the long name that goes on and on  ') });
  await x.c('/api/loadouts/save', { slot: 2, preset: good('Hands', { offhand: { itemId: offhand }, weapon: { itemId: oneHanded }, runes: { [rite0]: rune0, [rite1]: rune1 } }) });
  await x.c('/api/loadouts/save', { slot: 3, preset: good('Missing', { weapon: { itemId: head }, offhand: { itemId: offhand2 }, runes: {} }) });
  await x.c('/api/loadouts/save', { slot: 4, preset: good('WrongSlot', { weapon: { itemId: offhand }, runes: { [rite0]: null } }) });
  await x.get(`/api/loadouts/${x.cid}`);
  await x.c('/api/loadouts/apply', { slot: 5 });
  await x.c('/api/loadouts/apply', { slot: 0 });
  await x.c('/api/loadouts/apply', { slot: 0 });
  await x.c('/api/loadouts/apply', { slot: 2 });
  await x.c('/api/loadouts/apply', { slot: 2 });
  await x.c('/api/loadouts/apply', { slot: 3 });
  await x.c('/api/loadouts/apply', { slot: 4 });
  await x.c('/api/loadouts/apply', { slot: 0 });
  await x.c('/api/loadouts/apply', { slot: 7 });
  await x.c('/api/loadouts/delete', { slot: 0 });
  await x.c('/api/loadouts/delete', { slot: 8 });
  await x.get(`/api/loadouts/${x.cid}`);
  // a full bag: swapping a worn piece for a bag piece needs room only if more than one piece is displaced
  await x.save(Array.from({ length: 48 }, (_, i) => ({ slot_index: i, item_id: i === 0 ? twoHanded : i === 1 ? oneHanded : i === 2 ? offhand : 'sword_copper', quantity: 1 })));
  await x.c('/api/loadouts/apply', { slot: 2 });
  await x.get(`/api/inventory/${x.cid}`);
});

// ── 7. account: chronicle, bug reports, discipline, character ───────────────────────────────────────────────────────────────────────
await scenario('account', 707, T0, async (x) => {
  await x.post('/character/discipline', { characterId: x.cid, class_index: 12 });
  await x.post('/character/discipline', { characterId: x.cid, class_index: 'x' });
  await x.post('/character/discipline', { characterId: x.cid + 4, class_index: 6 });
  await x.post('/character/discipline', { characterId: x.cid, class_index: 6 });
  await x.call('GET', '/character');
  await x.call('POST', '/character', { class_index: 1 });
  await x.get(`/api/chronicle/${x.cid}`);
  await x.c('/api/chronicle/add', { deltas: { kills: 3.9, 'peak.x': -4, junk: 'zz' }, maxes: { 'peak.depth': 4, 'peak.neg': -3 } });
  await x.c('/api/chronicle/add', { deltas: { kills: 2 }, maxes: { 'peak.depth': 2 } });
  await x.c('/api/chronicle/add', {});
  await x.get(`/api/chronicle/${x.cid}`);
  x.advance(5000);
  await x.c('/api/chronicle/ascend', { ascension: 2 });
  await x.c('/api/chronicle/ascend', { ascension: 2 });
  await x.c('/api/chronicle/add', { deltas: { kills: 1 } });
  x.advance(5000);
  await x.c('/api/chronicle/ascend', {});
  await x.get(`/api/chronicle/${x.cid}`);
  await x.post('/api/bug-reports', { category: 'ui', message: 'short' });
  await x.post('/api/bug-reports', { category: 'ui', message: '   the inventory button is far too small   ' });
  await x.post('/api/bug-reports', { message: 'x'.repeat(2500) });
  await x.get('/api/bug-reports/mine');
  await x.c('/api/nope', {});
  await x.call('GET', '/api/nope');
  await x.call('POST', '/api/inventory/save', { characterId: x.cid + 1, slots: [] });
});

mkdirSync('godot/tests/offline/fixtures', { recursive: true });
writeFileSync('godot/tests/offline/fixtures/offline.json', JSON.stringify({ scenarios }) + '\n');
const total = scenarios.reduce((n, s) => n + s.steps.length, 0);
const errs = scenarios.reduce((n, s) => n + s.steps.filter((p) => p.thrown || (p.res as any)?.success === false).length, 0);
console.log(`offline fixtures: ${scenarios.length} scenarios, ${total} steps (${errs} refusals)`);
for (const s of scenarios) console.log(`  ${s.name}: ${s.steps.length} steps, ${s.steps.filter((p) => p.thrown || (p.res as any)?.success === false).length} refusals`);
process.exit(0);
