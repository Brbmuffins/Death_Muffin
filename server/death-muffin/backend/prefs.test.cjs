// Run: node --test server/death-muffin/backend/prefs.test.cjs
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const mountPrefs = require('./prefs.cjs');
const { checkValue, parsePrefs, readRows, DEFS, MAX_PER_REQUEST } = mountPrefs;
const { loadServer } = require('./server-harness.cjs');

/** In-memory account_prefs table keyed on the SQL text the module issues, plus a tiny Express stand-in. */
function harness({ missingTable = false } = {}) {
  const rows = [];
  const pool = {
    execute: async (sql, params = []) => {
      if (missingTable) throw Object.assign(new Error("Table 'account_prefs' doesn't exist"), { code: 'ER_NO_SUCH_TABLE' });
      if (sql.startsWith('SELECT pref_key, value FROM account_prefs')) return [rows.filter((r) => r.account_id === params[0]).map(({ pref_key, value }) => ({ pref_key, value }))];
      if (sql.startsWith('INSERT INTO account_prefs')) {
        const [account_id, pref_key, value] = params;
        const row = rows.find((r) => r.account_id === account_id && r.pref_key === pref_key);
        if (row) row.value = value;
        else rows.push({ account_id, pref_key, value });
        return [{}];
      }
      throw new Error(`unexpected SQL ${sql}`);
    },
  };
  const routes = {};
  const app = { post: (p, _a, fn) => (routes[`POST ${p}`] = fn), get: (p, _a, fn) => (routes[`GET ${p}`] = fn) };
  mountPrefs(app, pool, { requireAuth: () => {} });
  const call = async (route, body, accountId = 1) => {
    const res = { code: 200, body: null, status(c) { this.code = c; return this; }, json(b) { this.body = b; return this; } };
    await routes[route]({ user: { accountId }, body }, res);
    return res;
  };
  return { rows, call };
}

test('only known keys with a valid value are accepted', () => {
  assert.deepStrictEqual(checkValue('only_craftable', true), { ok: true, value: true });
  assert.deepStrictEqual(checkValue('only_craftable', false), { ok: true, value: false });
  for (const bad of ['true', 1, 0, null, undefined, {}, []]) assert.strictEqual(checkValue('only_craftable', bad).ok, false, String(bad));
  for (const key of ['nope', '', '__proto__', 'constructor', 'toString', 'ONLY_CRAFTABLE', 'only craftable', 'x'.repeat(41), 7, null]) {
    assert.strictEqual(checkValue(key, true).ok, false, String(key));
  }
});

test('enum and int definitions validate their range (for settings added later)', () => {
  DEFS.test_enum = { type: 'enum', values: ['a', 'b'] };
  DEFS.test_int = { type: 'int', min: 1, max: 5 };
  try {
    assert.strictEqual(checkValue('test_enum', 'a').ok, true);
    assert.strictEqual(checkValue('test_enum', 'c').ok, false);
    assert.strictEqual(checkValue('test_int', 5).ok, true);
    assert.strictEqual(checkValue('test_int', 6).ok, false);
    assert.strictEqual(checkValue('test_int', 2.5).ok, false);
    assert.strictEqual(checkValue('test_int', '3').ok, false);
  } finally {
    delete DEFS.test_enum;
    delete DEFS.test_int;
  }
});

test('loot rules: each rarity takes ground, auto or gold, and a legendary is never sold', () => {
  for (const tier of ['common', 'uncommon', 'rare', 'epic']) {
    for (const v of ['ground', 'auto', 'gold']) assert.strictEqual(checkValue(`loot_${tier}`, v).ok, true, `${tier} ${v}`);
    for (const bad of ['sell', '', null, true, 1]) assert.strictEqual(checkValue(`loot_${tier}`, bad).ok, false, `${tier} ${bad}`);
  }
  assert.strictEqual(checkValue('loot_legendary', 'auto').ok, true);
  assert.strictEqual(checkValue('loot_legendary', 'ground').ok, true);
  assert.strictEqual(checkValue('loot_legendary', 'gold').ok, false);
});

test('all five loot rules save in one request and read back', async () => {
  const h = harness();
  const prefs = { loot_common: 'gold', loot_uncommon: 'gold', loot_rare: 'auto', loot_epic: 'auto', loot_legendary: 'auto' };
  const saved = await h.call('POST /api/prefs', { prefs });
  assert.deepStrictEqual(saved.body, { success: true, data: prefs });
  assert.deepStrictEqual((await h.call('GET /api/prefs')).body.data, prefs);
  const bad = await h.call('POST /api/prefs', { prefs: { loot_legendary: 'gold' } });
  assert.strictEqual(bad.code, 400);
});

test('parsePrefs needs a prefs object of 1 to MAX_PER_REQUEST valid keys, all or nothing', () => {
  assert.ok(parsePrefs(null).error);
  assert.ok(parsePrefs({}).error);
  assert.ok(parsePrefs({ prefs: [] }).error);
  assert.ok(parsePrefs({ prefs: 'only_craftable' }).error);
  assert.ok(parsePrefs({ prefs: {} }).error);
  assert.deepStrictEqual(parsePrefs({ prefs: { only_craftable: true } }), { prefs: { only_craftable: true } });
  assert.ok(parsePrefs({ prefs: { only_craftable: true, mystery: 1 } }).error);
  assert.ok(parsePrefs({ prefs: Object.fromEntries(Array.from({ length: MAX_PER_REQUEST + 1 }, (_, i) => [`k${i}`, true])) }).error);
});

test('readRows drops unknown, unparsable and invalid stored values', () => {
  assert.deepStrictEqual(
    readRows([
      { pref_key: 'only_craftable', value: 'true' },
      { pref_key: 'retired_key', value: 'true' },
    ]),
    { only_craftable: true },
  );
  assert.deepStrictEqual(readRows([{ pref_key: 'only_craftable', value: '{nope' }]), {});
  assert.deepStrictEqual(readRows([{ pref_key: 'only_craftable', value: '"yes"' }]), {});
});

test('GET is empty at first; POST saves and answers every pref; a second POST overwrites', async () => {
  const h = harness();
  assert.deepStrictEqual((await h.call('GET /api/prefs')).body, { success: true, data: {} });
  const saved = await h.call('POST /api/prefs', { prefs: { only_craftable: true } });
  assert.deepStrictEqual(saved.body, { success: true, data: { only_craftable: true } });
  assert.deepStrictEqual((await h.call('GET /api/prefs')).body.data, { only_craftable: true });
  await h.call('POST /api/prefs', { prefs: { only_craftable: false } });
  assert.deepStrictEqual((await h.call('GET /api/prefs')).body.data, { only_craftable: false });
  assert.strictEqual(h.rows.length, 1);
});

test('a bad request is a readable 400 and writes nothing', async () => {
  const h = harness();
  for (const body of [{ prefs: { only_craftable: 'yes' } }, { prefs: { evil: true } }, { prefs: { only_craftable: true, evil: true } }, { prefs: [] }, undefined]) {
    const res = await h.call('POST /api/prefs', body);
    assert.strictEqual(res.code, 400);
    assert.strictEqual(res.body.success, false);
    assert.ok(typeof res.body.error === 'string' && res.body.error.length > 0);
  }
  assert.strictEqual(h.rows.length, 0);
});

test('preferences belong to the account: another account sees none of them', async () => {
  const h = harness();
  await h.call('POST /api/prefs', { prefs: { only_craftable: true } }, 1);
  assert.deepStrictEqual((await h.call('GET /api/prefs', undefined, 2)).body.data, {});
  await h.call('POST /api/prefs', { prefs: { only_craftable: false } }, 2);
  assert.deepStrictEqual((await h.call('GET /api/prefs', undefined, 1)).body.data, { only_craftable: true });
});

test('before the migration: GET is empty, POST is a readable 503', async () => {
  const h = harness({ missingTable: true });
  assert.deepStrictEqual((await h.call('GET /api/prefs')).body, { success: true, data: {} });
  const res = await h.call('POST /api/prefs', { prefs: { only_craftable: true } });
  assert.strictEqual(res.code, 503);
  assert.ok(res.body.error.length > 0);
});

test('the routes are mounted in server.js behind the login', async () => {
  const stored = [];
  const pool = {
    execute: async (sql, params = []) => {
      if (sql.startsWith('SELECT pref_key')) return [stored];
      if (sql.startsWith('INSERT INTO account_prefs')) { stored.push({ pref_key: params[1], value: params[2] }); return [{}]; }
      return [[]];
    },
    query: async () => [[]],
    getConnection: async () => { throw new Error('no connection'); },
  };
  const srv = loadServer({ pool });
  assert.ok(srv.routes.has('GET /api/prefs'));
  assert.ok(srv.routes.has('POST /api/prefs'));
  const anon = await srv.call('GET /api/prefs', { headers: { authorization: '' } });
  assert.strictEqual(anon.status, 401);
  const saved = await srv.call('POST /api/prefs', { body: { prefs: { only_craftable: true } }, user: { accountId: 5, username: 'tester' } });
  assert.deepStrictEqual(saved.json, { success: true, data: { only_craftable: true } });
});

test('migration 040 is additive and idempotent', () => {
  const sql = fs.readFileSync(path.join(__dirname, 'migrations', '040-account-prefs.sql'), 'utf8');
  assert.match(sql, /CREATE TABLE IF NOT EXISTS account_prefs/);
  assert.match(sql, /PRIMARY KEY \(account_id, pref_key\)/);
  assert.match(sql, /REFERENCES accounts \(id\) ON DELETE CASCADE/);
  assert.doesNotMatch(sql, /\b(DROP|TRUNCATE|DELETE\s+FROM|ALTER\s+TABLE\s+\w+\s+DROP)\b/i);
});
