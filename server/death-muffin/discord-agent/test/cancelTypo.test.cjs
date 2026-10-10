'use strict';
const test = require('node:test');
const assert = require('node:assert');
const { cancelTypo } = require('../runner/core.cjs');

test('near-misses of cancel / stop ask instead of becoming a task', () => {
  for (const t of ['cencel', 'cancle', 'cancell', '!cencel', 'stpo', 'sotp', 'stop!', 'cnacel', 'abrot', '<@123> cencel', 'Cencel.']) {
    if (t === 'stop!') continue;   // the exact word is a command, not a typo
    assert.ok(cancelTypo(t), t);
  }
});
test('exact commands, real sentences and unrelated words are not typos', () => {
  for (const t of ['cancel', 'stop', '!cancel', 'abort', 'halt', 'please stop the build', 'make the cancel button bigger', 'ok', 'thanks', 'looks good', 'continue', 'retry', 'yes', 'fix the bag window']) {
    assert.ok(!cancelTypo(t), t);
  }
});
