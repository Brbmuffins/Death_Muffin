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

/** The starter oak, and the deepest woodcutting post (a node nobody has the level for yet). */
const OAK = rules.NODES.coffin_oak;
const WOODCUTTING = Object.values(rules.NODES).filter((n) => n.skill === 'woodcutting');
const DEEP = WOODCUTTING.reduce((a, b) => (b.level > a.level ? b : a));
/** The tool of a given tier for a skill (tier 1 = the first metal). */
const tool = (skill, tier) => rules.toolItemId(skill, tier);

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
  assert.equal(r.json.data.xp, OAK.xp * 3);
  const logs = r.json.data.items.find((g) => g.itemId === OAK.item);
  assert.equal(logs.qty, 3);
  assert.equal(char().bag.find((b) => b.itemId === OAK.item).qty, 3);
  assert.deepEqual(char().skills.woodcutting, { level: 1, xp: OAK.xp * 3 });
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
  const r = await call({ nodeType: DEEP.id, actions: 2 });
  assert.equal(r.status, 400);
  assert.equal(r.json.error, `Requires Woodcutting level ${DEEP.level}`);
  assert.equal(char().bag.length, 0, 'nothing written');
});

test('the time budget clamps claimed actions and refuses an empty window', async () => {
  const { call, tick } = harness();
  const ms = rules.actionMs(OAK);
  // One window of credit (GATHER_MAX_WINDOW_MS worth of actions) plus the burst.
  const window = Math.floor(rules.GATHER_MAX_WINDOW_MS / ms) + rules.GATHER_BURST;
  const first = await call({ nodeType: OAK.id, actions: rules.GATHER_MAX_BATCH });
  assert.equal(first.json.data.accepted, Math.min(rules.GATHER_MAX_BATCH, window));
  const again = await call({ nodeType: OAK.id, actions: rules.GATHER_MAX_BATCH });
  assert.equal(again.json.data.accepted, rules.GATHER_BURST, 'no time passed: burst only');
  const earned = Math.max(1, Math.min(4, Math.floor(rules.GATHER_MAX_WINDOW_MS / ms))); // a few actions' worth, inside one window
  tick(ms * earned);
  const later = await call({ nodeType: OAK.id, actions: rules.GATHER_MAX_BATCH });
  assert.equal(later.json.data.accepted, earned + rules.GATHER_BURST);
  tick(60 * 60 * 1000); // an hour idle earns only one window, not an hour
  const idle = await call({ nodeType: OAK.id, actions: rules.GATHER_MAX_BATCH });
  assert.equal(idle.json.data.accepted, Math.min(rules.GATHER_MAX_BATCH, window));
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
  // one find short of the next level: the oak's XP carries her over, with one point to spare
  const { call } = harness({ char: { skills: { woodcutting: { level: 1, xp: rules.xpToNext(1) - OAK.xp + 1 } } } });
  const r = await call({ nodeType: OAK.id, actions: 1 });
  assert.equal(r.json.data.leveledUp, true);
  assert.deepEqual(r.json.data.skills[0], { profession_id: 'woodcutting', skill_level: 2, skill_xp: 1 });
});

test('a full bag rejects what does not fit but still grants XP', async () => {
  // the log stack has room for one more (the harness gives every material a 250 stack)
  const bag = Array.from({ length: rules.BAG_SLOTS }, (_, i) => ({ slot: i, itemId: i === 0 ? OAK.item : 'staff_oak', qty: i === 0 ? 249 : 1 }));
  const { call, char } = harness({ char: { bag } });
  const r = await call({ nodeType: OAK.id, actions: 3 });
  assert.equal(r.status, 200);
  assert.deepEqual(r.json.data.items.find((g) => g.itemId === OAK.item), { itemId: OAK.item, qty: 1 });
  assert.equal(r.json.data.rejected.find((g) => g.itemId === OAK.item).qty, 2);
  assert.equal(char().bag[0].qty, 250);
  assert.equal(char().skills.woodcutting.xp, OAK.xp * 3);
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
  // Gathering, gardening, cosmetics, reagent and Fen ids all need matching migration rows.
  const sql = ['002-gathering.sql', '007-gardening.sql', '010-cosmetics.sql', '014-alchemy-reagents.sql', '015-fen.sql'].map((f) => readFileSync(join(__dirname, '../migrations', f), 'utf8')).join('\n');
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
  assert.equal((await h.call({ nodeType: DEEP.id }, 'startAfk')).status, 400);
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
  assert.equal((await call({ nodeType: DEEP.id, actions: 2 }, false)).status, 400, 'a normal account is still gated');
  const r = await call({ nodeType: DEEP.id, actions: 2 }, true);
  assert.equal(r.status, 200);
  assert.equal(r.json.data.successes, 2, 'rolls as if at the node level');
  assert.equal(r.json.data.skills[0].skill_level > 1, true, 'real XP on the real level');
  const burst = await call({ nodeType: DEEP.id, actions: rules.GATHER_MAX_BATCH }, true);
  assert.equal(burst.json.data.accepted, rules.GATHER_BURST, 'the time budget still clamps staff');
});

test('tools on the belt count like tools in the bag: the best of belt and bag wins', async () => {
  const tier = async (char) => (await harness({ char }).call({ nodeType: 'coffin_oak', actions: 1 })).json.data.toolTier;
  const top = rules.TOOL_METALS.length;
  const [low, mid, high] = [1, 2, top];
  assert.equal(await tier({}), 0);
  assert.equal(await tier({ belt: [tool('woodcutting', mid)] }), mid);
  assert.equal(await tier({ bag: [{ slot: 0, itemId: tool('woodcutting', low), qty: 1 }] }), low);
  assert.equal(await tier({ belt: [tool('woodcutting', low)], bag: [{ slot: 0, itemId: tool('woodcutting', high), qty: 1 }] }), high, 'a better bag tool still wins');
  assert.equal(await tier({ belt: [tool('woodcutting', high)], bag: [{ slot: 0, itemId: tool('woodcutting', low), qty: 1 }] }), high);
  assert.equal(await tier({ belt: [tool('mining', high)] }), 0, 'another kind of tool does nothing');
});

test('a belt tool also counts for AFK gathering and takes no bag space', async () => {
  const bag = Array.from({ length: rules.BAG_SLOTS }, (_, i) => ({ slot: i, itemId: i === 0 ? 'log_oak' : 'staff_oak', qty: i === 0 ? 10 : 1 }));
  const tier = rules.TOOL_METALS.length - 1;
  const h = harness({ char: { belt: [tool('woodcutting', tier)], bag } });
  await h.call({ nodeType: 'coffin_oak' }, 'startAfk');
  h.tick(60000);
  const r = await h.call({ nodeType: 'coffin_oak', actions: 2, afk: true });
  assert.equal(r.json.data.toolTier, tier);
  assert.equal(h.char().bag.length, rules.BAG_SLOTS, 'the belt is not part of the bag');
});
