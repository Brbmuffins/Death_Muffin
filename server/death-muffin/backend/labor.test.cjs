// Run: node --test server/death-muffin/backend/labor.test.cjs
const test = require('node:test');
const assert = require('node:assert');
const mountLabor = require('./labor.cjs');

const HOUR = 3_600_000;

function fakeDb({ levels = {}, bag = [] } = {}) {
  let prof = new Map(Object.entries(levels).map(([k, v]) => [k, { level: v, xp: 0 }]));
  let inv = bag.map((b, i) => ({ id: i + 1, equipped: 0, character_id: 1, ...b }));
  let posts = new Map();
  let nextId = 900;
  const execute = async (sql, p = []) => {
    if (sql.startsWith('SELECT profession_id, skill_level')) return [[...prof].map(([profession_id, v]) => ({ profession_id, skill_level: v.level, skill_xp: v.xp }))];
    if (sql.startsWith('SELECT slot, node_type')) return [[...posts].map(([slot, r]) => ({ slot, node_type: r.nodeType, started_at: r.startedAt }))];
    if (sql.startsWith('INSERT INTO character_labor')) { posts.set(p[1], { nodeType: p[2], startedAt: p[3] }); return [{}]; }
    if (sql.startsWith('UPDATE character_labor SET started_at')) { posts.get(p[2]).startedAt = p[0]; return [{}]; }
    if (sql.startsWith('SELECT skill_level, skill_xp FROM professions')) { const v = prof.get(p[1]); return [[v ? { skill_level: v.level, skill_xp: v.xp } : undefined].filter(Boolean)]; }
    if (sql.startsWith('INSERT IGNORE INTO professions')) { if (!prof.has(p[1])) prof.set(p[1], { level: 1, xp: 0 }); return [{}]; }
    if (sql.startsWith('UPDATE professions')) { prof.set(p[3], { level: p[0], xp: p[1] }); return [{}]; }
    if (sql.startsWith('SELECT slot_index, item_id, quantity, equipped FROM inventory')) return [inv.filter((r) => r.slot_index <= 23).map((r) => ({ ...r }))];
    if (sql.startsWith('UPDATE inventory SET quantity = ? WHERE')) { inv.find((r) => r.slot_index === p[2]).quantity = p[0]; return [{}]; }
    if (sql.startsWith('INSERT INTO inventory')) { inv.push({ id: nextId++, character_id: p[0], slot_index: p[1], item_id: p[2], quantity: p[3], equipped: 0 }); return [{}]; }
    throw new Error(`unexpected SQL: ${sql.slice(0, 80)}`);
  };
  const query = async (sql, p) => {
    if (sql.startsWith('SELECT id, stackable')) return [p[0].map((id) => ({ id, stackable: 1, max_stack_size: 250 }))];
    throw new Error(`unexpected query: ${sql.slice(0, 80)}`);
  };
  let snap = null;
  const conn = {
    execute, query, release: () => {},
    beginTransaction: async () => { snap = { prof: new Map([...prof].map(([k, v]) => [k, { ...v }])), inv: JSON.parse(JSON.stringify(inv)), posts: new Map([...posts].map(([k, v]) => [k, { ...v }])) }; },
    commit: async () => { snap = null; },
    rollback: async () => { if (snap) { prof = snap.prof; inv = snap.inv; posts = snap.posts; snap = null; } },
  };
  return { get inv() { return inv; }, get prof() { return prof; }, get posts() { return posts; }, pool: { getConnection: async () => conn } };
}

function harness(db, { owned = true } = {}) {
  let t = 1_000_000_000_000;
  const routes = {};
  const app = { get: (p, _m, h) => (routes[`GET ${p}`] = h), post: (p, _m, h) => (routes[`POST ${p}`] = h) };
  mountLabor(app, db.pool, { requireAuth: () => {}, ownsCharacter: async () => owned, now: () => t });
  const call = async (route, { body, params } = {}) => {
    let status = 200, json;
    await routes[route]({ body, params, method: route.split(' ')[0], path: route, user: { accountId: 1 } }, { status(c) { status = c; return this; }, json(j) { json = j; return this; }, headersSent: false });
    return { status, json };
  };
  return { call, advance: (ms) => { t += ms; } };
}

const qty = (db, id) => db.inv.filter((r) => r.item_id === id).reduce((n, r) => n + r.quantity, 0);

test('a new character commands one laborer; the other slots are locked', async () => {
  const { call } = harness(fakeDb());
  const v = (await call('GET /api/labor/:characterId', { params: { characterId: '1' } })).json.data;
  assert.equal(v.slots.length, 4);
  assert.deepEqual(v.slots.map((s) => s.unlocked), [true, false, false, false]);
  const strong = (await harness(fakeDb({ levels: { woodcutting: 50, mining: 30, fishing: 10, gravedigging: 10 } })).call('GET /api/labor/:characterId', { params: { characterId: '1' } })).json.data;
  assert.equal(strong.slots.filter((s) => s.unlocked).length, 3);
});

test('assigning checks the slot and the level, and a laborer with work waiting must be collected first', async () => {
  const db = fakeDb({ levels: { woodcutting: 5 } });
  const { call, advance } = harness(db);
  const assign = async (body) => (await call('POST /api/labor/assign', { body: { characterId: 1, ...body } })).json;
  assert.match((await assign({ slot: 1, nodeType: 'coffin_oak' })).error, /do not command/);
  assert.match((await assign({ slot: 0, nodeType: 'seam_gold' })).error, /Requires level/);
  assert.equal((await assign({ slot: 0, nodeType: 'coffin_oak' })).success, true);
  advance(3 * HOUR);
  assert.match((await assign({ slot: 0, nodeType: null })).error, /Collect what they have gathered/);
  assert.equal(db.posts.get(0).nodeType, 'coffin_oak', 'the post was not changed by the refusal');
});

test('collecting too early is refused; later it pays finds and XP, and the laborer keeps working', async () => {
  const db = fakeDb({ levels: { woodcutting: 5 } });
  const { call, advance } = harness(db);
  await call('POST /api/labor/assign', { body: { characterId: 1, slot: 0, nodeType: 'coffin_oak' } });
  assert.match((await call('POST /api/labor/collect', { body: { characterId: 1, slot: 0 } })).json.error, /barely started/);
  advance(4 * HOUR);
  const r = (await call('POST /api/labor/collect', { body: { characterId: 1, slot: 0 } })).json;
  assert.equal(r.success, true);
  assert.ok(qty(db, 'log_oak') > 50, `expected a few hundred logs, got ${qty(db, 'log_oak')}`);
  assert.ok(r.data.collected.xp > 0);
  assert.ok(db.prof.get('woodcutting').level > 5 || db.prof.get('woodcutting').xp > 0, 'the skill gained XP');
  assert.equal(db.posts.get(0).startedAt, 1_000_000_000_000 + 4 * HOUR, 'the timer restarted at the collection');
  assert.match((await call('POST /api/labor/collect', { body: { characterId: 1, slot: 0 } })).json.error, /barely started/, 'nothing is left to collect straight away');
});

test('work stops accruing after eight hours', async () => {
  const a = harness(fakeDb({ levels: { woodcutting: 5 } }));
  await a.call('POST /api/labor/assign', { body: { characterId: 1, slot: 0, nodeType: 'coffin_oak' } });
  a.advance(8 * HOUR);
  const eight = (await a.call('GET /api/labor/:characterId', { params: { characterId: '1' } })).json.data.slots[0];
  a.advance(20 * HOUR);
  const later = (await a.call('GET /api/labor/:characterId', { params: { characterId: '1' } })).json.data.slots[0];
  assert.equal(later.pendingActions, eight.pendingActions);
  assert.equal(later.capped, true);
});

test('a full bag refuses the collection and changes nothing, so it cannot be re-rolled', async () => {
  const bag = Array.from({ length: 24 }, (_, i) => ({ slot_index: i, item_id: `junk_${i}`, quantity: 1 }));
  const db = fakeDb({ levels: { woodcutting: 5 }, bag });
  const { call, advance } = harness(db);
  await call('POST /api/labor/assign', { body: { characterId: 1, slot: 0, nodeType: 'coffin_oak' } });
  advance(2 * HOUR);
  const started = db.posts.get(0).startedAt;
  const r = (await call('POST /api/labor/collect', { body: { characterId: 1, slot: 0 } })).json;
  assert.equal(r.success, false);
  assert.match(r.error, /Make room/);
  assert.equal(db.posts.get(0).startedAt, started, 'the work is still waiting');
  assert.equal(qty(db, 'log_oak'), 0);
});

test('someone else\'s character is refused', async () => {
  const { call } = harness(fakeDb(), { owned: false });
  assert.equal((await call('POST /api/labor/collect', { body: { characterId: 1, slot: 0 } })).status, 403);
});
