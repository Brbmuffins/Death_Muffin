// Run: node --test server/death-muffin/backend/garden.test.cjs
const test = require('node:test');
const assert = require('node:assert');
const mountGarden = require('./garden.cjs');
const rules = require('./gathering/garden-rules.cjs');
const { BAG_SLOTS } = require('./gathering/gathering-rules.cjs');

/** The starter seed (the first herb), the first sapling, and a herb that needs more than level 1. */
const MOSS = rules.SEEDS.find((s) => s.kind === 'herb');
const SAPLING = rules.SEEDS.find((s) => s.kind === 'tree');
const DEMANDING = rules.SEEDS.filter((s) => s.kind === 'herb' && s.level > 1).sort((a, b) => a.level - b.level)[0];
const HERB_PLOT = rules.PLOTS.find((p) => p.kind === 'herb');
const TREE_PLOT = rules.PLOTS.find((p) => p.kind === 'tree');

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
    if (sql.startsWith('SELECT slot_index, item_id, quantity, equipped FROM inventory')) return [inv.filter((r) => r.slot_index <= p[1]).map((r) => ({ ...r }))];
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

test('a fresh garden has an empty plot for every plot the rules list, in their order', async () => {
  const call = harness(fakeDb());
  const r = (await call('GET /api/garden/:characterId', { params: { characterId: '1' } })).json;
  assert.equal(r.data.plots.length, rules.PLOTS.length);
  assert.ok(r.data.plots.every((p) => p.state === 'empty'));
  assert.deepEqual(r.data.plots.map((p) => [p.plot, p.kind]), rules.PLOTS.map((p) => [p.id, p.kind]));
});

test('planting takes the seed, sets a server-side ready time, and rejects the wrong plot, level and repeats', async () => {
  const db = fakeDb({ bag: [{ slot_index: 0, item_id: MOSS.id, quantity: 2 }, { slot_index: 1, item_id: DEMANDING.id, quantity: 1 }, { slot_index: 2, item_id: SAPLING.id, quantity: 1 }] });
  const call = harness(db);
  const bad = async (body) => (await call('POST /api/garden/plant', { body: { characterId: 1, ...body } })).json;
  assert.match((await bad({ plot: TREE_PLOT.id, seedId: MOSS.id })).error, /Mourning Bed/, 'a seed does not go in a tree patch');
  assert.match((await bad({ plot: HERB_PLOT.id, seedId: DEMANDING.id })).error, new RegExp(`Requires Grave Gardening ${DEMANDING.level}`));
  assert.match((await bad({ plot: TREE_PLOT.id, seedId: SAPLING.id })).error, new RegExp(`Requires Grave Gardening ${SAPLING.level}`));
  assert.equal(qty(db, MOSS.id), 2, 'refused plantings took nothing');

  const before = Date.now();
  const ok = (await bad({ plot: HERB_PLOT.id, seedId: MOSS.id }));
  assert.equal(ok.success, true);
  const p = ok.data.plots.find((x) => x.plot === HERB_PLOT.id);
  assert.equal(p.state, 'growing');
  assert.ok(p.readyAt - p.plantedAt === rules.growMs(MOSS, false) && p.plantedAt >= before);
  assert.equal(qty(db, MOSS.id), 1);
  assert.match((await bad({ plot: HERB_PLOT.id, seedId: MOSS.id })).error, /already growing/);
  assert.equal(qty(db, MOSS.id), 1, 'a repeat planting did not eat another seed');
});

test('bone meal shortens the growth and is only spent when planting succeeds', async () => {
  const plot = rules.PLOTS.filter((p) => p.kind === 'herb')[1] ?? HERB_PLOT; // a second herb bed, if there is one
  const db = fakeDb({ bag: [{ slot_index: 0, item_id: MOSS.id, quantity: 1 }, { slot_index: 1, item_id: rules.COMPOST_ITEM, quantity: 1 }] });
  const call = harness(db);
  const r = (await call('POST /api/garden/plant', { body: { characterId: 1, plot: plot.id, seedId: MOSS.id, compost: true } })).json;
  const p = r.data.plots.find((x) => x.plot === plot.id);
  assert.equal(p.readyAt - p.plantedAt, rules.growMs(MOSS, true));
  assert.ok(rules.growMs(MOSS, true) < rules.growMs(MOSS, false), 'bone meal is faster');
  assert.equal(p.composted, true);
  assert.equal(qty(db, rules.COMPOST_ITEM), 0);

  const db2 = fakeDb({ bag: [{ slot_index: 0, item_id: MOSS.id, quantity: 1 }] });
  const r2 = (await harness(db2)('POST /api/garden/plant', { body: { characterId: 1, plot: plot.id, seedId: MOSS.id, compost: true } })).json;
  assert.equal(r2.success, false);
  assert.match(r2.error, /bone meal/);
  assert.equal(qty(db2, MOSS.id), 1, 'the seed was rolled back with the failed compost');
});

test('harvest waits for the plot, then pays the crop, XP and (by luck) a seed back', async () => {
  const db = fakeDb({ bag: [{ slot_index: 0, item_id: MOSS.id, quantity: 1 }] });
  const call = harness(db, { random: () => 0 }); // lowest yield, and the seed comes back
  const empty = rules.PLOTS.find((p) => p.id !== HERB_PLOT.id).id;
  await call('POST /api/garden/plant', { body: { characterId: 1, plot: HERB_PLOT.id, seedId: MOSS.id } });
  assert.match((await call('POST /api/garden/harvest', { body: { characterId: 1, plot: HERB_PLOT.id } })).json.error, /not ready/);
  assert.match((await call('POST /api/garden/harvest', { body: { characterId: 1, plot: empty } })).json.error, /Nothing is growing/);

  db.plots.get(HERB_PLOT.id).ready_at = Date.now() - 1000; // time passes (server timestamps)
  const xpBefore = db.prof.xp + db.prof.level * 1000;
  const r = (await call('POST /api/garden/harvest', { body: { characterId: 1, plot: HERB_PLOT.id } })).json;
  assert.equal(r.success, true);
  assert.equal(qty(db, MOSS.harvest), MOSS.yields[0], 'the lowest yield');
  assert.equal(qty(db, MOSS.id), MOSS.seedBack > 0 ? 1 : 0, 'a seed came back to replant (the roll of 0 is under any seed-back chance)');
  assert.equal(r.data.plots.find((x) => x.plot === HERB_PLOT.id).state, 'empty');
  assert.ok(db.prof.xp + db.prof.level * 1000 > xpBefore, 'gardening XP was paid');
  assert.match((await call('POST /api/garden/harvest', { body: { characterId: 1, plot: HERB_PLOT.id } })).json.error, /Nothing is growing/, 'cannot harvest twice');
});

test('a full bag refuses the harvest and changes nothing', async () => {
  const bag = [{ slot_index: 0, item_id: MOSS.id, quantity: 1 }, ...Array.from({ length: BAG_SLOTS - 1 }, (_, i) => ({ slot_index: i + 1, item_id: `junk_${i}`, quantity: 1 }))];
  const db = fakeDb({ bag });
  const call = harness(db, { random: () => 0.99 });
  await call('POST /api/garden/plant', { body: { characterId: 1, plot: HERB_PLOT.id, seedId: MOSS.id } }); // frees slot 0
  // Fill the freed slot so nothing fits.
  db.inv.push({ id: 900, character_id: 1, slot_index: 0, item_id: 'junk_x', quantity: 1, equipped: 0 });
  db.plots.get(HERB_PLOT.id).ready_at = Date.now() - 1;
  const r = (await call('POST /api/garden/harvest', { body: { characterId: 1, plot: HERB_PLOT.id } })).json;
  assert.equal(r.success, false);
  assert.match(r.error, /Make room/);
  assert.equal(db.plots.get(HERB_PLOT.id).seed_id, MOSS.id, 'the crop is still growing in the plot');
});

test('someone else\'s character is refused', async () => {
  const call = harness(fakeDb(), { owned: false });
  assert.equal((await call('POST /api/garden/plant', { body: { characterId: 1, plot: HERB_PLOT.id, seedId: MOSS.id } })).status, 403);
});
