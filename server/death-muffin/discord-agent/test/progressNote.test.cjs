'use strict';
const test = require('node:test'), assert = require('node:assert/strict');
const { progressNote } = require('../runner/core.cjs');

test('progress note: agent percentage + sentence + time worked; plain sentence without a percentage; fallback before any status', () => {
  assert.equal(progressNote({ status: '40% · Found it, fixing the tooltip now.', mins: 12 }), '🔧 40% · Found it, fixing the tooltip now. · ⏱ 12 min');
  assert.equal(progressNote({ status: '40%: Found it', mins: 3 }), '🔧 40% · Found it · ⏱ 3 min');
  assert.equal(progressNote({ status: 'Reading the inventory code', mins: 2 }), '🔧 Reading the inventory code · ⏱ 2 min');
  assert.equal(progressNote({ status: '', mins: 5 }), '🔧 Working on it · ⏱ 5 min');
  assert.equal(progressNote({ status: '250% · Overachieving', mins: 1 }), '🔧 99% · Overachieving · ⏱ 1 min', 'capped below 100 until the proposal');
});

test('progress note: while checks run, the percentage moves from the agent\'s number toward 95 with the suites done', () => {
  const s = '60% · Fix in; running the Godot checks, ~35 min.';
  assert.equal(progressNote({ status: s, check: { done: 0, total: 70 }, mins: 20 }), '🔧 60% · Fix in; running the Godot checks, ~35 min. (checks: 0/70 suites done) · ⏱ 20 min');
  assert.equal(progressNote({ status: s, check: { done: 35, total: 70 }, mins: 38 }), '🔧 78% · Fix in; running the Godot checks, ~35 min. (checks: 35/70 suites done) · ⏱ 38 min');
  assert.equal(progressNote({ status: s, check: { done: 70, total: 70 }, mins: 55 }), '🔧 95% · Fix in; running the Godot checks, ~35 min. (checks: 70/70 suites done) · ⏱ 55 min');
  assert.equal(progressNote({ status: 'running checks', check: { done: 10, total: 20 }, mins: 9 }), '🔧 73% · running checks (checks: 10/20 suites done) · ⏱ 9 min', 'no agent number: starts from 50');
});
