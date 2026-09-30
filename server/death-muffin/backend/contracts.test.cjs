// Run: node --test server/death-muffin/backend/contracts.test.cjs
const test = require('node:test');
const assert = require('node:assert');
const mountContracts = require('./contracts.cjs');
const { removeFromBag, addToBag } = mountContracts;
const rules = require('./gathering/contract-rules.cjs');

/** In-memory stand-in for the tables contracts.cjs touches, dispatched on the SQL text. */
function fakeDb({ bag = [], levels = { woodcutting: 20, mining: 20, fishing: 20, gravedigging: 20 } } = {}) {
  const inv = bag.map((b, i) => ({ id: i + 1, equipped: 0, ...b }));
  let nextId = 1000;
  const contracts = [];
  const items = { gem_grave_garnet: { stackable: 1, max_stack_size: 99, name: 'Grave Garnet', rarity: 'uncommon' } };
  const stack = (id) => items[id] || { stackable: 1, max_stack_size: 250, name: id, rarity: 'common' };
  const execute = async (sql, p = []) => {
    if (sql.startsWith('SELECT profession_id')) return [Object.entries(levels).map(([profession_id, skill_level]) => ({ profession_id, skill_level }))];
    if (sql.includes('FROM character_contracts WHERE character_id = ? AND day = ? AND slot < ?')) {
      return [contracts.filter((c) => c.day === p[1] && c.slot < p[2]).sort((a, b) => a.slot - b.slot).map((c) => ({ ...c }))];
    }
    if (sql.startsWith('INSERT IGNORE INTO character_contracts')) {
      if (!contracts.some((c) => c.day === p[1] && c.slot === p[2] && c.character_id === p[0])) contracts.push({ character_id: p[0], day: p[1], slot: p[2], contract: p[3], done: 0 });
      return [{}];
    }
    if (sql.startsWith('SELECT done FROM character_contracts')) return [contracts.filter((c) => c.character_id === p[0] && c.day === p[1] && c.slot === p[2]).map((c) => ({ done: c.done }))];
    if (sql.startsWith('UPDATE character_contracts SET done = 1')) {
      contracts.find((c) => c.character_id === p[0] && c.day === p[1] && c.slot === p[2]).done = 1;
      return [{}];
    }
    if (sql.startsWith('INSERT INTO character_contracts')) {
      const [character_id, day, slot, contract] = p;
      const row = contracts.find((c) => c.day === day && c.slot === slot && c.character_id === character_id);
      if (row) row.done = 1;
      else contracts.push({ character_id, day, slot, contract, done: 1 });
      return [{}];
    }
    if (sql.startsWith('SELECT DISTINCT DATE_FORMAT')) return [[...new Set(contracts.filter((c) => c.done && c.slot < 3).map((c) => c.day))].sort().reverse().map((d) => ({ d }))];
    if (sql.startsWith('SELECT id, quantity FROM inventory')) {
      return [inv.filter((r) => r.character_id === p[0] && r.item_id === p[1] && !r.equipped && r.slot_index <= p[2]).sort((a, b) => a.slot_index - b.slot_index).map((r) => ({ id: r.id, quantity: r.quantity }))];
    }
    if (sql.startsWith('DELETE FROM inventory')) { inv.splice(inv.findIndex((r) => r.id === p[0]), 1); return [{}]; }
    if (sql.startsWith('UPDATE inventory SET quantity = quantity - ?')) { inv.find((r) => r.id === p[1]).quantity -= p[0]; return [{}]; }
    if (sql.startsWith('UPDATE inventory SET quantity = quantity + ?')) { inv.find((r) => r.id === p[1]).quantity += p[0]; return [{}]; }
    if (sql.startsWith('SELECT stackable')) return [[stack(p[0])]];
    if (sql.startsWith('SELECT id, slot_index, item_id, quantity FROM inventory')) return [inv.filter((r) => r.character_id === p[0] && r.slot_index <= p[1]).map((r) => ({ ...r }))];
    if (sql.startsWith('INSERT INTO inventory')) { inv.push({ id: nextId++, character_id: p[0], slot_index: p[1], item_id: p[2], quantity: p[3], equipped: 0 }); return [{}]; }
    throw new Error(`unexpected SQL: ${sql.slice(0, 80)}`);
  };
  const query = async (sql, p) => {
    if (sql.startsWith('SELECT id, name, rarity FROM items')) return [p[0].map((id) => ({ id, name: stack(id).name || id, rarity: stack(id).rarity || 'common' }))];
    throw new Error(`unexpected query: ${sql.slice(0, 80)}`);
  };
  // Real transactions: a rollback restores what the transaction saw at the start.
  let snap = null;
  const conn = {
    execute, query, release: () => {},
    beginTransaction: async () => { snap = { inv: JSON.parse(JSON.stringify(inv)), contracts: JSON.parse(JSON.stringify(contracts)) }; },
    commit: async () => { snap = null; },
    rollback: async () => { if (snap) { inv.splice(0, inv.length, ...snap.inv); contracts.splice(0, contracts.length, ...snap.contracts); snap = null; } },
  };
  return { inv, contracts, pool: { getConnection: async () => conn, execute, query } };
}

function harness(db, owned = true) {
  const routes = {};
  const app = { get: (path, _m, h) => (routes[`GET ${path}`] = h), post: (path, _m, h) => (routes[`POST ${path}`] = h) };
  mountContracts(app, db.pool, { requireAuth: () => {}, ownsCharacter: async () => owned });
  return async (route, { body, params } = {}) => {
    let status = 200, json;
    await routes[route]({ body, params, user: { accountId: 1 } }, { status(c) { status = c; return this; }, json(j) { json = j; return this; }, headersSent: false });
    return { status, json };
  };
}

const today = () => rules.dayKey(Date.now());

test('removeFromBag takes across stacks and refuses, changing nothing, when short', async () => {
  const db = fakeDb({ bag: [{ character_id: 1, slot_index: 0, item_id: 'log_oak', quantity: 30 }, { character_id: 1, slot_index: 1, item_id: 'log_oak', quantity: 25 }] });
  const conn = await db.pool.getConnection();
  assert.equal(await removeFromBag(conn, 1, 'log_oak', 60), false);
  assert.deepEqual(db.inv.map((r) => r.quantity), [30, 25]);
  assert.equal(await removeFromBag(conn, 1, 'log_oak', 40), true);
  assert.deepEqual(db.inv.map((r) => r.quantity), [15], 'the first stack is used up, the second reduced');
});

test('addToBag stacks first, then fills free slots, and reports what did not fit', async () => {
  const bag = Array.from({ length: 23 }, (_, i) => ({ character_id: 1, slot_index: i, item_id: `junk_${i}`, quantity: 1 }));
  bag[3] = { character_id: 1, slot_index: 3, item_id: 'gem_grave_garnet', quantity: 98 };
  const db = fakeDb({ bag });
  const conn = await db.pool.getConnection();
  assert.equal(await addToBag(conn, 1, 'gem_grave_garnet', 1), 0);
  assert.equal(db.inv.find((r) => r.slot_index === 3).quantity, 99);
  assert.equal(await addToBag(conn, 1, 'gem_grave_garnet', 1), 0, 'the last free slot');
  assert.equal(await addToBag(conn, 1, 'gem_grave_garnet', 1), 0, 'a partly filled stack still takes more');
  assert.equal(await addToBag(conn, 1, 'a_new_item', 1), 1, 'a full bag reports what did not fit');
});

test('delivering an order takes the items, pays once, and cannot be repeated', async () => {
  const db = fakeDb();
  const call = harness(db);
  const board = (await call('GET /api/contracts/:characterId', { params: { characterId: '1' } })).json.data;
  assert.equal(board.contracts.length, 3);
  const c = board.contracts[0];
  db.inv.push({ id: 900, character_id: 1, slot_index: 0, item_id: c.itemId, quantity: c.qty + 5, equipped: 0 });

  const short = await call('POST /api/contracts/deliver', { body: { characterId: 1, slot: 1 } });
  assert.equal(short.json.success, false, 'not enough of the second order');

  const r = (await call('POST /api/contracts/deliver', { body: { characterId: 1, slot: 0 } })).json;
  assert.equal(r.success, true);
  assert.equal(r.data.gold, c.rewardGold);
  assert.equal(db.inv.find((x) => x.id === 900).quantity, 5, 'exactly the ordered amount was taken');

  const again = (await call('POST /api/contracts/deliver', { body: { characterId: 1, slot: 0 } })).json;
  assert.equal(again.success, false);
  assert.match(again.error, /already filled/);
  assert.equal(db.inv.find((x) => x.id === 900).quantity, 5, 'a repeat does not take more');
});

test('finishing all three pays the day\'s bonus exactly once, and a streak builds', async () => {
  const db = fakeDb();
  const call = harness(db);
  const board = (await call('GET /api/contracts/:characterId', { params: { characterId: '1' } })).json.data.contracts;
  board.forEach((c, i) => db.inv.push({ id: 800 + i, character_id: 1, slot_index: i, item_id: c.itemId, quantity: c.qty, equipped: 0 }));
  let last;
  for (let slot = 0; slot < 3; slot++) last = (await call('POST /api/contracts/deliver', { body: { characterId: 1, slot } })).json;
  assert.equal(last.success, true);
  assert.ok(last.data.paidBonus && last.data.paidBonus.gold > 0, 'the third order pays the bonus');
  assert.equal(last.data.bonus.claimed, true);
  assert.equal(last.data.streak, 1);
  assert.equal(db.contracts.filter((c) => c.slot === 9).length, 1);
  assert.equal(db.inv.filter((x) => x.item_id === 'gem_grave_garnet').reduce((n, x) => n + x.quantity, 0) >= 1, true);
});

test('a full bag refuses a reward and nothing is lost', async () => {
  const db = fakeDb();
  const call = harness(db);
  const board = (await call('GET /api/contracts/:characterId', { params: { characterId: '1' } })).json.data.contracts;
  const hard = board[2];
  // The bag is packed with the ordered item plus 23 other things: taking the order frees slots, but only if it is one slot...
  db.inv.push({ id: 700, character_id: 1, slot_index: 0, item_id: hard.itemId, quantity: hard.qty + 1, equipped: 0 });
  for (let i = 1; i < 24; i++) db.inv.push({ id: 700 + i, character_id: 1, slot_index: i, item_id: `junk_${i}`, quantity: 1, equipped: 0 });
  const r = (await call('POST /api/contracts/deliver', { body: { characterId: 1, slot: 2 } })).json;
  assert.equal(r.success, false);
  assert.match(r.error, /Make room/);
  assert.equal(db.inv.find((x) => x.id === 700).quantity, hard.qty + 1, 'the order was rolled back, not half taken');
});

test('someone else\'s character is refused', async () => {
  const call = harness(fakeDb(), false);
  assert.equal((await call('POST /api/contracts/deliver', { body: { characterId: 1, slot: 0 } })).status, 403);
});
