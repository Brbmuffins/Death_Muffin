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

// ── errors that escape a route ──────────────────────────────────────────────────────────────────────────────────────────

test('body-parser and unexpected errors answer readable JSON, not an HTML page', () => {
  const srv = loadServer({ pool: fakePool().pool });
  const big = srv.fail(Object.assign(new Error('request entity too large'), { type: 'entity.too.large', status: 413 }));
  assert.equal(big.status, 413);
  assert.match(big.json.error, /too large/i);
  const bad = srv.fail(Object.assign(new SyntaxError('x'), { type: 'entity.parse.failed', status: 400 }));
  assert.equal(bad.status, 400);
  const boom = srv.fail(new TypeError('Cannot read properties of undefined'));
  assert.equal(boom.status, 500);
  assert.equal(boom.json.success, false);
  assert.equal(boom.json.error, 'internal server error', 'no internals leak to the client');
});

// ── GET /character ──────────────────────────────────────────────────────────────────────────────────────────────────────

test('GET /character: leftover XP past the last level cannot push the level over the 255 cap', async () => {
  // save-progress accepts any XP up to 2^31, so a saved row can hold far more than level * 100; normalising used to level it to ~20,000.
  const f = fakePool({ character: { level: 250, experience: 2_000_000_000 }, onQuery: (sql) => {
    if (/FROM accounts WHERE id/.test(sql)) return [[{ username: 'tester', role: 'player', gm_enabled: 0, gm_level: 0, gm_permissions: '' }]];
    if (/^UPDATE characters SET level = \?, experience = \? WHERE id = \?$/.test(sql)) return [{ affectedRows: 1 }];
    if (/^UPDATE characters SET online/.test(sql)) return [{ affectedRows: 1 }];
  } });
  const pool = { ...f.pool };
  const inner = pool.execute;
  pool.execute = async (sql, params) => (/FROM accounts WHERE id/.test(sql) ? [[{ username: 'tester', role: 'player', gm_enabled: 0, gm_level: 0, gm_permissions: '' }]] : inner(sql, params));
  const r = await loadServer({ pool }).call('GET /character', { user: { accountId: 1, username: 'tester', characterId: 1 } });
  assert.equal(r.status, 200, JSON.stringify(r.json));
  const fix = f.log.find((q) => /^UPDATE characters SET level = \?, experience = \?/.test(q.sql));
  assert.ok(fix, 'the row was normalised');
  assert.equal(fix.params[0], 255, 'level stops at the cap');
  assert.ok(fix.params[1] < 255 * 100, 'the leftover experience is below one level at the cap');
});

// ── POST /character ─────────────────────────────────────────────────────────────────────────────────────────────────────

test('POST /character: the character token still gets an expiry when JWT_EXPIRES_IN is not configured', async () => {
  const saved = process.env.JWT_EXPIRES_IN;
  delete process.env.JWT_EXPIRES_IN;
  try {
    const f = fakePool({ onQuery: (sql) => {
      if (/^INSERT INTO characters/.test(sql)) return [{ insertId: 1, affectedRows: 1 }];
      if (/^SELECT \* FROM characters WHERE id = \? AND account_id = \?$/.test(sql)) return [[{ ...f.owned }]];
      if (/FROM character_gear/.test(sql)) return [[]];
    } });
    const pool = { ...f.pool };
    const inner = pool.execute;
    pool.execute = async (sql, params) => (/FROM accounts WHERE id/.test(sql) ? [[{ username: 'tester', role: 'player', gm_enabled: 0, gm_level: 0, gm_permissions: '' }]] : inner(sql, params));
    const r = await loadServer({ pool }).call('POST /character', { body: { class_index: 2 } });
    assert.equal(r.status, 201, JSON.stringify(r.json));
    assert.ok(r.json.token, 'a character token was issued');
  } finally {
    if (saved !== undefined) process.env.JWT_EXPIRES_IN = saved;
  }
});

// ── PATCH /character/position ───────────────────────────────────────────────────────────────────────────────────────────

test('PATCH /character/position: Infinity and absurd coordinates are a 400, not a database error', async () => {
  const f = fakePool();
  const pool = { ...f.pool };
  const inner = pool.execute;
  pool.execute = async (sql, params) => (/FROM accounts WHERE id/.test(sql) ? [[{ username: 'tester', role: 'player', gm_enabled: 0 }]] : inner(sql, params));
  const srv = loadServer({ pool });
  const user = { accountId: 1, username: 'tester', characterId: 1 };
  for (const x of ['Infinity', '1e999', 1e30]) {
    const r = await srv.call('PATCH /character/position', { user, body: { x, y: 0, z: 0, orientation: 0 } });
    assert.equal(r.status, 400, String(x));
  }
  assert.equal(f.log.filter((q) => /^UPDATE characters/.test(q.sql)).length, 0);
  const ok = await srv.call('PATCH /character/position', { user, body: { x: 12.5, y: 0, z: -3, orientation: 1.2 } });
  assert.equal(ok.status, 200);
});

// ── legacy reward routes under AUTHORITY_MODE=enforce ───────────────────────────────────────────────────────────────────

async function withMode(mode, fn) {
  const saved = process.env.AUTHORITY_MODE;
  process.env.AUTHORITY_MODE = mode;
  try { return await fn(); } finally { if (saved === undefined) delete process.env.AUTHORITY_MODE; else process.env.AUTHORITY_MODE = saved; }
}

test('enforce mode closes the legacy reward routes to players: kill, loot/roll and loot/drop mint XP, gold and items for any instance id', async () => {
  await withMode('enforce', async () => {
    const f = fakePool();
    const srv = loadServer({ pool: f.pool });
    // The hit gate only needs a client-chosen id, so a script can loop hit + kill with fresh ids at HTTP speed.
    const body = { characterId: 1, enemyLevel: 100, enemyCategory: 'boss', enemyInstanceId: 'made-up-1', damageDealt: 1 };
    assert.equal((await srv.call('POST /api/combat/hit', { body })).status, 200);
    const kill = await srv.call('POST /api/combat/kill', { body });
    assert.equal(kill.status, 403);
    const roll = await srv.call('POST /api/loot/roll', { body: { characterId: 1, enemyType: 'elite' } });
    assert.equal(roll.status, 403);
    const drop = await srv.call('POST /api/loot/drop', { body: { characterId: 1, sourceId: 'boss' } });
    assert.equal(drop.status, 403);
    assert.deepEqual(f.log.filter((q) => /^(UPDATE characters|INSERT INTO inventory)/.test(q.sql)), [], 'nothing was paid');
  });
});

test('report mode keeps the legacy reward routes exactly as they were', async () => {
  await withMode('report', async () => {
    const f = fakePool({ onQuery: (sql) => {
      if (/FROM loot_tables/.test(sql)) return [[]];
      if (/SELECT level, experience, gold FROM characters/.test(sql)) return [[{ level: 1, experience: 0, gold: 0 }]];
    } });
    const srv = loadServer({ pool: f.pool });
    const body = { characterId: 1, enemyLevel: 3, enemyCategory: 'grunt', enemyInstanceId: 'a1', damageDealt: 1 };
    await srv.call('POST /api/combat/hit', { body });
    const kill = await srv.call('POST /api/combat/kill', { body });
    assert.equal(kill.status, 200, JSON.stringify(kill.json));
    assert.equal((await srv.call('POST /api/loot/drop', { body: { characterId: 1, sourceId: 'grunt' } })).status, 200);
  });
});

// ── the refusal log ─────────────────────────────────────────────────────────────────────────────────────────────────────

test('player-facing refusals are logged whether the route answers 4xx or a 200 with success:false', () => {
  const srv = loadServer({ pool: fakePool().pool });
  const lines = [];
  const warn = console.warn;
  console.warn = (...a) => lines.push(a.join(' '));
  try {
    const four = srv.wrap({ originalUrl: '/api/inventory/save?x=1' });
    four.res.status(400).json({ success: false, error: 'duplicate slot_index values are not allowed' });
    const soft = srv.wrap({ originalUrl: '/api/vault/deposit' });
    soft.res.json({ success: false, error: 'The Vault has no room for that.' });
    const fine = srv.wrap({ originalUrl: '/api/vault/deposit' });
    fine.res.json({ success: true, data: {} });
  } finally {
    console.warn = warn;
  }
  assert.equal(lines.length, 2, lines.join('\n'));
  assert.match(lines[0], /\[refused\] POST \/api\/inventory\/save 400 duplicate slot_index/);
  assert.match(lines[1], /\[refused\] POST \/api\/vault\/deposit 200 The Vault has no room/);
});
