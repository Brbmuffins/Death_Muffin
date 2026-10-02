// Run: node --test server/death-muffin/backend/salvage.test.cjs
const test = require('node:test');
const assert = require('node:assert');
const mountSalvage = require('./salvage.cjs');
const { fakeDb, harness, qty } = require('./bag-fake-db.cjs');

const call = (db, opts) => harness(mountSalvage, db, opts);
const go = (c, slots) => c('POST /api/salvage', { body: { characterId: 1, slots } });

test('salvaging gear removes it, pays materials and reagents, and awards Salvaging XP', async () => {
  const db = fakeDb({ bag: [{ slot_index: 0, item_id: 'staff_oak', quantity: 1 }, { slot_index: 1, item_id: 'helm_copper', quantity: 1 }] });
  const r = (await go(call(db, { random: () => 0 }), [0, 1])).json;
  assert.equal(r.success, true, r.error);
  assert.equal(r.data.salvaged.length, 2);
  assert.equal(db.inv.some((x) => x.item_id === 'staff_oak' || x.item_id === 'helm_copper'), false);
  // rand 0 always rolls the level bonus (+1 material) and every chance, so: 1 + 1 of the material, 1 dust each.
  assert.equal(qty(db.inv, 'plank_oak'), 2, 'a staff gives planks');
  assert.equal(qty(db.inv, 'ingot_copper'), 2, 'a helm gives ingots');
  assert.equal(qty(db.inv, 'reagent_grave_dust'), 2, 'dust 1 per item at rand 0');
  assert.equal(r.data.xp, 8);
  assert.ok(db.prof.exists);
  assert.equal(db.prof.xp, 8);
  assert.deepEqual(r.data.gained.map((g) => g.item_id).sort(), ['bone_meal', 'ingot_copper', 'plank_oak', 'reagent_grave_dust']);
  assert.ok(r.data.bag.length > 0);
  assert.equal(r.data.leveledUp, false);
});

test('enough XP levels the skill up', async () => {
  const db = fakeDb({ bag: [{ slot_index: 0, item_id: 'staff_moon', quantity: 1 }], level: 1, xp: 30 });
  const r = (await go(call(db, { random: () => 0.99 }), [0])).json;
  assert.equal(r.success, true);
  assert.equal(r.data.leveledUp, true);
  assert.ok(r.data.level >= 2);
});

test('refuses empty slots, equipped gear, materials and out-of-bag slots, changing nothing', async () => {
  const db = fakeDb({ bag: [{ slot_index: 0, item_id: 'ore_copper', quantity: 5 }, { slot_index: 1, item_id: 'staff_oak', quantity: 1 }], equipped: [{ slot_index: 105, item_id: 'staff_moon' }] });
  const c = call(db, { random: () => 0 });
  assert.match((await go(c, [0])).json.error, /Only weapons/);
  assert.match((await go(c, [9])).json.error, /empty/);
  assert.match((await go(c, [48])).json.error, /slots 0 to 47/);
  assert.match((await go(c, [105])).json.error, /slots 0 to 47/);
  assert.match((await go(c, [1, 1])).json.error, /each once/);
  assert.match((await go(c, [])).json.error, /Choose some gear/);
  assert.match((await go(c, [1, 0])).json.error, /Only weapons/);
  assert.equal(db.inv.length, 3, 'nothing was removed');
  assert.equal(db.prof.xp, 0);
});

test('equipped gear sitting in a bag row cannot be salvaged', async () => {
  const db = fakeDb({ bag: [{ slot_index: 0, item_id: 'staff_oak', quantity: 1, equipped: 1, equipped_slot: 'main_hand' }] });
  assert.match((await go(call(db), [0])).json.error, /Equipped gear/);
});

test('if the yield will not fit the whole request is refused and nothing changes', async () => {
  // 47 full non-stackable fillers + one staff; salvaging the staff frees its slot for 1 plank but the dust and ingot need more.
  const bag = [{ slot_index: 0, item_id: 'staff_oak', quantity: 1 }, ...Array.from({ length: 47 }, (_, i) => ({ slot_index: i + 1, item_id: 'wand_iron', quantity: 1 }))];
  const db = fakeDb({ bag });
  const r = (await go(call(db, { random: () => 0 }), [0])).json;
  assert.equal(r.success, false);
  assert.match(r.error, /Make room/);
  assert.equal(db.inv.length, 48);
  assert.equal(db.inv.some((x) => x.item_id === 'staff_oak'), true);
  assert.equal(db.prof.xp, 0, 'no XP awarded');
});

test('yields stack onto existing stacks and use freed slots', async () => {
  const bag = [{ slot_index: 0, item_id: 'staff_oak', quantity: 1 }, { slot_index: 1, item_id: 'plank_oak', quantity: 249 }, ...Array.from({ length: 46 }, (_, i) => ({ slot_index: i + 2, item_id: 'wand_iron', quantity: 1 }))];
  const db = fakeDb({ bag });
  const r = (await go(call(db, { random: () => 0.99 }), [0])).json; // no bonus, no chances: 1 plank (tops up the stack) + 2 dust (freed slot)
  assert.equal(r.success, true, r.error);
  assert.equal(qty(db.inv, 'plank_oak'), 250);
  assert.equal(qty(db.inv, 'reagent_grave_dust'), 2);
});

test('someone else\'s character is refused', async () => {
  assert.equal((await go(call(fakeDb(), { owned: false }), [0])).status, 403);
});
