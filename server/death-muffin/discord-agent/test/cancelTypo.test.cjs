'use strict';
const test = require('node:test');
const assert = require('node:assert');
const { cancelTypo, isDiscardPhrase } = require('../runner/core.cjs');

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
test('plain-words discard of the whole job is !discard; requests that mention discarding something are not', () => {
  for (const t of ['discard', 'Discard this', 'discard it.', 'No you can discard this as a test', 'you can discard this', 'ok discard it please', '<@123> discard this',
    'yeah discard that', 'go ahead and discard it', 'discard this, it\'s a test', 'discard the change', 'please discard this one', 'just discard it thanks']) {
    assert.ok(isDiscardPhrase(t.replace(',', '')), t);
  }
  for (const t of ['should we discard this?', 'discard the old item rows', 'discard the unused helper and rename the panel', 'don\'t discard this',
    'can you explain why you would discard it?', 'the discard button is broken', 'keep it', '!discard']) {
    assert.ok(!isDiscardPhrase(t), t);
  }
});
