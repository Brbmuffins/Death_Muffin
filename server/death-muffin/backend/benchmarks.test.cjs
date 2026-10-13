// Run: node --test server/death-muffin/backend/benchmarks.test.cjs
const test = require('node:test');
const assert = require('node:assert');
const mountBenchmarks = require('./benchmarks.cjs');
const { parseRun, parseFilters, DAILY_CAP } = mountBenchmarks;

const metrics = { avg_fps: 144.5, avg_ms: 6.9, p95_ms: 9.1, p99_ms: 14.2, worst_ms: 40, hitches: 3, draw_calls: 1800, kills_per_min: 52 };
const good = (over = {}) => ({
  clientRunId: 'run_0001-abcd', ranAt: '2026-10-13T12:30:05', version: '0.9.1', godot: '4.7.2', gpu: 'GTX 970', cpu: 'Core i7', os: 'Windows', renderer: 'forward_plus',
  resolution: '1920x1080', cores: 8, refreshHz: 144, preset: 'high', room: 'sanctum', discipline: 2, size: 'standard', length: 'full', standard: true,
  vsyncCapped: false, cancelled: false, metrics: { ...metrics }, breakdown: { base: { draws: 10 }, base_end: { draws: 12 }, rows: [{ what: 'thralls', draws: 5, frame_ms: 1.2 }] }, report: 'line one\nline two', ...over,
});

/** In-memory benchmark_runs / accounts keyed on the SQL text benchmarks.cjs issues, plus a tiny Express stand-in. */
function harness({ missingTable = false, now = () => Date.now() } = {}) {
  const accounts = [{ id: 1, username: 'Tyler', active: 1, role: 'admin' }, { id: 2, username: 'Helix', active: 1, role: 'player' }, { id: 3, username: 'Gone', active: 0, role: 'player' }];
  const rows = [];
  const pool = {
    execute: async (sql, p = []) => {
      if (missingTable) throw Object.assign(new Error("Table doesn't exist"), { code: 'ER_NO_SUCH_TABLE' });
      if (sql.startsWith('SELECT id FROM benchmark_runs')) return [rows.filter((r) => r.account_id === p[0] && r.client_run_id === p[1]).map((r) => ({ id: r.id }))];
      if (sql.startsWith('SELECT COUNT(*)')) return [[{ c: rows.filter((r) => r.account_id === p[0] && now() - r.created < 86400000).length }]];
      if (sql.startsWith('INSERT INTO benchmark_runs')) {
        const [account_id, client_run_id, ran_at, version, godot, gpu, cpu, cores, os, renderer, resolution, refresh_hz, preset, room, discipline_index, size, length, standard, flagged, flag_reason,
          avg_fps, p95_ms, p99_ms, worst_ms, hitches, draw_calls, kills_per_min, metricsJson, breakdown, report] = p;
        assert.strictEqual(p.length, 30);
        rows.push({ id: rows.length + 1, created: now(), created_at: new Date(now()), account_id, client_run_id, ran_at, version, godot, gpu, cpu, cores, os, renderer, resolution, refresh_hz, preset, room, discipline_index, size, length,
          standard, flagged, flag_reason, avg_fps, p95_ms, p99_ms, worst_ms, hitches, draw_calls, kills_per_min, metrics: metricsJson, breakdown, report });
        return [{ insertId: rows.length }];
      }
      if (sql.startsWith('SELECT b.id')) {
        const single = sql.includes('b.id = ?');
        let out = rows.map((r) => ({ ...r, username: accounts.find((a) => a.id === r.account_id).username, active: accounts.find((a) => a.id === r.account_id).active })).filter((r) => r.active);
        if (single) out = out.filter((r) => r.id === p[0]);
        else out = out.filter((r) => !sql.includes('b.flagged = 0') || !r.flagged).filter((r) => !sql.includes('b.standard = 1') || r.standard);
        return [out.reverse()];
      }
      if (sql.startsWith('DELETE FROM benchmark_runs')) {
        const i = rows.findIndex((r) => r.id === p[0]);
        if (i >= 0) rows.splice(i, 1);
        return [{ affectedRows: i >= 0 ? 1 : 0 }];
      }
      throw new Error(`unexpected SQL ${sql}`);
    },
  };
  const routes = {};
  const reg = (m) => (path, ...fns) => { for (const p of [].concat(path)) routes[`${m} ${p}`] = fns.at(-1); };
  const app = { post: reg('POST'), get: reg('GET'), delete: reg('DELETE') };
  mountBenchmarks(app, pool, { requireAuth: () => {}, isStaff: async (req) => accounts.find((a) => a.id === req.user.accountId).role === 'admin' });
  const call = async (route, { body, accountId = 2, params = {}, query = {} } = {}) => {
    const res = { code: 200, body: null, headers: {}, set(k, v) { this.headers[k] = v; }, status(c) { this.code = c; return this; }, json(b) { this.body = b; return this; } };
    await routes[route]({ user: { accountId }, body, params, query }, res);
    return res;
  };
  return { rows, call, routes };
}

test('parseRun accepts the client body and cleans it', () => {
  const { run } = parseRun(good());
  assert.strictEqual(run.ranAt, '2026-10-13 12:30:05');
  assert.strictEqual(run.flagged, false);
  assert.strictEqual(run.flagReason, null);
  assert.strictEqual(run.standard, true);
  assert.strictEqual(run.metrics.avg_fps, 144.5);
  assert.deepStrictEqual(run.breakdown.rows, [{ what: 'thralls', draws: 5, frame_ms: 1.2 }]);
});

test('parseRun refuses bodies it cannot trust, with a readable reason', () => {
  for (const bad of [null, [], {}, good({ clientRunId: 'short' }), good({ clientRunId: 'has space in it' }), good({ preset: 'max' }), good({ room: 'Sanctum!' }), good({ discipline: 21 }),
    good({ discipline: 1.5 }), good({ size: 'huge' }), good({ length: 'long' }), good({ metrics: {} }), good({ metrics: { avg_fps: 'fast' } }), good({ metrics: { avg_fps: Infinity } })]) {
    const r = parseRun(bad);
    assert.ok(r.error && r.error.length > 10, JSON.stringify(bad));
  }
});

test('parseRun clamps strings, drops junk numbers and keys, strips control characters', () => {
  const { run } = parseRun(good({
    gpu: `  ${'G'.repeat(500)}\u0000\n  `, version: 7, os: '\u001b[31mWin', cores: -4, refreshHz: 'x', ranAt: '13/10/2026',
    metrics: { avg_fps: 60, p99_ms: NaN, evil: 'x', 'bad key': 1, nested: { a: 1 }, hitches: 2, huge: 1e30, ...Object.fromEntries(Array.from({ length: 100 }, (_, i) => [`k${i}`, i])) },
    breakdown: { base: 'no', rows: [{ what: 'w'.repeat(200), draws: 'x' }, { draws: 3 }, 'junk', ...Array.from({ length: 100 }, () => ({ what: 'row', draws: 1 }))] },
    report: `a\u0000b\tc\nd${'x'.repeat(30000)}`,
  }));
  assert.strictEqual(run.gpu.length, 120);
  assert.ok(!/[\u0000-\u001f]/.test(run.gpu));
  assert.strictEqual(run.version, '');
  assert.strictEqual(run.os, '[31mWin');
  assert.strictEqual(run.cores, null);
  assert.strictEqual(run.refreshHz, null);
  assert.strictEqual(run.ranAt, null);
  assert.ok(Object.keys(run.metrics).length <= 60);
  assert.ok(!('evil' in run.metrics) && !('nested' in run.metrics) && !('bad key' in run.metrics) && !('p99_ms' in run.metrics));
  assert.strictEqual(run.metrics.huge, 1e9);
  assert.deepStrictEqual(run.breakdown.base, {});
  assert.ok(run.breakdown.rows.length > 30 && run.breakdown.rows.length <= 40);
  assert.strictEqual(run.breakdown.rows[0].what.length, 60);
  assert.ok(!('draws' in run.breakdown.rows[0]));
  assert.strictEqual(run.report.length, 24000);
  assert.ok(run.report.startsWith('ab\tc\nd'));
});

test('flagged = vsync-capped or cancelled, with the reason', () => {
  assert.deepStrictEqual([parseRun(good({ vsyncCapped: true })).run.flagged, parseRun(good({ vsyncCapped: true })).run.flagReason], [true, 'vsync']);
  assert.strictEqual(parseRun(good({ cancelled: true })).run.flagReason, 'cancelled');
  assert.strictEqual(parseRun(good({ cancelled: true, vsyncCapped: true })).run.flagReason, 'cancelled');
  assert.strictEqual(parseRun(good({ vsyncCapped: 'yes' })).run.flagged, false);
  assert.strictEqual(parseRun(good({ standard: 'true' })).run.standard, false);
});

test('POST stores a run and reports its id; both route spellings exist', async () => {
  const h = harness();
  const res = await h.call('POST /api/benchmarks', { body: good({ vsyncCapped: true }) });
  assert.deepStrictEqual(res.body, { success: true, data: { id: 1 } });
  assert.strictEqual(h.rows[0].flagged, 1);
  assert.strictEqual(h.rows[0].flag_reason, 'vsync');
  assert.strictEqual(h.rows[0].avg_fps, 144.5);
  assert.strictEqual(JSON.parse(h.rows[0].metrics).p99_ms, 14.2);
  assert.ok(h.routes['POST /benchmarks'] && h.routes['GET /benchmarks'] && h.routes['GET /benchmarks/:id'] && h.routes['DELETE /api/benchmarks/:id']);
  const bad = await h.call('POST /api/benchmarks', { body: good({ preset: 'x' }) });
  assert.strictEqual(bad.code, 400);
  assert.strictEqual(bad.body.success, false);
});

test('a retried clientRunId is idempotent; another account may reuse the id', async () => {
  const h = harness();
  const first = await h.call('POST /api/benchmarks', { body: good() });
  const again = await h.call('POST /api/benchmarks', { body: good({ report: 'different' }) });
  assert.strictEqual(again.code, 200);
  assert.strictEqual(again.body.data.id, first.body.data.id);
  assert.strictEqual(h.rows.length, 1);
  const other = await h.call('POST /api/benchmarks', { body: good(), accountId: 1 });
  assert.notStrictEqual(other.body.data.id, first.body.data.id);
  assert.strictEqual(h.rows.length, 2);
});

test('POST refuses past the daily cap, but a retry of a stored run still answers', async () => {
  const h = harness();
  for (let i = 0; i < DAILY_CAP; i++) assert.strictEqual((await h.call('POST /api/benchmarks', { body: good({ clientRunId: `run-number-${i}` }) })).code, 200);
  const over = await h.call('POST /api/benchmarks', { body: good({ clientRunId: 'run-one-too-many' }) });
  assert.strictEqual(over.code, 429);
  assert.match(over.body.error, /tomorrow/);
  assert.strictEqual((await h.call('POST /api/benchmarks', { body: good({ clientRunId: 'run-number-3' }) })).code, 200);
  assert.strictEqual((await h.call('POST /api/benchmarks', { body: good({ clientRunId: 'run-other-acct' }), accountId: 1 })).code, 200);
});

test('a missing table answers a readable 503 on write, empty on list', async () => {
  const h = harness({ missingTable: true });
  const w = await h.call('POST /api/benchmarks', { body: good() });
  assert.strictEqual(w.code, 503);
  assert.ok(w.body.error.length > 10);
  assert.deepStrictEqual((await h.call('GET /api/benchmarks')).body, { success: true, runs: [] });
});

test('the public list hides private fields, flagged runs and inactive accounts; detail has the report', async () => {
  const h = harness();
  await h.call('POST /api/benchmarks', { body: good() });
  await h.call('POST /api/benchmarks', { body: good({ clientRunId: 'flagged-run-1', cancelled: true }) });
  await h.call('POST /api/benchmarks', { body: good({ clientRunId: 'gone-run-0001' }), accountId: 3 });
  const list = await h.call('GET /benchmarks');
  assert.strictEqual(list.headers['Cache-Control'], 'public, max-age=30');
  assert.strictEqual(list.body.runs.length, 1);
  const run = list.body.runs[0];
  assert.strictEqual(run.username, 'Helix');
  assert.strictEqual(run.avgFps, 144.5);
  assert.strictEqual(run.discipline, 2);
  for (const k of ['email', 'accountId', 'account_id', 'metrics', 'report', 'clientRunId']) assert.ok(!(k in run), k);
  const all = await h.call('GET /api/benchmarks', { query: { includeFlagged: '1' } });
  assert.strictEqual(all.body.runs.length, 2);
  assert.strictEqual(all.body.runs[0].flagReason, 'cancelled');
  const one = await h.call('GET /api/benchmarks/:id', { params: { id: '1' } });
  assert.strictEqual(one.body.run.report, 'line one\nline two');
  assert.strictEqual(one.body.run.metrics.draw_calls, 1800);
  assert.strictEqual(one.body.run.breakdown.rows[0].what, 'thralls');
  assert.ok(!('account_id' in one.body.run) && !('email' in one.body.run));
  assert.strictEqual((await h.call('GET /api/benchmarks/:id', { params: { id: '3' } })).code, 404);   // inactive account
  assert.strictEqual((await h.call('GET /api/benchmarks/:id', { params: { id: 'x' } })).code, 404);
});

test('list filters are validated', () => {
  assert.ok(parseFilters({ room: 'Bad Room' }).error);
  assert.ok(parseFilters({ discipline: '99' }).error);
  assert.ok(parseFilters({ size: 'huge' }).error);
  assert.ok(parseFilters({ before: '1; DROP' }).error);
  assert.ok(parseFilters({ limit: '0' }).error);
  assert.ok(parseFilters({ room: ['a', 'b'] }).where, 'a repeated key is ignored, not a crash');
  const f = parseFilters({ gpu: '50%_\\x', limit: '99999', standard: '1', room: 'sanctum', discipline: '2' });
  assert.strictEqual(f.limit, 1000);
  assert.ok(f.where.includes('b.standard = 1') && f.where.includes('b.flagged = 0') && f.where.includes('a.active = 1'));
  assert.ok(f.params.includes('%50\\%\\_\\\\x%'));
  assert.strictEqual(parseFilters({}).limit, 200);
  assert.ok(!parseFilters({ includeFlagged: '1' }).where.includes('flagged'));
});

test('only staff can delete a run', async () => {
  const h = harness();
  await h.call('POST /api/benchmarks', { body: good() });
  const denied = await h.call('DELETE /api/benchmarks/:id', { params: { id: '1' }, accountId: 2 });
  assert.strictEqual(denied.code, 403);
  assert.strictEqual(denied.body.success, false);
  assert.strictEqual(h.rows.length, 1);
  assert.strictEqual((await h.call('DELETE /api/benchmarks/:id', { params: { id: '1' }, accountId: 1 })).code, 200);
  assert.strictEqual(h.rows.length, 0);
  assert.strictEqual((await h.call('DELETE /api/benchmarks/:id', { params: { id: '1' }, accountId: 1 })).code, 404);
});
