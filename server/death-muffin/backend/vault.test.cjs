// Run: node --test server/death-muffin/backend/vault.test.cjs
const test = require('node:test');
const assert = require('node:assert');
const mountVault = require('./vault.cjs');
const { fakeDb, harness, qty } = require('./bag-fake-db.cjs');

const call = (db, opts) => harness(mountVault, db, opts);
const dep = (c, body) => c('POST /api/vault/deposit', { body: { characterId: 1, ...body } });

test('GET returns the bag and the vault', async () => {
  const db = fakeDb({ bag: [{ slot_index: 0, item_id: 'ore_copper', quantity: 5 }], vault: [{ slot_index: 3, item_id: 'log_oak', quantity: 9 }] });
  const r = (await call(db)('GET /api/vault/:characterId', { params: { characterId: '1' } })).json;
  assert.equal(r.success, true);
  assert.equal(r.data.bag.length, 1);
  assert.deepEqual(r.data.vault.map((v) => [v.slot_index, v.item_id, v.quantity]), [[3, 'log_oak', 9]]);
});

test('depositing a stack tops up the vault stack first, then takes a free slot', async () => {
  const db = fakeDb({ bag: [{ slot_index: 4, item_id: 'ore_copper', quantity: 100 }], vault: [{ slot_index: 0, item_id: 'ore_copper', quantity: 200 }] });
  const r = (await dep(call(db), { bagSlot: 4 })).json;
  assert.equal(r.success, true);
  assert.deepEqual(db.vault.map((v) => [v.slot_index, v.quantity]), [[0, 250], [1, 50]]);
  assert.equal(db.inv.length, 0, 'the bag stack is gone');
  assert.equal(r.data.vault.length, 2);
});

test('partial deposit and withdraw by quantity', async () => {
  const db = fakeDb({ bag: [{ slot_index: 0, item_id: 'ore_copper', quantity: 10 }] });
  const c = call(db);
  await dep(c, { bagSlot: 0, quantity: 4 });
  assert.equal(qty(db.inv, 'ore_copper'), 6);
  assert.equal(qty(db.vault, 'ore_copper'), 4);
  const w = (await c('POST /api/vault/withdraw', { body: { characterId: 1, vaultSlot: 0, quantity: 3 } })).json;
  assert.equal(w.success, true);
  assert.equal(qty(db.inv, 'ore_copper'), 9);
  assert.equal(qty(db.vault, 'ore_copper'), 1);
});

test('gear does not stack: each piece takes its own slot, and equipped gear is never stored', async () => {
  const db = fakeDb({ bag: [{ slot_index: 0, item_id: 'staff_oak', quantity: 1 }, { slot_index: 1, item_id: 'staff_oak', quantity: 1 }], equipped: [{ slot_index: 105, item_id: 'staff_moon' }] });
  const c = call(db);
  await dep(c, { bagSlot: 0 });
  await dep(c, { bagSlot: 1 });
  assert.equal(db.vault.length, 2);
  const bad = (await dep(c, { bagSlot: 30 })).json;
  assert.match(bad.error, /nothing in that slot/);
  assert.equal(db.inv.filter((r) => r.slot_index === 105).length, 1, 'equipped slot 105 untouched');
  const all = (await c('POST /api/vault/deposit-all', { body: { characterId: 1, kind: 'all', exceptSlots: [] } })).json;
  assert.equal(all.success, false, 'nothing left to deposit');
  assert.equal(db.inv.filter((r) => r.slot_index === 105).length, 1, 'bulk deposit never touches slots 100-108');
});

test('a withdraw that will not fit is refused and changes nothing', async () => {
  const bag = Array.from({ length: 48 }, (_, i) => ({ slot_index: i, item_id: 'staff_oak', quantity: 1 }));
  const db = fakeDb({ bag, vault: [{ slot_index: 0, item_id: 'ore_copper', quantity: 5 }] });
  const r = (await call(db)('POST /api/vault/withdraw', { body: { characterId: 1, vaultSlot: 0 } })).json;
  assert.equal(r.success, false);
  assert.match(r.error, /no room/);
  assert.equal(db.vault.length, 1);
  assert.equal(db.inv.length, 48);
});

test('a deposit into a full vault is refused', async () => {
  const vault = Array.from({ length: 120 }, (_, i) => ({ slot_index: i, item_id: 'staff_oak', quantity: 1 }));
  const db = fakeDb({ bag: [{ slot_index: 0, item_id: 'ore_copper', quantity: 5 }], vault });
  const r = (await dep(call(db), { bagSlot: 0 })).json;
  assert.equal(r.success, false);
  assert.match(r.error, /Vault has no room/);
  assert.equal(qty(db.inv, 'ore_copper'), 5);
});

test('deposit-all materials takes materials and consumables, skips gear and the excepted slots', async () => {
  const db = fakeDb({ bag: [
    { slot_index: 0, item_id: 'staff_oak', quantity: 1 },
    { slot_index: 1, item_id: 'ore_copper', quantity: 30 },
    { slot_index: 2, item_id: 'flask_hp_minor', quantity: 3 },
    { slot_index: 40, item_id: 'log_oak', quantity: 7 },
    { slot_index: 41, item_id: 'log_oak', quantity: 7 },
  ] });
  const r = (await call(db)('POST /api/vault/deposit-all', { body: { characterId: 1, kind: 'materials', exceptSlots: [41] } })).json;
  assert.equal(r.success, true);
  assert.deepEqual(db.inv.map((x) => x.slot_index).sort((a, b) => a - b), [0, 41]);
  assert.equal(qty(db.vault, 'ore_copper'), 30);
  assert.equal(qty(db.vault, 'flask_hp_minor'), 3);
  assert.equal(qty(db.vault, 'log_oak'), 7, 'the locked log stack stayed');
});

test('deposit-all everything moves gear too, but all or nothing when it will not fit', async () => {
  const bag = [{ slot_index: 0, item_id: 'staff_oak', quantity: 1 }, { slot_index: 1, item_id: 'helm_copper', quantity: 1 }];
  const full = Array.from({ length: 119 }, (_, i) => ({ slot_index: i, item_id: 'staff_moon', quantity: 1 }));
  const db = fakeDb({ bag, vault: full });
  const r = (await call(db)('POST /api/vault/deposit-all', { body: { characterId: 1, kind: 'all', exceptSlots: [] } })).json;
  assert.equal(r.success, false);
  assert.match(r.error, /Nothing was moved/);
  assert.equal(db.inv.length, 2);
  assert.equal(db.vault.length, 119);
  const ok = fakeDb({ bag, vault: [] });
  assert.equal((await call(ok)('POST /api/vault/deposit-all', { body: { characterId: 1, kind: 'all', exceptSlots: [] } })).json.success, true);
  assert.equal(ok.inv.length, 0);
  assert.equal(ok.vault.length, 2);
  assert.equal((await call(ok)('POST /api/vault/deposit-all', { body: { characterId: 1, kind: 'bogus' } })).json.success, false);
});

test('sort merges stacks and orders by type, rarity (best first) and id', async () => {
  const db = fakeDb({ vault: [
    { slot_index: 5, item_id: 'ore_copper', quantity: 200 },
    { slot_index: 9, item_id: 'staff_oak', quantity: 1 },
    { slot_index: 20, item_id: 'ore_copper', quantity: 100 },
    { slot_index: 30, item_id: 'staff_moon', quantity: 1 },
    { slot_index: 31, item_id: 'flask_hp_minor', quantity: 2 },
    { slot_index: 32, item_id: 'ingot_gold', quantity: 4 },
  ] });
  const r = (await call(db)('POST /api/vault/sort', { body: { characterId: 1 } })).json;
  assert.equal(r.success, true);
  assert.deepEqual(db.vault.sort((a, b) => a.slot_index - b.slot_index).map((v) => [v.slot_index, v.item_id, v.quantity]), [
    [0, 'staff_moon', 1], [1, 'staff_oak', 1], [2, 'flask_hp_minor', 2], [3, 'ingot_gold', 4], [4, 'ore_copper', 250], [5, 'ore_copper', 50],
  ]);
});

test('a failing move rolls everything back, and someone else\'s character is refused', async () => {
  const db = fakeDb({ bag: [{ slot_index: 0, item_id: 'ore_copper', quantity: 5 }] });
  const real = db.conn.execute;
  db.conn.execute = async (sql, p) => { if (sql.startsWith('INSERT INTO account_vault')) throw new Error('boom'); return real(sql, p); };
  const orig = console.error; console.error = () => {};
  const r = await dep(call(db), { bagSlot: 0 });
  console.error = orig;
  assert.equal(r.status, 500);
  assert.equal(qty(db.inv, 'ore_copper'), 5, 'the bag was rolled back');
  assert.equal((await dep(call(fakeDb(), { owned: false }), { bagSlot: 0 })).status, 403);
});

test('bad slots are refused with readable errors', async () => {
  const c = call(fakeDb({ bag: [{ slot_index: 0, item_id: 'ore_copper', quantity: 5 }] }));
  assert.match((await dep(c, { bagSlot: 48 })).json.error, /between 0 and 47/);
  assert.match((await c('POST /api/vault/withdraw', { body: { characterId: 1, vaultSlot: 120 } })).json.error, /between 0 and 119/);
  assert.match((await dep(c, { bagSlot: 0, quantity: 0 })).json.error, /how many/);
});

test('belt tools (slots 110-113) are never deposited, listed in the bag or counted by deposit-all', async () => {
  const db = fakeDb({ bag: [{ slot_index: 0, item_id: 'ore_copper', quantity: 5 }], equipped: [{ slot_index: 110, item_id: 'tool_hatchet_copper', equipped_slot: 'belt_hatchet' }] });
  const c = call(db);
  const r = (await c('POST /api/vault/deposit-all', { body: { characterId: 1, kind: 'all', exceptSlots: [] } })).json;
  assert.equal(r.success, true);
  assert.equal(db.vault.some((v) => v.item_id === 'tool_hatchet_copper'), false);
  assert.equal(db.inv.filter((x) => x.slot_index === 110).length, 1);
  assert.equal(db.inv.length, 1, 'only the belt row is left in the inventory table');
  assert.equal((await dep(c, { bagSlot: 110 })).json.success, false, 'a belt slot is not a bag slot');
});

test('move: a stack to an exact slot, rearranging inside the bag and the vault, swapping across, merging, and bad input', async () => {
  const db = fakeDb({ bag: [{ slot_index: 0, item_id: 'ore_copper', quantity: 10 }, { slot_index: 1, item_id: 'staff_oak', quantity: 1 }], vault: [{ slot_index: 5, item_id: 'log_oak', quantity: 9 }] });
  const c = call(db);
  const mv = (body) => c('POST /api/vault/move', { body: { characterId: 1, ...body } });
  assert.equal((await mv({ from: 'bag', fromSlot: 1, to: 'bag', toSlot: 20 })).json.success, true);
  assert.deepEqual(db.inv.map((r) => [r.slot_index, r.item_id]).sort((a, b) => a[0] - b[0]), [[0, 'ore_copper'], [20, 'staff_oak']], 'rearranged in the bag');
  assert.equal((await mv({ from: 'vault', fromSlot: 5, to: 'vault', toSlot: 40 })).json.success, true);
  assert.deepEqual(db.vault.map((r) => [r.slot_index, r.item_id]), [[40, 'log_oak']], 'rearranged in the vault (another tab)');
  assert.equal((await mv({ from: 'bag', fromSlot: 0, to: 'vault', toSlot: 7, quantity: 4 })).json.success, true);
  assert.equal(db.vault.find((r) => r.slot_index === 7).quantity, 4, 'part of a stack to a chosen vault slot');
  assert.equal((await mv({ from: 'bag', fromSlot: 20, to: 'vault', toSlot: 40 })).json.success, true);
  assert.equal(db.vault.find((r) => r.slot_index === 40).item_id, 'staff_oak', 'swapped across');
  assert.equal(db.inv.find((r) => r.slot_index === 20).item_id, 'log_oak');
  assert.match((await mv({ from: 'bag', fromSlot: 0, to: 'sky', toSlot: 1 })).json.error, /bag or vault/);
  assert.match((await mv({ from: 'bag', fromSlot: 0, to: 'bag', toSlot: 48 })).json.error, /does not exist/);
});

