// Run: node --test server/death-muffin/backend/server-routes.test.cjs
// Routes defined in server.js itself, called through server-harness.cjs (no database, no socket).
const test = require('node:test');
const assert = require('node:assert');
const { loadServer } = require('./server-harness.cjs');

/** A pool that knows one account (id 1) owning one character (id 1) and logs every statement that reaches a connection. */
function fakePool({ onQuery, character = {} } = {}) {
  const log = [];
  const owned = { id: 1, account_id: 1, level: 5, experience: 10, gold: 100, stat_str: 5, stat_agi: 5, stat_int: 5, stat_vit: 10, ...character };
  const run = async (sql, params = []) => {
    log.push({ sql, params });
    if (onQuery) { const r = await onQuery(sql, params); if (r !== undefined) return r; }
    return [[]];
  };
  const base = async (sql, params = []) => {
    if (/FROM characters WHERE id = \? AND account_id = \?/.test(sql)) return params[0] === 1 && params[1] === 1 ? [[owned]] : [[]];
    if (/FROM accounts WHERE id/.test(sql)) return [[{ role: 'player', gm_enabled: 0 }]];
    return run(sql, params);
  };
  const conn = { execute: run, query: run, beginTransaction: async () => {}, commit: async () => {}, rollback: async () => {}, release: () => {} };
  return { log, owned, pool: { execute: base, query: base, getConnection: async () => conn } };
}

test('craft works on the character that ownership was proven for, not on the raw request value', async () => {
  // parseInt("1e1") is 1 (the caller's own character) but MySQL reads the string '1e1' as 10: another player's bag.
  const f = fakePool({
    onQuery: (sql) => {
      if (/FROM recipes r JOIN items/.test(sql)) return [[{ id: 'r1', profession_id: 'mining', skill_level_required: 1, result_item_id: 'copper_bar', result_quantity: 1, recipe_type: 'craft', stackable: 1, max_stack_size: 250 }]];
      if (/FROM professions WHERE character_id/.test(sql)) return [[{ skill_level: 5 }]];
      if (/FROM recipe_ingredients/.test(sql)) return [[{ item_id: 'copper_shard', quantity: 2, name: 'Copper Shard' }]];
    },
  });
  const srv = loadServer({ pool: f.pool });
  const r = await srv.call('POST /api/craft', { body: { characterId: '1e1', recipeId: 'r1' } });
  assert.equal(r.json.success, false, 'no ingredients in the bag, so the craft is refused');
  const touched = f.log.filter((q) => /character_id/.test(q.sql)).map((q) => q.params[0]);
  assert.ok(touched.length >= 2, 'the craft reached the profession and inventory queries');
  assert.deepEqual([...new Set(touched)], [1], 'every query used the verified numeric character id');
});

// ── POST /api/gold/adjust ───────────────────────────────────────────────────────────────────────────────────────────────

/** A pool whose characters row holds `gold`, with a staff flag on the account; records UPDATEs. */
function goldPool({ gold = 100, staff = false } = {}) {
  const state = { gold, updates: [] };
  const f = fakePool({
    character: { gold },
    onQuery: (sql, params) => {
      if (/FROM accounts WHERE id/.test(sql)) return [[{ role: staff ? 'gm' : 'player', gm_enabled: 0 }]];
      if (/SELECT gold FROM characters/.test(sql)) return [[{ gold: state.gold }]];
      if (/UPDATE characters SET gold/.test(sql)) { state.gold = params[0]; state.updates.push(params[0]); return [{ affectedRows: 1 }]; }
    },
  });
  // fakePool answers accounts lookups itself before onQuery; route them through it for this test.
  const inner = f.pool.execute;
  f.pool.execute = async (sql, params) => (/FROM accounts WHERE id/.test(sql) ? [[{ role: staff ? 'gm' : 'player', gm_enabled: 0 }]] : inner(sql, params));
  return { ...f, state };
}

test('gold/adjust: a player cannot credit gold to themselves', async () => {
  const g = goldPool({ gold: 100 });
  const r = await loadServer({ pool: g.pool }).call('POST /api/gold/adjust', { body: { characterId: 1, amount: 1_000_000 } });
  assert.equal(r.status, 403);
  assert.equal(r.json.success, false);
  assert.deepEqual(g.state.updates, [], 'nothing was written');
});

test('gold/adjust: staff may credit, anyone may spend, nobody can go below zero or past the column', async () => {
  const staff = goldPool({ gold: 100, staff: true });
  const srv = loadServer({ pool: staff.pool });
  assert.equal((await srv.call('POST /api/gold/adjust', { body: { characterId: 1, amount: 50 } })).json.data.gold, 150);
  assert.equal((await srv.call('POST /api/gold/adjust', { body: { characterId: 1, amount: -30 } })).json.data.gold, 120);
  const broke = await srv.call('POST /api/gold/adjust', { body: { characterId: 1, amount: -500 } });
  assert.equal(broke.status, 400);
  assert.match(broke.json.error, /insufficient funds \(have 120, need 500\)/);
  const over = await srv.call('POST /api/gold/adjust', { body: { characterId: 1, amount: 2_147_483_600 } });
  assert.equal(over.status, 400);
  assert.equal(staff.state.gold, 120, 'a refused adjustment changes nothing');

  const player = goldPool({ gold: 100 });
  const spent = await loadServer({ pool: player.pool }).call('POST /api/gold/adjust', { body: { characterId: 1, amount: -40 } });
  assert.equal(spent.json.data.gold, 60, 'spending is open to everyone');
});

// ── POST /api/character/save-progress ───────────────────────────────────────────────────────────────────────────────────

test('save-progress: a null, blank or non-numeric field keeps the stored value instead of zeroing it', async () => {
  // JSON.stringify turns a NaN into null, and Number(null) / Number('') / Number([]) are all 0.
  const f = fakePool({ character: { level: 7, experience: 42, gold: 900, stat_str: 6 }, onQuery: (sql) => {
    if (/^SELECT \* FROM characters WHERE id = \?$/.test(sql)) return [[{ ...f.owned }]];
    if (/^UPDATE characters SET level/.test(sql)) return [{ affectedRows: 1 }];
  } });
  const srv = loadServer({ pool: f.pool });
  const r = await srv.call('POST /api/character/save-progress', { body: { characterId: 1, level: 7, xp: null, gold: '', stat_str: [], stat_agi: false, stat_int: 'abc' } });
  assert.equal(r.json.success, true);
  const update = f.log.find((q) => /^UPDATE characters SET level/.test(q.sql));
  // level, experience, gold, str, agi, int, vit, id
  assert.deepEqual(update.params, [7, 42, 900, 6, 5, 5, 10, 1]);
});

// ── legacy loot routes: a full bag stays full ───────────────────────────────────────────────────────────────────────────

/** Bag slots 0-47 full, plus a worn helmet in 100 and a belt tool in 110; the next "free" index past the bag must NOT be used. */
const fullBag = () => [...Array.from({ length: 48 }, (_, i) => ({ slot_index: i })), { slot_index: 100 }, { slot_index: 110 }];

test('loot/drop: a full bag drops nothing instead of writing past the bag into the reserved slots', async () => {
  const f = fakePool({ onQuery: (sql) => {
    if (/FROM loot_tables/.test(sql)) return [[{ new_item_id: 'copper_bar', weight: 1, min_quantity: 1, max_quantity: 1 }]];
    if (/SELECT slot_index FROM inventory/.test(sql)) return [fullBag()];
  } });
  const r = await loadServer({ pool: f.pool }).call('POST /api/loot/drop', { body: { characterId: 1, sourceId: 'grunt' } });
  assert.equal(r.json.success, true);
  assert.equal(r.json.data.dropped, null);
  assert.deepEqual(f.log.filter((q) => /INSERT INTO inventory/.test(q.sql)), [], 'nothing was inserted');
});

test('loot/roll: a full bag stores no items (gold is still paid)', async () => {
  const realRandom = Math.random;
  Math.random = () => 0.99; // the last grunt entry: one copper_bar
  try {
    const f = fakePool({ onQuery: (sql) => {
      if (/SELECT slot_index FROM inventory/.test(sql)) return [fullBag()];
    } });
    const r = await loadServer({ pool: f.pool }).call('POST /api/loot/roll', { body: { characterId: 1, enemyType: 'grunt' } });
    assert.equal(r.json.success, true);
    assert.deepEqual(f.log.filter((q) => /INSERT INTO inventory/.test(q.sql)), [], 'nothing was inserted');
    assert.ok(f.log.some((q) => /UPDATE characters SET gold = gold \+ \?/.test(q.sql)), 'gold still paid');
  } finally {
    Math.random = realRandom;
  }
});

// ── POST /api/inventory/save ────────────────────────────────────────────────────────────────────────────────────────────

test('inventory/save: junk in the slot list is a readable 400, never a crash or a write', async () => {
  const f = fakePool();
  const srv = loadServer({ pool: f.pool });
  for (const slots of [[null], [{ slot_index: 3.5, item_id: 'log_oak', quantity: 1 }], [{ slot_index: '2abc', item_id: 'log_oak', quantity: 1 }]]) {
    const r = await srv.call('POST /api/inventory/save', { body: { characterId: 1, slots, bagSize: 48 } });
    assert.equal(r.status, 400, JSON.stringify(slots));
    assert.match(r.json.error, /slot_index/);
  }
  const noBody = await srv.call('POST /api/inventory/save', {});
  assert.equal(noBody.status, 400, 'a request without a JSON body is a 400 too');
  assert.equal(f.log.length, 0, 'nothing reached the database');
});
