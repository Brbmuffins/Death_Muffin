// Run: node --test server/death-muffin/backend/garden.test.cjs
const test = require('node:test');
const assert = require('node:assert');
const mountGarden = require('./garden.cjs');

const STACKS = { seed_mourning_moss: 250, seed_nightshade: 250, sapling_oak: 250, bone_meal: 250, herb_mourning_moss: 250, log_oak: 250 };

/** In-memory tables for what garden.cjs touches, dispatched on the SQL text, with real transaction rollback. */
function fakeDb({ bag = [], level = 1, xp = 0 } = {}) {
  let inv = bag.map((b, i) => ({ id: i + 1, equipped: 0, character_id: 1, ...b }));
  let plots = new Map();
  let prof = { level, xp };
  let nextId = 500;
  const execute = async (sql, p = []) => {
    if (sql.startsWith('INSERT IGNORE INTO professions')) return [{}];
    if (sql.startsWith('SELECT skill_level')) return [[{ skill_level: prof.level, skill_xp: prof.xp }]];
    if (sql.startsWith('UPDATE professions')) { prof = { level: p[0], xp: p[1] }; return [{}]; }
    if (sql.startsWith('SELECT plot, seed_id')) return [[...plots.values()].map((r) => ({ plot: r.plot, seed_id: r.seed_id, planted_at: r.planted_at, ready_at: r.ready_at, composted: r.composted }))];
    if (sql.startsWith('INSERT INTO garden_plots')) { plots.set(p[1], { plot: p[1], seed_id: p[2], planted_at: p[3], ready_at: p[4], composted: p[5] }); return [{}]; }
    if (sql.startsWith('UPDATE garden_plots SET seed_id = NULL')) { plots.set(p[1], { plot: p[1], seed_id: null, planted_at: 0, ready_at: 0, composted: 0 }); return [{}]; }
    if (sql.startsWith('SELECT id, quantity FROM inventory')) return [inv.filter((r) => r.item_id === p[1] && !r.equipped && r.slot_index <= p[2]).sort((a, b) => a.slot_index - b.slot_index).map((r) => ({ id: r.id, quantity: r.quantity }))];
    if (sql.startsWith('DELETE FROM inventory')) { inv = inv.filter((r) => r.id !== p[0]); return [{}]; }
    if (sql.startsWith('UPDATE inventory SET quantity = quantity - ?')) { inv.find((r) => r.id === p[1]).quantity -= p[0]; return [{}]; }
    if (sql.startsWith('SELECT slot_index, item_id, quantity, equipped FROM inventory')) return [inv.filter((r) => r.slot_index <= 23).map((r) => ({ ...r }))];
    if (sql.startsWith('UPDATE inventory SET quantity = ? WHERE')) { inv.find((r) => r.slot_index === p[2]).quantity = p[0]; return [{}]; }
    if (sql.startsWith('INSERT INTO inventory')) { inv.push({ id: nextId++, character_id: p[0], slot_index: p[1], item_id: p[2], quantity: p[3], equipped: 0 }); return [{}]; }
    throw new Error(`unexpected SQL: ${sql.slice(0, 80)}`);
  };
  const query = async (sql, p) => {
    if (sql.startsWith('SELECT id, stackable')) return [p[0].map((id) => ({ id, stackable: 1, max_stack_size: STACKS[id] || 250 }))];
    throw new Error(`unexpected query: ${sql.slice(0, 80)}`);
  };
  let snap = null;
  const conn = {
    execute, query, release: () => {},
    beginTransaction: async () => { snap = { inv: JSON.parse(JSON.stringify(inv)), plots: new Map(plots), prof: { ...prof } }; },
    commit: async () => { snap = null; },
    rollback: async () => { if (snap) { inv = snap.inv; plots = snap.plots; prof = snap.prof; snap = null; } },
  };
  return { get inv() { return inv; }, get plots() { return plots; }, get prof() { return prof; }, pool: { getConnection: async () => conn } };
}

function harness(db, { owned = true, random = () => 0.99 } = {}) {
  const routes = {};
  const app = { get: (p, _m, h) => (routes[`GET ${p}`] = h), post: (p, _m, h) => (routes[`POST ${p}`] = h) };
  mountGarden(app, db.pool, { requireAuth: () => {}, ownsCharacter: async () => owned, random });
  return async (route, { body, params } = {}) => {
    let status = 200, json;
    await routes[route]({ body, params, method: route.split(' ')[0], path: route, user: { accountId: 1 } }, { status(c) { status = c; return this; }, json(j) { json = j; return this; }, headersSent: false });
    return { status, json };
  };
}

const qty = (db, id) => db.inv.filter((r) => r.item_id === id).reduce((n, r) => n + r.quantity, 0);

test('a fresh garden has six empty plots', async () => {
  const call = harness(fakeDb());
  const r = (await call('GET /api/garden/:characterId', { params: { characterId: '1' } })).json;
  assert.equal(r.data.plots.length, 6);
  assert.ok(r.data.plots.every((p) => p.state === 'empty'));
  assert.deepEqual(r.data.plots.map((p) => p.kind), ['herb', 'herb', 'herb', 'herb', 'tree', 'tree']);
});

test('planting takes the seed, sets a server-side ready time, and rejects the wrong plot, level and repeats', async () => {
  const db = fakeDb({ bag: [{ slot_index: 0, item_id: 'seed_mourning_moss', quantity: 2 }, { slot_index: 1, item_id: 'seed_nightshade', quantity: 1 }, { slot_index: 2, item_id: 'sapling_oak', quantity: 1 }] });
  const call = harness(db);
  const bad = async (body) => (await call('POST /api/garden/plant', { body: { characterId: 1, ...body } })).json;
  assert.match((await bad({ plot: 't0', seedId: 'seed_mourning_moss' })).error, /Mourning Bed/, 'a seed does not go in a tree patch');
  assert.match((await bad({ plot: 'h0', seedId: 'seed_nightshade' })).error, /Requires Grave Gardening 15/);
  assert.match((await bad({ plot: 't0', seedId: 'sapling_oak' })).error, /Requires Grave Gardening 10/);
  assert.equal(qty(db, 'seed_mourning_moss'), 2, 'refused plantings took nothing');

  const before = Date.now();
  const ok = (await bad({ plot: 'h0', seedId: 'seed_mourning_moss' }));
  assert.equal(ok.success, true);
  const p = ok.data.plots.find((x) => x.plot === 'h0');
  assert.equal(p.state, 'growing');
  assert.ok(p.readyAt - p.plantedAt === 20 * 60_000 && p.plantedAt >= before);
  assert.equal(qty(db, 'seed_mourning_moss'), 1);
  assert.match((await bad({ plot: 'h0', seedId: 'seed_mourning_moss' })).error, /already growing/);
  assert.equal(qty(db, 'seed_mourning_moss'), 1, 'a repeat planting did not eat another seed');
});

test('bone meal shortens the growth by a quarter and is only spent when planting succeeds', async () => {
  const db = fakeDb({ bag: [{ slot_index: 0, item_id: 'seed_mourning_moss', quantity: 1 }, { slot_index: 1, item_id: 'bone_meal', quantity: 1 }] });
  const call = harness(db);
  const r = (await call('POST /api/garden/plant', { body: { characterId: 1, plot: 'h1', seedId: 'seed_mourning_moss', compost: true } })).json;
  const p = r.data.plots.find((x) => x.plot === 'h1');
  assert.equal(p.readyAt - p.plantedAt, 15 * 60_000);
  assert.equal(p.composted, true);
  assert.equal(qty(db, 'bone_meal'), 0);

  const db2 = fakeDb({ bag: [{ slot_index: 0, item_id: 'seed_mourning_moss', quantity: 1 }] });
  const r2 = (await harness(db2)('POST /api/garden/plant', { body: { characterId: 1, plot: 'h1', seedId: 'seed_mourning_moss', compost: true } })).json;
  assert.equal(r2.success, false);
  assert.match(r2.error, /bone meal/);
  assert.equal(qty(db2, 'seed_mourning_moss'), 1, 'the seed was rolled back with the failed compost');
});

test('harvest waits for the plot, then pays the crop, XP and (by luck) a seed back', async () => {
  const db = fakeDb({ bag: [{ slot_index: 0, item_id: 'seed_mourning_moss', quantity: 1 }] });
  const call = harness(db, { random: () => 0 }); // lowest yield, and the seed comes back
  await call('POST /api/garden/plant', { body: { characterId: 1, plot: 'h0', seedId: 'seed_mourning_moss' } });
  assert.match((await call('POST /api/garden/harvest', { body: { characterId: 1, plot: 'h0' } })).json.error, /not ready/);
  assert.match((await call('POST /api/garden/harvest', { body: { characterId: 1, plot: 'h2' } })).json.error, /Nothing is growing/);

  db.plots.get('h0').ready_at = Date.now() - 1000; // time passes (server timestamps)
  const xpBefore = db.prof.xp + db.prof.level * 1000;
  const r = (await call('POST /api/garden/harvest', { body: { characterId: 1, plot: 'h0' } })).json;
  assert.equal(r.success, true);
  assert.equal(qty(db, 'herb_mourning_moss'), 3, 'the lowest yield');
  assert.equal(qty(db, 'seed_mourning_moss'), 1, 'a seed came back to replant');
  assert.equal(r.data.plots.find((x) => x.plot === 'h0').state, 'empty');
  assert.ok(db.prof.xp + db.prof.level * 1000 > xpBefore, 'gardening XP was paid');
  assert.match((await call('POST /api/garden/harvest', { body: { characterId: 1, plot: 'h0' } })).json.error, /Nothing is growing/, 'cannot harvest twice');
});

test('a full bag refuses the harvest and changes nothing', async () => {
  const bag = [{ slot_index: 0, item_id: 'seed_mourning_moss', quantity: 1 }, ...Array.from({ length: 23 }, (_, i) => ({ slot_index: i + 1, item_id: `junk_${i}`, quantity: 1 }))];
  const db = fakeDb({ bag });
  const call = harness(db, { random: () => 0.99 });
  await call('POST /api/garden/plant', { body: { characterId: 1, plot: 'h0', seedId: 'seed_mourning_moss' } }); // frees slot 0
  // Fill the freed slot so nothing fits.
  db.inv.push({ id: 900, character_id: 1, slot_index: 0, item_id: 'junk_x', quantity: 1, equipped: 0 });
  db.plots.get('h0').ready_at = Date.now() - 1;
  const r = (await call('POST /api/garden/harvest', { body: { characterId: 1, plot: 'h0' } })).json;
  assert.equal(r.success, false);
  assert.match(r.error, /Make room/);
  assert.equal(db.plots.get('h0').seed_id, 'seed_mourning_moss', 'the crop is still growing in the plot');
});

test('someone else\'s character is refused', async () => {
  const call = harness(fakeDb(), { owned: false });
  assert.equal((await call('POST /api/garden/plant', { body: { characterId: 1, plot: 'h0', seedId: 'seed_mourning_moss' } })).status, 403);
});
