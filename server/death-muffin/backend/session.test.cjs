// Run: node --test server/death-muffin/backend/session.test.cjs
// One active session per account, newest login wins (session.cjs, migration 039), through the real routes in server.js.
const test = require('node:test');
const assert = require('node:assert');
const { loadServer } = require('./server-harness.cjs');

/** A pool with one account (id 1) whose active_session column really holds state. `role` makes it staff. */
function pool({ role = 'player', columnMissing = false } = {}) {
  const acct = { id: 1, username: 'tester', password_hash: 'h', active: 1, active_session: null, role, gm_enabled: 0 };
  const owned = { id: 1, account_id: 1, level: 255, experience: 0, gold: 10, stat_str: 5, stat_agi: 5, stat_int: 5, stat_vit: 10 };
  const saves = [];
  const run = async (sql, params = []) => {
    if (/^UPDATE accounts SET active_session/.test(sql)) {
      if (columnMissing) throw Object.assign(new Error('Unknown column'), { code: 'ER_BAD_FIELD_ERROR' });
      acct.active_session = params[0];
      return [{ affectedRows: 1 }];
    }
    if (/SELECT active_session, role, gm_enabled FROM accounts/.test(sql)) {
      if (columnMissing) throw Object.assign(new Error('Unknown column'), { code: 'ER_BAD_FIELD_ERROR' });
      return [[{ active_session: acct.active_session, role: acct.role, gm_enabled: 0 }]];
    }
    if (/FROM accounts WHERE username/.test(sql)) return [[acct]];
    if (/SELECT active FROM accounts/.test(sql)) return [[{ active: 1 }]];
    if (/FROM accounts WHERE id/.test(sql)) return [[{ username: 'tester', role: acct.role, gm_enabled: 0, gm_level: 0, gm_permissions: '' }]];
    if (/FROM characters WHERE id = \? AND account_id = \?/.test(sql)) return [[{ ...owned }]];
    if (/^SELECT \* FROM characters WHERE id = \?$/.test(sql)) return [[{ ...owned }]];
    if (/^UPDATE characters SET level/.test(sql)) { saves.push(params); return [{ affectedRows: 1 }]; }
    return [[]];
  };
  const conn = { execute: run, query: run, beginTransaction: async () => {}, commit: async () => {}, rollback: async () => {}, release: () => {} };
  return { acct, saves, pool: { execute: run, query: run, getConnection: async () => conn } };
}

const login = async (srv) => JSON.parse((await srv.call('POST /login', { body: { username: 'tester', password: 'password1' } })).json.token);
const save = (srv, user, level = 258) => srv.call('POST /api/character/save-progress', { user, body: { characterId: 1, level, xp: 5, gold: 10 } });

test('the newest login wins: the old session is refused, the new one saves', async () => {
  const p = pool();
  const srv = loadServer({ pool: p.pool });
  const a = await login(srv);
  assert.ok(a.sid, 'a login token carries a session id');
  assert.equal((await save(srv, a)).json.success, true, 'the only session saves');
  const b = await login(srv); // second device
  assert.notEqual(a.sid, b.sid);
  const refused = await save(srv, a, 300);
  assert.equal(refused.status, 409);
  assert.equal(refused.json.code, 'session_replaced');
  assert.match(refused.json.error, /opened somewhere else/);
  assert.equal(p.saves.length, 1, 'the stale write never reached the character row');
  assert.equal((await save(srv, b, 260)).json.success, true, 'the newer session keeps saving');
  assert.equal(p.saves.length, 2);
});

test('a reconnect on the same session keeps working (repeat saves, same token)', async () => {
  const srv = loadServer({ pool: pool().pool });
  const a = await login(srv);
  for (let i = 0; i < 3; i++) assert.equal((await save(srv, a)).json.success, true);
});

test('writes on every route family are refused for a replaced session; reads are not', async () => {
  const srv = loadServer({ pool: pool().pool });
  const a = await login(srv);
  await login(srv);
  for (const route of ['POST /api/inventory/save', 'POST /api/necro-progress/save', 'POST /api/craft', 'POST /api/offline/load', 'POST /character']) {
    if (!srv.routes.has(route)) continue;
    const r = await srv.call(route, { user: a, body: { characterId: 1 } });
    assert.equal(r.status, 409, route);
    assert.equal(r.json.code, 'session_replaced', route);
  }
  assert.equal((await srv.call('GET /api/session', { user: a })).json.active, false);
});

test('Play here: claiming gives a fresh session, and the other window becomes the stale one', async () => {
  const srv = loadServer({ pool: pool().pool });
  const a = await login(srv);
  const b = await login(srv);
  assert.equal((await save(srv, a)).status, 409);
  const claimed = await srv.call('POST /api/session/claim', { user: a });
  assert.equal(claimed.status, 200, JSON.stringify(claimed.json));
  const a2 = JSON.parse(claimed.json.token);
  assert.equal(a2.accountId, 1);
  assert.notEqual(a2.sid, a.sid);
  assert.equal((await save(srv, a2)).json.success, true, 'taken back');
  assert.equal((await save(srv, b)).status, 409, 'the window that took over is now stale');
  assert.equal((await srv.call('GET /api/session', { user: a2 })).json.active, true);
});

test('tokens from before this shipped (no sid), staff accounts and a missing column are never refused', async () => {
  const p = pool();
  const srv = loadServer({ pool: p.pool });
  await login(srv);
  assert.equal((await save(srv, { accountId: 1, username: 'tester' })).json.success, true, 'legacy token');
  const staff = pool({ role: 'gm' });
  const s2 = loadServer({ pool: staff.pool });
  const x = await login(s2);
  await login(s2);
  assert.equal((await save(s2, x)).json.success, true, 'staff exempt');
  const nocol = pool({ columnMissing: true });
  const s3 = loadServer({ pool: nocol.pool });
  const t = await login(s3);
  assert.equal(t.sid, undefined, 'no session id without the column');
  assert.equal((await save(s3, { ...t, sid: 'x' })).json.success, true, 'check fails open');
});
