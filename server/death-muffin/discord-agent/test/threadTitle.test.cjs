'use strict';
const test = require('node:test'), assert = require('node:assert/strict');
const TT = require('../runner/lib/threadTitle.cjs');

test('initialName strips mentions, the bot name and filler, and sentence-cases', () => {
  const bot = ['Muffin Core'];
  assert.equal(TT.initialName('<@123> hey can you please fix the bag tooltip crash', bot), 'Fix the bag tooltip crash');
  assert.equal(TT.initialName('@Muffin Core the thrall animation stutters', bot), 'The thrall animation stutters');
  assert.equal(TT.initialName('Hey Muffin Core, could you pls look at why shards cost so much?', bot), 'Look at why shards cost so much');
  assert.equal(TT.initialName('<@&55> <#77> <@!9>', bot), TT.FALLBACK);
  assert.equal(TT.initialName('', bot), TT.FALLBACK);
  assert.equal(TT.initialName('please\n\n  fix   the\tlag', bot), 'Fix the lag');
});
test('initialName is at most 60 characters and cuts at a word boundary', () => {
  const n = TT.initialName('fix ' + 'extraordinarilylongword '.repeat(10), []);
  assert.ok(n.length <= 60, n.length);
  const m = TT.initialName('the inventory bag tooltip crashes whenever I hover over a rare item while a thrall is attacking', []);
  assert.ok(m.length <= 60 && m.endsWith('…'), m); assert.ok(m.startsWith('The inventory bag tooltip'));
  const words = 'the inventory bag tooltip crashes whenever I hover over a rare item while a thrall is attacking'.split(' ');
  assert.ok(m.slice(0, -1).split(' ').every((w) => words.includes(w.toLowerCase()) || words.includes(w)), 'no word is cut in half: ' + m);
});
test('sanitizeTitle: one line, no mentions, links, markdown or control characters', () => {
  assert.equal(TT.sanitizeTitle('**Fix @everyone <@12> bag `tooltip`** https://evil.example/x crash\nsecond line'), 'Fix bag tooltip crash');
  assert.equal(TT.sanitizeTitle('\n\n  thrall animation stutter  \n'), 'Thrall animation stutter');
  assert.equal(TT.sanitizeTitle('@here'), '');
  assert.equal(TT.sanitizeTitle('a\u0000b‮c'), 'A b c');
  assert.equal(TT.sanitizeTitle('discord.gg/abc join'), 'Join');
  assert.ok(TT.sanitizeTitle('word '.repeat(40)).length <= 57);
  assert.equal(TT.sanitizeTitle(undefined), '');
  assert.ok(!/[@<>`*]/.test(TT.sanitizeTitle('<@&1> @someone `x` *y* <#2>')));
});
test('withMarker and titleKey', () => {
  assert.equal(TT.withMarker('Bag crash', 'shipped'), '✅ Bag crash');
  assert.equal(TT.withMarker('Bag crash', 'discarded'), '❌ Bag crash');
  assert.equal(TT.withMarker('Bag crash', 'proposed'), '📝 Bag crash');
  assert.equal(TT.withMarker('Bag crash', 'running'), '🔧 Bag crash'); assert.equal(TT.withMarker('Bag crash', 'shipping'), '🔧 Bag crash');
  assert.equal(TT.withMarker('Bag crash', 'idle'), 'Bag crash');
  assert.equal(TT.titleKey('Bag  Crash!'), TT.titleKey('bag crash'));
});
test('renamer: latest name wins, max 2 per 10 minutes, no-ops dropped (fake clock)', () => {
  let t = 1000; const timers = []; const sent = [];
  const r = TT.createRenamer({ now: () => t, send: (id, n) => sent.push([id, n]), setTimer: (fn, ms) => { const h = { fn, at: t + ms }; timers.push(h); return h; }, clearTimer: (h) => { h.dead = true; } });
  const advance = (ms) => { t += ms; for (const h of timers.splice(0)) { if (h.dead) continue; if (h.at <= t) h.fn(); else timers.push(h); } };
  r.setCurrent('a', 'Start');
  r.want('a', 'Start'); assert.equal(sent.length, 0, 'same name is a no-op');
  r.want('a', 'One'); r.want('a', 'Two'); assert.deepEqual(sent, [['a', 'One'], ['a', 'Two']], 'first two go immediately');
  r.want('a', 'Three'); r.want('a', 'Four'); r.want('a', '📝 Five'); assert.equal(sent.length, 2, 'third is held');
  advance(300000); assert.equal(sent.length, 2);
  advance(301000); assert.deepEqual(sent[2], ['a', '📝 Five'], 'only the latest wish is sent once the window frees');
  assert.equal(sent.length, 3);
  r.want('a', 'Six'); assert.equal(sent.length, 4, 'a third send in the window is allowed again after the first expired');
  r.want('a', 'Seven'); assert.equal(sent.length, 4);
  r.want('a', 'Six'); assert.equal(r.pending('a'), null, 'wanting the current name cancels the pending one');
  advance(700000); assert.equal(sent.length, 4, 'nothing left to send');
  r.want('b', 'Other'); assert.deepEqual(sent[4], ['b', 'Other'], 'threads are independent');
  r.forget('a'); assert.equal(r.pending('a'), null);
});
