// Run: node --test server/death-muffin/backend/cosmetics.test.cjs
const test = require('node:test');
const assert = require('node:assert');
const mountCosmetics = require('./cosmetics.cjs');

function fakeDb({ levels = {}, bag = [] } = {}) {
  let inv = bag.map((b, i) => ({ id: i + 1, equipped: 0, character_id: 1, ...b }));
  let cos = null;
  let pets = new Set();
  const execute = async (sql, p = []) => {
    if (sql.startsWith('SELECT profession_id, skill_level')) return [Object.entries(levels).map(([profession_id, skill_level]) => ({ profession_id, skill_level }))];
    if (sql.startsWith('SELECT cape, pet FROM character_cosmetics')) return [cos ? [{ ...cos }] : []];
    if (sql.startsWith('SELECT pet_id FROM character_pets WHERE character_id = ? AND pet_id')) return [pets.has(p[1]) ? [{ pet_id: p[1] }] : []];
    if (sql.startsWith('SELECT pet_id FROM character_pets')) return [[...pets].map((pet_id) => ({ pet_id }))];
    if (sql.startsWith('INSERT INTO character_cosmetics')) { cos = { cape: p[1], pet: p[2] }; return [{}]; }
    if (sql.startsWith('INSERT IGNORE INTO character_pets')) { pets.add(p[1]); return [{}]; }
    if (sql.startsWith('SELECT id, quantity FROM inventory')) return [inv.filter((r) => r.item_id === p[1] && !r.equipped && r.slot_index <= p[2]).map((r) => ({ id: r.id, quantity: r.quantity }))];
    if (sql.startsWith('DELETE FROM inventory')) { inv = inv.filter((r) => r.id !== p[0]); return [{}]; }
    if (sql.startsWith('UPDATE inventory SET quantity = quantity - ?')) { inv.find((r) => r.id === p[1]).quantity -= p[0]; return [{}]; }
    throw new Error(`unexpected SQL: ${sql.slice(0, 80)}`);
  };
  let snap = null;
  const conn = {
    execute, release: () => {},
    beginTransaction: async () => { snap = { inv: JSON.parse(JSON.stringify(inv)), cos: cos && { ...cos }, pets: new Set(pets) }; },
    commit: async () => { snap = null; },
    rollback: async () => { if (snap) { inv = snap.inv; cos = snap.cos; pets = snap.pets; snap = null; } },
  };
  return { get inv() { return inv; }, get cos() { return cos; }, get pets() { return pets; }, pool: { getConnection: async () => conn } };
}

function harness(db, { owned = true } = {}) {
  const routes = {};
  const app = { get: (p, _m, h) => (routes[`GET ${p}`] = h), post: (p, _m, h) => (routes[`POST ${p}`] = h) };
  mountCosmetics(app, db.pool, { requireAuth: () => {}, ownsCharacter: async () => owned });
  return async (route, { body, params } = {}) => {
    let status = 200, json;
    await routes[route]({ body, params, method: route.split(' ')[0], path: route, user: { accountId: 1 } }, { status(c) { status = c; return this; }, json(j) { json = j; return this; }, headersSent: false });
    return { status, json };
  };
}

const ALL99 = { woodcutting: 99, mining: 99, fishing: 99, gravedigging: 99, gardening: 99, alchemy: 99, salvaging: 99 };

test('a new character has no capes or pets, and nothing worn', async () => {
  const call = harness(fakeDb());
  const v = (await call('GET /api/cosmetics/:characterId', { params: { characterId: '1' } })).json.data;
  assert.ok(v.capes.length >= 9);
  assert.ok(v.capes.every((c) => !c.unlocked));
  assert.ok(v.pets.every((p) => !p.adopted));
  assert.deepEqual(v.selected, { cape: null, pet: null });
});

test('a cape must be earned before it can be worn, and can be put away', async () => {
  const db = fakeDb({ levels: { woodcutting: 99 } });
  const call = harness(db);
  const sel = async (body) => (await call('POST /api/cosmetics/select', { body: { characterId: 1, ...body } })).json;
  assert.match((await sel({ cape: 'cape_mining' })).error, /not earned/);
  assert.match((await sel({ cape: 'cape_nonsense' })).error, /not earned/);
  const ok = await sel({ cape: 'cape_woodcutting' });
  assert.equal(ok.success, true);
  assert.equal(ok.data.selected.cape, 'cape_woodcutting');
  assert.equal((await sel({ cape: null })).data.selected.cape, null);
});

test('total-level mantles and the Sexton\'s Mantle unlock from combined levels', async () => {
  const call = harness(fakeDb({ levels: ALL99 }));
  const v = (await call('GET /api/cosmetics/:characterId', { params: { characterId: '1' } })).json.data;
  assert.ok(v.capes.every((c) => c.unlocked), 'every cape at all 99');
  assert.equal(v.totalLevel, 693);
});

test('adopting spends exactly one charm, keeps the pet for good, and walks the first one out', async () => {
  const db = fakeDb({ bag: [{ slot_index: 3, item_id: 'charm_grave_rat', quantity: 1 }, { slot_index: 4, item_id: 'charm_grave_rat', quantity: 1 }] });
  const call = harness(db);
  const r = (await call('POST /api/cosmetics/adopt', { body: { characterId: 1, petId: 'pet_grave_rat' } })).json;
  assert.equal(r.success, true);
  assert.equal(r.data.adopted, 'pet_grave_rat');
  assert.equal(r.data.selected.pet, 'pet_grave_rat');
  assert.equal(db.inv.length, 1, 'one charm was spent, the spare stays');
  const again = (await call('POST /api/cosmetics/adopt', { body: { characterId: 1, petId: 'pet_grave_rat' } })).json;
  assert.equal(again.success, false);
  assert.match(again.error, /already yours/);
  assert.equal(db.inv.length, 1, 'a repeat adoption did not eat the spare charm');
});

test('you cannot adopt without the charm, or call a pet you have not adopted', async () => {
  const db = fakeDb();
  const call = harness(db);
  assert.match((await call('POST /api/cosmetics/adopt', { body: { characterId: 1, petId: 'pet_tithe_bat' } })).json.error, /no Tithe Bat Charm/);
  assert.match((await call('POST /api/cosmetics/adopt', { body: { characterId: 1, petId: 'pet_nope' } })).json.error, /no such companion/);
  assert.match((await call('POST /api/cosmetics/select', { body: { characterId: 1, pet: 'pet_tithe_bat' } })).json.error, /not adopted/);
  assert.equal(db.pets.size, 0);
});

test('selecting one slot leaves the other alone', async () => {
  const db = fakeDb({ levels: { woodcutting: 99 }, bag: [{ slot_index: 0, item_id: 'charm_tithe_bat', quantity: 1 }] });
  const call = harness(db);
  await call('POST /api/cosmetics/adopt', { body: { characterId: 1, petId: 'pet_tithe_bat' } });
  await call('POST /api/cosmetics/select', { body: { characterId: 1, cape: 'cape_woodcutting' } });
  const r = (await call('POST /api/cosmetics/select', { body: { characterId: 1, pet: null } })).json;
  assert.deepEqual(r.data.selected, { cape: 'cape_woodcutting', pet: null });
});

test('someone else\'s character is refused', async () => {
  const call = harness(fakeDb(), { owned: false });
  assert.equal((await call('POST /api/cosmetics/select', { body: { characterId: 1, cape: null } })).status, 403);
});
