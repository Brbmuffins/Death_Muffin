const { test } = require('node:test');
const assert = require('node:assert/strict');
const { mergeOfflineStats } = require('./offline-sync.cjs');

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

test('rejects invalid and non-normalized offline XP', () => {
  for (const stats of [{ level: 0, experience: 0 }, { level: 2, experience: -1 },
    { level: 2, experience: 200 }, { level: 300, experience: 0 },
    { level: '2', experience: 1 }]) {
    assert.throws(() => mergeOfflineStats({ level: 1, experience: 0 }, stats), RangeError);
  }
});
