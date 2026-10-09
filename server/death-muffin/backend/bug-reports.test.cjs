// Run: node --test server/death-muffin/backend/bug-reports.test.cjs
const test = require('node:test');
const assert = require('node:assert');
const mountBugReports = require('./bug-reports.cjs');
const { parseReport, cleanContext } = mountBugReports;

/** In-memory bug_reports table keyed on the SQL text the module issues, plus a tiny Express stand-in. */
function harness({ owned = [7] } = {}) {
  const rows = [];
  const pool = {
    execute: async (sql, params = []) => {
      if (sql.startsWith('SELECT COUNT(*)')) return [[{ n: rows.filter((r) => r.account_id === params[0]).length }]];
      if (sql.startsWith('INSERT INTO bug_reports')) {
        const [account_id, character_id, category, message, context] = params;
        rows.push({ id: rows.length + 1, account_id, character_id, category, message, context, status: 'new', agent_notes: null, created_at: new Date() });
        return [{ insertId: rows.length }];
      }
      if (sql.trim().startsWith('SELECT id, category')) return [rows.filter((r) => r.account_id === params[0]).reverse()];
      throw new Error(`unexpected SQL ${sql}`);
    },
  };
  const routes = {};
  const app = { post: (p, _a, fn) => (routes[`POST ${p}`] = fn), get: (p, _a, fn) => (routes[`GET ${p}`] = fn) };
  mountBugReports(app, pool, { requireAuth: () => {}, ownsCharacter: async (_req, id) => owned.includes(id) });
  const call = async (route, body) => {
    const res = { code: 200, body: null, status(c) { this.code = c; return this; }, json(b) { this.body = b; return this; } };
    await routes[route]({ user: { accountId: 1 }, body }, res);
    return res;
  };
  return { rows, call };
}

test('parseReport rejects short and overlong text, defaults the category', () => {
  assert.ok(parseReport({ message: 'too short' }).error);
  assert.ok(parseReport({ message: 'x'.repeat(2001) }).error);
  const ok = parseReport({ message: '  My thralls vanish after a zone change.  ', category: 'nonsense' });
  assert.deepStrictEqual(ok.report.category, 'bug');
  assert.strictEqual(ok.report.message, 'My thralls vanish after a zone change.');
});

test('parseReport strips control characters but keeps newlines', () => {
  const { report } = parseReport({ message: 'line one\u0000\u001b[31m\nline two here' });
  assert.strictEqual(report.message, 'line one[31m\nline two here');
});

test('cleanContext keeps short scalars and the last five errors, drops objects and bad keys', () => {
  const ctx = cleanContext({ area: 'graves', level: 12, ok: true, nested: { a: 1 }, 'bad key': 1, errors: ['a', 'b', 'c', 'd', 'e', 'f', 3] });
  assert.deepStrictEqual(ctx, { area: 'graves', level: 12, ok: true, errors: ['b', 'c', 'd', 'e', 'f'] });
  assert.deepStrictEqual(cleanContext(null), {});
  assert.deepStrictEqual(cleanContext(['x']), {});
});

test('cleanContext stays under its byte budget', () => {
  const ctx = cleanContext({ errors: Array.from({ length: 5 }, () => 'e'.repeat(400)), ...Object.fromEntries(Array.from({ length: 20 }, (_, i) => [`k${i}`, 'v'.repeat(300)])) });
  assert.ok(JSON.stringify(ctx).length <= 4000);
});

test('POST files a report; a character the account does not own is dropped, not trusted', async () => {
  const h = harness();
  const res = await h.call('POST /api/bug-reports', { message: 'The vault closes when I sort it.', category: 'ui', characterId: 99, context: { area: 'acre' } });
  assert.strictEqual(res.body.success, true);
  assert.strictEqual(h.rows[0].character_id, null);
  assert.strictEqual(h.rows[0].category, 'ui');
  assert.deepStrictEqual(JSON.parse(h.rows[0].context), { area: 'acre' });
  await h.call('POST /api/bug-reports', { message: 'Second report, my own character.', characterId: 7 });
  assert.strictEqual(h.rows[1].character_id, 7);
});

test('POST refuses past the daily cap', async () => {
  const h = harness();
  for (let i = 0; i < 10; i++) assert.strictEqual((await h.call('POST /api/bug-reports', { message: `report number ${i} here` })).code, 200);
  assert.strictEqual((await h.call('POST /api/bug-reports', { message: 'one report too many' })).code, 429);
});

test('GET mine shows player-facing status and hides notes until there is a verdict', async () => {
  const h = harness();
  await h.call('POST /api/bug-reports', { message: 'First: the minimap is blank.' });
  await h.call('POST /api/bug-reports', { message: 'Second: Q does not drink.' });
  Object.assign(h.rows[0], { status: 'fixed', agent_notes: 'Thanks, the minimap now redraws after travel.' });
  h.rows[1].agent_notes = 'internal draft';
  const { body } = await h.call('GET /api/bug-reports/mine');
  assert.strictEqual(body.data[0].status, 'Received');
  assert.strictEqual(body.data[0].note, null);
  assert.strictEqual(body.data[1].status, 'Fixed in an upcoming update');
  assert.match(body.data[1].note, /minimap now redraws/);
});

test('a released report reads as live for the player', async () => {
  const h = harness();
  await h.call('POST /api/bug-reports', { message: 'Thralls stop after waystone travel.' });
  Object.assign(h.rows[0], { status: 'released', agent_notes: 'Fixed: thralls follow you through waystones again.' });
  const { body } = await h.call('GET /api/bug-reports/mine');
  assert.strictEqual(body.data[0].status, 'Fixed — live now');
});

test('cleanContext keeps the tail of a game log apart from the context budget', () => {
  const log = 'old line\n'.repeat(3000) + 'SCRIPT ERROR: tooltip\u0007 crash';
  const ctx = cleanContext({ area: 'graves', log, errors: Array.from({ length: 5 }, () => 'e'.repeat(400)) });
  assert.strictEqual(ctx.area, 'graves');
  assert.strictEqual(ctx.errors.length, 5);
  assert.strictEqual(ctx.log.length, 12000);
  assert.ok(ctx.log.endsWith('SCRIPT ERROR: tooltip crash'));
  assert.deepStrictEqual(cleanContext({ log: 42 }), {});
  assert.deepStrictEqual(cleanContext({ log: '   ' }), {});
});
