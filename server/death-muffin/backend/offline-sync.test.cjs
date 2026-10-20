const { test } = require('node:test');
const assert = require('node:assert/strict');
const { mergeOfflineStats } = require('./offline-sync.cjs');
const { LEVEL_CAP } = require('./gathering/authority-rules.cjs');

test('offline stats advance an online character and repeated uploads are idempotent', () => {
  const first = mergeOfflineStats({ level: 3, experience: 20 }, { level: 4, experience: 100 });
  assert.deepEqual(first, { level: 4, experience: 100, improved: true });
  assert.deepEqual(mergeOfflineStats(first, { level: 4, experience: 100 }), { level: 4, experience: 100, improved: false });
});

test('offline stats cannot roll back online level or XP', () => {
  assert.deepEqual(mergeOfflineStats({ level: 5, experience: 2 }, { level: 4, experience: 399 }),
    { level: 5, experience: 2, improved: false });
  assert.deepEqual(mergeOfflineStats({ level: 5, experience: 20 }, { level: 5, experience: 19 }),
    { level: 5, experience: 20, improved: false });
});

test('offline levels past the old 255 cap merge, the level cap is the ceiling', () => {
  const past = Math.min(300, LEVEL_CAP);
  assert.deepEqual(mergeOfflineStats({ level: Math.min(255, past - 1), experience: 0 }, { level: past, experience: 50 }), { level: past, experience: 50, improved: true });
  assert.equal(mergeOfflineStats({ level: 5, experience: 0 }, { level: LEVEL_CAP, experience: 0 }).level, LEVEL_CAP);
  assert.throws(() => mergeOfflineStats({ level: 5, experience: 0 }, { level: LEVEL_CAP + 1, experience: 0 }), RangeError);
});

test('rejects invalid and non-normalized offline XP', () => {
  for (const stats of [{ level: 0, experience: 0 }, { level: 2, experience: -1 },
    { level: 2, experience: 200 }, { level: LEVEL_CAP + 1, experience: 0 },
    { level: '2', experience: 1 }]) {
    assert.throws(() => mergeOfflineStats({ level: 1, experience: 0 }, stats), RangeError);
  }
});
