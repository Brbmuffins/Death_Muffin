// Run: node --test server/death-muffin/backend/value-ledger.test.cjs
// The value ledger: one row per gold / XP / shard change, written in the caller's transaction, never failing the write.
const test = require('node:test');
const assert = require('node:assert');
const valueLedger = require('./value-ledger.cjs');

const recorder = () => {
  const rows = [];
  return { rows, db: { query: async (sql, p) => { assert.match(sql, /^INSERT INTO value_ledger/); rows.push(...p[0]); return [{}]; } } };
};

test('records each real change with its reason; zero deltas, unknown currencies and bad ids are skipped', async () => {
  const r = recorder();
  await valueLedger.record(r.db, [
    { characterId: 5, currency: 'gold', delta: 120.9, balance: 1120, reason: 'sell', ref: 'items:3' },
    { characterId: 5, currency: 'xp', delta: 0, reason: 'save' },
    { characterId: 5, currency: 'gems', delta: 4, reason: 'save' },
    { characterId: 0, currency: 'gold', delta: 4, reason: 'save' },
    { characterId: 5, currency: 'shards', delta: -10, reason: 'summon-prelate' },
  ]);
  assert.equal(r.rows.length, 2);
  assert.deepEqual(r.rows[0].slice(0, 6), [5, 'gold', 120, 1120, 'sell', 'items:3']);
  assert.deepEqual(r.rows[1].slice(0, 6), [5, 'shards', -10, null, 'summon-prelate', null]);
});

test('nothing to record sends no query; a failing table never throws', async () => {
  let calls = 0;
  await valueLedger.record({ query: async () => { calls += 1; } }, { characterId: 1, currency: 'gold', delta: 0, reason: 'x' });
  assert.equal(calls, 0);
  const errors = [];
  await valueLedger.record({ query: async () => { throw Object.assign(new Error('no table'), { code: 'ER_NO_SUCH_TABLE' }); } },
    { characterId: 1, currency: 'gold', delta: 5, reason: 'x' }, { error: (m) => errors.push(m) });
  assert.ok(errors.length <= 1);
});
