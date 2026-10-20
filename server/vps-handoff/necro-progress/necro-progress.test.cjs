'use strict';
// node --test server/vps-handoff/necro-progress/necro-progress.test.cjs
// Exercises the routes end-to-end against the in-memory store (no Express, no MySQL).
const test = require('node:test');
const assert = require('node:assert/strict');
const { createNecroProgressHandlers } = require('./necro-progress-routes.cjs');
const { createMemoryStore } = require('./mysql-store.cjs');
const rules = require('./necro-rules.cjs');

const BLANK = rules.blankState();
const LIMITS = rules.NECRO_LIMITS;
/** Kills in every ground up to the Nave, enough to stand past each seal on the way to the Bell Sanctum (an import is capped at LIMITS.importMaxAreaKills). */
const OPEN_TO_SANCTUM = { graves: LIMITS.importMaxAreaKills, ossuary: LIMITS.importMaxAreaKills, nave: LIMITS.importMaxAreaKills };
/** How many tiers an upgrade has: the count until its price is gone. */
const tiers = (cost, key) => { let n = 0; while (cost({ ...BLANK, [key]: n }) !== null) n++; return n; };
/** The soul shards a summon / unlock asks, read from the refusal a blank character gets (the rules price it, never the test). */
const asked = (r) => Number(/(?:demands|asks) (\d+) soul shards/.exec(r.json.error)[1]);

function harness({ gold = 10000, owner = true, staff = false, partyOpen } = {}) {
  const store = createMemoryStore({ 7: gold, 8: 0 });
  let staffNow = staff;
  const h = createNecroProgressHandlers({ store, ownsCharacter: async (_req, id) => owner && id === 7, isStaff: async () => staffNow, partyOpen, logger: { error() {} }, perMinute: 1000 });
  const call = async (name, body = {}, params = {}) => {
    let status = 0;
    let json = null;
    const res = { status: (s) => ((status = s), res), json: (j) => ((json = j), res) };
    await h[name]({ body: { characterId: 7, ...body }, params: { characterId: '7', ...params } }, res);
    return { status, json };
  };
  /** Test setup: a record carried over the way only GM mode may (a player's import starts blank). */
  const seed = async (record) => {
    staffNow = true;
    const r = await call('importLocal', { record });
    staffNow = staff;
    return r;
  };
  return { store, call, seed };
}

test('GET creates a blank record and returns gold', async () => {
  const { call } = harness();
  const r = await call('get');
  assert.equal(r.status, 200);
  assert.equal(r.json.data.progress.damageTier, 0);
  assert.deepEqual(r.json.data.progress.unlockedAreas, BLANK.unlockedAreas);
  assert.equal(r.json.data.gold, 10000);
});

test('ownership and ids are enforced', async () => {
  const { call } = harness({ owner: false });
  assert.equal((await call('get')).status, 403);
  const bad = harness();
  assert.equal((await bad.call('save', { characterId: 'x' })).status, 400);
});

test('purchase deducts gold server-side, atomically, with the right price', async () => {
  const first = rules.damageCost(BLANK);
  const second = rules.damageCost({ ...BLANK, damageTier: 1 });
  const { call, store } = harness({ gold: first + second });
  const r = await call('purchase', { upgrade: 'damage' });
  assert.equal(r.status, 200);
  assert.equal(r.json.data.cost, first);
  assert.equal(r.json.data.gold, second);
  assert.equal(store._chars.get(7).gold, second);
  const r2 = await call('purchase', { upgrade: 'damage' }); // exactly the second price
  assert.equal(r2.json.data.progress.damageTier, 2);
  assert.equal(r2.json.data.gold, 0);
  const broke = await call('purchase', { upgrade: 'damage' });
  assert.equal(broke.status, 400);
  assert.match(broke.json.error, /Not enough gold/);
  assert.equal((await call('purchase', { upgrade: 'teleport' })).status, 400);
});

test('Legion reinforcement: the server prices each tier, takes the gold atomically and stops at the top', async () => {
  const price = (tier) => rules.legionCost({ ...BLANK, legionTier: tier });
  const [c1, c2, c3] = [price(0), price(1), price(2)];
  const { call, store } = harness({ gold: c1 + c2 + c3 - 1 });   // two tiers, and one gold short of the third
  const r = await call('purchase', { upgrade: 'legion' });
  assert.equal(r.status, 200);
  assert.deepEqual([r.json.data.cost, r.json.data.gold, r.json.data.progress.legionTier], [c1, c2 + c3 - 1, 1]);
  const r2 = await call('purchase', { upgrade: 'legion' });
  assert.deepEqual([r2.json.data.cost, r2.json.data.gold, r2.json.data.progress.legionTier], [c2, c3 - 1, 2]);
  assert.equal(store._chars.get(7).gold, c3 - 1);
  const poor = await call('purchase', { upgrade: 'legion' });
  assert.equal(poor.status, 400);
  assert.match(poor.json.error, new RegExp(`Not enough gold \\(need ${c3}\\)`));
  assert.equal(store._chars.get(7).gold, c3 - 1, 'a refused buy takes nothing');
  assert.equal((await call('get')).json.data.progress.legionTier, 2);
});

test('Legion reinforcement stops at its top tier', async () => {
  const top = tiers(rules.legionCost, 'legionTier');
  const { call } = harness({ gold: 1e9 });
  let last;
  for (let i = 0; i < top; i++) last = await call('purchase', { upgrade: 'legion' });
  assert.equal(last.json.data.progress.legionTier, top);
  const over = await call('purchase', { upgrade: 'legion' });
  assert.equal(over.status, 400);
  assert.match(over.json.error, /max tier/);
});

test('saves clamp deltas and open seals from kills; locked areas earn nothing', async () => {
  const { call } = harness();
  const enough = rules.unlockKills(BLANK, 'ossuary') + 10;   // past the Hollow Graves' seal, inside one save
  assert.ok(enough <= LIMITS.killsPerSave);
  const r = await call('save', { areaKills: { graves: enough, nave: 500, chapterhouse: 9 }, shards: 3, peakWaveTier: 5 });
  const p = r.json.data.progress;
  assert.equal(p.areaKills.graves, enough);
  assert.equal(p.areaKills.nave, undefined, 'nave is sealed');
  assert.equal(p.areaKills.chapterhouse, undefined, 'no kills in the sanctuary');
  assert.ok(p.unlockedAreas.includes('ossuary'));
  assert.equal(p.soulShards, 3);
  assert.equal(p.run.peakWaveTier, 0, 'peak is capped by owned tiers');
  const flood = await call('save', { areaKills: { graves: 1e9 }, shards: 1e9 });
  assert.ok(flood.json.data.progress.areaKills.graves <= enough + LIMITS.killsPerSave);
  assert.ok(flood.json.data.progress.soulShards <= 3 + LIMITS.shardsPerSave);
});

test('Prelate kills must follow a paid summon', async () => {
  const { call, seed } = harness();
  let r = await call('save', { prelateKills: 1 });
  assert.equal(r.json.data.progress.bossKills, 0, 'no summon, no kill');
  r = await call('summonPrelate');
  assert.equal(r.status, 400, 'no shards / sanctum sealed');
  const price = asked(r);
  await seed({ areaKills: OPEN_TO_SANCTUM, shards: price });
  r = await call('summonPrelate');
  assert.equal(r.status, 200);
  assert.equal(r.json.data.progress.soulShards, 0);
  r = await call('save', { prelateKills: 3 });
  assert.equal(r.json.data.progress.bossKills, 1, 'one summon, one kill');
  assert.equal(r.json.data.progress.run.prelateKills, 1);
});

test('area-boss summons charge their own cost, need their area, and owe no Prelate kill', async () => {
  const { call, seed } = harness();
  let r = await call('summonBoss', { boss: 'abbess' });
  assert.equal(r.status, 400, 'no shards');
  const king = asked(await call('summonBoss', { boss: 'gravedigger' }));
  await seed({ areaKills: { graves: LIMITS.importMaxAreaKills }, shards: LIMITS.importMaxShards });
  r = await call('summonBoss', { boss: 'congregation' });
  assert.equal(r.status, 400, 'the Nave is still sealed');
  r = await call('summonBoss', { boss: 'gravedigger' });
  assert.equal(r.status, 200);
  assert.equal(r.json.data.progress.soulShards, LIMITS.importMaxShards - king, 'the King costs its own price');
  assert.equal(r.json.data.progress.summonsPending, 0, 'no Prelate summon is owed');
  r = await call('summonBoss', { boss: 'prelate' });
  assert.equal(r.status, 400, 'the Prelate keeps its own route');
});

test('staff (dev access) stand past every seal without their save changing; players still unlock with kills', async () => {
  const saint = asked(await harness().call('summonBoss', { boss: 'saint' }));
  const dev = harness({ staff: true });
  await dev.call('importLocal', { record: { areaKills: { graves: 10 }, shards: LIMITS.importMaxShards } });
  let r = await dev.call('save', { areaKills: { cloister: 40, chapterhouse: 5 } });
  assert.equal(r.json.data.progress.areaKills.cloister, 40, 'dev kills count in a sealed area');
  assert.equal(r.json.data.progress.areaKills.chapterhouse, undefined, 'still none in the sanctuary');
  assert.ok(!r.json.data.progress.unlockedAreas.includes('cloister'), 'the saved seals are untouched');
  r = await dev.call('summonBoss', { boss: 'saint' });
  assert.equal(r.status, 200, 'dev summons the Saint in a sealed area');
  assert.equal(r.json.data.progress.soulShards, LIMITS.importMaxShards - saint, 'and still pays for it');
  r = await dev.call('summonPrelate');
  assert.equal(r.status, 200);
  const player = harness();
  await player.call('importLocal', { record: { areaKills: { graves: 10 }, shards: LIMITS.importMaxShards } });
  r = await player.call('summonBoss', { boss: 'saint' });
  assert.equal(r.status, 400, 'a player needs the Cloister open');
  r = await player.call('save', { areaKills: { cloister: 40 } });
  assert.equal(r.json.data.progress.areaKills.cloister, undefined);
});

test('a party guest wakes a boss of its host\'s world with its own shards; only for summons, only a party the server knows (B68)', async () => {
  const SID = 'ab'.repeat(16);
  const HOST_OPEN = ['chapterhouse', 'graves', 'cloister', 'sanctum'];
  const asks = [];
  const { call, seed } = harness({ partyOpen: async (cid, sid) => { asks.push([cid, sid]); return sid === SID ? HOST_OPEN : []; } });
  const saint = asked(await call('summonBoss', { boss: 'saint' }));   // (a blank record: the price, before any seal is asked about)
  const bell = asked(await call('summonPrelate'));
  await seed({ areaKills: { graves: 10 }, shards: LIMITS.importMaxShards });
  let r = await call('summonBoss', { boss: 'saint' });
  assert.equal(r.status, 400, 'its own world: the Cloister is sealed to it');
  assert.deepEqual(asks, [], 'a summon that names no party looks nothing up');
  r = await call('summonBoss', { boss: 'saint', sessionId: 'cd'.repeat(16) });
  assert.equal(r.status, 400, 'a party the server does not know it in changes nothing');
  r = await call('summonBoss', { boss: 'saint', sessionId: SID });
  assert.equal(r.status, 200, 'in its host\'s world it may');
  assert.deepEqual(asks.at(-1), [7, SID], 'the server asked about this character in that party');
  assert.equal(r.json.data.progress.soulShards, LIMITS.importMaxShards - saint, 'and it pays its own shards');
  assert.ok(!r.json.data.progress.unlockedAreas.includes('cloister'), 'its own seals stay as they are');
  r = await call('summonPrelate', { sessionId: SID });
  assert.equal(r.status, 200, 'the Prelate\'s bell too');
  assert.equal(r.json.data.progress.soulShards, LIMITS.importMaxShards - saint - bell);
  r = await call('summonBoss', { boss: 'regent', sessionId: SID });
  assert.equal(r.status, 400, 'an area its host has not opened either stays sealed');
  const n = asks.length;
  r = await call('save', { areaKills: { cloister: 40 }, sessionId: SID });
  assert.equal(r.json.data.progress.areaKills.cloister, undefined, 'a save is not a summon: the party opens nothing for it');
  assert.equal(asks.length, n, 'and looks nothing up');
});

test('Ascend and boons are server rules', async () => {
  const { call, seed } = harness();
  assert.equal((await call('ascend')).status, 400);
  const price = asked(await call('summonPrelate'));
  await seed({ areaKills: OPEN_TO_SANCTUM, shards: price, damageTier: 9, ashes: LIMITS.importMaxAshes });
  await call('summonPrelate');
  await call('save', { prelateKills: 1 });
  const a = await call('ascend');
  assert.equal(a.status, 200);
  assert.ok(a.json.data.earned > 0);
  const p = a.json.data.progress;
  assert.equal(p.ascension, 0, 'no vows sworn: heat 0, best rank stays 0');
  assert.equal(p.damageTier, 0);
  assert.ok(p.unlockedAreas.includes('sanctum'), 'seals do not reset on Ascension');
  assert.deepEqual(p.vows, {});
  const b = await call('boon', { boonId: 'vigil' });
  assert.equal(b.status, 200);
  assert.equal(b.json.data.progress.boons.vigil, 1);
  assert.equal((await call('boon', { boonId: 'legion_pact' })).status, 400, 'rank gate');
  assert.equal((await call('boon', { boonId: 'nope' })).status, 400);
});

test('vows: sworn server-side, validated, and the run restarts only when the vows change mid-run', async () => {
  const { call, seed } = harness();
  const price = asked(await call('summonPrelate'));
  await seed({ areaKills: OPEN_TO_SANCTUM, shards: price });
  assert.equal((await call('vows', { vows: { bogus: 1 } })).status, 400);
  assert.equal((await call('vows', { vows: { elder_dead: 1e6 } })).status, 400);
  assert.equal((await call('vows', { vows: { prelate_echo: 1 } })).status, 400, 'locked');
  assert.equal((await call('vows', {})).status, 400, 'a vow set is required');
  const r = await call('vows', { vows: { elder_dead: 1, iron_dead: 1 }, heat: -5, ashes: 99 });
  assert.equal(r.status, 200);
  assert.deepEqual(r.json.data.progress.vows, { elder_dead: 1, iron_dead: 1 });
  assert.equal(r.json.data.progress.ashes, 0, 'client extras are ignored');
  await call('summonPrelate');
  await call('save', { prelateKills: 1 });
  const same = await call('vows', { vows: { iron_dead: 1, elder_dead: 1 } });
  assert.equal(same.json.data.progress.run.prelateKills, 1, 'same vows: the tally stands');
  const changed = await call('vows', { vows: { elder_dead: 1 } });
  assert.equal(changed.json.data.progress.run.prelateKills, 0, 'changed mid-run: the tally restarts');
});

test('soul shards unlock vows and boons, priced by the server', async () => {
  const { call, seed } = harness();
  const refused = await call('unlock', { key: 'vow:prelate_echo' });
  assert.equal(refused.status, 400, 'no shards');
  const cost = asked(refused);
  await seed({ areaKills: { graves: 50 }, shards: LIMITS.importMaxShards });
  // earn the price at the most a save may bring
  let held = LIMITS.importMaxShards;
  for (let i = 0; held < cost && i < Math.ceil(cost / LIMITS.shardsPerSave) + 5; i++) held = (await call('save', { shards: LIMITS.shardsPerSave })).json.data.progress.soulShards;
  assert.ok(held >= cost, 'the shards were earned');
  assert.equal((await call('unlock', { key: 'vow:elder_dead' })).status, 400, 'free vows need no unlock');
  assert.equal((await call('unlock', { key: 'vow:nope' })).status, 400);
  assert.equal((await call('boon', { boonId: 'bonded_dead' })).status, 400, 'locked boon');
  const r = await call('unlock', { key: 'vow:prelate_echo', cost: 1 });
  assert.equal(r.status, 200);
  assert.equal(r.json.data.cost, cost, 'client-sent cost is ignored');
  assert.equal(r.json.data.progress.soulShards, held - cost);
  assert.deepEqual(r.json.data.progress.unlocks, ['vow:prelate_echo']);
  assert.equal((await call('unlock', { key: 'vow:prelate_echo' })).status, 400, 'once only');
  assert.equal((await call('vows', { vows: { prelate_echo: 1 } })).status, 200);
});

test('an existing row without vows loads as N steps of Elder Dead, keeping rank, Ashes and boons', async () => {
  const { call, store } = harness();
  await store.withLock(7, (state) => ({ state: { ...state, ascension: 2, ashes: 9, boons: { vigil: 2 }, vows: undefined, unlocks: undefined } }));
  const r = await call('get');
  const p = r.json.data.progress;
  assert.equal(p.ascension, 2);
  assert.equal(p.ashes, 9);
  assert.deepEqual(p.boons, { vigil: 2 });
  assert.deepEqual(p.vows, { elder_dead: 2 });
  assert.deepEqual(p.unlocks, []);
});

test('a player\'s import starts from a blank record: the client\'s local record is not proof of play', async () => {
  const { call } = harness();
  const r = await call('importLocal', { record: { damageTier: 9, shards: 40, ascension: 5, areaKills: { graves: 300 }, boons: { vigil: 3 } } });
  assert.equal(r.status, 200);
  const p = r.json.data.progress;
  assert.deepEqual([p.damageTier, p.soulShards, p.ascension, p.areaKills.graves, p.boons.vigil], [0, 0, 0, undefined, undefined]);
  assert.equal(p.migrated, true);
  assert.equal((await call('importLocal', { record: {} })).status, 400, 'still once');
});

test('a GM-mode import runs once and is clamped', async () => {
  const { call } = harness({ staff: true });
  const r = await call('importLocal', {
    record: { damageTier: 999, waveTierOwned: 99, shards: 1e6, ascension: 50, ashes: 1e9, areaKills: { graves: 50 }, unlocked: ['sanctum'], boons: { legion_pact: 1, vigil: 99 } },
  });
  const p = r.json.data.progress;
  assert.equal(p.damageTier, tiers(rules.damageCost, 'damageTier'), 'held to the top damage tier');
  assert.equal(p.waveTierOwned, tiers(rules.waveCost, 'waveTierOwned'), 'held to the top Wave Speed tier');
  assert.equal(p.soulShards, LIMITS.importMaxShards);
  assert.equal(p.ascension, LIMITS.importMaxAscension);
  assert.equal(p.ashes, LIMITS.importMaxAshes);
  assert.deepEqual(p.unlockedAreas, BLANK.unlockedAreas, 'seals come from kills, not the browser');
  assert.ok(p.boons.vigil > 0 && p.boons.vigil < 99, 'a boon is held to its top rank');
  assert.equal(p.boons.legion_pact, 1, 'allowed: the imported rank clears its gate');
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
