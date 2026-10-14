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
      if (/FROM accounts WHERE id/.test(sql)) return [[{ role: staff ? 'gm' : 'player', gm_enabled: 0, gm_active: staff ? 1 : 0 }]];
      if (/SELECT gold FROM characters/.test(sql)) return [[{ gold: state.gold }]];
      if (/UPDATE characters SET gold/.test(sql)) { state.gold = params[0]; state.updates.push(params[0]); return [{ affectedRows: 1 }]; }
    },
  });
  // fakePool answers accounts lookups itself before onQuery; route them through it for this test.
  const inner = f.pool.execute;
  f.pool.execute = async (sql, params) => (/FROM accounts WHERE id/.test(sql) ? [[{ role: staff ? 'gm' : 'player', gm_enabled: 0, gm_active: staff ? 1 : 0 }]] : inner(sql, params));
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

test('save-progress: levels past the old 255 cap are saved, and anything past 999 is clamped to 999', async () => {
  for (const [sent, stored] of [[258, 258], [999, 999], [5000, 999]]) {
    const f = fakePool({ character: { level: 255, experience: 10 }, onQuery: (sql) => {
      if (/^SELECT \* FROM characters WHERE id = \?$/.test(sql)) return [[{ ...f.owned }]];
      if (/^UPDATE characters SET level/.test(sql)) return [{ affectedRows: 1 }];
    } });
    const r = await loadServer({ pool: f.pool }).call('POST /api/character/save-progress', { body: { characterId: 1, level: sent, xp: 120 } });
    assert.equal(r.json.success, true);
    assert.equal(f.log.find((q) => /^UPDATE characters SET level/.test(q.sql)).params[0], stored, `level ${sent}`);
  }
});

// ── GM-mode-only routes ─────────────────────────────────────────────────────────────────────────────────────────────────

test('adding an item by name and loading a client-made save are GM-mode tools: refused for players before anything is read or written', async () => {
  const f = fakePool();
  const srv = loadServer({ pool: f.pool });
  const add = await srv.call('POST /api/inventory/add-item', { body: { characterId: 1, itemId: 'ore_copper', quantity: 5 } });
  assert.equal(add.status, 403);
  const user = { accountId: 1, characterId: 1 };
  assert.equal((await srv.call('POST /api/offline/load', { user, body: { snapshot: {}, expectedFingerprint: 'x' } })).status, 403);
  assert.equal((await srv.call('POST /api/offline/sync-stats', { user, body: { classIndex: 1, level: 99, experience: 0 } })).status, 403);
  assert.deepEqual(f.log.filter((q) => /^(INSERT|UPDATE|DELETE)/.test(q.sql)), [], 'nothing was written');
});

// ── retired routes ──────────────────────────────────────────────────────────────────────────────────────────────────────

test('the web-era reward routes are gone: they paid XP, gold and items for an enemy the client made up', async () => {
  const srv = loadServer({ pool: fakePool().pool });
  for (const route of ['POST /api/combat/hit', 'POST /api/combat/kill', 'POST /api/loot/roll', 'POST /api/loot/drop', 'POST /api/professions/award-xp']) {
    await assert.rejects(srv.call(route, { body: { characterId: 1 } }), /no such route/, route);
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

test('GET /character: leftover XP past the last level cannot push the level over the 999 cap', async () => {
  // save-progress accepts any XP up to 2^31, so a saved row can hold far more than level * 100; normalising used to level it to ~20,000.
  const f = fakePool({ character: { level: 990, experience: 2_000_000_000 }, onQuery: (sql) => {
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
  assert.equal(fix.params[0], 999, 'level stops at the cap');
  assert.ok(fix.params[1] < 999 * 100, 'the leftover experience is below one level at the cap');
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

test('GET /api/me reports staff from the account row only, with no character write', async () => {
  const check = async (acct, user) => {
    const f = fakePool();
    const inner = f.pool.execute;
    const execute = async (sql, params) => { if (/FROM accounts WHERE id/.test(sql)) { f.log.push({ sql, params }); return [[acct]]; } return inner(sql, params); };
    const r = await loadServer({ pool: { ...f.pool, execute, query: execute } }).call('GET /api/me', { user });
    assert.ok(!f.log.some((q) => /UPDATE|INSERT|DELETE/i.test(q.sql)), 'read-only');
    return r;
  };
  const player = await check({ username: 'p', role: 'player', gm_enabled: 0 }, { accountId: 1, username: 'p' });
  assert.equal(player.json.staff, false);
  assert.equal((await check({ username: 'g', role: 'gm', gm_enabled: 0 }, { accountId: 1, username: 'g' })).json.staff, true);
  assert.equal((await check({ username: 'a', role: 'admin', gm_enabled: 0 }, { accountId: 1, username: 'a' })).json.staff, true);
  assert.equal((await check({ username: 'b', role: 'player', gm_enabled: 1 }, { accountId: 1, username: 'b' })).json.staff, true);
  // a name that looks like staff gives nothing: the claim's username is not consulted for the decision
  assert.equal((await check({ username: 'Brbmuffins', role: 'player', gm_enabled: 0 }, { accountId: 1, username: 'Brbmuffins' })).json.staff, false);
});

// One character per account (owner, 2026-10-11): a discipline card selects the main character instead of creating one per class.
function characterPool(main) {
  return fakePool({
    onQuery: (sql, params) => {
      if (/SELECT id FROM characters WHERE account_id = \? ORDER BY level DESC/.test(sql)) return [main ? [{ id: main }] : []];
      if (/INSERT INTO characters/.test(sql)) return [{ insertId: 77, affectedRows: 1 }];
      if (/SELECT \* FROM characters WHERE id = \? AND account_id = \?/.test(sql)) return [[{ id: params[0], account_id: 1, class_index: 5, level: 631 }]];
    },
  });
}
test('POST /character with a main character: a necromantic card switches its discipline, no new character', async () => {
  const f = characterPool(129);
  const srv = loadServer({ pool: f.pool });
  const r = await srv.call('POST /character', { body: { class_index: 2 }, user: { accountId: 1 } });
  assert.equal(r.status, 200);
  assert.equal(r.json.id, 129);
  assert.ok(!f.log.some((q) => /INSERT INTO characters/.test(q.sql)), 'no second character');
  assert.ok(f.log.some((q) => /UPDATE characters SET discipline_index = \?/.test(q.sql) && q.params[0] === 2 && q.params[1] === 129), 'discipline 2 on the main');
  assert.ok(f.log.some((q) => /UPDATE accounts SET active_character_id/.test(q.sql) && q.params[0] === 129), 'the main is the active character');
});
test('POST /character class 5 (a discipline above 4) leaves the discipline to POST /character/discipline; no character at all creates one', async () => {
  const f = characterPool(129);
  await loadServer({ pool: f.pool }).call('POST /character', { body: { class_index: 5 }, user: { accountId: 1 } });
  assert.ok(!f.log.some((q) => /discipline_index/.test(q.sql) || /INSERT INTO characters/.test(q.sql)));
  const g = characterPool(null);
  const r = await loadServer({ pool: g.pool }).call('POST /character', { body: { class_index: 3 }, user: { accountId: 1 } });
  assert.equal(r.status, 201); assert.equal(r.json.id, 77);
  assert.ok(g.log.some((q) => /INSERT INTO characters/.test(q.sql) && q.params[1] === 3));
});

// ── save-progress: gains, not totals (DECISIONS B23) ────────────────────────────────────────────────────────────────────────

test('a gains save adds to the server\'s own record, works the level out of the XP, and pays a retried seq only once', async () => {
  const { totalXp, splitXp } = require('./gathering/authority-rules.cjs');
  let seq = 0;
  const f = fakePool({ character: { level: 5, experience: 10, gold: 100 }, onQuery: (sql, p) => {
    if (/^SELECT \* FROM characters WHERE id = \?$/.test(sql)) return [[{ ...f.owned }]];
    if (/^UPDATE character_authority SET progress_seq = \? WHERE character_id = \? AND progress_seq < \?/.test(sql)) {
      if (seq < p[0]) { seq = p[0]; return [{ affectedRows: 1 }]; }
      return [{ affectedRows: 0 }];
    }
    if (/^UPDATE characters SET level/.test(sql)) return [{ affectedRows: 1 }];
    if (/^SELECT progress_seq FROM character_authority/.test(sql)) return [[{ progress_seq: seq }]];
  } });
  const srv = loadServer({ pool: f.pool });
  const body = { characterId: 1, gains: { xp: 500, gold: 50 }, seq: 7, level: 999, xp: 0, gold: 9e8 };
  const r = await srv.call('POST /api/character/save-progress', { body });
  assert.equal(r.status, 200, JSON.stringify(r.json));
  const w = f.log.find((q) => /^UPDATE characters SET level/.test(q.sql)).params;
  const want = splitXp(totalXp(5, 10) + 500);
  assert.deepEqual([w[0], w[1], w[2]], [want.level, want.xp, 150], 'gains on top of the stored record; the totals in the body are ignored');
  const again = await srv.call('POST /api/character/save-progress', { body });
  assert.equal(again.json.data.duplicate, true, 'the retry is recognised');
  assert.equal(f.log.filter((q) => /^UPDATE characters SET level/.test(q.sql)).length, 1, 'and pays nothing more');
});

// ── selling (sell.cjs) ──────────────────────────────────────────────────────────────────────────────────────────────────────

test('selling: the server takes the items and pays their price, an affixed piece at its affixed price; worn or missing lines refuse the sale', async () => {
  const { sellItems } = require('./sell.cjs');
  const affix = require('./gathering/affix-rules.cjs');
  const affixes = [{ id: affix.AFFIXES[0].id, v: affix.affixRange(affix.AFFIXES[0].id, 20)[0] }];
  const rows = [
    { id: 1, slot_index: 0, item_id: 'ore_copper', quantity: 10, equipped: 0, instance_id: null, sell_value: 3 },
    { id: 2, slot_index: 1, item_id: 'helm_iron', quantity: 1, equipped: 0, instance_id: 55, sell_value: 40, ilvl: 20, affixes: JSON.stringify(affixes) },
    { id: 3, slot_index: 2, item_id: 'helm_gold', quantity: 1, equipped: 1, instance_id: null, sell_value: 90 },
  ];
  const log = [];
  let gold = 1000;
  const conn = {
    execute: async (sql, p) => {
      log.push(sql);
      if (/^\s*SELECT inv\.id/.test(sql)) return [rows.map((r) => ({ ...r }))];
      if (/^UPDATE characters SET gold/.test(sql)) { gold += p[0]; return [{}]; }
      if (/^SELECT gold FROM characters/.test(sql)) return [[{ gold }]];
      return [{}];
    },
    query: async () => [{}], beginTransaction: async () => {}, commit: async () => {}, rollback: async () => {}, release: () => {},
  };
  const pool = { getConnection: async () => conn, execute: async () => [[]] };
  const out = await sellItems(pool, { characterId: 1, items: [{ slot_index: 0, quantity: 4 }, { slot_index: 1, quantity: 1 }] });
  const helm = Math.floor(affix.instanceSellValue(40, { ilvl: 20, affixes }));
  assert.ok(helm > 40, 'the affixed helm is worth more than its base');
  assert.equal(out.gold, 4 * 3 + helm);
  assert.equal(out.goldTotal, 1000 + 4 * 3 + helm);
  assert.ok(log.some((q) => /UPDATE inventory SET quantity = quantity - \?/.test(q)) && log.some((q) => /DELETE FROM inventory WHERE id = \?/.test(q)));
  await assert.rejects(sellItems(pool, { characterId: 1, items: [{ slot_index: 2, quantity: 1 }] }), /no longer in your bag/, 'worn gear is not sold');
  await assert.rejects(sellItems(pool, { characterId: 1, items: [{ slot_index: 0, quantity: 99 }] }), /no longer in your bag/, 'not more than the stack');
});
