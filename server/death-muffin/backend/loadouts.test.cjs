// Run: node --test server/death-muffin/backend/loadouts.test.cjs
const test = require('node:test');
const assert = require('node:assert');
const mountLoadouts = require('./loadouts.cjs');
const { fakeDb, harness, qty } = require('./bag-fake-db.cjs');

const KEYS = ['bone_needle', 'marrow_spear', 'exhume', 'miasma', 'black_litany'];
const preset = (over = {}) => ({ name: 'Colossus', rites: { primary: 'bone_needle', keys: KEYS }, runes: {}, weapon: null, offhand: null, ...over });
const call = (db, route, body, opts) => harness(mountLoadouts, db, opts)(route, { body: { characterId: 1, ...body }, params: { characterId: '1' } });
const save = (db, slot, p) => call(db, 'POST /api/loadouts/save', { slot, preset: p });
const apply = (db, slot) => call(db, 'POST /api/loadouts/apply', { slot });
const gear = (...rows) => rows.map((r) => ({ quantity: 1, ...r }));
const at = (db, slot) => db.inv.find((r) => r.slot_index === slot);
const fullBag = (extra = []) => Array.from({ length: 48 }, (_, i) => extra.find((e) => e.slot_index === i) || { slot_index: i, item_id: 'ore_copper', quantity: 1 });

test('save, list, overwrite, delete; names tidy and presets are validated', async () => {
  const db = fakeDb();
  let r = (await save(db, 0, preset({ name: '  Plague   Doctor ' }))).json;
  assert.equal(r.success, true, r.error);
  assert.equal(r.data[0].preset.name, 'Plague Doctor');
  await save(db, 2, preset({ name: 'Tank', runes: { exhume: 'rune_bone_colossus' } }));
  const list = (await call(db, 'GET /api/loadouts/:characterId')).json;
  assert.deepEqual(list.data.map((p) => [p.slot, p.preset.name]), [[0, 'Plague Doctor'], [2, 'Tank']]);
  assert.equal(list.data[1].preset.runes.exhume, 'rune_bone_colossus');
  await save(db, 0, preset({ name: 'Renamed' }));
  assert.equal(db.loadouts.length, 2, 'slot 0 was replaced, not added');
  r = (await call(db, 'POST /api/loadouts/delete', { slot: 0 })).json;
  assert.deepEqual(r.data.map((p) => p.slot), [2]);
});

test('bad presets and slots are refused and nothing is stored', async () => {
  const db = fakeDb();
  assert.equal((await save(db, 6, preset())).status, 400);
  assert.equal((await save(db, -1, preset())).status, 400);
  assert.equal((await save(db, 0, preset({ name: '' }))).json.success, false);
  assert.equal((await save(db, 0, preset({ runes: { exhume: 'rune_volley' } }))).json.success, false);
  assert.equal((await save(db, 0, preset({ rites: { primary: 'a', keys: ['a', 'b'] } }))).json.success, false);
  assert.equal((await save(db, 0, preset({ weapon: { itemId: "x'; DROP TABLE", instanceId: null } }))).json.success, false);
  assert.equal(db.loadouts.length, 0);
});

test("another account's character is refused on every route", async () => {
  const db = fakeDb();
  for (const [route, body] of [['POST /api/loadouts/save', { slot: 0, preset: preset() }], ['POST /api/loadouts/delete', { slot: 0 }], ['POST /api/loadouts/apply', { slot: 0 }], ['GET /api/loadouts/:characterId', {}]]) {
    const r = await call(db, route, body, { owned: false });
    assert.equal(r.status, 403, route);
  }
});

test('apply swaps weapon, off-hand and runes in one go and answers the bag, the report and the preset', async () => {
  const db = fakeDb({
    bag: [{ slot_index: 0, item_id: 'wand_iron', quantity: 1 }, { slot_index: 1, item_id: 'grimoire_bone', quantity: 1 }, { slot_index: 2, item_id: 'rune_volley', quantity: 2 }],
    equipped: gear({ slot_index: 105, item_id: 'staff_oak', equipped_slot: 'main_hand' }, { slot_index: 130, item_id: 'rune_splinter', equipped_slot: 'rune_bone_needle' }),
  });
  await save(db, 1, preset({ weapon: { itemId: 'wand_iron', instanceId: null }, offhand: { itemId: 'grimoire_bone', instanceId: null }, runes: { bone_needle: 'rune_volley' } }));
  const r = (await apply(db, 1)).json;
  assert.equal(r.success, true, r.error);
  assert.deepEqual(r.report.skipped, []);
  assert.equal(at(db, 105).item_id, 'wand_iron');
  assert.equal(at(db, 105).equipped_slot, 'main_hand');
  assert.equal(at(db, 106).item_id, 'grimoire_bone');
  assert.equal(at(db, 130).item_id, 'rune_volley');
  assert.equal(at(db, 130).equipped_slot, 'rune_bone_needle');
  assert.equal(qty(db.inv, 'staff_oak'), 1, 'the staff went back to the bag');
  assert.equal(qty(db.inv, 'rune_splinter'), 1);
  assert.equal(qty(db.inv, 'rune_volley'), 2);
  assert.ok(db.inv.every((x) => x.slot_index !== 105 || x.equipped === 1));
  assert.equal(r.preset.name, 'Colossus');
  assert.ok(Array.isArray(r.data));
});

test('a rolled weapon is matched by its instance, and a missing one is skipped while the rest applies', async () => {
  const db = fakeDb({
    bag: [{ slot_index: 0, item_id: 'wand_iron', quantity: 1, instance_id: 41 }, { slot_index: 2, item_id: 'rune_volley', quantity: 1 }],
    loot: [{ id: 41, item_id: 'wand_iron' }],
    equipped: gear({ slot_index: 105, item_id: 'staff_oak', equipped_slot: 'main_hand' }),
  });
  await save(db, 0, preset({ weapon: { itemId: 'wand_iron', instanceId: 77 }, runes: { bone_needle: 'rune_volley', exhume: 'rune_bone_colossus' } }));
  const r = (await apply(db, 0)).json;
  assert.equal(r.success, true, r.error);
  assert.deepEqual(r.report.skipped.map((s) => [s.part, s.itemId, s.reason]), [['weapon', 'wand_iron', 'missing'], ['rune', 'rune_bone_colossus', 'missing']]);
  assert.equal(at(db, 105).item_id, 'staff_oak', 'the worn staff stayed');
  assert.equal(at(db, 130).item_id, 'rune_volley', 'the rune that was owned went in');
  const exact = fakeDb({ bag: [{ slot_index: 0, item_id: 'wand_iron', quantity: 1, instance_id: 41 }], loot: [{ id: 41, item_id: 'wand_iron' }] });
  await save(exact, 0, preset({ weapon: { itemId: 'wand_iron', instanceId: 41 } }));
  const ok = (await apply(exact, 0)).json;
  assert.equal(at(exact, 105).instance_id, 41, 'the roll travelled with the weapon');
  assert.deepEqual(ok.report.skipped, []);
});

test('a full bag loses nothing: swaps that need no new room work, the ones that do are refused and named', async () => {
  const db = fullBag([]) && fakeDb({
    bag: fullBag([{ slot_index: 3, item_id: 'staff_moon', quantity: 1 }, { slot_index: 5, item_id: 'rune_volley', quantity: 2 }]),
    equipped: gear({ slot_index: 105, item_id: 'wand_iron', equipped_slot: 'main_hand' }, { slot_index: 106, item_id: 'grimoire_bone', equipped_slot: 'off_hand' }, { slot_index: 130, item_id: 'rune_splinter', equipped_slot: 'rune_bone_needle' }),
  });
  const before = db.inv.reduce((n, r) => n + r.quantity, 0);
  // two-handed staff would push the wand AND the grimoire into a bag with one vacated slot; the rune swap needs a slot the stack of two does not free.
  await save(db, 0, preset({ weapon: { itemId: 'staff_moon', instanceId: null }, runes: { bone_needle: 'rune_volley' } }));
  const r = (await apply(db, 0)).json;
  assert.equal(r.success, true, r.error);
  assert.deepEqual(r.report.skipped.map((s) => [s.part, s.reason]), [['weapon', 'no_room'], ['rune', 'no_room']]);
  assert.deepEqual(r.report.applied, []);
  assert.equal(at(db, 105).item_id, 'wand_iron');
  assert.equal(at(db, 106).item_id, 'grimoire_bone');
  assert.equal(at(db, 130).item_id, 'rune_splinter');
  assert.equal(db.inv.reduce((n, x) => n + x.quantity, 0), before);
});

test('a full bag: a one-for-one weapon swap and a rune swap through a vacated slot still work, and nothing is lost', async () => {
  const db = fakeDb({
    bag: fullBag([{ slot_index: 3, item_id: 'staff_moon', quantity: 1 }, { slot_index: 5, item_id: 'rune_volley', quantity: 1 }]),
    equipped: gear({ slot_index: 105, item_id: 'staff_oak', equipped_slot: 'main_hand' }, { slot_index: 130, item_id: 'rune_splinter', equipped_slot: 'rune_bone_needle' }),
  });
  const before = db.inv.reduce((n, r) => n + r.quantity, 0);
  await save(db, 0, preset({ weapon: { itemId: 'staff_moon', instanceId: null }, runes: { bone_needle: 'rune_volley' } }));
  const r = (await apply(db, 0)).json;
  assert.deepEqual(r.report.skipped, []);
  assert.equal(at(db, 105).item_id, 'staff_moon');
  assert.equal(at(db, 3).item_id, 'staff_oak');
  assert.equal(at(db, 130).item_id, 'rune_volley');
  assert.equal(at(db, 5).item_id, 'rune_splinter');
  assert.equal(db.inv.reduce((n, x) => n + x.quantity, 0), before);
  assert.equal(db.inv.filter((x) => x.slot_index >= 0 && x.slot_index < 48).length, 48);
});

test('applying an empty slot is a readable refusal; applying again changes nothing', async () => {
  const db = fakeDb({ equipped: gear({ slot_index: 105, item_id: 'wand_iron', equipped_slot: 'main_hand' }) });
  assert.equal((await apply(db, 3)).json.success, false);
  await save(db, 0, preset({ weapon: { itemId: 'wand_iron', instanceId: null } }));
  const r = (await apply(db, 0)).json;
  assert.equal(r.report.unchanged, true);
  assert.equal(at(db, 105).item_id, 'wand_iron');
});
