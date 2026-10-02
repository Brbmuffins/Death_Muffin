// Run: node --test server/death-muffin/backend/chronicle.test.cjs
const test = require('node:test');
const assert = require('node:assert');
const mountChronicle = require('./chronicle.cjs');
const { sanitize, merge, SUM_KEYS, MAX_KEYS } = mountChronicle;

/** A tiny in-memory stand-in for the two tables, keyed on the SQL text the module issues. */
function fakePool() {
  const chronicle = new Map();
  const runs = [];
  const execute = async (sql, params = []) => {
    if (sql.startsWith('INSERT IGNORE INTO character_chronicle')) {
      if (!chronicle.has(params[0])) chronicle.set(params[0], { character_id: params[0], life: params[1], run: params[2], run_no: 1, run_started_at: new Date('2026-01-01') });
      return [{}];
    }
    if (sql.startsWith('SELECT * FROM character_chronicle')) {
      const row = chronicle.get(params[0]);
      return [row ? [{ ...row }] : []];
    }
    if (sql.startsWith('UPDATE character_chronicle SET life')) {
      Object.assign(chronicle.get(params[2]), { life: params[0], run: params[1] });
      return [{}];
    }
    if (sql.startsWith("UPDATE character_chronicle SET run = '{}'")) {
      const row = chronicle.get(params[0]);
      Object.assign(row, { run: '{}', run_no: row.run_no + 1 });
      return [{}];
    }
    if (sql.startsWith('INSERT INTO character_runs')) {
      runs.push({ run_no: params[1], started_at: params[2], ended_at: new Date(), ascension_after: params[3], stats: params[4] });
      return [{}];
    }
    if (sql.includes('FROM character_runs')) return [[...runs].sort((a, b) => b.run_no - a.run_no)];
    throw new Error(`unexpected SQL: ${sql}`);
  };
  const conn = { execute, beginTransaction: async () => {}, commit: async () => {}, rollback: async () => {}, release: () => {} };
  return { execute, getConnection: async () => conn };
}

function harness(owned = true) {
  const routes = {};
  const app = { get: (p, _mw, h) => (routes[`GET ${p}`] = h), post: (p, _mw, h) => (routes[`POST ${p}`] = h) };
  mountChronicle(app, fakePool(), { requireAuth: () => {}, ownsCharacter: async () => owned, invalidateLeaderboard: () => {} });
  const call = async (route, { body, params } = {}) => {
    let status = 200;
    let json;
    const res = { status(c) { status = c; return this; }, json(j) { json = j; return this; }, headersSent: false };
    await routes[route]({ body, params, user: { accountId: 1 } }, res);
    return { status, json };
  };
  return { call };
}

test('sanitize keeps known counters, floors them, and drops junk', () => {
  const out = sanitize({ kills: 5.9, 'kills.graves': 3, deaths: -1, hacked: 9, 'gold.earned': 'x', playSeconds: 1e12 }, SUM_KEYS);
  assert.deepEqual(Object.keys(out).sort(), ['kills', 'kills.graves', 'playSeconds']);
  assert.equal(out.kills, 5);
  assert.equal(out.playSeconds, 50_000_000, 'clamped to the per-request cap');
  assert.deepEqual(sanitize({ 'peak.level': 12, kills: 3 }, MAX_KEYS), { 'peak.level': 12 });
  assert.deepEqual(sanitize(null, SUM_KEYS), {});
});

test('merge adds counters and keeps the best of the maxima', () => {
  const a = merge({ kills: 10, 'peak.level': 20 }, { kills: 5, deaths: 1 }, { 'peak.level': 15, 'peak.wave': 3 });
  assert.deepEqual(a, { kills: 15, 'peak.level': 20, deaths: 1, 'peak.wave': 3 });
});

test('add merges into lifetime and run; ascend archives the run and starts the next', async () => {
  const { call } = harness();
  await call('POST /api/chronicle/add', { body: { characterId: 7, deltas: { kills: 10, 'gold.earned': 500 }, maxes: { 'peak.level': 12 } } });
  await call('POST /api/chronicle/add', { body: { characterId: 7, deltas: { kills: 5, deaths: 1 }, maxes: { 'peak.level': 9 } } });
  let g = (await call('GET /api/chronicle/:characterId', { params: { characterId: '7' } })).json.data;
  assert.equal(g.life.kills, 15);
  assert.equal(g.run.kills, 15);
  assert.equal(g.life['peak.level'], 12);
  assert.equal(g.runNo, 1);
  assert.equal(g.runs.length, 0);

  const asc = await call('POST /api/chronicle/ascend', { body: { characterId: 7, ascension: 1 } });
  assert.equal(asc.json.data.archived, true);
  // A second press without new activity must not archive an empty run.
  assert.equal((await call('POST /api/chronicle/ascend', { body: { characterId: 7, ascension: 1 } })).json.data.archived, false);

  await call('POST /api/chronicle/add', { body: { characterId: 7, deltas: { kills: 2 } } });
  g = (await call('GET /api/chronicle/:characterId', { params: { characterId: '7' } })).json.data;
  assert.equal(g.life.kills, 17, 'lifetime never resets');
  assert.equal(g.run.kills, 2, 'the new run starts from zero');
  assert.equal(g.runNo, 2);
  assert.equal(g.runs.length, 1);
  assert.equal(g.runs[0].stats.kills, 15);
  assert.equal(g.runs[0].ascensionAfter, 1);
});

test('someone else\'s character is refused', async () => {
  const { call } = harness(false);
  const r = await call('POST /api/chronicle/add', { body: { characterId: 7, deltas: { kills: 1 } } });
  assert.equal(r.status, 403);
});

test('no bound LIMIT parameter (mysql2 execute + MySQL 8 rejects it with ER_WRONG_ARGUMENTS)', () => {
  const src = require('node:fs').readFileSync(require('node:path').join(__dirname, 'chronicle.cjs'), 'utf8');
  assert.equal(/LIMIT\s*\?/.test(src), false);
});

// ── The Catacomb Depths: the deepest floor rides the Chronicle (no migration) ──────────────────────────────────────────────────────

test('depths: the Chronicle knows the Depths\' counters and keeps the deepest floor as a best', async () => {
  for (const k of ['depths.runs', 'depths.floors', 'depths.chests', 'kills.depths']) assert.ok(SUM_KEYS.has(k), k);
  assert.ok(MAX_KEYS.has('peak.depth'));
  const { call } = harness();
  await call('POST /api/chronicle/add', { body: { characterId: 3, deltas: { 'depths.runs': 1, 'kills.depths': 12, kills: 12, 'depths.floors': 1 }, maxes: { 'peak.depth': 4 } } });
  await call('POST /api/chronicle/add', { body: { characterId: 3, deltas: { 'depths.runs': 1, 'depths.chests': 1 }, maxes: { 'peak.depth': 9 } } });
  // A shallower run later never lowers the best.
  await call('POST /api/chronicle/add', { body: { characterId: 3, deltas: { 'depths.runs': 1 }, maxes: { 'peak.depth': 2 } } });
  let g = (await call('GET /api/chronicle/:characterId', { params: { characterId: '3' } })).json.data;
  assert.equal(g.life['peak.depth'], 9);
  assert.equal(g.life['depths.runs'], 3);
  assert.equal(g.life['depths.floors'], 1);
  assert.equal(g.life['depths.chests'], 1);
  assert.equal(g.life['kills.depths'], 12);

  // Ascension archives the run's best with the run and starts the next from zero; the lifetime best stands.
  await call('POST /api/chronicle/ascend', { body: { characterId: 3, ascension: 1 } });
  await call('POST /api/chronicle/add', { body: { characterId: 3, maxes: { 'peak.depth': 3 } } });
  g = (await call('GET /api/chronicle/:characterId', { params: { characterId: '3' } })).json.data;
  assert.equal(g.runs[0].stats['peak.depth'], 9, 'the finished run keeps its own deepest floor');
  assert.equal(g.run['peak.depth'], 3, 'the new run counts from its own floors');
  assert.equal(g.life['peak.depth'], 9, 'Ascension never lowers the lifetime best');
});

test('depths: a request can raise the best by a few floors, never to a nonsense depth', async () => {
  assert.deepEqual(merge({}, {}, { 'peak.depth': 5000 }), { 'peak.depth': mountChronicle.PEAK_DEPTH_STEP }, 'from nothing: one step');
  assert.deepEqual(merge({ 'peak.depth': 40 }, {}, { 'peak.depth': 5000 }), { 'peak.depth': 40 + mountChronicle.PEAK_DEPTH_STEP });
  assert.deepEqual(merge({ 'peak.depth': 990 }, {}, { 'peak.depth': 5000 }), { 'peak.depth': mountChronicle.PEAK_DEPTH_MAX });
  assert.deepEqual(merge({ 'peak.depth': 12 }, {}, { 'peak.depth': 13 }), { 'peak.depth': 13 });
  // The other bests are untouched by the bound.
  assert.deepEqual(merge({}, {}, { 'peak.level': 200 }), { 'peak.level': 200 });
  // Junk is dropped before the merge ever sees it.
  assert.deepEqual(sanitize({ 'peak.depth': -3 }, MAX_KEYS), {});
  assert.deepEqual(sanitize({ 'peak.depth': '12.9' }, MAX_KEYS), { 'peak.depth': 12 });
  assert.deepEqual(sanitize({ 'depths.hacked': 5, 'kills.depthz': 5 }, SUM_KEYS), {});
});

test('depths: the public leaderboard carries each character\'s deepest floor', async () => {
  const mountLeaderboard = require('./leaderboard.cjs');
  let sql = '';
  const pool = { query: async (q) => { sql = q; return [[
    { username: 'ada', class_index: 2, has_discipline: 1, level: 44, ascension: 1, bossKills: 3, totalKills: 900, playSeconds: '7200', runs: 0, bestDepth: '17' },
    { username: 'bo', class_index: 1, has_discipline: 1, level: 12, ascension: 0, bossKills: 0, totalKills: 40, playSeconds: null, runs: 0, bestDepth: null },
  ]]; } };
  const routes = {};
  mountLeaderboard({ get: (p, h) => (routes[p] = h) }, pool);
  let body;
  await routes['/leaderboard']({}, { set() {}, json(j) { body = j; }, status() { return this; } });
  assert.match(sql, /peak\.depth/, 'reads the lifetime best out of the Chronicle JSON');
  assert.deepEqual(body.players.map((p) => p.bestDepth), [17, 0]);
});
