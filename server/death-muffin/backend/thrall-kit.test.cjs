// Run: node --test server/death-muffin/backend/thrall-kit.test.cjs
const test = require('node:test');
const assert = require('node:assert');
const mountKit = require('./thrall-kit.cjs');
const mountVault = require('./vault.cjs');
const mountSalvage = require('./salvage.cjs');
const { replaceBag, saveBagSize } = require('./inventory-save.cjs');
const sync = require('./offline-full-sync.cjs');
const legion = require('./gathering/legion-rules.cjs');
const { fakeDb, harness } = require('./bag-fake-db.cjs');

const kit = (db, slot_index, equipped, opts) => harness(mountKit, db, opts)('POST /api/inventory/kit', { body: { characterId: 1, slot_index, equipped } });
const at = (db, slot) => db.inv.find((r) => r.slot_index === slot);
const fullBag = (extra = []) => Array.from({ length: 48 }, (_, i) => extra.find((e) => e.slot_index === i) || { slot_index: i, item_id: 'wand_iron', quantity: 1 });

test('kit slots: weapon 120, armour 121, clear of the gear (100-108) and the tool belt (110-113)', () => {
  assert.deepEqual(legion.KIT_IDS.map((k) => legion.kitSlotIndex(k)), [120, 121]);
  assert.equal(legion.kitEquippedSlot('armor'), 'kit_armor');
  assert.ok(legion.kitEquippedSlot('weapon').length <= 12, 'no longer than the belt values the live column already holds');
  assert.deepEqual([119, 122, 110, 105].map(legion.isKitSlot), [false, false, false, false]);
});

test('a weapon goes to the weapon slot, armour to the armour slot, and the bag slot is freed', async () => {
  const db = fakeDb({ bag: [{ slot_index: 5, item_id: 'staff_oak', quantity: 1 }, { slot_index: 6, item_id: 'chest_iron', quantity: 1 }, { slot_index: 7, item_id: 'grimoire_bone', quantity: 1 }] });
  const r = (await kit(db, 5, 1)).json;
  assert.equal(r.success, true);
  assert.deepEqual([at(db, 120).item_id, at(db, 120).equipped, at(db, 120).equipped_slot], ['staff_oak', 1, 'kit_weapon']);
  assert.equal(at(db, 5), undefined);
  assert.ok(r.data.some((s) => s.slot_index === 120), 'the reply carries the kit row');
  await kit(db, 6, 1);
  assert.deepEqual([at(db, 121).item_id, at(db, 121).equipped_slot], ['chest_iron', 'kit_armor']);
  // An off-hand is weapon-side gear too: it swaps with the staff.
  await kit(db, 7, 1);
  assert.equal(at(db, 120).item_id, 'grimoire_bone');
  assert.deepEqual([at(db, 7).item_id, at(db, 7).equipped], ['staff_oak', 0]);
});

test('a second piece swaps with the kit piece even with a full bag, and nothing is created or lost', async () => {
  const db = fakeDb({ bag: fullBag([{ slot_index: 9, item_id: 'staff_moon', quantity: 1 }]), equipped: [{ slot_index: 120, item_id: 'staff_oak', equipped_slot: 'kit_weapon' }] });
  const r = (await kit(db, 9, 1)).json;
  assert.equal(r.success, true);
  assert.equal(at(db, 120).item_id, 'staff_moon');
  assert.deepEqual([at(db, 9).item_id, at(db, 9).equipped, at(db, 9).equipped_slot], ['staff_oak', 0, null]);
  assert.equal(db.inv.length, 49);
});

test('a rolled piece keeps its item level and affixes on the way in and out', async () => {
  const db = fakeDb({ bag: [{ slot_index: 3, item_id: 'chest_iron', quantity: 1, instance_id: 1001 }], loot: [{ id: 1001, item_id: 'chest_iron', ilvl: 14, affixes: [{ id: 's_thrall_hp', v: 120 }] }] });
  await kit(db, 3, 1);
  assert.equal(at(db, 121).instance_id, 1001);
  const out = (await kit(db, 121, 0)).json;
  assert.equal(out.success, true);
  assert.equal(at(db, 0).instance_id, 1001, 'back in the first free bag slot');
  assert.equal(db.loot.length, 1);
});

test('only weapons and the five armour pieces fit, and only from the bag', async () => {
  const db = fakeDb({ bag: [{ slot_index: 0, item_id: 'ring_copper', quantity: 1 }, { slot_index: 1, item_id: 'ore_copper', quantity: 5 }, { slot_index: 2, item_id: 'tool_hatchet_copper', quantity: 1 }] });
  assert.match((await kit(db, 0, 1)).json.error, /weapons and armour only/);
  assert.match((await kit(db, 1, 1)).json.error, /weapons and armour only/);
  assert.match((await kit(db, 2, 1)).json.error, /weapons and armour only/);
  assert.match((await kit(db, 7, 1)).json.error, /nothing in that slot/);
  assert.match((await kit(db, 120, 0)).json.error, /empty/);
  assert.match((await kit(db, 3, 0)).json.error, /not a legion slot/);
  assert.match((await kit(db, 110, 1)).json.error, /Pick a piece from your bag/);
  assert.equal(db.inv.length, 3);
});

test('taking a piece off returns it to the first free bag slot; a full bag refuses and changes nothing', async () => {
  const db = fakeDb({ bag: [{ slot_index: 0, item_id: 'wand_iron', quantity: 1 }, { slot_index: 2, item_id: 'wand_iron', quantity: 1 }], equipped: [{ slot_index: 121, item_id: 'helm_iron', equipped_slot: 'kit_armor' }] });
  const r = (await kit(db, 121, 0)).json;
  assert.equal(r.success, true);
  assert.deepEqual([at(db, 1).item_id, at(db, 1).equipped, at(db, 1).equipped_slot], ['helm_iron', 0, null]);
  const full = fakeDb({ bag: fullBag(), equipped: [{ slot_index: 120, item_id: 'staff_oak', equipped_slot: 'kit_weapon' }] });
  const before = JSON.stringify(full.inv);
  const refused = await kit(full, 120, 0);
  assert.equal(refused.json.success, false);
  assert.match(refused.json.error, /bag is full/);
  assert.equal(JSON.stringify(full.inv), before);
});

test('an unowned character is refused', async () => {
  const db = fakeDb({ bag: [{ slot_index: 5, item_id: 'staff_oak', quantity: 1 }] });
  const r = await kit(db, 5, 1, { owned: false });
  assert.equal(r.status, 403);
  assert.equal(at(db, 5).item_id, 'staff_oak');
});

test('a bag save (any bag, including an empty one) leaves kit, belt and gear rows intact', async () => {
  const db = fakeDb({
    bag: [{ slot_index: 0, item_id: 'ore_copper', quantity: 3 }],
    equipped: [{ slot_index: 120, item_id: 'staff_oak', equipped_slot: 'kit_weapon' }, { slot_index: 121, item_id: 'chest_iron', equipped_slot: 'kit_armor' }, { slot_index: 110, item_id: 'tool_hatchet_copper', equipped_slot: 'belt_hatchet' }, { slot_index: 105, item_id: 'staff_oak' }],
  });
  await replaceBag(db.conn, 1, [{ slot_index: 4, item_id: 'bone_meal', quantity: 2 }], saveBagSize(48));
  assert.deepEqual(db.inv.map((r) => r.slot_index).sort((a, b) => a - b), [4, 105, 110, 120, 121]);
  await replaceBag(db.conn, 1, [], saveBagSize(48));
  assert.deepEqual(db.inv.map((r) => r.slot_index).sort((a, b) => a - b), [105, 110, 120, 121]);
  assert.equal(at(db, 121).equipped_slot, 'kit_armor');
});

test('the Vault and Salvage cannot touch a kit piece', async () => {
  const db = fakeDb({
    bag: [{ slot_index: 0, item_id: 'wand_iron', quantity: 1 }],
    equipped: [{ slot_index: 120, item_id: 'staff_oak', equipped_slot: 'kit_weapon' }, { slot_index: 121, item_id: 'chest_iron', equipped_slot: 'kit_armor' }],
  });
  const salvage = harness(mountSalvage, db, { random: () => 0 });
  for (const slot of [120, 121]) assert.match((await salvage('POST /api/salvage', { body: { characterId: 1, slots: [slot] } })).json.error, /slots 0 to 47/);
  const vault = harness(mountVault, db);
  assert.equal((await vault('POST /api/vault/deposit', { body: { characterId: 1, bagSlot: 120 } })).json.success, false);
  const all = (await vault('POST /api/vault/deposit-all', { body: { characterId: 1, kind: 'all', exceptSlots: [] } })).json;
  assert.equal(all.success, true);
  assert.deepEqual(db.inv.map((r) => r.slot_index).sort((a, b) => a - b), [120, 121], 'only the bag emptied; both kit rows stayed');
  assert.deepEqual(db.vault.map((v) => v.item_id), ['wand_iron']);
});

test('the save route drops echoed kit rows rather than failing (server.js filter range)', () => {
  const src = require('node:fs').readFileSync(require('node:path').join(__dirname, 'server.js'), 'utf8');
  // The filter runs 100 .. the last Relic rune socket (runes.cjs), which sits above the kit: it must still cover both kit slots.
  assert.match(src, /runeRules\.RUNE_BASE \+ runeRules\.RUNE_SLOT_COUNT - 1/);
  assert.match(src, /require\('\.\/thrall-kit\.cjs'\)/);
});

// --- offline sync -------------------------------------------------------------------------------------------------

const save = (slots) => ({
  username: 't', character: { id: 7, class_index: 2, class_name: 'Ossuary', level: 4, experience: 120, gold: 50, stat_str: 5, stat_agi: 5, stat_int: 8, stat_vit: 10, pos_x: 0, pos_y: 0, pos_z: 0, pos_map: 'HUB', orientation: 0 },
  slots, professions: [], necro: { ascension: 0, legionTier: 3 }, garden: {}, labor: {}, cosmetics: { cape: null, pet: null, pets: [] },
});

test('offline sync accepts kit slots 120-121 and rejects 119, 122 and a belt-sized overflow', () => {
  const ok = [{ slot_index: 120, item_id: 'staff_oak', quantity: 1, equipped: 1 }, { slot_index: 121, item_id: 'chest_iron', quantity: 1, equipped: 1 }];
  assert.doesNotThrow(() => sync.validate(save(ok), 2));
  for (const slot_index of [119, 122, 135]) assert.throws(() => sync.validate(save([{ slot_index, item_id: 'staff_oak', quantity: 1 }]), 2), RangeError);
});

test('offline sync apply files kit rows with their kit_ equipped_slot and checks the piece fits its slot', async () => {
  const inserts = [];
  const conn = {
    execute: async (sql, p) => {
      if (sql.startsWith('INSERT INTO inventory')) inserts.push(p);
      if (sql.startsWith('SELECT account_id')) return [[{ account_id: 7 }]];
      return [[]];
    },
    query: async (sql) => {
      if (sql.includes('FROM items')) return [[
        { id: 'staff_oak', stackable: 0, max_stack_size: 1, equipment_slot: 'main_hand', item_type: 'weapon' },
        { id: 'chest_iron', stackable: 0, max_stack_size: 1, equipment_slot: 'chest', item_type: 'armor_chest' },
        { id: 'ring_copper', stackable: 0, max_stack_size: 1, equipment_slot: 'ring', item_type: 'ring' },
      ]];
      return [[]];
    },
  };
  await sync.apply(conn, 7, save([{ slot_index: 120, item_id: 'staff_oak', quantity: 1 }, { slot_index: 121, item_id: 'chest_iron', quantity: 1 }])).catch((e) => { if (!/(reading|undefined|not a function)/.test(e.message)) throw e; });
  assert.deepEqual(inserts.map((p) => [p[1], p[4], p[5]]), [[120, 1, 'kit_weapon'], [121, 1, 'kit_armor']]);
  // A weapon in the armour slot, or a ring in either, is refused before anything is written.
  inserts.length = 0;
  await assert.rejects(sync.apply(conn, 7, save([{ slot_index: 121, item_id: 'staff_oak', quantity: 1 }])), /Invalid equipped item/);
  await assert.rejects(sync.apply(conn, 7, save([{ slot_index: 120, item_id: 'ring_copper', quantity: 1 }])), /Invalid equipped item/);
  assert.equal(inserts.length, 0);
});
