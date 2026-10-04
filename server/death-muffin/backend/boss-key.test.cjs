// Run: node --test server/death-muffin/backend/boss-key.test.cjs
const test = require('node:test');
const assert = require('node:assert');
const mountBossKey = require('./boss-key.cjs');
const { fakeDb, harness, qty } = require('./bag-fake-db.cjs');
const sinks = require('./gathering/gold-sink-rules.cjs');

/** The boss-key SQL on top of fakeDb: gold, the empowered_summons table, the area record and item metadata. */
function setup({ gold = 500000, bag, open = true, clock = { t: 1_000_000_000 }, mode = 'off' } = {}) {
  const state = { gold, summons: [], nextId: 1, audit: [] };
  const extra = (sql, p) => {
    if (sql.startsWith('SELECT account_id, gold, level FROM characters')) return [[{ account_id: 7, gold: state.gold, level: 30 }]];
    if (sql.startsWith('SELECT id, gold, UNIX_TIMESTAMP')) {
      const rows = state.summons.filter((s) => s.character_id === p[0] && s.boss === p[1] && s.status === 'open').sort((a, b) => (sql.includes('DESC') ? b.id - a.id : a.id - b.id));
      return [(sql.includes('LIMIT 1') ? rows.slice(0, 1) : rows).map((s) => ({ id: s.id, gold: s.gold, made: s.made, killed_at: s.killed_at ?? null, boss: s.boss }))];
    }
    if (sql.startsWith('SELECT id, boss, UNIX_TIMESTAMP')) return [state.summons.filter((s) => s.character_id === p[0] && s.status === 'open').map((s) => ({ id: s.id, boss: s.boss, made: s.made }))];
    if (sql.startsWith('UPDATE empowered_summons SET killed_at')) { const r = state.summons.find((x) => x.id === p[0] && x.character_id === p[1] && x.boss === p[2] && x.status === 'open' && !x.killed_at); if (r) r.killed_at = clock.t; return [{}]; }
    if (sql.startsWith('INSERT INTO progress_audit')) { state.audit.push(p); return [{}]; }
    if (sql.startsWith('UPDATE characters SET gold = gold -')) { state.gold -= p[0]; return [{}]; }
    if (sql.startsWith('UPDATE characters SET gold = ?')) { state.gold = p[0]; return [{}]; }
    if (sql.startsWith('INSERT INTO empowered_summons')) { state.summons.push({ id: state.nextId++, character_id: p[0], boss: p[1], gold: p[2], status: 'open', made: clock.t }); return [{ insertId: state.nextId - 1 }]; }
    if (sql.startsWith("UPDATE empowered_summons SET status = 'refunded'")) { state.summons.find((s) => s.id === p[0]).status = 'refunded'; return [{}]; }
    if (sql.startsWith("UPDATE empowered_summons SET status = 'claimed'")) { state.summons.find((s) => s.id === p[0]).status = 'claimed'; return [{}]; }
    if (sql.startsWith('SELECT item_id FROM inventory WHERE character_id')) return [db.inv.filter((r) => r.character_id === p[0]).map((r) => ({ item_id: r.item_id }))];
    if (sql.startsWith('SELECT rarity, item_type FROM items')) return [[{ rarity: p[0].startsWith('leg_') ? 'legendary' : 'common', item_type: 'armor_head' }]];
    return null;
  };
  const db = fakeDb({ bag: bag ?? [{ slot_index: 0, item_id: 'covenant_seal', quantity: 2 }, { slot_index: 1, item_id: 'helm_iron', quantity: 1 }], extra });
  // The fake item table has no covenant_seal: stackable 99, like the live row.
  const base = db.conn.query;
  db.conn.query = async (sql, p) => {
    if (sql.trim().startsWith('SELECT id, stackable') && p[0].includes('covenant_seal')) return [[{ id: 'covenant_seal', stackable: 1, max_stack_size: 99, item_type: 'material', rarity: 'epic' }]];
    return base(sql, p);
  };
  const call = (opts = {}) => harness((app, pool, o) => mountBossKey(app, pool, { ...o, now: () => clock.t, areaOpen: async () => open, isStaff: async () => false, killsMode: () => mode, log: { error() {}, warn() {}, log() {} } }), db, opts);
  return { db, state, call, clock };
}
const post = (c, name, body) => c(`POST /api/boss-key/${name}`, { body: { characterId: 1, boss: 'gravedigger', ...body } });

test('prices: 7,500 x shards squared, Prelate excluded', () => {
  assert.equal(sinks.empowerGold('gravedigger'), 30000);
  assert.equal(sinks.empowerGold('abbess'), 67500);
  assert.equal(sinks.empowerGold('mire'), 367500);
  assert.equal(sinks.canEmpower('prelate'), false);
  assert.equal(sinks.canEmpower('nope'), false);
  assert.ok(Math.abs(sinks.empoweredLegendaryChance('gravedigger') - 0.15) < 1e-9);
  assert.ok(Math.abs(sinks.empoweredLegendaryChance('abbess') - 0.5) < 1e-9);
  assert.ok(Math.abs(sinks.empoweredLegendaryChance('mire') - 0.6) < 1e-9);
});

test('a summon takes one Seal and the boss price and binds a summon', async () => {
  const t = setup();
  const r = (await post(t.call(), 'summon')).json;
  assert.equal(r.success, true, r.error);
  assert.equal(r.data.cost, 30000);
  assert.equal(r.data.reused, false);
  assert.equal(t.state.gold, 470000);
  assert.equal(qty(t.db.inv, 'covenant_seal'), 1);
  assert.equal(t.state.summons.length, 1);
});

test('the last Seal leaves the bag; a bound summon is reused free after a wipe', async () => {
  const t = setup({ bag: [{ slot_index: 0, item_id: 'covenant_seal', quantity: 1 }] });
  const c = t.call();
  assert.equal((await post(c, 'summon')).json.success, true);
  assert.equal(qty(t.db.inv, 'covenant_seal'), 0);
  const again = (await post(c, 'summon')).json;
  assert.equal(again.success, true, 'no seal needed the second time');
  assert.equal(again.data.reused, true);
  assert.equal(again.data.cost, 0);
  assert.equal(t.state.gold, 470000, 'not charged twice');
  assert.equal(t.state.summons.length, 1);
});

test('no Seal, not enough gold, a sealed ground, the Prelate and junk bosses are refused and change nothing', async () => {
  const noSeal = setup({ bag: [{ slot_index: 1, item_id: 'helm_iron', quantity: 1 }] });
  assert.match((await post(noSeal.call(), 'summon')).json.error, /Covenant Seal/);
  const poor = setup({ gold: 29999 });
  assert.match((await post(poor.call(), 'summon')).json.error, /30,000 gold \(you have 29,999\)/);
  assert.equal(qty(poor.db.inv, 'covenant_seal'), 2);
  assert.equal(poor.state.gold, 29999);
  const shut = setup({ open: false });
  assert.match((await post(shut.call(), 'summon')).json.error, /sealed/);
  assert.equal(qty(shut.db.inv, 'covenant_seal'), 2);
  const t = setup();
  assert.match((await post(t.call(), 'summon', { boss: 'prelate' })).json.error, /cannot be called/);
  assert.match((await post(t.call(), 'summon', { boss: '../x' })).json.error, /cannot be called/);
  assert.equal(t.state.summons.length, 0);
  assert.equal(t.state.gold, 500000);
});

test('someone else\'s character is refused on every route', async () => {
  const t = setup();
  for (const name of ['summon', 'refund', 'claim']) assert.equal((await post(t.call({ owned: false }), name)).status, 403);
});

test('a summon the host refused can be taken back within two minutes, not later', async () => {
  const t = setup({ bag: [{ slot_index: 0, item_id: 'covenant_seal', quantity: 1 }] });
  const c = t.call();
  await post(c, 'summon');
  t.clock.t += 60_000;
  const r = (await post(c, 'refund')).json;
  assert.equal(r.success, true, r.error);
  assert.equal(t.state.gold, 500000);
  assert.equal(qty(t.db.inv, 'covenant_seal'), 1);
  assert.equal(t.state.summons[0].status, 'refunded');
  assert.match((await post(c, 'refund')).json.error, /no recent summon/);
  await post(c, 'summon');
  t.clock.t += 3 * 60_000;
  assert.match((await post(c, 'refund')).json.error, /no recent summon/);
});

test('claim pays one server-rolled epic-or-better piece, once, and never from a client-named item', async () => {
  const t = setup();
  const c = t.call({ random: () => 0.99 });
  await post(c, 'summon');
  t.clock.t += 120_000;
  const r = (await post(c, 'claim', { discipline: 'gravecaller', level: 5, item_id: 'helm_gold', affixes: [{ id: 'p_str', v: 99 }], rarity: 'legendary' })).json;
  assert.equal(r.success, true, r.error);
  assert.notEqual(r.data.item_id, 'helm_gold');
  assert.equal(r.data.legendary, false, 'rand 0.99 misses the legendary roll');
  assert.ok(r.data.affixes.length >= 3, 'three affixes show as epic');
  assert.ok(r.data.instance_id > 0);
  const row = t.db.loot.find((l) => l.id === r.data.instance_id);
  assert.ok(row && row.item_id === r.data.item_id && row.account_id === 7, 'a loot_instances row the account owns');
  assert.equal(t.state.summons[0].status, 'claimed');
  assert.match((await post(c, 'claim')).json.error, /No Empowered summon/, 'one prize per summon');
});

test('claim can be a legendary set piece (rand 0), with the Gravedigger King at the starter odds', async () => {
  const t = setup();
  const c = t.call({ random: () => 0 });
  await post(c, 'summon', { boss: 'abbess' });
  t.clock.t += 120_000;
  const r = (await post(c, 'claim', { boss: 'abbess', discipline: 'gravecaller', level: 5 })).json;
  assert.equal(r.success, true, r.error);
  assert.equal(r.data.legendary, true);
  assert.match(r.data.item_id, /^leg_/);
});

test('claim is refused: no summon, wrong boss, too soon, expired', async () => {
  const t = setup();
  const c = t.call({ random: () => 0.5 });
  assert.match((await post(c, 'claim')).json.error, /No Empowered summon/);
  await post(c, 'summon');
  assert.match((await post(c, 'claim', { boss: 'abbess' })).json.error, /No Empowered summon/);
  assert.match((await post(c, 'claim')).json.error, /barely woken/, 'a summon-and-claim loop in one breath');
  t.clock.t += 4 * 60 * 60 * 1000;
  assert.match((await post(c, 'claim')).json.error, /No Empowered summon/, 'unclaimed summons expire after three hours');
  assert.equal(t.db.loot.length, 0, 'nothing was minted');
});

test('the prize roll: epic pieces always have three affixes, and the empowered boss is stronger than the normal one', () => {
  let n = 0;
  const rand = () => ((n = (n * 1103515245 + 12345) % 2147483648) / 2147483648);
  for (let i = 0; i < 200; i++) {
    const inst = sinks.rollEmpoweredInstance({ item_id: 'helm_iron', legendary: false }, 'common', 30, rand);
    assert.equal(inst.affixes.length, 3);
    assert.equal(new Set(inst.affixes.map((a) => a.id)).size, 3);
  }
  assert.ok(sinks.empoweredLevel(1) > 1 && sinks.empoweredLevel(255) > 255);
});

test('summon answers its id, and status says which summons are still bound (survives a reload: it is the server row)', async () => {
  const t = setup();
  const c = t.call();
  const made = (await post(c, 'summon')).json.data;
  assert.equal(made.summon_id, 1);
  const st = (await c('POST /api/boss-key/status', { body: { characterId: 1 } })).json.data;
  assert.deepEqual(st.bound, ['gravedigger']);
  assert.deepEqual(st.summons, [{ id: 1, boss: 'gravedigger' }]);
  assert.equal((await post(c, 'summon')).json.data.summon_id, 1, 'the reused summon keeps its id');
  t.clock.t += 4 * 60 * 60 * 1000;
  assert.deepEqual((await c('POST /api/boss-key/status', { body: { characterId: 1 } })).json.data.bound, [], 'expired summons are not offered');
});

test('status refuses someone else\'s character', async () => {
  assert.equal((await setup().call({ owned: false })('POST /api/boss-key/status', { body: { characterId: 1 } })).status, 403);
});

test('AUTHORITY_KILLS off: the claim needs only the 10 s minimum, no reported kill', async () => {
  const t = setup({ mode: 'off' });
  const c = t.call({ random: () => 0.99 });
  await post(c, 'summon');
  t.clock.t += 11_000;
  assert.equal((await post(c, 'claim')).json.success, true);
  assert.equal(t.state.audit.length, 0);
});

test('AUTHORITY_KILLS audit: no reported kill is logged as a finding but still pays', async () => {
  const t = setup({ mode: 'audit' });
  const c = t.call({ random: () => 0.99 });
  await post(c, 'summon');
  t.clock.t += 11_000;
  const r = (await post(c, 'claim')).json;
  assert.equal(r.success, true, r.error);
  assert.equal(t.state.audit.length, 1, 'one boss_key_no_kill finding');
  assert.ok(t.state.audit[0].some((v) => v === 'boss_key_no_kill'));
});

test('AUTHORITY_KILLS audit: a reported kill pays with no finding', async () => {
  const t = setup({ mode: 'audit' });
  const c = t.call({ random: () => 0.99 });
  const { data } = (await post(c, 'summon')).json;
  t.clock.t += 11_000;
  await mountBossKey.markSummonKills(t.db.conn, 1, [{ boss: 'gravedigger', summon: data.summon_id }], { error() {} });
  assert.equal((await post(c, 'claim')).json.success, true);
  assert.equal(t.state.audit.length, 0);
});

test('AUTHORITY_KILLS enforce: no reported kill is refused (summon stays claimable), a reported kill pays', async () => {
  const t = setup({ mode: 'enforce' });
  const c = t.call({ random: () => 0.99 });
  const { data } = (await post(c, 'summon')).json;
  t.clock.t += 11_000;
  const no = (await post(c, 'claim')).json;
  assert.equal(no.success, false);
  assert.match(no.error, /not seen that boss die/);
  assert.equal(t.state.summons[0].status, 'open');
  assert.equal(t.db.loot.length, 0);
  await mountBossKey.markSummonKills(t.db.conn, 1, [{ boss: 'gravedigger', summon: data.summon_id }], { error() {} });
  const yes = (await post(c, 'claim')).json;
  assert.equal(yes.success, true, yes.error);
  assert.equal(t.state.summons[0].status, 'claimed');
});

test('a kill report naming another character\'s, another boss\'s or an unknown summon stamps nothing', async () => {
  const t = setup({ mode: 'enforce' });
  await post(t.call(), 'summon');
  await mountBossKey.markSummonKills(t.db.conn, 2, [{ boss: 'gravedigger', summon: 1 }], { error() {} });
  await mountBossKey.markSummonKills(t.db.conn, 1, [{ boss: 'abbess', summon: 1 }, { boss: 'gravedigger', summon: 99 }, { boss: 'prelate', summon: 1 }, { boss: 'gravedigger' }], { error() {} });
  assert.equal(t.state.summons[0].killed_at, undefined);
  await mountBossKey.markSummonKills(t.db.conn, 1, [{ boss: 'gravedigger', summon: 1 }], { error() {} });
  assert.ok(t.state.summons[0].killed_at);
});

test('a stamped summon is claimed before an unstamped one', async () => {
  const t = setup({ mode: 'enforce', bag: [{ slot_index: 0, item_id: 'covenant_seal', quantity: 1 }] });
  t.state.summons.push({ id: 5, character_id: 1, boss: 'gravedigger', gold: 30000, status: 'open', made: t.clock.t - 60_000 }, { id: 6, character_id: 1, boss: 'gravedigger', gold: 30000, status: 'open', made: t.clock.t - 50_000, killed_at: t.clock.t });
  const r = (await post(t.call({ random: () => 0.99 }), 'claim')).json;
  assert.equal(r.success, true, r.error);
  assert.equal(t.state.summons.find((x) => x.id === 6).status, 'claimed');
});
