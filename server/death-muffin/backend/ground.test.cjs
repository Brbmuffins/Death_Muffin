// Run: node --test server/death-muffin/backend/ground.test.cjs
const test = require('node:test');
const assert = require('node:assert');
const ground = require('./ground.cjs');
const { LIMITS } = require('./party-sessions.cjs');

const S = 'a'.repeat(32);       // the party session
const OLD = 'b'.repeat(32);     // another session
const NOW = 1_000_000;

/** In-memory party_sessions / party_session_members / inventory / loot_instances / ground_drops, dispatched on the SQL ground.cjs sends. */
function fake({ sessions = {}, members = [], inventory = [], instances = [] } = {}) {
  const db = {
    sessions: { [S]: { id: S, status: 'open', last_host_at: NOW }, ...sessions },
    members: members.map((m) => ({ status: 'active', ...m })),
    inventory: inventory.map((r, i) => ({ id: i + 1, quantity: 1, equipped: 0, equipped_slot: null, instance_id: null, ...r })),
    instances: instances.map((r) => ({ ilvl: 10, affixes: '[]', found_session_id: null, found_at: null, ...r })),
    ground: [],
  };
  let nextInv = 100;
  const live = (sid, idleBefore) => { const s = db.sessions[sid]; return s && s.status !== 'ended' && s.last_host_at >= idleBefore; };
  const exec = async (sql, p = []) => {
    sql = sql.trim().replace(/\s+/g, ' ');
    if (sql.startsWith('DELETE li FROM loot_instances li JOIN ground_drops g ON g.instance_id = li.id JOIN party_sessions')) {
      const dead = db.ground.filter((g) => !live(g.session_id, p[0])).map((g) => g.instance_id);
      db.instances = db.instances.filter((i) => !dead.includes(i.id));
      return [{}];
    }
    if (sql.startsWith('DELETE g FROM ground_drops g JOIN party_sessions')) { db.ground = db.ground.filter((g) => live(g.session_id, p[0])); return [{}]; }
    if (sql.startsWith('DELETE li FROM loot_instances li JOIN ground_drops g ON g.instance_id = li.id WHERE g.session_id = ?')) {
      const gone = db.ground.filter((g) => g.session_id === p[0]).map((g) => g.instance_id);
      db.instances = db.instances.filter((i) => !gone.includes(i.id));
      return [{}];
    }
    if (sql.startsWith('DELETE FROM ground_drops WHERE session_id = ?')) { db.ground = db.ground.filter((g) => g.session_id !== p[0]); return [{}]; }
    if (sql.startsWith('SELECT id, status, last_host_at FROM party_sessions')) return [db.sessions[p[0]] ? [{ ...db.sessions[p[0]] }] : []];
    if (sql.startsWith('SELECT character_id, account_id, joined_at FROM party_session_members')) {
      return [db.members.filter((m) => m.session_id === p[0] && m.character_id === p[1] && m.status === 'active').map((m) => ({ ...m }))];
    }
    if (sql.startsWith('SELECT COUNT(*) AS n FROM ground_drops')) return [[{ n: db.ground.filter((g) => g.session_id === p[0] && g.from_character_id === p[1]).length }]];
    if (sql.startsWith('SELECT id, slot_index, item_id, quantity, equipped, instance_id FROM inventory')) {
      return [db.inventory.filter((r) => r.character_id === p[0] && r.slot_index === p[1]).map((r) => ({ ...r }))];
    }
    if (sql.startsWith('SELECT id, account_id, item_id, ilvl, affixes, found_session_id, found_at FROM loot_instances')
      || sql.startsWith('SELECT id, found_session_id, found_at FROM loot_instances')) return [db.instances.filter((i) => i.id === p[0]).map((i) => ({ ...i }))];
    if (sql.startsWith('DELETE FROM inventory WHERE id = ?')) { db.inventory = db.inventory.filter((r) => r.id !== p[0]); return [{}]; }
    if (sql.startsWith('INSERT INTO ground_drops')) {
      const [id, session_id, instance_id, item_id, from_character_id, from_account_id, x, z, created_at] = p;
      db.ground.push({ id, session_id, instance_id, item_id, from_character_id, from_account_id, x, z, created_at });
      return [{}];
    }
    if (sql.startsWith("SELECT character_id FROM party_session_members WHERE session_id = ? AND status = 'active' AND joined_at <= ?")) {
      return [db.members.filter((m) => m.session_id === p[0] && m.status === 'active' && m.joined_at <= p[1]).map((m) => ({ character_id: m.character_id }))];
    }
    if (sql.startsWith('SELECT id, session_id, instance_id, item_id, from_account_id FROM ground_drops')) return [db.ground.filter((g) => g.id === p[0]).map((g) => ({ ...g }))];
    if (sql.startsWith('SELECT slot_index FROM inventory WHERE character_id = ?')) {
      return [db.inventory.filter((r) => r.character_id === p[0] && r.slot_index >= 0 && r.slot_index < p[1]).map((r) => ({ slot_index: r.slot_index }))];
    }
    if (sql.startsWith('INSERT INTO inventory')) {
      db.inventory.push({ id: nextInv++, character_id: p[0], slot_index: p[1], item_id: p[2], quantity: 1, equipped: 0, equipped_slot: null, instance_id: p[3] });
      return [{}];
    }
    if (sql.startsWith('UPDATE loot_instances SET account_id = ?')) { db.instances.find((i) => i.id === p[1]).account_id = p[0]; return [{}]; }
    if (sql.startsWith('DELETE FROM ground_drops WHERE id = ?')) { db.ground = db.ground.filter((g) => g.id !== p[0]); return [{}]; }
    if (sql.startsWith('SELECT instance_id FROM ground_drops WHERE instance_id IN')) return [db.ground.filter((g) => p[0].includes(g.instance_id)).map((g) => ({ instance_id: g.instance_id }))];
    if (sql.startsWith('SELECT inv.id')) return [db.inventory.filter((r) => r.character_id === p[0]).map((r) => ({ ...r }))];
    throw new Error(`unexpected SQL: ${sql}`);
  };
  // Transactions: snapshot on begin, restore on rollback.
  let snap = null;
  const conn = {
    execute: exec, query: exec,
    beginTransaction: async () => { snap = JSON.stringify(db); },
    commit: async () => { snap = null; },
    rollback: async () => { if (snap) Object.assign(db, JSON.parse(snap)); snap = null; },
    release: () => {},
  };
  return { db, conn, pool: { getConnection: async () => conn, execute: exec, query: exec } };
}

/** Alice (char 1, account 7) hosts; Bob (char 2, account 8) was there from the start; Cara (char 3, account 9) joined after the find. */
const party = (extra = {}) => fake({
  members: [
    { session_id: S, character_id: 1, account_id: 7, joined_at: NOW - 5000 },
    { session_id: S, character_id: 2, account_id: 8, joined_at: NOW - 4000 },
    { session_id: S, character_id: 3, account_id: 9, joined_at: NOW - 1000 },
  ],
  inventory: [
    { character_id: 1, slot_index: 0, item_id: 'helm_iron', instance_id: 50 },
    { character_id: 1, slot_index: 1, item_id: 'ore_copper', quantity: 5 },
    { character_id: 1, slot_index: 2, item_id: 'staff_oak', instance_id: 51, equipped: 1 },
    { character_id: 1, slot_index: 3, item_id: 'wand_iron', instance_id: 52 },
  ],
  instances: [
    { id: 50, account_id: 7, item_id: 'helm_iron', found_session_id: S, found_at: NOW - 2000 },   // found with Alice and Bob, before Cara joined
    { id: 51, account_id: 7, item_id: 'staff_oak' },
    { id: 52, account_id: 7, item_id: 'wand_iron' },                                             // found solo
  ],
  ...extra,
});

const dropAs = (f, slot, who = { characterId: 1, accountId: 7 }) => ground.drop(f.conn, { ...who, sessionId: S, slot, x: 3, z: 4, now: NOW });
const pickAs = (f, dropId, characterId, accountId) => ground.pickup(f.conn, { characterId, accountId, dropId, now: NOW });
const refused = async (p, code) => assert.rejects(p, (e) => e.player === true && e.code === code && typeof e.message === 'string' && e.message.length > 0);

test('a drop takes the gear out of the bag and names who may pick it up: the dropper and whoever was there when it was found', async () => {
  const f = party();
  const out = await dropAs(f, 0);
  assert.match(out.dropId, /^[0-9a-f]{32}$/);
  assert.deepStrictEqual(out.item, { item_id: 'helm_iron', quantity: 1, instance: { id: 50, ilvl: 10, affixes: [] } });
  assert.deepStrictEqual(out.eligible.sort(), [1, 2], 'Cara joined after the find');
  assert.ok(!f.db.inventory.some((r) => r.instance_id === 50), 'gone from the bag');
  assert.deepStrictEqual([f.db.ground.length, f.db.ground[0].x, f.db.ground[0].z], [1, 3, 4]);
  assert.strictEqual(f.db.instances.find((i) => i.id === 50).account_id, 7, 'the instance stays the dropper\'s until someone picks it up');
});

test('gear found outside the session can only be picked back up by the dropper', async () => {
  const f = party();
  const out = await dropAs(f, 3);
  assert.deepStrictEqual(out.eligible, [1]);
  await refused(pickAs(f, out.dropId, 2, 8), 'not_eligible');
  await pickAs(f, out.dropId, 1, 7);
  assert.ok(f.db.inventory.some((r) => r.character_id === 1 && r.instance_id === 52), 'back in the bag');
});

test('an eligible member picks it up: first free slot, the instance becomes theirs, a second pickup finds it gone', async () => {
  const f = party({ inventory: [
    { character_id: 1, slot_index: 0, item_id: 'helm_iron', instance_id: 50 },
    { character_id: 2, slot_index: 0, item_id: 'ore_copper', quantity: 3 },
  ] });
  const { dropId } = await dropAs(f, 0);
  const got = await pickAs(f, dropId, 2, 8);
  assert.strictEqual(got.slot, 1);
  const row = f.db.inventory.find((r) => r.instance_id === 50);
  assert.deepStrictEqual([row.character_id, row.slot_index, row.item_id, row.equipped], [2, 1, 'helm_iron', 0]);
  assert.strictEqual(f.db.instances.find((i) => i.id === 50).account_id, 8);
  assert.strictEqual(f.db.ground.length, 0);
  await refused(pickAs(f, dropId, 1, 7), 'gone');
});

test('a member who joined after the find, or someone outside the party, cannot take it', async () => {
  const f = party();
  const { dropId } = await dropAs(f, 0);
  await refused(pickAs(f, dropId, 3, 9), 'not_eligible');
  await refused(pickAs(f, dropId, 4, 10), 'not_member');
  f.db.members.find((m) => m.character_id === 2).status = 'left';
  await refused(pickAs(f, dropId, 2, 8), 'not_member');
  assert.strictEqual(f.db.ground.length, 1, 'still on the ground');
});

test('only gear, never worn, never an empty slot, only from inside a live session', async () => {
  const f = party();
  await refused(dropAs(f, 1), 'not_gear');
  await refused(dropAs(f, 2), 'equipped');
  await refused(dropAs(f, 9), 'empty');
  await refused(dropAs(f, 0, { characterId: 4, accountId: 10 }), 'not_member');
  f.db.sessions[S].status = 'ended';
  await refused(dropAs(f, 0), 'no_session');
  f.db.sessions[S] = { id: S, status: 'open', last_host_at: NOW - LIMITS.SESSION_IDLE_MS - 1 };
  await refused(dropAs(f, 0), 'no_session');
  assert.strictEqual(f.db.ground.length, 0);
});

test('a full bag refuses the pickup and the piece stays on the ground', async () => {
  const bag = Array.from({ length: 48 }, (_, i) => ({ character_id: 2, slot_index: i, item_id: 'ore_copper', quantity: 1 }));
  const f = party({ inventory: [{ character_id: 1, slot_index: 0, item_id: 'helm_iron', instance_id: 50 }, ...bag] });
  const { dropId } = await dropAs(f, 0);
  await refused(pickAs(f, dropId, 2, 8), 'bag_full');
  assert.strictEqual(f.db.ground.length, 1);
});

test(`at most ${ground.MAX_DROPS_PER_SESSION} pieces per player lie on one session's ground`, async () => {
  const inv = Array.from({ length: ground.MAX_DROPS_PER_SESSION + 1 }, (_, i) => ({ character_id: 1, slot_index: i, item_id: 'wand_iron', instance_id: 200 + i }));
  const inst = inv.map((r) => ({ id: r.instance_id, account_id: 7, item_id: 'wand_iron' }));
  const f = party({ inventory: inv, instances: inst });
  for (let i = 0; i < ground.MAX_DROPS_PER_SESSION; i++) await dropAs(f, i);
  await refused(dropAs(f, ground.MAX_DROPS_PER_SESSION), 'too_many');
});

test('when the session ends the piece is gone: rows and instances (sweep on the next call, clearSession at the host\'s end)', async () => {
  const f = party();
  const { dropId } = await dropAs(f, 0);
  f.db.sessions[S].status = 'ended';
  await refused(pickAs(f, dropId, 2, 8), 'gone');
  assert.deepStrictEqual([f.db.ground.length, f.db.instances.some((i) => i.id === 50)], [0, false]);
  const g = party();
  await dropAs(g, 0);
  await ground.clearSession(g.conn, S);
  assert.deepStrictEqual([g.db.ground.length, g.db.instances.some((i) => i.id === 50)], [0, false]);
});

test('onGround names the instances lying on the ground (a bag save may not claim them)', async () => {
  const f = party();
  await dropAs(f, 0);
  assert.deepStrictEqual(await ground.onGround(f.conn, [50, 52]), [50]);
  assert.deepStrictEqual(await ground.onGround(f.conn, []), []);
  const missing = { query: async () => { throw Object.assign(new Error('no table'), { code: 'ER_NO_SUCH_TABLE' }); } };
  assert.deepStrictEqual(await ground.onGround(missing, [1]), [], 'fails open before migration 043');
});

test('routes: bad body 400, someone else\'s character 403, a refusal is a readable 200, success answers the bag', async () => {
  const f = party();
  const routes = {};
  const owned = { yes: true };
  ground.mountGround({ post: (p, _a, h) => (routes[p] = h) }, f.pool, { requireAuth: () => {}, ownsCharacter: async () => owned.yes, now: () => NOW, log: { error() {} } });
  const call = async (path, body, accountId = 7) => {
    let status = 200, json;
    await routes[path]({ body, user: { accountId } }, { status(c) { status = c; return this; }, json(j) { json = j; return this; }, headersSent: false });
    return { status, json };
  };
  assert.strictEqual((await call('/api/ground/drop', { characterId: 1, sessionId: 'nope', slot: 0 })).status, 400);
  assert.strictEqual((await call('/api/ground/pickup', { characterId: 1, dropId: 'x' })).status, 400);
  owned.yes = false;
  assert.strictEqual((await call('/api/ground/drop', { characterId: 1, sessionId: S, slot: 0 })).status, 403);
  owned.yes = true;
  const bad = await call('/api/ground/drop', { characterId: 1, sessionId: S, slot: 1 });
  assert.deepStrictEqual([bad.status, bad.json.success, bad.json.code], [200, false, 'not_gear']);
  const ok = await call('/api/ground/drop', { characterId: 1, sessionId: S, slot: 0, x: 1, z: 2 });
  assert.strictEqual(ok.json.success, true);
  assert.deepStrictEqual(ok.json.data.eligible.sort(), [1, 2]);
  assert.ok(Array.isArray(ok.json.data.bag) && !ok.json.data.bag.some((r) => r.instance_id === 50), 'the reply carries the bag without it');
  const pick = await call('/api/ground/pickup', { characterId: 2, dropId: ok.json.data.dropId }, 8);
  assert.strictEqual(pick.json.success, true);
  assert.ok(pick.json.data.bag.some((r) => r.instance_id === 50));
});
