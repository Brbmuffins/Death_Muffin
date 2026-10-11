'use strict';
// node --test server/death-muffin/backend/discipline.test.cjs
// Exercises POST /character/discipline's validation and ownership checks
// against a fake app and pool (no Express, no MySQL).
const test = require('node:test');
const assert = require('node:assert/strict');
const mountDiscipline = require('./discipline.cjs');

/**
 * Captures the route handler mountDiscipline registers, then lets a test call
 * it with a synthetic req/res. `rows` is what the UPDATE reports as affected.
 */
function harness({ maxIndex = 9, playable = null, character = { id: 7 }, affectedRows = 1 } = {}) {
  let handler = null;
  const app = { post: (_path, _auth, fn) => { handler = fn; } };
  const updates = [];
  const pool = {
    execute: async (sql, params) => {
      if (/^UPDATE/i.test(sql.trim())) {
        updates.push({ sql, params });
        return [{ affectedRows }];
      }
      // The follow-up SELECT of the freshly changed row.
      return [[{ id: character.id, discipline_index: params[0] === character.id ? updates.at(-1)?.params[0] : null }]];
    },
  };
  mountDiscipline(app, pool, {
    verifyJWT: () => {},
    formatCharacter: (char) => ({ id: char.id, class_index: char.discipline_index }),
    getGearLoadout: async () => [],
    invalidateLeaderboard: () => {},
    maxIndex,
    playable,
  });
  const call = async (body) => {
    let status = 200;
    let json = null;
    const res = { status: (s) => ((status = s), res), json: (j) => ((json = j), res) };
    await handler({ body, user: { accountId: 1 }, character, gmFields: {} }, res);
    return { status, json };
  };
  return { call, updates };
}

test('accepts the four necromantic disciplines', async () => {
  for (const index of [1, 2, 3, 4]) {
    const { call, updates } = harness();
    const { status } = await call({ characterId: 7, class_index: index });
    assert.equal(status, 200, `index ${index} should be accepted`);
    assert.equal(updates[0].params[0], index);
  }
});

test('accepts the Release 0.3 class indices 5-9', async () => {
  for (const index of [5, 6, 7, 8, 9]) {
    const { call, updates } = harness();
    const { status } = await call({ characterId: 7, class_index: index });
    assert.equal(status, 200, `index ${index} should be accepted`);
    assert.equal(updates[0].params[0], index);
  }
});

test('accepts the Reaper (index 11) and only the playable list when one is given', async () => {
  const playable = [1, 2, 3, 4, 11];
  for (const index of playable) {
    const { call, updates } = harness({ maxIndex: 11, playable });
    const { status } = await call({ characterId: 7, class_index: index });
    assert.equal(status, 200, `index ${index} should be accepted`);
    assert.equal(updates[0].params[0], index);
  }
  for (const index of [5, 6, 7, 8, 9, 10, 12]) {
    const { call, updates } = harness({ maxIndex: 11, playable });
    const { status, json } = await call({ characterId: 7, class_index: index });
    assert.equal(status, 400, `index ${index} should be refused`);
    assert.match(json.error, /5 classes/);
    assert.equal(updates.length, 0, 'a refused index must not touch the database');
  }
});

test('rejects out-of-range, non-integer and missing indices', async () => {
  for (const index of [0, -1, 10, 99, 1.5, '3', null, undefined, NaN]) {
    const { call, updates } = harness();
    const { status } = await call({ characterId: 7, class_index: index });
    assert.equal(status, 400, `index ${JSON.stringify(index)} should be rejected`);
    assert.equal(updates.length, 0, 'a rejected index must not touch the database');
  }
});

test('honours a lower maxIndex so the server never outruns the client build', async () => {
  const { call, updates } = harness({ maxIndex: 4 });
  const { status, json } = await call({ characterId: 7, class_index: 8 });
  assert.equal(status, 400);
  assert.match(json.error, /4 classes/);
  assert.equal(updates.length, 0);
});

test('refuses a character that is not the caller\'s active one', async () => {
  const { call, updates } = harness();
  const { status } = await call({ characterId: 999, class_index: 3 });
  assert.equal(status, 403);
  assert.equal(updates.length, 0);
});

test('404s when the request has no active character', async () => {
  const { call } = harness({ character: null });
  const { status } = await call({ characterId: 7, class_index: 3 });
  assert.equal(status, 404);
});

test('404s when the update matches no row', async () => {
  const { call } = harness({ affectedRows: 0 });
  const { status } = await call({ characterId: 7, class_index: 3 });
  assert.equal(status, 404);
});
