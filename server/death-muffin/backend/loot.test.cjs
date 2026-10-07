// Run: node --test server/death-muffin/backend/loot.test.cjs
const test = require('node:test');
const assert = require('node:assert');
const mountLoot = require('./loot.cjs');
const affix = require('./gathering/affix-rules.cjs');
const { fakeDb, harness } = require('./bag-fake-db.cjs');

const seeded = (seed = 7) => () => {
  seed = (seed * 1664525 + 1013904223) % 4294967296;
  return seed / 4294967296;
};
const roll = (c, drops, characterId = 1) => c('POST /api/loot/roll-gear', { body: { characterId, drops } });
const drop = (item_id, level = 8, source = 'kill') => ({ item_id, level, source });

test('a gear drop becomes a stored instance with a server-computed item level and server-rolled affixes', async () => {
  const db = fakeDb();
  const r = (await roll(harness(mountLoot, db, { random: seeded() }), [drop('helm_iron', 8, 'elite')])).json;
  assert.equal(r.success, true);
  const [one] = r.data;
  assert.equal(one.item_id, 'helm_iron');
  assert.equal(one.ilvl, affix.itemLevelFor(8, 'elite'));
  assert.ok(one.instance_id > 0);
  assert.deepEqual(db.loot.map((l) => [l.id, l.account_id, l.item_id, l.ilvl]), [[one.instance_id, 7, 'helm_iron', one.ilvl]]);
  assert.deepEqual(db.loot[0].affixes, one.affixes);
  assert.equal(affix.instanceProblem({ ilvl: one.ilvl, affixes: one.affixes }, 'armor_head'), null, 'what it rolled is a legal roll');
});

test('materials and unknown ids: materials answer no instance, unknown items are refused', async () => {
  const db = fakeDb();
  const c = harness(mountLoot, db, { random: seeded() });
  const ok = (await roll(c, [drop('ore_copper'), drop('staff_oak')])).json;
  assert.equal(ok.data[0].instance_id, null);
  assert.ok(ok.data[1].instance_id);
  assert.equal(db.loot.length, 1);
  const bad = (await roll(c, [drop('nope_item')])).json;
  assert.equal(bad.success, false);
  assert.match(bad.error, /Unknown item/);
});

test('bad requests are refused with readable errors and write nothing', async () => {
  const db = fakeDb();
  const c = harness(mountLoot, db, { random: seeded() });
  for (const drops of [[], Array.from({ length: 13 }, () => drop('staff_oak')), [drop('staff_oak', 5, 'jackpot')], [{ item_id: 'staff_oak; DROP', level: 3, source: 'kill' }], 'x']) {
    const r = (await roll(c, drops)).json;
    assert.equal(r.success, false, JSON.stringify(drops));
    assert.equal(typeof r.error, 'string');
  }
  assert.equal(db.loot.length, 0);
  const foreign = harness(mountLoot, db, { owned: false });
  assert.equal((await roll(foreign, [drop('staff_oak')])).status, 403);
});

test('the claimed level is clamped to what the character could reach, so a script cannot ask for level 99 loot', async () => {
  const db = fakeDb({ charLevel: 5 });
  const r = (await roll(harness(mountLoot, db, { random: seeded() }), [drop('staff_oak', 99, 'boss')])).json;
  assert.equal(r.data[0].ilvl, affix.itemLevelFor(5 + affix.ILVL_REACH, 'boss'));
  assert.ok(r.data[0].ilvl <= 5 + affix.ILVL_REACH + 4);
});

test('bosses and first kills guarantee affixes', async () => {
  const db = fakeDb();
  const c = harness(mountLoot, db, { random: seeded(3) });
  for (let i = 0; i < 20; i++) {
    const r = (await roll(c, [drop('staff_oak', 6, 'first_kill'), drop('ring_copper', 6, 'boss')])).json;
    assert.ok(r.data[0].affixes.length >= 2, 'first kill: at least two');
    assert.ok(r.data[1].affixes.length >= 1, 'boss: at least one');
  }
});

test('too many unclaimed relics on the ground are refused; claimed ones do not count', async () => {
  const loot = Array.from({ length: mountLoot.MAX_UNCLAIMED }, (_, i) => ({ id: i + 1, item_id: 'staff_oak', created_at: Date.now() }));
  const db = fakeDb({ loot });
  const c = harness(mountLoot, db, { random: seeded() });
  const r = (await roll(c, [drop('staff_oak')])).json;
  assert.equal(r.success, false);
  assert.match(r.error, /Too many unclaimed/);
  assert.equal(db.loot.length, mountLoot.MAX_UNCLAIMED);
  // Claiming one (it sits in a bag slot) frees a place.
  const db2 = fakeDb({ loot, bag: [{ slot_index: 0, item_id: 'staff_oak', quantity: 1, instance_id: 1 }] });
  assert.equal((await roll(harness(mountLoot, db2, { random: seeded() }), [drop('staff_oak')])).json.success, true);
});

test('unclaimed instances older than two days are forgotten', async () => {
  const old = Date.now() - 3 * 86400000;
  const db = fakeDb({ loot: [{ id: 1, item_id: 'staff_oak', created_at: old }, { id: 2, item_id: 'staff_oak', created_at: old }], bag: [{ slot_index: 0, item_id: 'staff_oak', quantity: 1, instance_id: 2 }] });
  await roll(harness(mountLoot, db, { random: seeded() }), [drop('staff_oak')]);
  assert.deepEqual(db.loot.map((l) => l.id).sort((a, b) => a - b), [2, 1000], 'the unclaimed old one is gone, the one in a bag stays');
});

test('a failed roll leaves nothing behind (transaction rolls back)', async () => {
  const db = fakeDb();
  let n = 0;
  const flaky = () => { if (++n > 8) throw new Error('boom'); return 0.4; };
  const r = await roll(harness(mountLoot, db, { random: flaky }), [drop('staff_oak', 4, 'first_kill'), drop('ring_copper', 4, 'first_kill'), drop('helm_iron', 4, 'first_kill')]);
  assert.equal(r.json.success, false);
  assert.equal(db.loot.length, 0);
});

test('ownership is checked before a pooled connection is taken (concurrent rolls must not wedge the pool, 2026-10-06 incident)', async () => {
  const db = fakeDb();
  let held = 0, heldDuringOwnership = -1;
  const pool = { ...db.pool, getConnection: async () => { held++; const c = await db.pool.getConnection(); const rel = c.release; return { ...c, release: () => { held--; if (rel) rel.call(c); } }; } };
  const routes = {};
  const app = { post: (p, ...hs) => (routes[p] = hs[hs.length - 1]) };
  mountLoot(app, pool, { requireAuth: () => {}, ownsCharacter: async () => { heldDuringOwnership = held; return true; }, random: seeded() });
  let json;
  await routes['/api/loot/roll-gear']({ body: { characterId: 1, drops: [drop('helm_iron')] }, method: 'POST', path: '/api/loot/roll-gear', user: { accountId: 7 } }, { status() { return this; }, json(j) { json = j; return this; }, headersSent: false });
  assert.equal(json.success, true);
  assert.equal(heldDuringOwnership, 0, 'no connection held while ownership is checked');
  assert.equal(held, 0, 'connection released');
});
