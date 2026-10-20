// Run: node --test server/death-muffin/backend/inventory-save.test.cjs
const test = require('node:test');
const assert = require('node:assert');
const { LEGACY_BAG_SLOTS: LEGACY, saveBagSize, slotProblem, replaceBag } = require('./inventory-save.cjs');
const { BAG_SLOTS: BAG } = require('./gathering/gathering-rules.cjs');
const { fakeDb } = require('./bag-fake-db.cjs');

const row = (slot_index, item_id = 'ore_copper', quantity = 1) => ({ slot_index, item_id, quantity });

test('bagSize defaults to the old legacy size when a stale client omits it, and is bounded by the live bag', () => {
  assert.equal(saveBagSize(undefined), LEGACY);
  assert.equal(saveBagSize(null), LEGACY);
  assert.equal(saveBagSize(BAG), BAG);
  assert.equal(saveBagSize(String(BAG)), BAG);
  assert.equal(saveBagSize(BAG + 1), null);
  assert.equal(saveBagSize(0), null);
  assert.equal(saveBagSize(1.5), null);
  assert.equal(saveBagSize('x'), null);
});

test('slot validation follows bagSize', () => {
  assert.equal(slotProblem([row(0), row(BAG - 1)], BAG), null);
  assert.match(slotProblem([row(LEGACY)], LEGACY), new RegExp(`between 0 and ${LEGACY - 1}`));
  assert.match(slotProblem([row(BAG)], BAG), new RegExp(`between 0 and ${BAG - 1}`));
  assert.match(slotProblem([row(1), row(1)], BAG), /duplicate/);
  assert.match(slotProblem(Array.from({ length: LEGACY + 1 }, (_, i) => row(i)), LEGACY), new RegExp(`cannot exceed ${LEGACY}`));
});

test('a stale save cannot delete slots above its bag size (even an empty one)', async () => {
  const bag = Array.from({ length: BAG }, (_, i) => ({ slot_index: i, item_id: 'ore_copper', quantity: i + 1 }));
  const db = fakeDb({ bag });
  // The stale tab only knows slots 0 to LEGACY-2 (it spent the last one) and sends no bagSize.
  const incoming = Array.from({ length: LEGACY - 1 }, (_, i) => row(i, 'ore_copper', i + 1));
  await replaceBag(db.conn, 1, incoming, saveBagSize(undefined));
  const slots = db.inv.map((r) => r.slot_index).sort((a, b) => a - b);
  assert.equal(slots.includes(LEGACY - 1), false, 'the last slot in the stale tab\'s range was deleted as it asked');
  for (let i = LEGACY; i < BAG; i++) assert.ok(slots.includes(i), `slot ${i} survived`);
  assert.equal(db.inv.find((r) => r.slot_index === BAG - 1).quantity, BAG);

  const empty = fakeDb({ bag });
  await replaceBag(empty.conn, 1, [], saveBagSize(undefined));
  assert.deepEqual(empty.inv.map((r) => r.slot_index).sort((a, b) => a - b), Array.from({ length: BAG - LEGACY }, (_, i) => i + LEGACY));
});

test('a current client (the full bagSize) replaces the whole bag and never touches equipped slots', async () => {
  const db = fakeDb({ bag: Array.from({ length: BAG }, (_, i) => row(i)), equipped: [{ slot_index: 105, item_id: 'staff_moon' }] });
  const mid = Math.floor(BAG / 2);
  await replaceBag(db.conn, 1, [row(mid, 'log_oak', 4)], saveBagSize(BAG));
  assert.deepEqual(db.inv.map((r) => r.slot_index).sort((a, b) => a - b), [mid, 105]);
  assert.equal(db.inv.find((r) => r.slot_index === mid).item_id, 'log_oak');
});

test('slot validation refuses entries that are not whole-numbered slot objects', () => {
  // These used to throw (null) or slip through parseInt and be rounded or truncated by MySQL (5.5 -> slot 6, '5abc' -> an error).
  for (const bad of [null, 7, 'x', [], row(5.5), row('5abc'), row(undefined), row(null), row(NaN), row(true)]) {
    const problem = slotProblem([bad], BAG);
    assert.match(String(problem), /each slot_index/, `refused: ${JSON.stringify(bad)}`);
  }
  assert.equal(slotProblem([row('5')], BAG), null, 'a whole number sent as a string is still fine');
});
