// Run: node --test server/death-muffin/backend/salvage.test.cjs
const test = require('node:test');
const assert = require('node:assert');
const mountSalvage = require('./salvage.cjs');
const { fakeDb, harness, qty, ITEMS } = require('./bag-fake-db.cjs');
const salvage = require('./gathering/salvage-rules.cjs');
const gather = require('./gathering/gathering-rules.cjs');

/** What the rules say salvaging these bag items gives at this Salvaging level and roll (items are the fake table's gear). */
const expected = (ids, level, roll) => {
  const outs = ids.map((id) => salvage.salvageYield({ id, item_type: ITEMS[id].type, rarity: ITEMS[id].rarity }, level, () => roll));
  return { gained: salvage.mergeGrants(outs.map((o) => o.items)), xp: outs.reduce((n, o) => n + o.xp, 0) };
};

const call = (db, opts) => harness(mountSalvage, db, opts);
const go = (c, slots) => c('POST /api/salvage', { body: { characterId: 1, slots } });

test('salvaging gear removes it, pays materials and reagents, and awards Salvaging XP', async () => {
  const db = fakeDb({ bag: [{ slot_index: 0, item_id: 'staff_oak', quantity: 1 }, { slot_index: 1, item_id: 'helm_copper', quantity: 1 }] });
  const r = (await go(call(db, { random: () => 0 }), [0, 1])).json;
  assert.equal(r.success, true, r.error);
  assert.equal(r.data.salvaged.length, 2);
  assert.equal(db.inv.some((x) => x.item_id === 'staff_oak' || x.item_id === 'helm_copper'), false);
  // what the bag holds now is exactly what the rules yield for these two pieces at this roll
  const want = expected(['staff_oak', 'helm_copper'], 1, 0);
  for (const g of want.gained) assert.equal(qty(db.inv, g.item_id), g.quantity, g.item_id);
  assert.deepEqual(r.data.gained.map((g) => g.item_id).sort(), want.gained.map((g) => g.item_id).sort());
  assert.ok(salvage.yieldsPlanks({ id: 'staff_oak' }) && want.gained.some((g) => g.item_id.startsWith('plank_')), 'a staff gives planks');
  assert.ok(!salvage.yieldsPlanks({ id: 'helm_copper' }) && want.gained.some((g) => g.item_id.startsWith('ingot_')), 'a helm gives ingots');
  assert.ok(want.xp > 0);
  assert.equal(r.data.xp, want.xp);
  assert.ok(db.prof.exists);
  assert.equal(db.prof.xp, want.xp);
  assert.ok(r.data.bag.length > 0);
  assert.equal(r.data.leveledUp, gather.addSkillXp({ level: 1, xp: 0 }, want.xp).leveled > 0);
});

test('enough XP levels the skill up', async () => {
  // one point short of the next level: any salvage pays more than that
  const db = fakeDb({ bag: [{ slot_index: 0, item_id: 'staff_moon', quantity: 1 }], level: 1, xp: gather.xpToNext(1) - 1 });
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
  assert.match((await go(c, [gather.BAG_SLOTS])).json.error, new RegExp(`slots 0 to ${gather.BAG_SLOTS - 1}`));
  assert.match((await go(c, [105])).json.error, new RegExp(`slots 0 to ${gather.BAG_SLOTS - 1}`));
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
  // A bag full of non-stackable fillers plus one staff: salvaging the staff frees its one slot, but the yield needs a slot for each kind it gives.
  const kinds = expected(['staff_oak'], 1, 0).gained.length;
  assert.ok(kinds > 1, 'the scenario needs a yield of more than one kind');
  const bag = [{ slot_index: 0, item_id: 'staff_oak', quantity: 1 }, ...Array.from({ length: gather.BAG_SLOTS - 1 }, (_, i) => ({ slot_index: i + 1, item_id: 'wand_iron', quantity: 1 }))];
  const db = fakeDb({ bag });
  const r = (await go(call(db, { random: () => 0 }), [0])).json;
  assert.equal(r.success, false);
  assert.match(r.error, /Make room/);
  assert.equal(db.inv.length, gather.BAG_SLOTS);
  assert.equal(db.inv.some((x) => x.item_id === 'staff_oak'), true);
  assert.equal(db.prof.xp, 0, 'no XP awarded');
});

test('yields stack onto existing stacks and use freed slots', async () => {
  // At a roll of 0.99 nothing is lucky. The bag holds a plank stack with room for exactly the planks the staff gives, and just enough free
  // slots (the staff's own, plus any more the other kinds need) for everything else.
  const want = expected(['staff_oak'], 1, 0.99).gained;
  const planks = want.find((g) => g.item_id.startsWith('plank_'));
  const others = want.filter((g) => g !== planks);
  assert.ok(planks && others.length >= 1, 'the staff gives planks and something else');
  const fillers = Array.from({ length: gather.BAG_SLOTS - 2 - (others.length - 1) }, (_, i) => ({ slot_index: i + 2, item_id: 'wand_iron', quantity: 1 }));
  const bag = [{ slot_index: 0, item_id: 'staff_oak', quantity: 1 }, { slot_index: 1, item_id: planks.item_id, quantity: ITEMS[planks.item_id].stack - planks.quantity }, ...fillers];
  const db = fakeDb({ bag });
  const r = (await go(call(db, { random: () => 0.99 }), [0])).json;
  assert.equal(r.success, true, r.error);
  assert.equal(qty(db.inv, planks.item_id), ITEMS[planks.item_id].stack, 'the planks topped the stack up');
  for (const g of others) assert.equal(qty(db.inv, g.item_id), g.quantity, g.item_id);
});

test('someone else\'s character is refused', async () => {
  assert.equal((await go(call(fakeDb(), { owned: false }), [0])).status, 403);
});

test('belt slots (110-113) are out of bag range: salvage refuses them and leaves the belt alone', async () => {
  const db = fakeDb({ bag: [{ slot_index: 0, item_id: 'staff_oak', quantity: 1 }], equipped: [{ slot_index: 110, item_id: 'tool_hatchet_copper', equipped_slot: 'belt_hatchet' }] });
  const r = (await go(call(db, { random: () => 0 }), [110])).json;
  assert.equal(r.success, false);
  assert.equal(db.inv.filter((x) => x.slot_index === 110).length, 1);
});
