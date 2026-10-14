// Run: node --test server/death-muffin/backend/bag-ops.test.cjs
// The bag's own operations (DECISIONS B25): sort and use change the server's bag and answer it.
const test = require('node:test');
const assert = require('node:assert');
const mountBagOps = require('./bag-ops.cjs');
const { fakeDb, harness, qty } = require('./bag-fake-db.cjs');

const call = (db, opts) => harness((app, pool, o) => mountBagOps(app, pool, { ...o, log: { error: () => {} } }), db, opts);

test('sort merges stacks, packs from slot 0 and answers the moves; a locked stack never merges', async () => {
  const db = fakeDb({ bag: [{ slot_index: 3, item_id: 'ore_copper', quantity: 5 }, { slot_index: 9, item_id: 'ore_copper', quantity: 7 }, { slot_index: 6, item_id: 'staff_oak', quantity: 1 }] });
  const r = (await call(db)('POST /api/inventory/sort', { body: { characterId: 1 } })).json;
  assert.equal(r.success, true);
  assert.deepEqual(db.inv.filter((x) => x.slot_index < 48).map((x) => [x.slot_index, x.item_id, x.quantity]).sort((a, b) => a[0] - b[0]), [[0, 'staff_oak', 1], [1, 'ore_copper', 12]]);
  assert.deepEqual(r.data.moves, { 6: 0, 3: 1, 9: 1 });
  assert.ok(Array.isArray(r.data.bag));
  const locked = fakeDb({ bag: [{ slot_index: 3, item_id: 'ore_copper', quantity: 5 }, { slot_index: 9, item_id: 'ore_copper', quantity: 7 }] });
  await call(locked)('POST /api/inventory/sort', { body: { characterId: 1, locked: [9] } });
  assert.equal(locked.inv.filter((x) => x.item_id === 'ore_copper').length, 2);
});

test('use spends consumables the bag holds, from the named slot first; anything else is untouched', async () => {
  const db = fakeDb({ bag: [{ slot_index: 0, item_id: 'flask_hp_minor', quantity: 2 }, { slot_index: 5, item_id: 'flask_hp_minor', quantity: 3 }, { slot_index: 1, item_id: 'ore_copper', quantity: 4 }] });
  const r = (await call(db)('POST /api/inventory/use', { body: { characterId: 1, uses: [{ item_id: 'flask_hp_minor', slot_index: 5, quantity: 4 }, { item_id: 'ore_copper', quantity: 2 }] } })).json;
  assert.equal(r.success, true);
  assert.deepEqual(r.data.used, [{ item_id: 'flask_hp_minor', quantity: 4 }]);
  assert.equal(qty(db.inv, 'flask_hp_minor'), 1);
  assert.equal(qty(db.inv, 'ore_copper'), 4);
  // Drinking more than the bag holds spends what is there and is not an error: the answer is the truth.
  const more = (await call(db)('POST /api/inventory/use', { body: { characterId: 1, uses: [{ item_id: 'flask_hp_minor', quantity: 9 }] } })).json;
  assert.deepEqual(more.data.used, [{ item_id: 'flask_hp_minor', quantity: 1 }]);
  assert.equal(qty(db.inv, 'flask_hp_minor'), 0);
});

test('bad requests are refused readably and change nothing; another account\'s character is refused', async () => {
  const db = fakeDb({ bag: [{ slot_index: 0, item_id: 'flask_hp_minor', quantity: 2 }] });
  const c = call(db);
  for (const uses of [undefined, [], [{ item_id: 'flask_hp_minor', quantity: 0 }], [{ quantity: 1 }], Array.from({ length: 41 }, () => ({ item_id: 'flask_hp_minor', quantity: 1 }))]) {
    const r = (await c('POST /api/inventory/use', { body: { characterId: 1, uses } })).json;
    assert.equal(r.success, false);
    assert.equal(typeof r.error, 'string');
  }
  assert.equal(qty(db.inv, 'flask_hp_minor'), 2);
  const other = await call(db, { owned: false })('POST /api/inventory/use', { body: { characterId: 1, uses: [{ item_id: 'flask_hp_minor', quantity: 1 }] } });
  assert.equal(other.status, 403);
});
