'use strict';
// node --test server/vps-handoff/necro-progress/necro-progress.test.cjs
// Exercises the routes end-to-end against the in-memory store (no Express, no MySQL).
const test = require('node:test');
const assert = require('node:assert/strict');
const { createNecroProgressHandlers } = require('./necro-progress-routes.cjs');
const { createMemoryStore } = require('./mysql-store.cjs');

function harness({ gold = 10000, owner = true, staff = false } = {}) {
  const store = createMemoryStore({ 7: gold, 8: 0 });
  const h = createNecroProgressHandlers({ store, ownsCharacter: async (_req, id) => owner && id === 7, isStaff: async () => staff, logger: { error() {} }, perMinute: 1000 });
  const call = async (name, body = {}, params = {}) => {
    let status = 0;
    let json = null;
    const res = { status: (s) => ((status = s), res), json: (j) => ((json = j), res) };
    await h[name]({ body: { characterId: 7, ...body }, params: { characterId: '7', ...params } }, res);
    return { status, json };
  };
  return { store, call };
}

test('GET creates a blank record and returns gold', async () => {
  const { call } = harness();
  const r = await call('get');
  assert.equal(r.status, 200);
  assert.equal(r.json.data.progress.damageTier, 0);
  assert.deepEqual(r.json.data.progress.unlockedAreas, ['chapterhouse', 'graves']);
  assert.equal(r.json.data.gold, 10000);
});

test('ownership and ids are enforced', async () => {
  const { call } = harness({ owner: false });
  assert.equal((await call('get')).status, 403);
  const bad = harness();
  assert.equal((await bad.call('save', { characterId: 'x' })).status, 400);
});

test('purchase deducts gold server-side, atomically, with the right price', async () => {
  const { call, store } = harness({ gold: 100 });
  const r = await call('purchase', { upgrade: 'damage' });
  assert.equal(r.status, 200);
  assert.equal(r.json.data.cost, 40);
  assert.equal(r.json.data.gold, 60);
  assert.equal(store._chars.get(7).gold, 60);
  const r2 = await call('purchase', { upgrade: 'damage' }); // 60 → costs 60
  assert.equal(r2.json.data.progress.damageTier, 2);
  const broke = await call('purchase', { upgrade: 'damage' });
  assert.equal(broke.status, 400);
  assert.match(broke.json.error, /Not enough gold/);
  assert.equal((await call('purchase', { upgrade: 'teleport' })).status, 400);
});

test('saves clamp deltas and open seals from kills; locked areas earn nothing', async () => {
  const { call } = harness();
  const r = await call('save', { areaKills: { graves: 310, nave: 500, chapterhouse: 9 }, shards: 3, peakWaveTier: 5 });
  const p = r.json.data.progress;
  assert.equal(p.areaKills.graves, 310);
  assert.equal(p.areaKills.nave, undefined, 'nave is sealed');
  assert.equal(p.areaKills.chapterhouse, undefined, 'no kills in the sanctuary');
  assert.ok(p.unlockedAreas.includes('ossuary'));
  assert.equal(p.soulShards, 3);
  assert.equal(p.run.peakWaveTier, 0, 'peak is capped by owned tiers');
  const flood = await call('save', { areaKills: { graves: 1e9 }, shards: 1e9 });
  assert.ok(flood.json.data.progress.areaKills.graves <= 310 + 900);
  assert.ok(flood.json.data.progress.soulShards <= 3 + 30);
});

test('Prelate kills must follow a paid summon', async () => {
  const { call } = harness();
  let r = await call('save', { prelateKills: 1 });
  assert.equal(r.json.data.progress.bossKills, 0, 'no summon, no kill');
  r = await call('summonPrelate');
  assert.equal(r.status, 400, 'no shards / sanctum sealed');
  await call('importLocal', { record: { areaKills: { graves: 300, ossuary: 420, nave: 520 }, shards: 5 } });
  r = await call('summonPrelate');
  assert.equal(r.status, 200);
  assert.equal(r.json.data.progress.soulShards, 0);
  r = await call('save', { prelateKills: 3 });
  assert.equal(r.json.data.progress.bossKills, 1, 'one summon, one kill');
  assert.equal(r.json.data.progress.run.prelateKills, 1);
});

test('area-boss summons charge their own cost, need their area, and owe no Prelate kill', async () => {
  const { call } = harness();
  let r = await call('summonBoss', { boss: 'abbess' });
  assert.equal(r.status, 400, 'no shards');
  await call('importLocal', { record: { areaKills: { graves: 300 }, shards: 5 } });
  r = await call('summonBoss', { boss: 'congregation' });
  assert.equal(r.status, 400, 'the Nave is still sealed');
  r = await call('summonBoss', { boss: 'gravedigger' });
  assert.equal(r.status, 200);
  assert.equal(r.json.data.progress.soulShards, 3, 'the King costs 2');
  assert.equal(r.json.data.progress.summonsPending, 0, 'no Prelate summon is owed');
  r = await call('summonBoss', { boss: 'prelate' });
  assert.equal(r.status, 400, 'the Prelate keeps its own route');
});

test('staff (dev access) stand past every seal without their save changing; players still unlock with kills', async () => {
  const dev = harness({ staff: true });
  await dev.call('importLocal', { record: { areaKills: { graves: 10 }, shards: 20 } });
  let r = await dev.call('save', { areaKills: { cloister: 40, chapterhouse: 5 } });
  assert.equal(r.json.data.progress.areaKills.cloister, 40, 'dev kills count in a sealed area');
  assert.equal(r.json.data.progress.areaKills.chapterhouse, undefined, 'still none in the sanctuary');
  assert.ok(!r.json.data.progress.unlockedAreas.includes('cloister'), 'the saved seals are untouched');
  r = await dev.call('summonBoss', { boss: 'saint' });
  assert.equal(r.status, 200, 'dev summons the Saint in a sealed area');
  assert.equal(r.json.data.progress.soulShards, 15, 'and still pays for it');
  r = await dev.call('summonPrelate');
  assert.equal(r.status, 200);
  const player = harness();
  await player.call('importLocal', { record: { areaKills: { graves: 10 }, shards: 20 } });
  r = await player.call('summonBoss', { boss: 'saint' });
  assert.equal(r.status, 400, 'a player needs the Cloister open');
  r = await player.call('save', { areaKills: { cloister: 40 } });
  assert.equal(r.json.data.progress.areaKills.cloister, undefined);
});

test('Ascend and boons are server rules', async () => {
  const { call } = harness();
  assert.equal((await call('ascend')).status, 400);
  await call('importLocal', { record: { areaKills: { graves: 300, ossuary: 420, nave: 520 }, shards: 5, damageTier: 9 } });
  await call('summonPrelate');
  await call('save', { prelateKills: 1 });
  const a = await call('ascend');
  assert.equal(a.status, 200);
  assert.ok(a.json.data.earned > 0);
  const p = a.json.data.progress;
  assert.equal(p.ascension, 1);
  assert.equal(p.damageTier, 0);
  assert.deepEqual(p.unlockedAreas, ['chapterhouse', 'graves']);
  const b = await call('boon', { boonId: 'vigil' });
  assert.equal(b.status, 200);
  assert.equal(b.json.data.progress.boons.vigil, 1);
  assert.equal((await call('boon', { boonId: 'legion_pact' })).status, 400, 'rank gate');
  assert.equal((await call('boon', { boonId: 'nope' })).status, 400);
});

test('the browser import runs once and is clamped', async () => {
  const { call } = harness();
  const r = await call('importLocal', {
    record: { damageTier: 999, waveTierOwned: 99, shards: 1e6, ascension: 50, ashes: 1e9, areaKills: { graves: 50 }, unlocked: ['sanctum'], boons: { legion_pact: 1, vigil: 9 } },
  });
  const p = r.json.data.progress;
  assert.equal(p.damageTier, 25);
  assert.equal(p.waveTierOwned, 8);
  assert.equal(p.soulShards, 40);
  assert.equal(p.ascension, 5);
  assert.equal(p.ashes, 400);
  assert.deepEqual(p.unlockedAreas, ['chapterhouse', 'graves'], 'seals come from kills, not the browser');
  assert.equal(p.boons.vigil, 3);
  assert.equal(p.boons.legion_pact, 1, 'allowed: imported rank 5 ≥ 3');
  assert.equal(p.migrated, true);
  const again = await call('importLocal', { record: { damageTier: 1 } });
  assert.equal(again.status, 400);
});

test('unknown character → 404', async () => {
  const store = createMemoryStore({});
  const h = createNecroProgressHandlers({ store, ownsCharacter: async () => true, logger: { error() {} } });
  let status = 0;
  const res = { status: (s) => ((status = s), res), json: () => res };
  await h.get({ params: { characterId: '99' }, body: {} }, res);
  assert.equal(status, 404);
});
