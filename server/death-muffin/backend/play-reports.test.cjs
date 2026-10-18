// Run: node --test server/death-muffin/backend/play-reports.test.cjs
const test = require('node:test');
const assert = require('node:assert');
const mountPlayReports = require('./play-reports.cjs');
const { parseReport, readRow, summarize, DAILY_CAP } = mountPlayReports;

const V1 = '20261018.211258-bb6acd8';
const V0 = '20261010.000000-aaaaaaa';
const T0 = 1_760_000_000_000;        // party session clocks are epoch ms
const HOUR = 3_600_000;
const S1 = 'a1'.repeat(16);          // party session ids are 32 hex characters
const S2 = 'b2'.repeat(16);
const S3 = 'c3'.repeat(16);

const frames = (over = {}) => ({ count: 100000, avgMs: 8, p50Ms: 7, p99Ms: 20, worstMs: 100, hitches: 10, hist: [1, 2, 3, 4, 5, 6, 7, 8, 9], ...over });
const good = (over = {}) => ({
  reportId: 'report-0001-abcdefgh', version: V1, seconds: 3600, endReason: 'quit', endArea: 'graves', discipline: 2, level: 31, partySize: 2, host: true, preset: 'high',
  gpu: 'NVIDIA GeForce RTX 3060', driver: 'Vulkan 1.3.255', os: 'Windows 11', cpuCores: 8, ramMb: 16384, resolution: '2560x1440', vsync: true, fpsCap: 0,
  frames: frames(), areas: { graves: { seconds: 3000, deaths: 6, avgMs: 8 }, fen: { seconds: 600, deaths: 0, avgMs: 10 } }, sessionIds: [S1], ...over,
});

/** In-memory play_reports and the party / value-ledger tables the summary reads, keyed on the SQL play-reports.cjs issues, plus a tiny Express stand-in. */
function harness({ missingTable = false, cacheMs = 0 } = {}) {
  let clock = T0;
  const rows = [];
  const sessions = new Map();   // id -> { ended_at, last_host_at }
  const members = [];           // { session_id, character_id, account_id, joined_at, left_at, accepted_kills, accepted_bosses }
  const ledger = [];            // { character_id, currency, delta, reason, created_at }
  const stats = { reads: 0 };
  const flat = (sql) => sql.replace(/\s+/g, ' ').trim();
  const pool = {
    execute: async (rawSql, p = []) => {
      const sql = flat(rawSql);
      if (missingTable) throw Object.assign(new Error("Table doesn't exist"), { code: 'ER_NO_SUCH_TABLE' });
      if (sql.startsWith('SELECT id FROM play_reports WHERE account_id = ? AND report_id = ?')) return [rows.filter((r) => r.account_id === p[0] && r.report_id === p[1]).map((r) => ({ id: r.id }))];
      if (sql.startsWith('SELECT COUNT(*) AS c FROM play_reports WHERE account_id = ?')) return [[{ c: rows.filter((r) => r.account_id === p[0] && clock - r.created < 86400000).length }]];
      if (sql.startsWith('INSERT INTO play_reports')) {
        const m = /INSERT INTO play_reports \(([^)]*)\) VALUES \(([^)]*)\)/.exec(sql);
        const cols = m[1].split(',').map((c) => c.trim());
        assert.strictEqual(m[2].split(',').length, cols.length, 'one ? per column');
        assert.strictEqual(p.length, cols.length, 'one parameter per column');
        const row = Object.fromEntries(cols.map((c, i) => [c, p[i]]));
        rows.push({ id: rows.length + 1, created: clock, created_at: new Date(clock), ...row });
        return [{ insertId: rows.length }];
      }
      if (sql.startsWith('SELECT version, COUNT(*) AS reports')) {
        stats.reads++;
        const by = new Map();
        for (const r of rows) { if (!by.has(r.version)) by.set(r.version, []); by.get(r.version).push(r); }
        const out = [...by].map(([version, list]) => ({
          version, reports: list.length, players: new Set(list.map((r) => r.account_id)).size, seconds: list.reduce((a, r) => a + r.seconds, 0),
          first_at: new Date(Math.min(...list.map((r) => r.created))), last_at: new Date(Math.max(...list.map((r) => r.created))),
        }));
        out.sort((a, b) => b.first_at - a.first_at || (a.version < b.version ? 1 : -1));
        return [out];
      }
      if (sql.startsWith('SELECT id, account_id, seconds, end_reason')) {
        stats.reads++;
        const limit = Number(/LIMIT (\d+)$/.exec(sql)[1]);
        return [rows.filter((r) => r.version === p[0]).sort((a, b) => b.id - a.id).slice(0, limit)];
      }
      throw new Error(`unexpected SQL ${sql}`);
    },
    // IN (?) lists go through query(), as in loot.cjs
    query: async (rawSql, p = []) => {
      const sql = flat(rawSql);
      if (missingTable) throw Object.assign(new Error("Table doesn't exist"), { code: 'ER_NO_SUCH_TABLE' });
      stats.reads++;
      if (sql.startsWith('SELECT m.session_id, m.account_id, m.joined_at, m.left_at, m.accepted_kills, m.accepted_bosses, s.ended_at, s.last_host_at FROM party_session_members m JOIN party_sessions s ON s.id = m.session_id WHERE m.session_id IN (?)')) {
        return [members.filter((m) => p[0].includes(m.session_id)).map((m) => ({ ...m, ended_at: sessions.get(m.session_id).ended_at, last_host_at: sessions.get(m.session_id).last_host_at }))];
      }
      if (sql.startsWith('SELECT l.currency AS currency, SUM(l.delta) AS total FROM party_session_members m JOIN party_sessions s ON s.id = m.session_id JOIN value_ledger l ON l.character_id = m.character_id')) {
        // the JOIN's conditions, as written in the SQL
        assert.ok(sql.includes("l.reason = 'save'") && sql.includes('l.delta > 0') && sql.includes('GROUP BY l.currency'));
        const sums = new Map();
        for (const m of members.filter((x) => p[0].includes(x.session_id))) {
          const s = sessions.get(m.session_id);
          const end = m.left_at ?? s.ended_at ?? s.last_host_at;
          for (const l of ledger) {
            if (l.character_id !== m.character_id || l.reason !== 'save' || !['xp', 'gold'].includes(l.currency) || !(l.delta > 0)) continue;
            if (l.created_at >= m.joined_at && l.created_at <= end) sums.set(l.currency, (sums.get(l.currency) || 0) + l.delta);
          }
        }
        return [[...sums].map(([currency, total]) => ({ currency, total: String(total) }))];
      }
      throw new Error(`unexpected SQL ${sql}`);
    },
  };
  const routes = {};
  const reg = (m) => (path, ...fns) => { for (const p of [].concat(path)) routes[`${m} ${p}`] = fns; };
  const app = { post: reg('POST'), get: reg('GET') };
  // requireJWT's 401 has no code
  const requireAuth = (req, res, next) => (req.user ? next() : res.status(401).json({ success: false, error: 'missing or invalid Authorization header' }));
  const limiter = (req, res, next) => next();
  mountPlayReports(app, pool, { requireAuth, limiter, cacheMs });
  const call = async (route, { body, accountId = 2, query = {}, anon = false } = {}) => {
    const res = { statusCode: 200, body: null, headers: {}, set(k, v) { this.headers[k] = v; }, status(c) { this.statusCode = c; return this; }, json(b) { this.body = b; return this; } };
    const req = { user: anon ? undefined : { accountId }, body, query };
    const fns = routes[route];
    let i = 0;
    const next = async () => { const fn = fns[i++]; if (fn) await fn(req, res, next); };
    await next();
    return res;
  };
  return { rows, sessions, members, ledger, stats, call, routes, setClock: (ms) => { clock = ms; }, advance: (ms) => { clock += ms; } };
}

test('parseReport accepts the contract body and cleans it', () => {
  const { report } = parseReport(good());
  assert.strictEqual(report.reportId, 'report-0001-abcdefgh');
  assert.strictEqual(report.version, V1);
  assert.strictEqual(report.seconds, 3600);
  assert.strictEqual(report.endReason, 'quit');
  assert.strictEqual(report.endArea, 'graves');
  assert.deepStrictEqual([report.discipline, report.level, report.partySize, report.host, report.preset], [2, 31, 2, true, 'high']);
  assert.deepStrictEqual([report.gpu, report.driver, report.os, report.resolution], ['NVIDIA GeForce RTX 3060', 'Vulkan 1.3.255', 'Windows 11', '2560x1440']);
  assert.deepStrictEqual([report.cpuCores, report.ramMb, report.vsync, report.fpsCap], [8, 16384, true, 0]);
  assert.deepStrictEqual(report.frames, { count: 100000, avgMs: 8, p50Ms: 7, p99Ms: 20, worstMs: 100, hitches: 10, hist: [1, 2, 3, 4, 5, 6, 7, 8, 9] });
  assert.deepStrictEqual(report.areas.fen, { seconds: 600, deaths: 0, avgMs: 10 });
  assert.deepStrictEqual(report.sessionIds, [S1]);
});

test('parseReport refuses a body with no usable id, version or play time, with a readable reason', () => {
  for (const bad of [null, [], 'text', {}, good({ reportId: 'short' }), good({ reportId: 'has space in the id here' }), good({ reportId: 'x'.repeat(65) }), good({ reportId: 12345678901234567 }),
    good({ version: '' }), good({ version: undefined }), good({ version: 'not a version' }), good({ version: 7 }), good({ seconds: undefined }), good({ seconds: '3600' }),
    good({ seconds: NaN }), good({ seconds: Infinity })]) {
    const r = parseReport(bad);
    assert.ok(r.error && r.error.length > 10 && !r.report, JSON.stringify(bad));
  }
  assert.ok(parseReport(good({ reportId: `  ${'r'.repeat(16)}  ` })).report, 'a padded id is trimmed');
});

test('parseReport clamps numbers, falls back on enums, drops unknown keys and junk', () => {
  const { report } = parseReport(good({
    seconds: 1e9, discipline: 99, level: -3, partySize: 9, cpuCores: 0, ramMb: 1e12, fpsCap: 5000, endReason: 'exploded', preset: 'max', vsync: 'yes', host: 'true',
    email: 'a@b.c', accountId: 7, chat: 'hello', frames: { count: -5, avgMs: 'x', p99Ms: NaN, worstMs: 1e12, hitches: 2.6, hist: [1, 2, 3], extra: 1 },
  }));
  assert.strictEqual(report.seconds, 86400);
  assert.deepStrictEqual([report.discipline, report.level, report.partySize, report.cpuCores, report.ramMb, report.fpsCap], [20, 0, 4, 1, 4194304, 1000]);
  assert.strictEqual(parseReport(good({ seconds: -5, partySize: 0, level: 500 })).report.seconds, 0);
  assert.strictEqual(parseReport(good({ partySize: 0 })).report.partySize, 1);
  assert.strictEqual(parseReport(good({ level: 500 })).report.level, 200);
  assert.strictEqual(report.endReason, 'unknown');
  assert.strictEqual(report.preset, null);
  assert.strictEqual(report.vsync, null);
  assert.strictEqual(report.host, false);
  assert.deepStrictEqual(Object.keys(report).sort(), ['areas', 'cpuCores', 'discipline', 'driver', 'endArea', 'endReason', 'fpsCap', 'frames', 'gpu', 'host', 'level', 'os', 'partySize', 'preset',
    'ramMb', 'reportId', 'resolution', 'seconds', 'sessionIds', 'version', 'vsync']);
  assert.strictEqual(report.frames.count, 0);
  assert.strictEqual(report.frames.avgMs, null);
  assert.strictEqual(report.frames.p99Ms, null);
  assert.strictEqual(report.frames.worstMs, 600000);
  assert.strictEqual(report.frames.hitches, 3);
  assert.strictEqual(report.frames.hist, null, 'a histogram that is not 9 numbers is dropped');
  assert.ok(!('extra' in report.frames));
  for (const bad of [undefined, null, 'x', [1]]) assert.deepStrictEqual(parseReport(good({ frames: bad })).report.frames, { count: 0, avgMs: null, p50Ms: null, p99Ms: null, worstMs: null, hitches: 0, hist: null });
});

test('parseReport trims and caps strings and strips control and hidden characters', () => {
  const { report } = parseReport(good({
    gpu: `  ${'G'.repeat(500)}\u0000\n  `, driver: 'Vulkan\u0000 1.3\u0007', os: '\u001b[31mWin\u202edows\u200b 11\ttab', endArea: `${'a'.repeat(40)}`, resolution: 'x'.repeat(100), version: `  ${V1}\n`,
  }));
  assert.strictEqual(report.gpu.length, 120);
  assert.ok(!/[\u0000-\u001f]/.test(report.gpu));
  assert.strictEqual(report.driver, 'Vulkan 1.3');
  assert.strictEqual(report.os, '[31mWindows 11 tab');
  assert.strictEqual(report.endArea.length, 24);
  assert.strictEqual(report.resolution.length, 20);
  assert.strictEqual(report.version, V1);
  assert.strictEqual(parseReport(good({ gpu: 42, os: { a: 1 } })).report.gpu, '');
});

test('areas keep at most 24 identifier-named entries with a finite play time; session ids are unique, clean and at most 20', () => {
  const many = Object.fromEntries(Array.from({ length: 60 }, (_, i) => [`area_${i}`, { seconds: 10, deaths: 1, avgMs: 5 }]));
  const { report } = parseReport(good({
    areas: { ...many, 'bad key!': { seconds: 5 }, nope: 'x', nosec: { deaths: 3 }, [`${'z'.repeat(25)}`]: { seconds: 1 } },
    sessionIds: [S1, S1, `  ${S2}  `, 'bad id', '', 7, 'x'.repeat(65), ...Array.from({ length: 40 }, (_, i) => `id-${i}`)],
  }));
  assert.strictEqual(Object.keys(report.areas).length, 24);
  assert.ok(Object.keys(report.areas).every((k) => /^[A-Za-z0-9_-]{1,24}$/.test(k)));
  assert.strictEqual(report.sessionIds.length, 20);
  assert.deepStrictEqual(report.sessionIds.slice(0, 2), [S1, S2]);
  const one = parseReport(good({ areas: { graves: { seconds: 1e9, deaths: -4, avgMs: 'x' }, fen: { seconds: 5, deaths: 2.4 } } })).report.areas;
  assert.deepStrictEqual(one.graves, { seconds: 86400, deaths: 0, avgMs: null });
  assert.deepStrictEqual(one.fen, { seconds: 5, deaths: 2, avgMs: null });
  assert.deepStrictEqual(parseReport(good({ areas: [1, 2], sessionIds: 'x' })).report.areas, {});
  assert.deepStrictEqual(parseReport(good({ areas: null, sessionIds: null })).report.sessionIds, []);
});

test('POST stores a report and answers its id; both route spellings exist', async () => {
  const h = harness();
  assert.ok(h.routes['POST /api/play-reports'] && h.routes['POST /play-reports'] && h.routes['GET /api/play-reports/releases'] && h.routes['GET /play-reports/summary']);
  const res = await h.call('POST /api/play-reports', { body: good() });
  assert.strictEqual(res.statusCode, 200);
  assert.deepStrictEqual(res.body, { success: true, data: { id: 1 } });
  const row = h.rows[0];
  assert.deepStrictEqual([row.account_id, row.report_id, row.version, row.seconds, row.end_reason, row.end_area], [2, 'report-0001-abcdefgh', V1, 3600, 'quit', 'graves']);
  assert.deepStrictEqual([row.discipline_index, row.level, row.party_size, row.host, row.preset, row.vsync, row.fps_cap, row.cpu_cores, row.ram_mb], [2, 31, 2, 1, 'high', 1, 0, 8, 16384]);
  assert.deepStrictEqual([row.frames_count, row.avg_ms, row.p50_ms, row.p99_ms, row.worst_ms, row.hitches], [100000, 8, 7, 20, 100, 10]);
  assert.deepStrictEqual(JSON.parse(row.frame_hist), [1, 2, 3, 4, 5, 6, 7, 8, 9]);
  assert.strictEqual(JSON.parse(row.areas).graves.deaths, 6);
  assert.deepStrictEqual(JSON.parse(row.session_ids), [S1]);
  const second = await h.call('POST /play-reports', { body: good({ reportId: 'report-0002-abcdefgh' }) });
  assert.strictEqual(second.body.data.id, 2);
  const bad = await h.call('POST /api/play-reports', { body: good({ reportId: 'x' }) });
  assert.strictEqual(bad.statusCode, 400);
  assert.deepStrictEqual([bad.body.success, bad.body.code], [false, 'bad_request']);
  assert.ok(bad.body.error.length > 10);
  assert.strictEqual(h.rows.length, 2);
});

test('a resent reportId answers the first id and stores nothing; another account may reuse the id', async () => {
  const h = harness();
  const first = await h.call('POST /api/play-reports', { body: good() });
  const again = await h.call('POST /api/play-reports', { body: good({ seconds: 5, gpu: 'something else' }) });
  assert.strictEqual(again.statusCode, 200);
  assert.strictEqual(again.body.data.id, first.body.data.id);
  assert.strictEqual(h.rows.length, 1);
  assert.strictEqual(h.rows[0].seconds, 3600, 'the first row is kept as it was');
  const other = await h.call('POST /api/play-reports', { body: good(), accountId: 1 });
  assert.notStrictEqual(other.body.data.id, first.body.data.id);
  assert.strictEqual(h.rows.length, 2);
});

test('a resend that races the first insert answers the stored id', async () => {
  // the unique key (account_id, report_id) is the last word: an insert that loses the race comes back as a duplicate
  let lookups = 0;
  const pool = {
    execute: async (sql) => {
      if (sql.startsWith('SELECT id FROM play_reports')) return [lookups++ === 0 ? [] : [{ id: 41 }]];
      if (sql.startsWith('SELECT COUNT(*)')) return [[{ c: 0 }]];
      throw Object.assign(new Error('Duplicate entry'), { code: 'ER_DUP_ENTRY' });
    },
  };
  const table = {};
  mountPlayReports({ post: (path, ...fns) => { for (const p of [].concat(path)) table[p] = fns; }, get: () => {} }, pool, { requireAuth: (req, res, next) => next() });
  const res = { statusCode: 200, set() {}, status(c) { this.statusCode = c; return this; }, json(b) { this.body = b; return this; } };
  const handler = table['/play-reports'].at(-1);
  await handler({ user: { accountId: 2 }, body: good() }, res);
  assert.deepStrictEqual(res.body, { success: true, data: { id: 41 } });
});

test('POST refuses past the daily cap of 50, but a resend of a stored report still answers', async () => {
  assert.strictEqual(DAILY_CAP, 50);
  const h = harness();
  for (let i = 0; i < DAILY_CAP; i++) assert.strictEqual((await h.call('POST /api/play-reports', { body: good({ reportId: `report-number-${String(i).padStart(4, '0')}` }) })).statusCode, 200);
  const over = await h.call('POST /api/play-reports', { body: good({ reportId: 'report-one-too-many-x' }) });
  assert.strictEqual(over.statusCode, 429);
  assert.deepStrictEqual([over.body.success, over.body.code], [false, 'rate_limited']);
  assert.match(over.body.error, /tomorrow/);
  assert.strictEqual(h.rows.length, DAILY_CAP);
  assert.strictEqual((await h.call('POST /api/play-reports', { body: good({ reportId: 'report-number-0003' }) })).statusCode, 200);
  assert.strictEqual((await h.call('POST /api/play-reports', { body: good({ reportId: 'report-other-acct-1' }), accountId: 1 })).statusCode, 200);
  h.advance(25 * 3600 * 1000);
  assert.strictEqual((await h.call('POST /api/play-reports', { body: good({ reportId: 'report-next-day-001' }) })).statusCode, 200);
});

test('POST needs a signed-in player: 401 with a code, and nothing is stored', async () => {
  const h = harness();
  const res = await h.call('POST /api/play-reports', { body: good(), anon: true });
  assert.strictEqual(res.statusCode, 401);
  assert.deepStrictEqual([res.body.success, res.body.code], [false, 'unauthorized']);
  assert.ok(res.body.error);
  assert.strictEqual(h.rows.length, 0);
  assert.strictEqual((await h.call('POST /play-reports', { body: good(), anon: true })).statusCode, 401);
  // the reads are public
  assert.strictEqual((await h.call('GET /api/play-reports/releases', { anon: true })).statusCode, 200);
  assert.strictEqual((await h.call('GET /api/play-reports/summary', { anon: true, query: { version: V1 } })).statusCode, 200);
});

test('a missing table answers a readable 503 on write and an empty answer on read', async () => {
  const h = harness({ missingTable: true });
  const w = await h.call('POST /api/play-reports', { body: good() });
  assert.strictEqual(w.statusCode, 503);
  assert.deepStrictEqual([w.body.success, w.body.code], [false, 'unavailable']);
  assert.ok(w.body.error.length > 10);
  assert.deepStrictEqual((await h.call('GET /api/play-reports/releases')).body, { success: true, releases: [] });
  const s = (await h.call('GET /api/play-reports/summary', { query: { version: V1 } })).body.summary;
  assert.deepStrictEqual([s.reports, s.players, s.hours, s.presets, s.gpus, s.areas], [0, 0, 0, [], [], []]);
  assert.strictEqual(s.server.sessions, 0);
});

/** The fixed data set: four reports of V1 (one with no frames), one of V0, and the party sessions, members and saves behind them. */
async function seed(h) {
  h.setClock(T0 - 10 * 86400000);
  await h.call('POST /api/play-reports', { accountId: 1, body: good({ reportId: 'old-release-0000001', version: V0, seconds: 900, sessionIds: [] }) });
  h.setClock(T0);
  // acct 1 (Tyler): 3600 s, high, RTX 3060; acct 2 (Helix): 1800 s, high, RTX 3060; both in the same party session S1
  await h.call('POST /api/play-reports', { accountId: 1, body: good({ reportId: 'tyler-report-000001' }) });
  await h.call('POST /api/play-reports', {
    accountId: 2,
    body: good({ reportId: 'helix-report-000001', seconds: 1800, frames: frames({ count: 50000, avgMs: 10, p99Ms: 30, worstMs: 300, hitches: 40 }), areas: { graves: { seconds: 1800, deaths: 3, avgMs: 10 } }, sessionIds: [S1] }),
  });
  // acct 3 (War): 600 s, low, GTX 970, crashed in the fen; names S2 (a member) and S3 (never a member) and something that is no session id
  await h.call('POST /api/play-reports', {
    accountId: 3,
    body: good({ reportId: 'war-report-0000001', seconds: 600, endReason: 'crash', endArea: 'fen', preset: 'low', gpu: 'GTX 970', frames: frames({ count: 20000, avgMs: 16, p99Ms: 45, worstMs: 250, hitches: 30 }),
      areas: { fen: { seconds: 600, deaths: 1, avgMs: 16 } }, sessionIds: [S2, S3, 'not-a-session'] }),
  });
  // acct 1 again: 1200 s, low, GTX 970, logged out, no frame times, no session
  await h.call('POST /api/play-reports', {
    accountId: 1,
    body: good({ reportId: 'tyler-report-000002', seconds: 1200, endReason: 'logout', endArea: '', preset: 'low', gpu: 'GTX 970', frames: {}, areas: {}, sessionIds: [] }),
  });
  // S1: Tyler (11) 1 h to the session's end, Helix (12) 30 min to its explicit leave, a third member (13, no report) 30 min
  h.sessions.set(S1, { ended_at: T0 + HOUR, last_host_at: T0 + HOUR });
  h.members.push({ session_id: S1, character_id: 11, account_id: 1, joined_at: T0, left_at: null, accepted_kills: 3000, accepted_bosses: 6 });
  h.members.push({ session_id: S1, character_id: 12, account_id: 2, joined_at: T0 + HOUR / 2, left_at: T0 + HOUR, accepted_kills: 1000, accepted_bosses: 2 });
  h.members.push({ session_id: S1, character_id: 13, account_id: 9, joined_at: T0, left_at: T0 + HOUR / 2, accepted_kills: 500, accepted_bosses: 0 });
  // S2: still open, no end: War (21) from joining to the host's last call, 30 min
  h.sessions.set(S2, { ended_at: null, last_host_at: T0 + 10_000_000 + HOUR / 2 });
  h.members.push({ session_id: S2, character_id: 21, account_id: 3, joined_at: T0 + 10_000_000, left_at: null, accepted_kills: 400, accepted_bosses: 1 });
  // S3: War is not a member of it, so naming it earns nothing
  h.sessions.set(S3, { ended_at: T0 + HOUR, last_host_at: T0 + HOUR });
  h.members.push({ session_id: S3, character_id: 31, account_id: 2, joined_at: T0, left_at: null, accepted_kills: 99999, accepted_bosses: 99, });
  const save = (character_id, currency, delta, at, reason = 'save') => h.ledger.push({ character_id, currency, delta, reason, created_at: at });
  save(11, 'xp', 5000, T0 + 100); save(11, 'gold', 2000, T0 + 200);
  save(11, 'xp', 700, T0 + HOUR + 100);                       // after Tyler's window
  save(11, 'xp', 8000, T0 + 300, 'save-gm');                  // a GM-mode save
  save(12, 'xp', 2500, T0 + 2_000_000); save(12, 'gold', 1000, T0 + 2_000_000);
  save(12, 'xp', 900, T0 + 1_000_000);                        // before Helix joined
  save(12, 'gold', 400, T0 + 2_000_000, 'sell');              // not a save
  save(12, 'xp', -50, T0 + 2_000_000);                        // not a gain
  save(13, 'xp', 500, T0 + 1_000_000);
  save(21, 'xp', 1500, T0 + 10_000_100); save(21, 'gold', 300, T0 + 10_000_200);
  save(99, 'xp', 99999, T0 + 100);                            // a character in no named session
  save(31, 'xp', 77777, T0 + 100);                            // S3's member
  save(21, 'shards', 40, T0 + 10_000_100);                    // not xp or gold
}

test('the summary adds up a small fixed data set', async () => {
  const h = harness();
  await seed(h);
  const res = await h.call('GET /api/play-reports/summary', { query: { version: V1 } });
  assert.strictEqual(res.statusCode, 200);
  assert.strictEqual(res.headers['Cache-Control'], 'public, max-age=60');
  const s = res.body.summary;
  assert.deepStrictEqual([s.version, s.truncated, s.reports, s.players, s.hours, s.medianMinutes, s.averageMinutes], [V1, false, 4, 3, 2, 25, 30]);
  assert.deepStrictEqual(s.presets, [
    { preset: 'low', reports: 2, avgMs: 16, p99Ms: 45, worstMedianMs: 250, hitchesPerHour: 180 },
    { preset: 'high', reports: 2, avgMs: 8.67, p99Ms: 25, worstMedianMs: 200, hitchesPerHour: 33.33 },
  ]);
  assert.deepStrictEqual(s.gpus, [
    { gpu: 'GTX 970', reports: 2, avgMs: 16, p99Ms: 45 },
    { gpu: 'NVIDIA GeForce RTX 3060', reports: 2, avgMs: 8.67, p99Ms: 25 },
  ]);
  assert.deepStrictEqual(s.endReasons, [{ reason: 'quit', count: 2 }, { reason: 'crash', count: 1 }, { reason: 'logout', count: 1 }]);
  assert.deepStrictEqual(s.endAreas, [{ area: 'graves', count: 2 }, { area: 'fen', count: 1 }]);
  assert.deepStrictEqual(s.areas, [
    { area: 'graves', hours: 1.33, deaths: 9, deathsPerHour: 6.75, avgMs: 8.75 },
    { area: 'fen', hours: 0.33, deaths: 1, deathsPerHour: 3, avgMs: 13 },
  ]);
  // S1 (3 members: 1 h + 0.5 h + 0.5 h) and S2 (0.5 h); S3 is left out because War was not in it
  assert.deepStrictEqual(s.server, {
    sessions: 2, members: 4, hours: 2.5, kills: 4900, bosses: 9, xp: 9500, gold: 3300,
    killsPerHour: 1960, bossesPerHour: 3.6, xpPerHour: 3800, goldPerHour: 1320, dropsPerHour: null,
  });
  // the older release has its own numbers
  const old = (await h.call('GET /api/play-reports/summary', { query: { version: V0 } })).body.summary;
  assert.deepStrictEqual([old.reports, old.players, old.hours, old.server.sessions], [1, 1, 0.25, 0]);
});

test('a session counts only when an account that named it was in it; no sessions, no server numbers', async () => {
  const h = harness();
  await h.call('POST /api/play-reports', { accountId: 3, body: good({ reportId: 'war-report-0000002', sessionIds: [S1, S3] }) });
  h.sessions.set(S1, { ended_at: T0 + HOUR, last_host_at: T0 + HOUR });
  h.members.push({ session_id: S1, character_id: 11, account_id: 1, joined_at: T0, left_at: null, accepted_kills: 3000, accepted_bosses: 6 });
  h.sessions.set(S3, { ended_at: T0 + HOUR, last_host_at: T0 + HOUR });
  h.members.push({ session_id: S3, character_id: 31, account_id: 2, joined_at: T0, left_at: null, accepted_kills: 5, accepted_bosses: 0 });
  h.ledger.push({ character_id: 11, currency: 'xp', delta: 1000, reason: 'save', created_at: T0 + 5 });
  const s = (await h.call('GET /api/play-reports/summary', { query: { version: V1 } })).body.summary;
  assert.deepStrictEqual([s.server.sessions, s.server.members, s.server.kills, s.server.xp, s.server.hours], [0, 0, 0, 0, 0]);
  assert.deepStrictEqual([s.server.xpPerHour, s.server.killsPerHour, s.server.dropsPerHour], [null, null, null]);
  // naming a session the account is in counts it
  h.members.push({ session_id: S1, character_id: 41, account_id: 3, joined_at: T0, left_at: T0 + HOUR / 2, accepted_kills: 10, accepted_bosses: 0 });
  const t = (await h.call('GET /play-reports/summary', { query: { version: V1 } })).body.summary;
  assert.deepStrictEqual([t.server.sessions, t.server.members, t.server.kills, t.server.hours, t.server.xp], [1, 2, 3010, 1.5, 1000]);
});

test('reports without frame times still count in reports and hours, not in the frame numbers', () => {
  const rows = [readRow({ account_id: 1, seconds: 600, end_reason: 'crash', preset: 'low', gpu: 'GTX 970', frames_count: 0, avg_ms: null, p99_ms: null, worst_ms: null, hitches: 0, areas: null, session_ids: null })];
  const s = summarize(V1, rows);
  assert.deepStrictEqual([s.reports, s.hours, s.medianMinutes], [1, 0.17, 10]);
  assert.deepStrictEqual(s.presets, [{ preset: 'low', reports: 1, avgMs: null, p99Ms: null, worstMedianMs: null, hitchesPerHour: null }]);
  assert.deepStrictEqual(summarize(V1, []).server.dropsPerHour, null);
  // JSON columns may come back already parsed
  const parsed = readRow({ account_id: 1, seconds: 60, areas: { fen: { seconds: 60, deaths: 1, avgMs: 9 } }, session_ids: [S1] });
  assert.deepStrictEqual([parsed.areas.fen.deaths, parsed.sessionIds], [1, [S1]]);
  assert.strictEqual(parsed.preset, 'unknown');
});

test('the graphics card list keeps the 15 most reported; presets come in graphics order', () => {
  const rows = [];
  for (let g = 0; g < 20; g++) for (let i = 0; i <= g; i++) rows.push(readRow({ account_id: g, seconds: 60, preset: g % 2 ? 'ultra' : 'low', gpu: `GPU ${String(g).padStart(2, '0')}`, frames_count: 10, avg_ms: 10, p99_ms: 20, worst_ms: 30, hitches: 0 }));
  const s = summarize(V1, rows);
  assert.strictEqual(s.gpus.length, 15);
  assert.strictEqual(s.gpus[0].gpu, 'GPU 19');
  assert.strictEqual(s.gpus[0].reports, 20);
  assert.strictEqual(s.gpus.at(-1).gpu, 'GPU 05');
  assert.deepStrictEqual(s.presets.map((p) => p.preset), ['low', 'ultra']);
});

test('releases come newest first with their counts', async () => {
  const h = harness();
  await seed(h);
  const res = await h.call('GET /api/play-reports/releases');
  assert.strictEqual(res.headers['Cache-Control'], 'public, max-age=60');
  assert.deepStrictEqual(res.body.releases.map((r) => r.version), [V1, V0]);
  assert.deepStrictEqual(res.body.releases[0], { version: V1, reports: 4, players: 3, hours: 2, first: new Date(T0).toISOString(), last: new Date(T0).toISOString() });
  assert.deepStrictEqual([res.body.releases[1].reports, res.body.releases[1].hours, res.body.releases[1].first], [1, 0.25, new Date(T0 - 10 * 86400000).toISOString()]);
});

test('the summary needs a sensible version, and an unknown version is simply empty', async () => {
  const h = harness();
  for (const query of [{}, { version: '' }, { version: ['a', 'b'] }, { version: 'not a version' }, { version: '../..' }]) {
    const res = await h.call('GET /api/play-reports/summary', { query });
    assert.strictEqual(res.statusCode, 400, JSON.stringify(query));
    assert.deepStrictEqual([res.body.success, res.body.code], [false, 'bad_request']);
    assert.ok(!res.headers['Cache-Control']);
  }
  const empty = (await h.call('GET /api/play-reports/summary', { query: { version: '9.9.9' } })).body.summary;
  assert.deepStrictEqual([empty.reports, empty.players, empty.medianMinutes, empty.presets, empty.endReasons], [0, 0, null, [], []]);
});

test('the summary is kept for a minute: a second read does not touch the database', async () => {
  const h = harness({ cacheMs: 60000 });
  await seed(h);
  await h.call('GET /api/play-reports/summary', { query: { version: V1 } });
  const reads = h.stats.reads;
  assert.ok(reads > 0);
  const again = await h.call('GET /api/play-reports/summary', { query: { version: V1 } });
  assert.strictEqual(h.stats.reads, reads);
  assert.strictEqual(again.body.summary.reports, 4);
});

test('nothing private is in any reply', async () => {
  const h = harness();
  await seed(h);
  const replies = [
    await h.call('POST /api/play-reports', { body: good({ reportId: 'private-check-0001', email: 'tyler@example.com', username: 'Tyler', chat: 'secret chat' }) }),
    await h.call('GET /api/play-reports/releases'),
    await h.call('GET /api/play-reports/summary', { query: { version: V1 } }),
    await h.call('GET /api/play-reports/summary', { query: { version: V0 } }),
    await h.call('POST /api/play-reports', { body: good({ reportId: 'x' }) }),
    await h.call('POST /api/play-reports', { body: good(), anon: true }),
  ];
  const all = JSON.stringify(replies.map((r) => r.body));
  for (const secret of [S1, S2, S3, 'tyler-report-000001', 'helix-report-000001', 'war-report-0000001', 'private-check-0001', 'tyler@example.com', 'Tyler', 'secret chat']) assert.ok(!all.includes(secret), secret);
  const forbidden = ['accountId', 'account_id', 'email', 'username', 'sessionIds', 'session_ids', 'reportId', 'report_id', 'characterId', 'character_id', 'token'];
  const walk = (v) => {
    if (Array.isArray(v)) return v.forEach(walk);
    if (v && typeof v === 'object') for (const [k, x] of Object.entries(v)) { assert.ok(!forbidden.includes(k), `a reply carries "${k}"`); walk(x); }
  };
  replies.forEach((r) => walk(r.body));
});
