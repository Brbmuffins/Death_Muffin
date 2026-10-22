'use strict';
const test = require('node:test');
const assert = require('node:assert');
const { cancelTypo } = require('../runner/core.cjs');

test('near-misses of !cancel / !stop ask instead of becoming a task', () => {
  for (const t of ['!cencel', '!cancle', '!cancell', '!stpo', '!sotp', '!cnacel', '!abrot', '<@123> !cencel', '!Cencel.']) assert.ok(cancelTypo(t), t);
});
test('exact commands, plain words (every command starts with !), real sentences and unrelated words are not typos', () => {
  for (const t of ['!cancel', '!stop', 'cancel', 'stop', 'cencel', 'stpo', 'abort', 'halt', 'please stop the build', 'make the cancel button bigger', 'ok', 'thanks', 'looks good', 'continue', 'retry', 'yes', 'fix the bag window']) {
    assert.ok(!cancelTypo(t), t);
  }
});
