// Run: node --test server/death-muffin/backend/tool-belt.test.cjs
const test = require('node:test');
const assert = require('node:assert');
const mountBelt = require('./tool-belt.cjs');
const { replaceBag, saveBagSize } = require('./inventory-save.cjs');
const gather = require('./gathering/gathering-rules.cjs');
const { fakeDb, harness } = require('./bag-fake-db.cjs');

const belt = (db, slot_index, equipped, opts) => harness(mountBelt, db, opts)('POST /api/inventory/belt', { body: { characterId: 1, slot_index, equipped } });
const at = (db, slot) => db.inv.find((r) => r.slot_index === slot);
const fullBag = (extra = []) => Array.from({ length: 48 }, (_, i) => extra.find((e) => e.slot_index === i) || { slot_index: i, item_id: 'staff_oak', quantity: 1 });

test('belt slots: hatchet 110, pickaxe 111, rod 112, spade 113', () => {
  assert.deepEqual(gather.BELT_KINDS.map((k, i) => [k, gather.BELT_BASE + i]), [['hatchet', 110], ['pickaxe', 111], ['rod', 112], ['spade', 113]]);
  assert.equal(gather.beltSlotOf('tool_rod_copper'), 112);
  assert.equal(gather.beltSlotOf('tool_rod_adamant'), -1);
  assert.equal(gather.beltSlotOf('staff_oak'), -1);
});

test('equipping a tool moves it to its belt slot and frees the bag slot', async () => {
  const db = fakeDb({ bag: [{ slot_index: 5, item_id: 'tool_pickaxe_copper', quantity: 1 }] });
  const r = (await belt(db, 5, 1)).json;
  assert.equal(r.success, true);
  assert.equal(at(db, 5), undefined);
  assert.deepEqual([at(db, 111).item_id, at(db, 111).equipped, at(db, 111).equipped_slot], ['tool_pickaxe_copper', 1, 'belt_pickaxe']);
  assert.ok(r.data.some((s) => s.slot_index === 111), 'the reply carries the belt row');
});

test('a second tool of the same kind swaps with the belt tool, even with a full bag', async () => {
  const db = fakeDb({ bag: fullBag([{ slot_index: 9, item_id: 'tool_hatchet_iron', quantity: 1 }]), equipped: [{ slot_index: 110, item_id: 'tool_hatchet_copper', equipped_slot: 'belt_hatchet' }] });
  const r = (await belt(db, 9, 1)).json;
  assert.equal(r.success, true);
  assert.equal(at(db, 110).item_id, 'tool_hatchet_iron');
  assert.deepEqual([at(db, 9).item_id, at(db, 9).equipped, at(db, 9).equipped_slot], ['tool_hatchet_copper', 0, null]);
  assert.equal(db.inv.length, 49, 'nothing created or lost');
});

test('only gathering tools go on the belt, and only from the bag', async () => {
  const db = fakeDb({ bag: [{ slot_index: 0, item_id: 'staff_oak', quantity: 1 }, { slot_index: 1, item_id: 'ore_copper', quantity: 5 }] });
  assert.match((await belt(db, 0, 1)).json.error, /Only gathering tools/);
  assert.match((await belt(db, 1, 1)).json.error, /Only gathering tools/);
  assert.match((await belt(db, 7, 1)).json.error, /nothing in that slot/);
  assert.match((await belt(db, 110, 0)).json.error, /empty/);
  assert.match((await belt(db, 3, 0)).json.error, /not a belt slot/);
  assert.equal(db.inv.length, 2);
});

test('unequipping returns the tool to the first free bag slot', async () => {
  const db = fakeDb({ bag: [{ slot_index: 0, item_id: 'staff_oak', quantity: 1 }, { slot_index: 2, item_id: 'staff_oak', quantity: 1 }], equipped: [{ slot_index: 112, item_id: 'tool_rod_copper', equipped_slot: 'belt_rod' }] });
  const r = (await belt(db, 112, 0)).json;
  assert.equal(r.success, true);
  assert.deepEqual([at(db, 1).item_id, at(db, 1).equipped, at(db, 1).equipped_slot], ['tool_rod_copper', 0, null]);
  assert.equal(at(db, 112), undefined);
});

test('unequipping with a full bag is refused readably and changes nothing', async () => {
  const db = fakeDb({ bag: fullBag(), equipped: [{ slot_index: 113, item_id: 'tool_spade_copper', equipped_slot: 'belt_spade' }] });
  const before = JSON.stringify(db.inv);
  const r = await belt(db, 113, 0);
  assert.equal(r.json.success, false);
  assert.match(r.json.error, /bag is full/);
  assert.equal(JSON.stringify(db.inv), before);
});

test('an unowned character is refused', async () => {
  const db = fakeDb({ bag: [{ slot_index: 5, item_id: 'tool_pickaxe_copper', quantity: 1 }] });
  const r = await belt(db, 5, 1, { owned: false });
  assert.equal(r.status, 403);
  assert.equal(at(db, 5).item_id, 'tool_pickaxe_copper');
});

test('a bag save (any bag, including an empty one) leaves belt and gear rows intact', async () => {
  const db = fakeDb({
    bag: [{ slot_index: 0, item_id: 'ore_copper', quantity: 3 }],
    equipped: [{ slot_index: 110, item_id: 'tool_hatchet_copper', equipped_slot: 'belt_hatchet' }, { slot_index: 113, item_id: 'tool_spade_copper', equipped_slot: 'belt_spade' }, { slot_index: 105, item_id: 'staff_oak' }],
  });
  await replaceBag(db.conn, 1, [{ slot_index: 4, item_id: 'bone_meal', quantity: 2 }], saveBagSize(48));
  assert.deepEqual(db.inv.map((r) => r.slot_index).sort((a, b) => a - b), [4, 105, 110, 113]);
  await replaceBag(db.conn, 1, [], saveBagSize(48));
  assert.deepEqual(db.inv.map((r) => r.slot_index).sort((a, b) => a - b), [105, 110, 113]);
  assert.equal(at(db, 110).equipped_slot, 'belt_hatchet');
});

test('the save route drops echoed belt rows rather than failing (server.js filter range)', () => {
  const src = require('node:fs').readFileSync(require('node:path').join(__dirname, 'server.js'), 'utf8');
  assert.match(src, /BELT_BASE \+ gatheringRules\.BELT_SLOT_COUNT - 1/);
});
