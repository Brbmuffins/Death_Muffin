// Run: node --test server/death-muffin/backend/friends.test.cjs
const test = require('node:test');
const assert = require('node:assert');
const mountFriends = require('./friends.cjs');
const { MAX_FRIENDS, MAX_OUTGOING } = mountFriends;

/** In-memory accounts / characters / friendships keyed on the SQL text friends.cjs issues, plus a tiny Express stand-in. */
function harness({ missingTable = false } = {}) {
  const accounts = [
    { id: 1, username: 'Tyler', active: 1, active_character_id: 10 },
    { id: 2, username: 'Helix', active: 1, active_character_id: 20 },
    { id: 3, username: 'warbogar', active: 1, active_character_id: null },
    { id: 4, username: 'Gone', active: 0, active_character_id: null },
  ];
  const characters = [{ id: 10, discipline_index: 2, level: 40 }, { id: 20, discipline_index: 11, level: 631 }];
  const rows = [];
  const find = (lo, hi) => rows.find((r) => r.account_lo === lo && r.account_hi === hi);
  const mine = (me) => rows.filter((r) => r.account_lo === me || r.account_hi === me);
  const pool = {
    execute: async (sql, p = []) => {
      if (missingTable && sql.includes('friendships')) throw Object.assign(new Error("Table 'friendships' doesn't exist"), { code: 'ER_NO_SUCH_TABLE' });
      if (sql.startsWith('SELECT f.status')) {
        const me = p[0];
        return [mine(me).map((r) => {
          const a = accounts.find((x) => x.id === (r.account_lo === me ? r.account_hi : r.account_lo));
          if (!a || !a.active) return null;
          const c = characters.find((x) => x.id === a.active_character_id);
          return { status: r.status, requested_by: r.requested_by, id: a.id, username: a.username, discipline_index: c ? c.discipline_index : null, level: c ? c.level : null };
        }).filter(Boolean)];
      }
      if (sql.startsWith('SELECT id, username FROM accounts')) return [accounts.filter((a) => a.active && a.username.toLowerCase() === p[0].toLowerCase())];
      if (sql.startsWith('SELECT requested_by, status')) { const r = find(p[0], p[1]); return [r ? [r] : []]; }
      if (sql.startsWith('SELECT COUNT(*) AS total, SUM')) {
        const m = mine(p[1]);
        return [[{ total: m.length, outgoing: m.filter((r) => r.status === 'pending' && r.requested_by === p[0]).length }]];
      }
      if (sql.startsWith('SELECT COUNT(*) AS total FROM')) return [[{ total: mine(p[0]).length }]];
      if (sql.startsWith('INSERT INTO friendships')) {
        if (find(p[0], p[1])) throw Object.assign(new Error('dup'), { code: 'ER_DUP_ENTRY' });
        rows.push({ account_lo: p[0], account_hi: p[1], requested_by: p[2], status: 'pending' });
        return [{ affectedRows: 1 }];
      }
      if (sql.startsWith('UPDATE friendships')) {
        const r = find(p[0], p[1]);
        if (!r || r.status !== 'pending' || r.requested_by === p[2]) return [{ affectedRows: 0 }];
        r.status = 'accepted';
        return [{ affectedRows: 1 }];
      }
      if (sql.startsWith('DELETE FROM friendships')) {
        const i = rows.findIndex((r) => r.account_lo === p[0] && r.account_hi === p[1]);
        if (i >= 0) rows.splice(i, 1);
        return [{ affectedRows: i >= 0 ? 1 : 0 }];
      }
      throw new Error(`unexpected SQL ${sql}`);
    },
  };
  const routes = {};
  const app = { post: (path, ...fns) => (routes[`POST ${path}`] = fns.at(-1)), get: (path, ...fns) => (routes[`GET ${path}`] = fns.at(-1)) };
  mountFriends(app, pool, { requireAuth: () => {} });
  const call = async (route, body, accountId) => {
    const res = { code: 200, body: null, status(c) { this.code = c; return this; }, json(b) { this.body = b; return this; } };
    await routes[route]({ user: { accountId }, body }, res);
    return res;
  };
  return { rows, accounts, call };
}

test('a request, then accepting it, makes two friends who see each other with their class and level', async () => {
  const h = harness();
  const sent = await h.call('POST /api/friends/request', { username: 'helix' }, 1);   // any case: the username column is case-insensitive
  assert.strictEqual(sent.code, 200);
  assert.match(sent.body.message, /request sent to Helix/);
  assert.deepStrictEqual(sent.body.data.outgoing, [{ accountId: 2, username: 'Helix' }]);
  const theirs = await h.call('GET /api/friends', null, 2);
  assert.deepStrictEqual(theirs.body.data, { friends: [], incoming: [{ accountId: 1, username: 'Tyler' }], outgoing: [] });
  const ok = await h.call('POST /api/friends/accept', { accountId: 1 }, 2);
  assert.strictEqual(ok.code, 200);
  assert.match(ok.body.message, /You and Tyler are friends now/);
  assert.deepStrictEqual(ok.body.data.friends, [{ accountId: 1, username: 'Tyler', disciplineIndex: 2, level: 40 }]);
  const mine = await h.call('GET /api/friends', null, 1);
  assert.deepStrictEqual(mine.body.data, { friends: [{ accountId: 2, username: 'Helix', disciplineIndex: 11, level: 631 }], incoming: [], outgoing: [] });
  assert.strictEqual(h.rows.length, 1);
});

test('a friend without a character shows null class and level', async () => {
  const h = harness();
  await h.call('POST /api/friends/request', { username: 'warbogar' }, 1);
  await h.call('POST /api/friends/accept', { accountId: 1 }, 3);
  const v = (await h.call('GET /api/friends', null, 1)).body.data;
  assert.deepStrictEqual(v.friends, [{ accountId: 3, username: 'warbogar', disciplineIndex: null, level: null }]);
});

test('asking someone who already asked you accepts, in either order of ids', async () => {
  const h = harness();
  await h.call('POST /api/friends/request', { username: 'Tyler' }, 2);
  const back = await h.call('POST /api/friends/request', { username: 'Helix' }, 1);
  assert.strictEqual(back.code, 200);
  assert.match(back.body.message, /friends now/);
  assert.strictEqual(h.rows[0].status, 'accepted');
});

test('requests are refused with a readable reason', async () => {
  const h = harness();
  for (const [body, code] of [[{}, 400], [{ username: '' }, 400], [{ username: 'x'.repeat(33) }, 400], [{ username: 7 }, 400], [{ username: 'nobody' }, 404], [{ username: 'Gone' }, 404], [{ username: 'tyler' }, 400]]) {
    const r = await h.call('POST /api/friends/request', body, 1);
    assert.strictEqual(r.code, code, JSON.stringify(body));
    assert.strictEqual(r.body.success, false);
    assert.ok(r.body.error.length > 0);
  }
  await h.call('POST /api/friends/request', { username: 'Helix' }, 1);
  const again = await h.call('POST /api/friends/request', { username: 'Helix' }, 1);
  assert.strictEqual(again.code, 409);
  assert.match(again.body.error, /already asked Helix/);
  await h.call('POST /api/friends/accept', { accountId: 1 }, 2);
  const dupe = await h.call('POST /api/friends/request', { username: 'Helix' }, 1);
  assert.strictEqual(dupe.code, 409);
  assert.match(dupe.body.error, /already your friend/);
});

test('you cannot accept your own request, or one that does not exist', async () => {
  const h = harness();
  await h.call('POST /api/friends/request', { username: 'Helix' }, 1);
  assert.strictEqual((await h.call('POST /api/friends/accept', { accountId: 2 }, 1)).code, 404);
  assert.strictEqual((await h.call('POST /api/friends/accept', { accountId: 3 }, 1)).code, 404);
  for (const bad of [null, {}, { accountId: '2' }, { accountId: 0 }, { accountId: -1 }, { accountId: 1.5 }, { accountId: 1 }]) {
    assert.strictEqual((await h.call('POST /api/friends/accept', bad, 1)).code, 400, JSON.stringify(bad));
  }
  assert.strictEqual(h.rows[0].status, 'pending');
});

test('remove unfriends, declines and cancels: the row is gone for both', async () => {
  const h = harness();
  await h.call('POST /api/friends/request', { username: 'Helix' }, 1);
  const cancel = await h.call('POST /api/friends/remove', { accountId: 2 }, 1);
  assert.deepStrictEqual(cancel.body.data, { friends: [], incoming: [], outgoing: [] });
  await h.call('POST /api/friends/request', { username: 'Helix' }, 1);
  await h.call('POST /api/friends/remove', { accountId: 1 }, 2);   // decline
  assert.strictEqual(h.rows.length, 0);
  await h.call('POST /api/friends/request', { username: 'Helix' }, 1);
  await h.call('POST /api/friends/accept', { accountId: 1 }, 2);
  await h.call('POST /api/friends/remove', { accountId: 1 }, 2);   // unfriend
  assert.deepStrictEqual((await h.call('GET /api/friends', null, 1)).body.data.friends, []);
  assert.strictEqual((await h.call('POST /api/friends/remove', { accountId: 2 }, 1)).code, 200);   // already gone: still fine
});

test('a deactivated friend drops out of the list', async () => {
  const h = harness();
  await h.call('POST /api/friends/request', { username: 'Helix' }, 1);
  await h.call('POST /api/friends/accept', { accountId: 1 }, 2);
  h.accounts[1].active = 0;
  assert.deepStrictEqual((await h.call('GET /api/friends', null, 1)).body.data.friends, []);
});

test('the list and the waiting requests are capped', async () => {
  const h = harness();
  for (let i = 0; i < MAX_OUTGOING; i++) h.rows.push({ account_lo: 1, account_hi: 100 + i, requested_by: 1, status: 'pending' });
  const many = await h.call('POST /api/friends/request', { username: 'Helix' }, 1);
  assert.strictEqual(many.code, 409);
  assert.match(many.body.error, /requests waiting/);
  h.rows.length = 0;
  for (let i = 0; i < MAX_FRIENDS; i++) h.rows.push({ account_lo: 2, account_hi: 100 + i, requested_by: 2, status: 'accepted' });
  const full = await h.call('POST /api/friends/request', { username: 'Helix' }, 1);
  assert.strictEqual(full.code, 409);
  assert.match(full.body.error, /Helix's friends list is full/);
});

test('before migration 045 the list is empty and writes answer a readable 503', async () => {
  const h = harness({ missingTable: true });
  const g = await h.call('GET /api/friends', null, 1);
  assert.deepStrictEqual(g.body, { success: true, data: { friends: [], incoming: [], outgoing: [] } });
  const r = await h.call('POST /api/friends/request', { username: 'Helix' }, 1);
  assert.strictEqual(r.code, 503);
  assert.match(r.body.error, /not available just yet/);
});
