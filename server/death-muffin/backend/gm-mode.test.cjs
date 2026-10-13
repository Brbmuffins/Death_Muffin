'use strict';
// node --test server/death-muffin/backend/gm-mode.test.cjs
const test = require('node:test');
const assert = require('node:assert/strict');
const { createGmMode } = require('./gm-mode.cjs');

/** accounts: { id: { role, gm_enabled, gm_active } }; records every statement. */
function fakePool(accounts) {
  const log = [];
  const execute = async (sql, params = []) => {
    log.push({ sql, params });
    if (/^SELECT role, gm_enabled, gm_active FROM accounts/.test(sql)) return [[accounts[params[0]]].filter(Boolean)];
    if (/^UPDATE accounts SET gm_active/.test(sql)) { accounts[params[1]].gm_active = params[0]; return [{ affectedRows: 1 }]; }
    return [{ affectedRows: 1 }];
  };
  return { log, pool: { execute } };
}

function app() {
  const routes = new Map();
  return { routes, post: (path, ...chain) => routes.set(path, chain) };
}

async function call(a, path, { accountId, body }) {
  const chain = a.routes.get(path);
  const req = { user: { accountId }, body };
  let status = 200; let json = null;
  const res = { status: (s) => ((status = s), res), json: (j) => ((json = j), res) };
  for (const fn of chain) await new Promise((resolve) => { const r = fn(req, res, resolve); if (r && r.then) r.then(resolve); else if (fn.length < 3) resolve(); });
  return { status, json };
}

const quiet = { error() {}, warn() {} };

test('an allowed account is not staff until it switches GM mode on; switching is logged and marks its characters', async () => {
  const f = fakePool({ 1: { role: 'player', gm_enabled: 1, gm_active: 0 } });
  const gm = createGmMode(f.pool, { log: quiet });
  const a = app();
  gm.mount(a, { requireAuth: (_req, _res, next) => next() });
  assert.equal(await gm.isActive(1), false, 'allowed but off: plays like everyone else');
  const on = await call(a, '/api/gm/mode', { accountId: 1, body: { on: true } });
  assert.deepEqual([on.status, on.json.data.active], [200, true]);
  assert.equal(await gm.isActive(1), true);
  assert.ok(f.log.some((q) => /^UPDATE characters SET gm_marked = 1 WHERE account_id = \?/.test(q.sql) && q.params[0] === 1));
  assert.ok(f.log.some((q) => /INSERT INTO progress_audit/.test(q.sql) && q.params[2] === 'gm_mode'));
  await call(a, '/api/gm/mode', { accountId: 1, body: { on: false } });
  assert.equal(await gm.isActive(1), false, 'off again: checked like everyone else at once (cache dropped)');
});

test('a normal player cannot switch GM mode on, and a stale gm_active without the permission is not staff', async () => {
  const f = fakePool({ 2: { role: 'player', gm_enabled: 0, gm_active: 1 } });
  const gm = createGmMode(f.pool, { log: quiet });
  const a = app();
  gm.mount(a, { requireAuth: (_req, _res, next) => next() });
  const r = await call(a, '/api/gm/mode', { accountId: 2, body: { on: true } });
  assert.equal(r.status, 403);
  assert.equal(await gm.isActive(2), false);
  assert.ok(!f.log.some((q) => /^UPDATE/.test(q.sql)));
});

test('an error reading the account counts as not in GM mode (closed)', async () => {
  const gm = createGmMode({ execute: async () => { throw new Error('db down'); } }, { log: quiet });
  assert.equal(await gm.isActive(1), false);
});

test('writes made in GM mode are logged; reads and writes outside GM mode are not', async () => {
  const f = fakePool({ 1: { role: 'player', gm_enabled: 1, gm_active: 1 }, 3: { role: 'player', gm_enabled: 0, gm_active: 0 } });
  const gm = createGmMode(f.pool, { log: quiet, verifyToken: (t) => JSON.parse(t) });
  const send = async (method, accountId, status = 200) => {
    const listeners = [];
    const res = { statusCode: status, on: (ev, fn) => listeners.push(fn) };
    await new Promise((next) => gm.logWrites({ method, path: '/api/inventory/save', headers: { authorization: `Bearer ${JSON.stringify({ accountId })}` }, body: { characterId: 9 } }, res, next));
    for (const fn of listeners) fn();
    await new Promise((r) => setTimeout(r, 5));
  };
  await send('GET', 1);
  await send('POST', 3);
  await send('POST', 1, 400);
  assert.equal(f.log.filter((q) => /INSERT INTO progress_audit/.test(q.sql)).length, 0);
  await send('POST', 1);
  const rows = f.log.filter((q) => /INSERT INTO progress_audit/.test(q.sql));
  assert.equal(rows.length, 1);
  assert.deepEqual([rows[0].params[0], rows[0].params[1], rows[0].params[2]], [9, 1, 'gm_write']);
});
