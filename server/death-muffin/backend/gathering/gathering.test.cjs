'use strict';
// node --test server/death-muffin/backend/gathering/gathering.test.cjs
// Exercises POST /api/gather against the in-memory store (no Express, no MySQL).
const test = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const rules = require('./gathering-rules.cjs');
const { createGatherHandlers } = require('./gathering-routes.cjs');
const { createMemoryGatherStore } = require('./gather-store.cjs');

/** Every grantable id with the stack size migration 002 gives it (gear = 1). */
const GEAR = new Set(['ring_copper', 'helm_gold', 'chest_iron', 'kit_iron_warden']);
const ITEMS = Object.fromEntries(rules.grantableItems().map((id) => [id, GEAR.has(id) ? 1 : 250]));

function harness({ owner = true, char = {}, items = ITEMS, rng = () => 0 } = {}) {
  let clock = 1_000_000;
  const store = createMemoryGatherStore({ characters: { 7: char }, items });
  const h = createGatherHandlers({ store, ownsCharacter: async (_req, id) => owner && id === 7, logger: { error() {} }, now: () => clock, rng, perMinute: 1000 });
  const call = async (body, method = 'gather') => {
    let status = 0;
    let json = null;
    const res = { status: (s) => ((status = s), res), json: (j) => ((json = j), res) };
    await h[method]({ body: { characterId: 7, ...body } }, res);
    return { status, json };
  };
  return { store, call, tick: (ms) => (clock += ms), char: () => store._chars.get(7) };
}

test('a batch rolls items and XP server-side and stores them in the bag', async () => {
  const { call, char } = harness(); // rng 0 → every roll succeeds, every extra hits
  const r = await call({ nodeType: 'coffin_oak', actions: 3 });
  assert.equal(r.status, 200);
  assert.equal(r.json.data.accepted, 3);
  assert.equal(r.json.data.successes, 3);
  assert.equal(r.json.data.xp, 18);
  const logs = r.json.data.items.find((g) => g.itemId === 'log_oak');
  assert.equal(logs.qty, 3);
  assert.equal(char().bag.find((b) => b.itemId === 'log_oak').qty, 3);
  assert.deepEqual(char().skills.woodcutting, { level: 1, xp: 18 });
});

test('ownership, ids and node names are enforced', async () => {
  assert.equal((await harness({ owner: false }).call({ nodeType: 'coffin_oak', actions: 1 })).status, 403);
  const h = harness();
  assert.equal((await h.call({ characterId: 'x', nodeType: 'coffin_oak', actions: 1 })).status, 400);
  const bad = await h.call({ nodeType: 'money_tree', actions: 1 });
  assert.equal(bad.status, 400);
  assert.equal(bad.json.error, 'Unknown gathering node');
  assert.equal((await h.call({ nodeType: 'coffin_oak', actions: 0 })).status, 400);
});

test('the skill level gates the node with a readable error', async () => {
  const { call, char } = harness();
  const r = await call({ nodeType: 'churchyard_yew', actions: 2 });
  assert.equal(r.status, 400);
  assert.equal(r.json.error, 'Requires Woodcutting level 45');
  assert.equal(char().bag.length, 0, 'nothing written');
});

test('the time budget clamps claimed actions and refuses an empty window', async () => {
  const { call, tick } = harness();
  const first = await call({ nodeType: 'coffin_oak', actions: 40 });
  // First batch: one 30 s window of credit (30000 / 2400 = 12) + burst 3.
  assert.equal(first.json.data.accepted, 15);
  const again = await call({ nodeType: 'coffin_oak', actions: 40 });
  assert.equal(again.json.data.accepted, 3, 'no time passed: burst only');
  tick(9600); // four actions' worth
  const later = await call({ nodeType: 'coffin_oak', actions: 40 });
  assert.equal(later.json.data.accepted, 4 + 3);
  tick(60 * 60 * 1000); // an hour idle earns only one window, not an hour
  const idle = await call({ nodeType: 'coffin_oak', actions: 40 });
  assert.equal(idle.json.data.accepted, 15);
});

test('the hourly ledger caps actions and rolls over', async () => {
  const { call, tick, char } = harness({ char: { ledger: { lastAt: 1, hourStart: 1_000_000, hourActions: rules.GATHER_MAX_ACTIONS_PER_HOUR } } });
  const spent = await call({ nodeType: 'coffin_oak', actions: 5 });
  assert.equal(spent.status, 400);
  assert.match(spent.json.error, /spent for this hour/);
  tick(3_600_000);
  const fresh = await call({ nodeType: 'coffin_oak', actions: 5 });
  assert.equal(fresh.status, 200);
  assert.equal(char().ledger.hourActions, 5);
  assert.equal(char().ledger.hourStart, 1_000_000 + 3_600_000);
});

test('levels roll over mid-batch and the reply carries the new level', async () => {
  const { call } = harness({ char: { skills: { woodcutting: { level: 1, xp: 45 } } } });
  const r = await call({ nodeType: 'coffin_oak', actions: 1 });
  assert.equal(r.json.data.leveledUp, true);
  assert.deepEqual(r.json.data.skills[0], { profession_id: 'woodcutting', skill_level: 2, skill_xp: 1 });
});

test('a full bag rejects what does not fit but still grants XP', async () => {
  const bag = Array.from({ length: 24 }, (_, i) => ({ slot: i, itemId: i === 0 ? 'log_oak' : 'staff_oak', qty: i === 0 ? 249 : 1 }));
  const { call, char } = harness({ char: { bag } });
  const r = await call({ nodeType: 'coffin_oak', actions: 3 });
  assert.equal(r.status, 200);
  assert.deepEqual(r.json.data.items.find((g) => g.itemId === 'log_oak'), { itemId: 'log_oak', qty: 1 });
  assert.equal(r.json.data.rejected.find((g) => g.itemId === 'log_oak').qty, 2);
  assert.equal(char().bag[0].qty, 250);
  assert.equal(char().skills.woodcutting.xp, 18);
});

test('gravedigging pays gold into the character', async () => {
  const { call, char } = harness();
  const r = await call({ nodeType: 'grave_pauper', actions: 2 });
  assert.equal(r.json.data.gold, 0, 'rng 0 rolls the minimum');
  const rich = harness({ rng: (() => { let i = 0; return () => ((i++ % 3 === 2) ? 0.99 : 0); })() });
  const r2 = await rich.call({ nodeType: 'grave_pauper', actions: 3 });
  assert.ok(r2.json.data.gold >= 0);
  assert.equal(rich.char().gold, r2.json.data.gold);
  assert.equal(char().gold, 0);
});

test('an item missing from the server items table fails the whole batch', async () => {
  const { call, char } = harness({ items: { log_oak: 250 } });
  const r = await call({ nodeType: 'coffin_oak', actions: 2 }); // rng 0 → crow's nest seed too
  assert.equal(r.status, 400);
  assert.match(r.json.error, /not available/);
  assert.equal(char().bag.length, 0);
  assert.equal(char().ledger.lastAt, 0, 'ledger untouched');
});

test('a migration inserts every grantable id that is not already live', () => {
  // 002 adds the gathering items; 007 the garden seeds and saplings, and 010 the pet charms that nodes now drop, 015 the Mourning Fen herbs.
  const sql = ['002-gathering.sql', '007-gardening.sql', '010-cosmetics.sql', '015-fen.sql'].map((f) => readFileSync(join(__dirname, '../migrations', f), 'utf8')).join('\n');
  const live = new Set(['log_oak', 'fish_river', 'ore_copper', 'ore_tin', 'ore_iron', 'ore_bronze', 'ore_silver', 'ore_gold', 'ore_steel', 'ore_hell', 'ore_moon', ...GEAR]);
  for (const id of rules.grantableItems()) {
    if (live.has(id)) continue;
    assert.match(sql, new RegExp(`\\('${id}',`), `${id} missing from the migrations`);
  }
});


test('AFK requires a start and cannot grant instant or repeated free cycles', async () => {
  const h = harness();
  assert.equal((await h.call({ nodeType: 'coffin_oak', actions: 40, afk: true })).status, 400);
  assert.equal((await h.call({ nodeType: 'coffin_oak' }, 'startAfk')).status, 200);
  assert.equal((await h.call({ nodeType: 'coffin_oak', actions: 40, afk: true })).status, 400);
  h.tick(rules.actionMs(rules.NODES.coffin_oak) * 3);
  const earned = await h.call({ nodeType: 'coffin_oak', actions: 40, afk: true });
  assert.equal(earned.json.data.accepted, 3);
  assert.equal((await h.call({ nodeType: 'coffin_oak', actions: 40, afk: true })).status, 400);
});

test('AFK accepts a background minute in batches without losing remaining earned time', async () => {
  const h = harness();
  await h.call({ nodeType: 'coffin_oak' }, 'startAfk');
  h.tick(60000);
  const first = await h.call({ nodeType: 'coffin_oak', actions: 3, afk: true });
  const rest = await h.call({ nodeType: 'coffin_oak', actions: 40, afk: true });
  assert.equal(first.json.data.accepted + rest.json.data.accepted, Math.floor(60000 / rules.actionMs(rules.NODES.coffin_oak)));
});

test('AFK starts check ownership, level and preserve the hourly limit', async () => {
  assert.equal((await harness({ owner: false }).call({ nodeType: 'coffin_oak' }, 'startAfk')).status, 403);
  const h = harness({ char: { ledger: { lastAt: 1, hourStart: 1000000, hourActions: rules.GATHER_MAX_ACTIONS_PER_HOUR } } });
  assert.equal((await h.call({ nodeType: 'bone_elder' }, 'startAfk')).status, 400);
  await h.call({ nodeType: 'coffin_oak' }, 'startAfk');h.tick(60000);
  assert.equal((await h.call({ nodeType: 'coffin_oak', actions: 40, afk: true })).status, 400);
  assert.equal(h.char().ledger.hourActions, rules.GATHER_MAX_ACTIONS_PER_HOUR);
});

test('staff skip the level gate (only): budget still applies, XP lands on the real level', async () => {
  const store = createMemoryGatherStore({ characters: { 7: {} }, items: ITEMS });
  let clock = 1_000_000;
  const h = createGatherHandlers({ store, ownsCharacter: async () => true, isStaff: async (req) => req.staff === true, logger: { error() {} }, now: () => clock, rng: () => 0, perMinute: 1000 });
  const call = async (body, staff) => {
    let status = 0;
    let json = null;
    const res = { status: (s) => ((status = s), res), json: (j) => ((json = j), res) };
    await h.gather({ body: { characterId: 7, ...body }, staff }, res);
    return { status, json };
  };
  assert.equal((await call({ nodeType: 'bone_elder', actions: 2 }, false)).status, 400, 'a normal account is still gated');
  const r = await call({ nodeType: 'bone_elder', actions: 2 }, true);
  assert.equal(r.status, 200);
  assert.equal(r.json.data.successes, 2, 'rolls as if at the node level');
  assert.equal(r.json.data.skills[0].skill_level > 1, true, 'real XP on the real level');
  const burst = await call({ nodeType: 'bone_elder', actions: 40 }, true);
  assert.equal(burst.json.data.accepted, rules.GATHER_BURST, 'the time budget still clamps staff');
});
