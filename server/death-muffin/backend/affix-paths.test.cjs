// Run: node --test server/death-muffin/backend/affix-paths.test.cjs
// Every path that moves or consumes gear carries rolled instances, and none of them can mint or change a roll.
const test = require('node:test');
const assert = require('node:assert');
const mountVault = require('./vault.cjs');
const mountSalvage = require('./salvage.cjs');
const mountToolBelt = require('./tool-belt.cjs');
const sync = require('./offline-full-sync.cjs');
const { replaceBag, resolveInstances, CANT_VERIFY } = require('./inventory-save.cjs');
const affix = require('./gathering/affix-rules.cjs');
const { fakeDb, harness } = require('./bag-fake-db.cjs');

const A = [{ id: 'p_thrall_dmg', v: 90 }, { id: 's_thrall_hp', v: 160 }];
const gear = (slot_index, id, item_id = 'helm_iron', extra = {}) => ({ slot_index, item_id, quantity: 1, instance_id: id, ...extra });
const loot = (id, item_id = 'helm_iron', extra = {}) => ({ id, item_id, ilvl: 12, affixes: A, ...extra });
const save = (db, slots, bagSize = 48, accountId = 7) => replaceBag(db.conn, 1, slots, bagSize, accountId);
const refused = (p) => assert.rejects(p, (e) => e.refusal === true && e.message === CANT_VERIFY);

// --- bag save -------------------------------------------------------------------------------------------------------------------

test('a save may attach an instance the server rolled for this account, and GET returns its ilvl and affixes', async () => {
  const db = fakeDb({ loot: [loot(1)] });
  await save(db, [gear(3, 1)]);
  assert.equal(db.inv.find((r) => r.slot_index === 3).instance_id, 1);
  const [rows] = await db.conn.execute('SELECT inv.id FROM inventory inv WHERE inv.character_id = ?', [1]);
  assert.equal(rows[0].instance_id, 1);
  assert.equal(rows[0].ilvl, 12);
  assert.deepEqual(rows[0].affixes, A);
});

test('a save cannot mint or alter a roll: affixes/ilvl in the payload are ignored, unknown ids are refused', async () => {
  const db = fakeDb({ loot: [loot(1)] });
  const forged = { ...gear(0, 1), ilvl: 99, affixes: [{ id: 'p_thrall_dmg', v: 150 }, { id: 's_thrall_hp', v: 200 }] };
  await save(db, [forged]);
  assert.equal(db.loot.length, 1);
  assert.equal(db.loot[0].ilvl, 12, 'the stored roll is untouched');
  assert.deepEqual(db.loot[0].affixes, A);
  const before = JSON.stringify(db.inv);
  await refused(save(db, [gear(0, 55)]));
  await refused(save(db, [gear(0, -1)]));
  await refused(save(db, [gear(0, 'abc')]));
  await refused(save(db, [gear(0, 1.5)]));
  assert.equal(JSON.stringify(db.inv), before, 'a refused save writes nothing');
});

test('an instance of another account, of a different item, or held elsewhere is refused', async () => {
  const db = fakeDb({
    loot: [loot(1), loot(2, 'helm_iron', { account_id: 99 }), loot(3, 'staff_oak'), loot(4), loot(5), loot(6)],
    bag: [],
    equipped: [{ slot_index: 100, item_id: 'helm_iron', equipped_slot: 'head', instance_id: 4 }],
    vault: [{ slot_index: 0, item_id: 'helm_iron', quantity: 1, instance_id: 5 }],
  });
  await refused(save(db, [gear(0, 2)])); // another account's
  await refused(save(db, [gear(0, 3)])); // it is a staff
  await refused(save(db, [gear(0, 4)])); // worn (equipped slots are not the bag's to name)
  await refused(save(db, [gear(0, 5)])); // in the Vault
  await refused(save(db, [gear(0, 1), gear(1, 1)])); // twice in one payload
  await refused(save(db, [{ ...gear(0, 1), quantity: 2 }])); // a stack of rolled gear
  // a clone on another character's bag
  db.inv.push({ id: 900, character_id: 2, slot_index: 0, item_id: 'helm_iron', quantity: 1, instance_id: 6, equipped: 0, equipped_slot: null });
  await refused(save(db, [gear(0, 6)]));
  assert.equal(db.inv.filter((r) => r.character_id === 1 && r.slot_index === 0).length, 0);
});

test('two rolled pieces can swap slots in one save (the unique link is freed first)', async () => {
  const db = fakeDb({ loot: [loot(1), loot(2, 'helm_iron', { ilvl: 30 })], bag: [gear(0, 1), gear(1, 2)] });
  await save(db, [gear(0, 2), gear(1, 1)]);
  assert.deepEqual(db.inv.map((r) => [r.slot_index, r.instance_id]).sort(), [[0, 2], [1, 1]]);
  assert.equal(db.loot.length, 2);
});

test('a relic the save no longer names is deleted (sold or thrown away), so it cannot be brought back', async () => {
  const db = fakeDb({ loot: [loot(1), loot(2)], bag: [gear(0, 1), gear(1, 2)] });
  await save(db, [gear(1, 2)]); // sold slot 0
  assert.deepEqual(db.loot.map((l) => l.id), [2]);
  await refused(save(db, [gear(1, 2), gear(0, 1)]));
  assert.deepEqual(db.inv.map((r) => r.slot_index), [1]);
});

test('an explicit instance_id: null detaches (and deletes) the roll; an omitted one keeps it (a stale tab from before affixes)', async () => {
  const db = fakeDb({ loot: [loot(1)], bag: [gear(0, 1)] });
  await save(db, [{ slot_index: 0, item_id: 'helm_iron', quantity: 1 }]); // no instance_id key at all
  assert.equal(db.inv[0].instance_id, 1);
  assert.equal(db.loot.length, 1);
  await save(db, [{ slot_index: 0, item_id: 'helm_iron', quantity: 1, instance_id: null }]);
  assert.equal(db.inv[0].instance_id, null);
  assert.equal(db.loot.length, 0);
});

test('a stale tab that changed the item in a slot does not inherit the old slot\'s roll', async () => {
  const db = fakeDb({ loot: [loot(1)], bag: [gear(0, 1)] });
  await save(db, [{ slot_index: 0, item_id: 'staff_oak', quantity: 1 }]);
  assert.equal(db.inv[0].item_id, 'staff_oak');
  assert.equal(db.inv[0].instance_id, null);
});

test('a stale 24-slot save cannot detach or delete rolls in slots 24-47', async () => {
  const db = fakeDb({ loot: [loot(1), loot(2)], bag: [gear(2, 1), gear(30, 2)] });
  await save(db, [{ slot_index: 2, item_id: 'helm_iron', quantity: 1 }], 24);
  assert.equal(db.inv.find((r) => r.slot_index === 30).instance_id, 2);
  assert.deepEqual(db.loot.map((l) => l.id).sort(), [1, 2]);
});

// --- equip / belt ---------------------------------------------------------------------------------------------------------------

test('resolveInstances treats worn rows as outside the bag range, and the tool belt never carries a roll', async () => {
  const db = fakeDb({ loot: [loot(1)], equipped: [{ slot_index: 100, item_id: 'helm_iron', equipped_slot: 'head', instance_id: 1 }] });
  const bySlot = new Map();
  await assert.rejects(resolveInstances(db.conn, 7, 1, [gear(0, 1)], bySlot, 48), (e) => e.refusal);
  // The belt moves tools by row id and only reads item ids: a rolled piece is not a tool and is refused.
  const bag = fakeDb({ loot: [loot(1)], bag: [gear(0, 1)] });
  const r = (await harness(mountToolBelt, bag)('POST /api/inventory/belt', { body: { characterId: 1, slot_index: 0, equipped: 1 } })).json;
  assert.equal(r.success, false);
  assert.match(r.error, /Only gathering tools/);
  assert.equal(bag.inv[0].instance_id, 1);
});

// --- Vault ------------------------------------------------------------------------------------------------------------------------

const v = (db) => harness(mountVault, db);

test('depositing and withdrawing rolled gear moves the instance with the row; it never stacks', async () => {
  const db = fakeDb({ loot: [loot(1), loot(2)], bag: [gear(0, 1), gear(1, 2)] });
  const c = v(db);
  await c('POST /api/vault/deposit', { body: { characterId: 1, bagSlot: 0 } });
  await c('POST /api/vault/deposit', { body: { characterId: 1, bagSlot: 1 } });
  assert.deepEqual(db.vault.map((r) => [r.slot_index, r.item_id, r.quantity, r.instance_id]), [[0, 'helm_iron', 1, 1], [1, 'helm_iron', 1, 2]]);
  assert.equal(db.inv.length, 0);
  const w = (await c('POST /api/vault/withdraw', { body: { characterId: 1, vaultSlot: 1 } })).json;
  assert.equal(w.success, true, w.error);
  assert.deepEqual(db.inv.map((r) => [r.item_id, r.instance_id]), [['helm_iron', 2]]);
  assert.deepEqual(db.vault.map((r) => r.instance_id), [1]);
  assert.deepEqual(w.data.bag.map((r) => [r.instance_id, r.ilvl]), [[2, 12]]);
  assert.deepEqual(w.data.vault.map((r) => r.affixes), [A]);
  assert.equal(db.loot.length, 2, 'moving never creates or deletes a roll');
});

test('deposit-all moves every rolled piece with its roll, and a plain duplicate does not merge into a rolled one', async () => {
  const db = fakeDb({ loot: [loot(1)], bag: [gear(0, 1), { slot_index: 1, item_id: 'helm_iron', quantity: 1 }] });
  const r = (await v(db)('POST /api/vault/deposit-all', { body: { characterId: 1, kind: 'all', exceptSlots: [] } })).json;
  assert.equal(r.success, true);
  assert.deepEqual(db.vault.map((x) => x.instance_id).sort(), [1, null].sort());
  assert.equal(db.vault.length, 2);
});

test('sorting the Vault keeps every roll attached, best first', async () => {
  const db = fakeDb({
    loot: [loot(1, 'helm_iron', { affixes: [A[0]] }), loot(2, 'helm_iron', { affixes: A, ilvl: 20 }), loot(3, 'helm_iron', { affixes: [A[0], A[1], { id: 'p_withered', v: 1 }] })],
    vault: [{ slot_index: 5, item_id: 'helm_iron', quantity: 1, instance_id: 1 }, { slot_index: 9, item_id: 'helm_iron', quantity: 1, instance_id: 2 }, { slot_index: 11, item_id: 'helm_iron', quantity: 1, instance_id: 3 }, { slot_index: 20, item_id: 'ore_copper', quantity: 4 }],
  });
  const r = (await v(db)('POST /api/vault/sort', { body: { characterId: 1 } })).json;
  assert.equal(r.success, true);
  const gearRows = db.vault.filter((x) => x.item_id === 'helm_iron').sort((a, b) => a.slot_index - b.slot_index);
  assert.deepEqual(gearRows.map((x) => x.instance_id), [3, 2, 1], 'three affixes, then two, then one');
  assert.equal(db.loot.length, 3);
});

test('a withdraw that will not fit leaves the instance in the Vault', async () => {
  const bag = Array.from({ length: 48 }, (_, i) => ({ slot_index: i, item_id: 'staff_oak', quantity: 1 }));
  const db = fakeDb({ loot: [loot(1)], bag, vault: [{ slot_index: 0, item_id: 'helm_iron', quantity: 1, instance_id: 1 }] });
  const r = (await v(db)('POST /api/vault/withdraw', { body: { characterId: 1, vaultSlot: 0 } })).json;
  assert.equal(r.success, false);
  assert.equal(db.vault[0].instance_id, 1);
});

// --- Salvage ------------------------------------------------------------------------------------------------------------------

const salvage = (db, rand) => harness(mountSalvage, db, { random: rand });

test('salvaging a rolled piece deletes its instance and pays a little more than plain gear of the same base', async () => {
  const seq = () => { let i = 0; const s = [0.5, 0.99, 0.5, 0.99, 0.99, 0.99, 0.99, 0.99]; return () => s[i++ % s.length]; };
  const plain = fakeDb({ bag: [{ slot_index: 0, item_id: 'helm_iron', quantity: 1 }] });
  const p = (await salvage(plain, seq())('POST /api/salvage', { body: { characterId: 1, slots: [0] } })).json;
  const rolled = fakeDb({ loot: [loot(1, 'helm_iron', { ilvl: 30, affixes: [...A, { id: 'p_withered', v: 2 }] })], bag: [gear(0, 1)] });
  // rand() low on the extra-material roll: the third affix piece always gets the extra material.
  const lowAtEnd = (() => { const base = seq(); let n = 0; return () => (++n > 8 ? 0 : base()); })();
  const r = (await salvage(rolled, lowAtEnd)('POST /api/salvage', { body: { characterId: 1, slots: [0] } })).json;
  assert.equal(p.success, true);
  assert.equal(r.success, true);
  assert.equal(rolled.loot.length, 0, 'the instance is gone with the item');
  assert.equal(rolled.inv.some((x) => x.instance_id), false);
  assert.ok(r.data.xp > p.data.xp, `xp ${r.data.xp} vs ${p.data.xp}`);
});

test('salvage that will not fit keeps the item AND its roll', async () => {
  const bag = [gear(0, 1), ...Array.from({ length: 47 }, (_, i) => ({ slot_index: i + 1, item_id: 'staff_oak', quantity: 1 }))];
  const db = fakeDb({ loot: [loot(1)], bag });
  const r = (await salvage(db, () => 0.5)('POST /api/salvage', { body: { characterId: 1, slots: [0] } })).json;
  assert.equal(r.success, false);
  assert.equal(db.loot.length, 1);
  assert.equal(db.inv.find((x) => x.slot_index === 0).instance_id, 1);
});

test('equipped rolled gear cannot be salvaged', async () => {
  const db = fakeDb({ loot: [loot(1)], equipped: [{ slot_index: 100, item_id: 'helm_iron', equipped_slot: 'head', instance_id: 1 }] });
  const r = (await salvage(db, () => 0.5)('POST /api/salvage', { body: { characterId: 1, slots: [100] } })).json;
  assert.equal(r.success, false);
  assert.equal(db.loot.length, 1);
});

// --- Offline full sync -------------------------------------------------------------------------------------------------------

test('rolls from the previous (2 Oct) affix ranges stay valid after the 3 Oct tuning, and nothing re-checks a stored roll on a bag save', async () => {
  // Top-of-range rolls at ilvl 47 under the old ranges: above the NEW ranges, so only the legacy envelope keeps them legal.
  const old = [{ id: 'p_thrall_dmg', v: 194 }, { id: 's_thrall_hp', v: 370 }, { id: 'p_essence_regen', v: 387 }];
  assert.ok(old[0].v > affix.affixRange('p_thrall_dmg', 47)[1], 'the fixture is above the new range');
  assert.equal(affix.instanceProblem({ ilvl: 47, affixes: old }, 'armor_chest'), null);
  assert.notEqual(affix.instanceProblem({ ilvl: 47, affixes: [{ id: 'p_thrall_dmg', v: 9999 }] }, 'armor_chest'), null, 'a forged value is still refused');
  const db = fakeDb({ loot: [{ id: 1, item_id: 'helm_iron', ilvl: 47, affixes: old }] });
  await save(db, [gear(3, 1)]);
  const [rows] = await db.conn.execute('SELECT inv.id FROM inventory inv WHERE inv.character_id = ?', [1]);
  assert.deepEqual(rows[0].affixes, old, 'the stored roll comes back untouched');
});

const save1 = (slots) => ({
  username: 't',
  character: { id: 7, class_index: 2, class_name: 'Ossuary', level: 4, experience: 120, gold: 50, stat_str: 5, stat_agi: 5, stat_int: 8, stat_vit: 10, pos_x: 0, pos_y: 0, pos_z: 0, pos_map: 'HUB', orientation: 0 },
  slots, professions: [], necro: {}, garden: {}, labor: {}, cosmetics: { cape: null, pet: null, pets: [] },
});

test('a save import validates imported rolls: unknown affixes, out-of-range values and too many are refused', () => {
  const ok = { slot_index: 0, item_id: 'helm_iron', quantity: 1, inst: { ilvl: 12, affixes: A } };
  assert.doesNotThrow(() => sync.validate(save1([ok]), 2));
  for (const inst of [
    { ilvl: 12, affixes: [{ id: 'p_fake', v: 3 }] },
    { ilvl: 12, affixes: [{ id: 'p_thrall_dmg', v: 5000 }] },
    { ilvl: 12, affixes: [{ id: 'p_thrall_dmg', v: 0 }] },
    { ilvl: 12, affixes: [A[0], A[0]] },
    { ilvl: 12, affixes: [A[0], A[1], { id: 'p_withered', v: 1 }, { id: 'p_str', v: 1 }] },
    { ilvl: 0, affixes: [] },
    { ilvl: 100, affixes: [] },
    { ilvl: 12.5, affixes: [] },
    { ilvl: 12, affixes: 'x' },
  ]) assert.throws(() => sync.validate(save1([{ ...ok, inst }]), 2), RangeError, JSON.stringify(inst));
  assert.throws(() => sync.validate(save1([{ ...ok, quantity: 2 }]), 2), RangeError);
});

test('applying a save creates FRESH instances for the imported rolls and deletes the replaced inventory\'s', async () => {
  const db = fakeDb({ loot: [loot(1)], bag: [gear(0, 1)] });
  // apply() talks to the connection with query() for items; add that and the account lookup on top of the fake.
  const conn = Object.create(db.conn);
  const fakeQuery = db.conn.query;
  conn.query = async (sql, p) => {
    if (sql.includes('FROM items')) return [[{ id: 'helm_iron', stackable: 0, max_stack_size: 1, equipment_slot: 'head', item_type: 'armor_head' }]];
    if (sql.startsWith('SELECT instance_id FROM inventory WHERE character_id')) return [db.inv.filter((r) => r.instance_id).map((r) => ({ instance_id: r.instance_id }))];
    return fakeQuery(sql, p);
  };
  const realExecute = db.conn.execute;
  conn.execute = async (sql, p) => {
    if (sql.startsWith('DELETE FROM inventory WHERE character_id = ?')) { db.inv.splice(0, db.inv.length); return [{}]; }
    if (sql.startsWith('INSERT INTO inventory (character_id, slot_index, item_id, quantity, equipped, equipped_slot, instance_id)')) {
      db.inv.push({ id: 7000, character_id: p[0], slot_index: p[1], item_id: p[2], quantity: p[3], equipped: p[4], equipped_slot: p[5], instance_id: p[6] });
      return [{}];
    }
    if (sql.startsWith('SELECT account_id FROM characters')) return [[{ account_id: 7 }]];
    try { return await realExecute(sql, p); } catch (e) { if (/unexpected SQL/.test(e.message)) return [{}]; throw e; } // the rest of apply() (chronicle, contracts...) is not under test
  };
  const imported = { slot_index: 3, item_id: 'helm_iron', quantity: 1, inst: { ilvl: 22, affixes: [{ id: 'p_thrall_dmg', v: 100, extra: 'ignored' }] } };
  await sync.apply(conn, 1, save1([imported])).catch((e) => { if (!(e instanceof TypeError)) throw e; });
  assert.equal(db.loot.find((l) => l.id === 1), undefined, 'the replaced inventory\'s roll was deleted');
  const made = db.loot.find((l) => l.ilvl === 22);
  assert.ok(made && made.id >= 1000, 'a fresh instance, not the offline save\'s id');
  assert.deepEqual(made.affixes, [{ id: 'p_thrall_dmg', v: 100 }], 'only id and value are stored');
  assert.equal(db.inv[0].instance_id, made.id);
  const bad = { ...imported, inst: { ilvl: 22, affixes: [{ id: 'p_thrall_dmg', v: 5000 }] } };
  await assert.rejects(() => sync.apply(conn, 1, save1([bad])), /out of range/);
});
