// Run: node --test server/death-muffin/backend/runes.test.cjs
const test = require('node:test');
const assert = require('node:assert');
const mountRunes = require('./runes.cjs');
const mountVault = require('./vault.cjs');
const mountSalvage = require('./salvage.cjs');
const { replaceBag } = require('./inventory-save.cjs');
const sync = require('./offline-full-sync.cjs');
const rules = require('./gathering/rune-rules.cjs');
const salvageRules = require('./gathering/salvage-rules.cjs');
const authority = require('./gathering/authority-rules.cjs');
const { fakeDb, harness, qty } = require('./bag-fake-db.cjs');
const { BAG_SLOTS } = require('./gathering/gathering-rules.cjs');

const rune = (db, rite, itemId, opts) => harness(mountRunes, db, opts)('POST /api/inventory/rune', { body: { characterId: 1, rite, itemId } });
const at = (db, slot) => db.inv.find((r) => r.slot_index === slot);
const fullBag = (extra = []) => Array.from({ length: BAG_SLOTS }, (_, i) => extra.find((e) => e.slot_index === i) || { slot_index: i, item_id: 'wand_iron', quantity: 1 });

test('sockets: 130 needle, 131 spear, 132 exhume, 133 miasma, 134 litany, clear of the kit (120-121) and the belt (110-113)', () => {
  const rites = ['bone_needle', 'marrow_spear', 'exhume', 'miasma', 'black_litany'];
  assert.deepEqual(rites.map((r) => rules.runeSlotIndex(r)), [130, 131, 132, 133, 134]);
  assert.equal(rules.runeEquippedSlot('exhume'), 'rune_exhume');
  assert.ok(rules.runeEquippedSlot('black_litany').length <= 32, 'fits the live varchar(32) column');
  assert.deepEqual([129, 130, 134, 135].map(rules.isRuneSlot), [false, true, true, false]);
  assert.equal(rules.runeFits('rune_requiem', 'black_litany'), true);
  assert.equal(rules.runeFits('rune_requiem', 'exhume'), false);
});

const learn = (db, slot, opts) => harness(mountRunes, db, opts)('POST /api/inventory/rune/learn', { body: { characterId: 1, slot } });

test('learn: one rune of the stack is spent, the rune is learned, and an empty socket of its rite takes it', async () => {
  const db = fakeDb({ bag: [{ slot_index: 4, item_id: 'rune_volley', quantity: 3 }] });
  const r = (await learn(db, 4)).json;
  assert.equal(r.success, true, r.error);
  assert.equal(at(db, 4).quantity, 2);
  assert.deepEqual(db.learned, ['rune_volley']);
  assert.deepEqual(r.data.learned, ['rune_volley']);
  assert.equal(r.data.rune, 'rune_volley');
  assert.equal(r.data.socketed, true);
  assert.deepEqual([at(db, 130).item_id, at(db, 130).quantity, at(db, 130).equipped, at(db, 130).equipped_slot], ['rune_volley', 1, 1, 'rune_bone_needle']);
  assert.ok(r.data.bag.some((s) => s.slot_index === 130 && s.item_id === 'rune_volley'), 'the reply carries the socket row');
});

test('learn: the last rune empties its bag slot; a filled socket keeps its rune', async () => {
  const db = fakeDb({ bag: [{ slot_index: 4, item_id: 'rune_requiem', quantity: 1 }], equipped: [{ slot_index: 134, item_id: 'rune_hollow_choir', equipped_slot: 'rune_black_litany' }], runes: ['rune_hollow_choir'] });
  const r = (await learn(db, 4)).json;
  assert.equal(r.success, true, r.error);
  assert.equal(r.data.socketed, false);
  assert.equal(at(db, 4), undefined);
  assert.equal(at(db, 134).item_id, 'rune_hollow_choir');
  assert.deepEqual(r.data.learned, ['rune_hollow_choir', 'rune_requiem'], 'in rune order');
});

test('learn refusals: a rune already known (the copy stays), not a rune, an empty slot, a socket or reserved slot', async () => {
  const db = fakeDb({ bag: [{ slot_index: 0, item_id: 'rune_volley', quantity: 2 }, { slot_index: 1, item_id: 'sword_copper', quantity: 1 }], equipped: [{ slot_index: 130, item_id: 'rune_splinter', equipped_slot: 'rune_bone_needle' }], runes: ['rune_volley', 'rune_splinter'] });
  assert.match((await learn(db, 0)).json.error, /already know this rune/);
  assert.equal(at(db, 0).quantity, 2, 'the copy stays');
  assert.match((await learn(db, 1)).json.error, /not a rune/);
  assert.match((await learn(db, 7)).json.error, /no rune in that bag slot/);
  assert.match((await learn(db, 130)).json.error, /no rune in that bag slot/);
  assert.equal((await harness(mountRunes, db)('POST /api/inventory/rune/learn', { body: { characterId: 1 } })).status, 400);
  assert.equal(db.inv.length, 3, 'nothing moved');
});

test('socket: any learned rune of the rite goes in (replacing the old one) without touching the bag, even a full one', async () => {
  const db = fakeDb({ bag: fullBag(), equipped: [{ slot_index: 132, item_id: 'rune_bone_colossus', equipped_slot: 'rune_exhume' }], runes: ['rune_bone_colossus', 'rune_mass_grave'] });
  const r = (await rune(db, 'exhume', 'rune_mass_grave')).json;
  assert.equal(r.success, true, r.error);
  assert.equal(at(db, 132).item_id, 'rune_mass_grave');
  assert.equal(db.inv.length, BAG_SLOTS + 1, 'the bag is untouched');
  assert.equal(qty(db.inv, 'rune_bone_colossus'), 0, 'the old rune stays learned, not an item');
  assert.ok(r.data.some((s) => s.slot_index === 132 && s.item_id === 'rune_mass_grave'), 'the reply is the bag with the socket row');
});

test('null empties the socket without needing bag room; the rune stays learned', async () => {
  const db = fakeDb({ bag: fullBag(), equipped: [{ slot_index: 131, item_id: 'rune_impale', equipped_slot: 'rune_marrow_spear' }], runes: ['rune_impale'] });
  const r = (await rune(db, 'marrow_spear', null)).json;
  assert.equal(r.success, true, r.error);
  assert.equal(at(db, 131), undefined);
  assert.equal(db.inv.length, BAG_SLOTS);
  assert.deepEqual(db.learned, ['rune_impale']);
});

test('socket refusals: a rune that does not fit the rite, a rune not learned (even one in the bag), an unknown id, an empty socket, an unknown rite', async () => {
  const db = fakeDb({ bag: [{ slot_index: 0, item_id: 'rune_volley', quantity: 1 }, { slot_index: 1, item_id: 'sword_copper', quantity: 1 }], runes: ['rune_splinter'] });
  assert.match((await rune(db, 'miasma', 'rune_volley')).json.error, /doesn't fit this rite/);
  assert.match((await rune(db, 'bone_needle', 'rune_volley')).json.error, /haven't learned that rune/);
  assert.match((await rune(db, 'exhume', 'sword_copper')).json.error, /not a rune/);
  assert.match((await rune(db, 'exhume', null)).json.error, /socket is empty/);
  assert.match((await rune(db, 'wailing_skull', 'rune_volley')).json.error, /not a rite that takes a rune/);
  assert.equal(db.inv.length, 2, 'nothing moved');
});

test('re-socketing the rune already there is a no-op; GET answers the learned runes', async () => {
  const db = fakeDb({ equipped: [{ slot_index: 130, item_id: 'rune_volley', equipped_slot: 'rune_bone_needle' }], runes: ['rune_volley'] });
  assert.equal((await rune(db, 'bone_needle', 'rune_volley')).json.success, true);
  assert.equal(db.inv.length, 1);
  const g = (await harness(mountRunes, db)('GET /api/runes/:characterId', { params: { characterId: '1' } })).json;
  assert.deepEqual(g, { success: true, data: { learned: ['rune_volley'] } });
});

test('a character that is not yours is refused; a malformed body is a 400', async () => {
  const db = fakeDb({ bag: [{ slot_index: 0, item_id: 'rune_volley', quantity: 1 }] });
  const r = await rune(db, 'bone_needle', 'rune_volley', { owned: false });
  assert.equal((await learn(db, 0, { owned: false })).status, 403);
  assert.equal(r.status, 403);
  const bad = await harness(mountRunes, db)('POST /api/inventory/rune', { body: { characterId: 1, rite: 'bone_needle' } });
  assert.equal(bad.status, 400);
});

test('socket rows are invisible to the bag save, the Vault and the Bone Grinder (they only ever look at the bag slots)', async () => {
  const db = fakeDb({ bag: [{ slot_index: 2, item_id: 'rune_volley', quantity: 2 }], equipped: [{ slot_index: 130, item_id: 'rune_splinter', equipped_slot: 'rune_bone_needle' }, { slot_index: 133, item_id: 'rune_contagion', equipped_slot: 'rune_miasma' }] });
  // Deposit all empties the bag and leaves both sockets
  const vault = harness(mountVault, db);
  const all = (await vault('POST /api/vault/deposit-all', { body: { characterId: 1, kind: 'all', exceptSlots: [] } })).json;
  assert.equal(all.success, true);
  assert.deepEqual(db.inv.map((r) => r.slot_index).sort((a, b) => a - b), [130, 133]);
  assert.deepEqual(db.vault.map((v) => [v.item_id, v.quantity]), [['rune_volley', 2]], 'a rune stack rests in the Vault');
  // withdraw it again
  const back = (await vault('POST /api/vault/withdraw', { body: { characterId: 1, vaultSlot: 0 } })).json;
  assert.equal(back.success, true, back.error);
  assert.equal(qty(db.inv, 'rune_volley'), 2);
  // a bag save never touches the sockets (and a save that echoes them is the route's job to filter; replaceBag only writes 0..bagSize-1)
  const conn = db.conn;
  await conn.beginTransaction();
  await replaceBag(conn, 1, [{ slot_index: 0, item_id: 'ore_copper', quantity: 1 }], BAG_SLOTS, 7);
  await conn.commit();
  assert.equal(at(db, 130).item_id, 'rune_splinter');
  assert.equal(at(db, 133).item_id, 'rune_contagion');
  // the Grinder refuses a slot it cannot see
  const prof = fakeDb({ equipped: [{ slot_index: 130, item_id: 'rune_splinter', equipped_slot: 'rune_bone_needle' }] });
  const grind = (await harness(mountSalvage, prof)('POST /api/salvage', { body: { characterId: 1, slots: [130] } })).json;
  assert.equal(grind.success, false);
  assert.equal(at(prof, 130).item_id, 'rune_splinter');
});

test('salvage grinds ONE rune of a stack into reagents only and leaves the rest', async () => {
  const db = fakeDb({ bag: [{ slot_index: 3, item_id: 'rune_volley', quantity: 3 }] });
  const r = (await harness(mountSalvage, db, { random: () => 0.5 })('POST /api/salvage', { body: { characterId: 1, slots: [3] } })).json;
  assert.equal(r.success, true, r.error);
  assert.equal(r.data.salvaged.length, 1);
  assert.equal(at(db, 3).quantity, 2);
  assert.ok(r.data.gained.length > 0);
  for (const g of r.data.gained) assert.match(g.item_id, /^(reagent_|bone_meal)/, `${g.item_id} is a reagent`);
  const dust = salvageRules.salvagePreview({ id: 'rune_volley', item_type: 'rune', rarity: 'rare' }).reagents.find((x) => x.id === 'reagent_grave_dust');
  assert.ok(r.data.gained.some((g) => g.item_id === 'reagent_grave_dust' && g.quantity >= dust.qty[0]), 'at least the least dust a rune gives');
  assert.ok(r.data.xp > 0);
  // the last rune empties the slot
  const one = fakeDb({ bag: [{ slot_index: 3, item_id: 'rune_requiem', quantity: 1 }] });
  assert.equal((await harness(mountSalvage, one, { random: () => 0.1 })('POST /api/salvage', { body: { characterId: 1, slots: [3] } })).json.success, true);
  assert.equal(qty(one.inv, 'rune_requiem'), 0, 'the last rune is gone');
});

test('salvage rules: runes are salvageable, gear still is, materials still are not', () => {
  assert.equal(salvageRules.isSalvageable('rune'), true);
  assert.equal(salvageRules.isSalvageable('weapon'), true);
  assert.equal(salvageRules.isSalvageable('material'), false);
  assert.equal(salvageRules.isSalvageGear('rune'), false);
});

test('the authority guard knows runes are ground drops (a client save may add a few)', () => {
  for (const id of ['rune_splinter', 'rune_bone_colossus', 'rune_requiem']) assert.ok(authority.itemCap(id) >= authority.AUTHORITY.ITEM_MIN_BURST, id);
  assert.equal(authority.itemCap('rune_nope'), 0);
});

test('offline sync accepts the five sockets with their own rune, and rejects a wrong rite, a stack and slot 135', () => {
  const save = (slots) => ({
    username: 't', character: { id: 7, class_index: 2, class_name: 'Gravecaller', level: 4, experience: 120, gold: 50, stat_str: 5, stat_agi: 5, stat_int: 8, stat_vit: 10, pos_x: 0, pos_y: 0, pos_z: 0, pos_map: 'HUB', orientation: 0 },
    slots, professions: [], necro: { ascension: 0, legionTier: 0 }, garden: {}, labor: {}, cosmetics: { cape: null, pet: null, pets: [] },
  });
  const ok = [{ slot_index: 130, item_id: 'rune_volley', quantity: 1, equipped: 1 }, { slot_index: 134, item_id: 'rune_requiem', quantity: 1, equipped: 1 }, { slot_index: 2, item_id: 'rune_impale', quantity: 40 }];
  assert.doesNotThrow(() => sync.validate(save(ok), 2));
  assert.throws(() => sync.validate(save([{ slot_index: 135, item_id: 'rune_volley', quantity: 1 }]), 2), RangeError);
  assert.doesNotThrow(() => sync.validate({ ...save(ok), runes: ['rune_volley'] }, 2));
  assert.throws(() => sync.validate({ ...save(ok), runes: ['sword_copper'] }, 2), RangeError);
});

test('offline sync apply files socket rows as rune_<rite> and refuses a rune in the wrong rite or an item that is not a rune', async () => {
  const inserts = [];
  const learnedIns = [];
  const conn = {
    execute: async (sql, p) => {
      if (sql.startsWith('INSERT INTO inventory')) inserts.push(p);
      if (sql.startsWith('INSERT IGNORE INTO character_runes')) learnedIns.push(p[1]);
      if (sql.startsWith('DELETE FROM character_runes')) throw new Error('learned runes are never deleted');
      if (sql.startsWith('SELECT account_id')) return [[{ account_id: 7 }]];
      if (sql.startsWith('SELECT instance_id')) return [[]];
      if (sql.startsWith('SELECT')) return [[]];
      return [{ insertId: 1 }];
    },
    query: async (sql) => {
      if (sql.startsWith('SELECT id, stackable')) return [[
        { id: 'rune_volley', stackable: 1, max_stack_size: 99, equipment_slot: null, item_type: 'rune' },
        { id: 'rune_requiem', stackable: 1, max_stack_size: 99, equipment_slot: null, item_type: 'rune' },
        { id: 'sword_copper', stackable: 0, max_stack_size: 1, equipment_slot: 'main_hand', item_type: 'weapon' },
      ]];
      return [[]];
    },
  };
  const account = (slots) => ({
    username: 't', character: { id: 7, class_index: 2, class_name: 'Gravecaller', level: 4, experience: 120, gold: 50, stat_str: 5, stat_agi: 5, stat_int: 8, stat_vit: 10, pos_x: 0, pos_y: 0, pos_z: 0, pos_map: 'HUB', orientation: 0 },
    slots, professions: [], necro: { ascension: 0, legionTier: 0 }, garden: {}, labor: {}, cosmetics: { cape: null, pet: null, pets: [] },
  });
  await sync.apply(conn, 7, { ...account([{ slot_index: 130, item_id: 'rune_volley', quantity: 1, equipped: 1 }, { slot_index: 134, item_id: 'rune_requiem', quantity: 1, equipped: 1 }]), runes: ['rune_impale', 'rune_volley'] });
  assert.deepEqual(learnedIns.sort(), ['rune_impale', 'rune_requiem', 'rune_volley'], 'the save\'s learned runes and its socketed ones are learned');
  const inv = inserts.filter((p) => typeof p[1] === 'number' && p[1] >= 130);
  assert.deepEqual(inv.map((p) => [p[1], p[2], p[4], p[5]]), [[130, 'rune_volley', 1, 'rune_bone_needle'], [134, 'rune_requiem', 1, 'rune_black_litany']]);
  await assert.rejects(sync.apply(conn, 7, account([{ slot_index: 133, item_id: 'rune_volley', quantity: 1, equipped: 1 }])), RangeError);
  await assert.rejects(sync.apply(conn, 7, account([{ slot_index: 130, item_id: 'sword_copper', quantity: 1, equipped: 1 }])), RangeError);
});

test('the save route drops echoed rune sockets rather than failing (server.js filter range)', () => {
  const src = require('node:fs').readFileSync(require('node:path').join(__dirname, 'server.js'), 'utf8');
  assert.match(src, /runeRules\.RUNE_BASE \+ runeRules\.RUNE_SLOT_COUNT - 1/);
  assert.match(src, /require\('\.\/runes\.cjs'\)/);
});
