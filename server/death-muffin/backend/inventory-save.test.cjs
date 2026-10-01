// Run: node --test server/death-muffin/backend/inventory-save.test.cjs
const test = require('node:test');
const assert = require('node:assert');
const { saveBagSize, slotProblem, replaceBag } = require('./inventory-save.cjs');
const { fakeDb } = require('./bag-fake-db.cjs');

const row = (slot_index, item_id = 'ore_copper', quantity = 1) => ({ slot_index, item_id, quantity });

test('bagSize defaults to the old 24 when a stale client omits it, and is bounded by the live bag', () => {
  assert.equal(saveBagSize(undefined), 24);
  assert.equal(saveBagSize(null), 24);
  assert.equal(saveBagSize(48), 48);
  assert.equal(saveBagSize('48'), 48);
  assert.equal(saveBagSize(49), null);
  assert.equal(saveBagSize(0), null);
  assert.equal(saveBagSize(1.5), null);
  assert.equal(saveBagSize('x'), null);
});

test('slot validation follows bagSize', () => {
  assert.equal(slotProblem([row(0), row(47)], 48), null);
  assert.match(slotProblem([row(24)], 24), /between 0 and 23/);
  assert.match(slotProblem([row(48)], 48), /between 0 and 47/);
  assert.match(slotProblem([row(1), row(1)], 48), /duplicate/);
  assert.match(slotProblem(Array.from({ length: 25 }, (_, i) => row(i)), 24), /cannot exceed 24/);
});

test('a stale 24-slot save cannot delete slots 24-47 (even an empty one)', async () => {
  const bag = Array.from({ length: 48 }, (_, i) => ({ slot_index: i, item_id: 'ore_copper', quantity: i + 1 }));
  const db = fakeDb({ bag });
  // The stale tab only knows slots 0-22 (it spent slot 23) and sends no bagSize.
  const incoming = Array.from({ length: 23 }, (_, i) => row(i, 'ore_copper', i + 1));
  await replaceBag(db.conn, 1, incoming, saveBagSize(undefined));
  const slots = db.inv.map((r) => r.slot_index).sort((a, b) => a - b);
  assert.equal(slots.includes(23), false, 'slot 23 (in the stale tab\'s range) was deleted as it asked');
  for (let i = 24; i < 48; i++) assert.ok(slots.includes(i), `slot ${i} survived`);
  assert.equal(db.inv.find((r) => r.slot_index === 40).quantity, 41);

  const empty = fakeDb({ bag });
  await replaceBag(empty.conn, 1, [], saveBagSize(undefined));
  assert.deepEqual(empty.inv.map((r) => r.slot_index).sort((a, b) => a - b), Array.from({ length: 24 }, (_, i) => i + 24));
});

test('a current client (bagSize 48) replaces the whole bag and never touches equipped slots', async () => {
  const db = fakeDb({ bag: Array.from({ length: 48 }, (_, i) => row(i)), equipped: [{ slot_index: 105, item_id: 'staff_moon' }] });
  await replaceBag(db.conn, 1, [row(30, 'log_oak', 4)], saveBagSize(48));
  assert.deepEqual(db.inv.map((r) => r.slot_index).sort((a, b) => a - b), [30, 105]);
  assert.equal(db.inv.find((r) => r.slot_index === 30).item_id, 'log_oak');
});
