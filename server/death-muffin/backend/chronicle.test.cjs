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
