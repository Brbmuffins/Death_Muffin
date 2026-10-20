'use strict';
// node --test server/death-muffin/backend/drops.test.cjs
const test = require('node:test');
const assert = require('node:assert/strict');
const rules = require('./gathering/loot-rules.cjs');
const { issueTape, claimDrop, creditSummon, summonCredits, seedFor, tapeKey, AHEAD, SLACK } = require('./drops.cjs');

const ENV = { JWT_SECRET: 'test-secret', DROPS_MODE: 'audit' };
const ENFORCE = { JWT_SECRET: 'test-secret' };   // enforce is the default
const quiet = { error() {}, warn() {} };

/** An in-memory slice of the tables drops.cjs touches. */
function fakeDb({ level = 30, cls = 2, unlocked = ['chapterhouse', 'graves', 'ossuary'], waveOwned = 0, kills = 1000, bosses = 10, floors = 50, depth = 12, ledger = true } = {}) {
  const db = {
    character: { id: 1, account_id: 7, level, cls },
    tape: null,
    events: new Map(),
    inv: [],
    runes: [],
    vault: [],
    instances: [],
    audit: [],
    ledger: ledger ? { kills_total: kills, bosses_total: bosses, floors_total: floors, depth_proved: depth } : null,
    necro: { unlockedAreas: unlocked, waveTierOwned: waveOwned, vows: {} },
  };
  const evKey = (p) => `${p[0]}|${p[1]}|${p[2]}`;
  const run = async (sql, p = []) => {
    const q = sql.replace(/\s+/g, ' ').trim();
    if (q.startsWith('SELECT id, account_id, level, COALESCE')) return [[db.character]];
    if (q.startsWith('SELECT issued, spent')) return [db.tape ? [db.tape] : []];
    if (q.startsWith('INSERT IGNORE INTO character_drop_tape')) {
      db.tape ??= { issued: p[1], spent: p[2], base_kills: p[3], base_bosses: p[4], base_floors: p[5], boss_credit: 0, last_rune_elite: -1, last_surge_at: 0 };
      return [{}];
    }
    if (q.startsWith('UPDATE character_drop_tape')) {
      Object.assign(db.tape, { issued: p[0], spent: p[1], base_kills: p[2], base_bosses: p[3], base_floors: p[4], last_rune_elite: p[5], last_surge_at: p[6] });
      return [{}];
    }
    if (q.startsWith('SELECT kills_total, bosses_total')) return [db.ledger ? [db.ledger] : []];
    if (q.startsWith('SELECT facts, items, claimed')) { const e = db.events.get(evKey(p)); return [e ? [e] : []]; }
    if (q.startsWith('INSERT INTO character_drop_events')) { db.events.set(evKey(p), { facts: p[3], items: p[4], claimed: p[5], rune_claimed: 0 }); return [{}]; }
    if (q.startsWith('UPDATE character_drop_events SET claimed')) {
      const e = db.events.get(evKey([p[1], p[2], p[3]]));
      e.claimed = p[0];
      if (q.includes('rune_claimed = 1')) e.rune_claimed = 1;
      return [{}];
    }
    if (q.startsWith('SELECT MAX(n) AS n FROM character_drop_events')) {
      const ns = [...db.events.entries()].filter(([k, e]) => k.startsWith(`${p[0]}|elite|`) && e.rune_claimed === 1 && Number(k.split('|')[2]) < p[1]).map(([k]) => Number(k.split('|')[2]));
      return [[{ n: ns.length ? Math.max(...ns) : null }]];
    }
    if (q.startsWith('SELECT COUNT(*) AS n FROM character_drop_events')) {
      const n = [...db.events.entries()].filter(([k, e]) => k.startsWith(`${p[0]}|boss|`) && JSON.parse(e.facts).boss === p[1] && JSON.parse(e.facts).first === true).length;
      return [[{ n }]];
    }
    if (q.startsWith('SELECT state FROM character_necro_progress')) return [[{ state: JSON.stringify(db.necro) }]];
    if (q.startsWith('SELECT life FROM character_chronicle')) return [[]];
    if (q.startsWith("SELECT item_id FROM inventory WHERE character_id = ? AND item_id LIKE 'leg")) return [db.inv.filter((r) => r.item_id.startsWith('leg_')).map((r) => ({ item_id: r.item_id }))];
    if (q.startsWith('SELECT COUNT(*) AS n FROM character_runes')) return [[{ n: db.runes.includes(p[1]) ? 1 : 0 }]];
    if (q.startsWith('SELECT COUNT(*) AS n FROM inventory WHERE character_id = ? AND item_id = ?')) return [[{ n: db.inv.filter((r) => r.item_id === p[1]).length }]];
    if (q.startsWith('SELECT COUNT(*) AS n FROM account_vault')) return [[{ n: db.vault.includes(p[1]) ? 1 : 0 }]];
    if (q.startsWith('SELECT stackable, max_stack_size FROM items')) return [[{ stackable: rules.canRoll(p[0]) ? 0 : 1, max_stack_size: rules.canRoll(p[0]) ? 1 : 250 }]];
    if (q.startsWith('SELECT id, slot_index, item_id, quantity, instance_id FROM inventory')) return [db.inv.filter((r) => r.slot_index <= p[1])];
    if (q.startsWith('INSERT INTO loot_instances')) { db.instances.push({ item: p[1], ilvl: p[2], affixes: p[3] }); return [{ insertId: db.instances.length }]; }
    if (q.startsWith('INSERT INTO inventory')) {
      db.inv.push({ id: db.inv.length + 1, slot_index: p[1], item_id: p[2], quantity: q.includes('instance_id') ? 1 : p[3], instance_id: q.includes('instance_id') ? p[3] : null });
      return [{}];
    }
    if (q.startsWith('UPDATE inventory SET quantity = quantity +')) { db.inv.find((r) => r.id === p[1]).quantity += p[0]; return [{}]; }
    if (q.startsWith('INSERT INTO progress_audit')) { db.audit.push({ kind: p[2], mode: p[3], action: p[4], detail: JSON.parse(p[5]) }); return [{}]; }
    if (q.startsWith('SELECT inv.id, inv.slot_index')) return [db.inv];
    throw new Error(`fake db: unexpected ${q.slice(0, 90)}`);
  };
  const conn = { execute: run, query: run, beginTransaction: async () => {}, commit: async () => {}, rollback: async () => {}, release: () => {} };
  return { db, pool: { execute: run, query: run, getConnection: async () => conn } };
}

const roll = (kind, n, facts, env = ENV) => rules.rollEvent(kind, facts, rules.eventStreams(kind, seedFor(tapeKey(env), 1, kind, n))).items;
/**
 * A tape (the secret is the test's own input) in which `find(roll)` turns something up. Which elite sheds a rune, and which floor clear
 * drops, depends on the drop chances, so a scenario that needs one hunts a tape that has it instead of trusting today's chances.
 */
function huntTape(find, extraEnv = { DROPS_MODE: 'audit' }) {
  for (let i = 0; i < 500; i++) {
    const env = { JWT_SECRET: `hunt-${i}`, ...extraEnv };
    const hit = find((kind, n, facts) => roll(kind, n, facts, env));
    if (hit) return { env, hit };
  }
  throw new Error('no tape in 500 has what the scenario needs');
}
const killFacts = (over = {}) => ({ def: 'robber', area: 'graves', level: 12, waveTier: 0, difficulty: 'medium', itemChanceMult: 1, ...over });
/** The first index of `kind` whose server roll drops something (with these facts), scanning from 0. */
function firstDropping(kind, facts, ctx = { characterLevel: 30, disciplineId: 'gravecaller', owned: [] }) {
  for (let n = 0; n < AHEAD[kind]; n++) {
    const items = roll(kind, n, { ...facts, ...ctx });
    if (items.length) return { n, items };
  }
  throw new Error('no drop in the tape');
}
const claim = (f, body, env = ENV) => claimDrop(f.pool, { characterId: 1, accountId: 7, body: { characterId: 1, ...body }, env, now: 1_000_000, log: quiet });

test('the tape deals the next seeds of every kind, derived from the secret, and never before what is spent', async () => {
  const f = fakeDb();
  const a = await issueTape(f.pool, { characterId: 1, env: ENV });
  assert.equal(a.mode, 'audit');
  for (const kind of rules.DROP_KINDS) {
    assert.equal(a.tape[kind].from, 0);
    assert.equal(a.tape[kind].seeds.length, AHEAD[kind]);
    assert.deepEqual(a.tape[kind].seeds[3], seedFor(tapeKey(ENV), 1, kind, 3));
  }
  const ahead = AHEAD.kill;
  const b = await issueTape(f.pool, { characterId: 1, next: { kill: ahead - 1 }, env: ENV });
  assert.equal(b.tape.kill.from, ahead - 1, 'the client says where it is');
  const c = await issueTape(f.pool, { characterId: 1, next: { kill: 99999 }, env: ENV });
  assert.ok(c.tape.kill.from <= ahead + b.tape.kill.from, 'never past what was dealt (the first deal plus the second)');
  assert.notDeepEqual(seedFor(tapeKey(ENV), 1, 'kill', 0), seedFor(tapeKey({ JWT_SECRET: 'other' }), 1, 'kill', 0), 'another secret, another tape');
});

test('a claim grants exactly the server roll of that event, once, into the bag', async () => {
  const f = fakeDb();
  await issueTape(f.pool, { characterId: 1, env: ENV });
  const { n, items } = firstDropping('kill', killFacts());
  const r = await claim(f, { kind: 'kill', n, index: 0, facts: killFacts(), expect: items[0].item_id });
  assert.equal(r.body.success, true, JSON.stringify(r.body));
  assert.equal(r.body.data.item.item_id, items[0].item_id);
  assert.ok(f.db.inv.some((row) => row.item_id === items[0].item_id));
  const again = await claim(f, { kind: 'kill', n, index: 0, facts: killFacts() });
  assert.match(again.body.error, /already picked up/);
  const beyond = await claim(f, { kind: 'kill', n: AHEAD.kill + 5, index: 0, facts: killFacts() });
  assert.match(beyond.body.error, /never dealt/);
  assert.deepEqual(f.db.audit, [], 'an honest claim leaves no finding');
});

test('what the client says dropped does not matter: a different item is logged and the server roll is granted', async () => {
  const f = fakeDb();
  await issueTape(f.pool, { characterId: 1, env: ENV });
  const { n, items } = firstDropping('kill', killFacts());
  const r = await claim(f, { kind: 'kill', n, index: 0, facts: killFacts(), expect: 'leg_legion_unburied_head' });
  assert.equal(r.body.data.item.item_id, items[0].item_id);
  assert.equal(f.db.audit[0].kind, 'drop_mismatch');
});

test('facts the server knows are its own: another discipline or level in the claim does not change the roll', async () => {
  const f = fakeDb({ cls: 2, level: 30 });
  await issueTape(f.pool, { characterId: 1, env: ENV });
  const { n, items } = firstDropping('kill', killFacts());
  const r = await claim(f, { kind: 'kill', n, index: 0, facts: { ...killFacts(), disciplineId: 'ossuary', characterLevel: 999, owned: ['x'] } });
  assert.equal(r.body.data.item.item_id, items[0].item_id);
});

test('broken bounds are findings: audit lets the claim through clamped, enforce refuses it', async () => {
  const facts = killFacts({ area: 'nave', def: 'robber', itemChanceMult: 5, waveTier: 8 });   // the Nave needs the Ossuary open (the Graves alone open only the Ossuary's seal)
  const fresh = async (env, n) => {
    const f = fakeDb({ unlocked: ['chapterhouse', 'graves'] });
    await issueTape(f.pool, { characterId: 1, env });
    return { f, r: await claim(f, { kind: 'kill', n, index: 0, facts }, env) };
  };
  const kinds = (f) => f.db.audit.map((a) => a.kind).sort();
  // audit: the first kill in the tape that drops something once the claim is clamped to its bounds goes through
  let granted = null;
  for (let n = 0; n < AHEAD.kill && !granted; n++) {
    const { f, r } = await fresh(ENV, n);
    if (r.body.success) granted = { f, n };
  }
  assert.ok(granted, 'some kill in the tape drops something');
  assert.deepEqual(kinds(granted.f), ['drop_area', 'drop_fortune', 'drop_wave']);
  // enforce: the same broken claim is refused and nothing is granted
  const { f: e, r: refused } = await fresh(ENFORCE, 0);
  assert.equal(refused.body.success, false, JSON.stringify(refused.body));
  assert.deepEqual(kinds(e), ['drop_area', 'drop_fortune', 'drop_wave']);
  assert.equal(e.db.inv.length, 0, 'enforce: nothing granted');
});

test('the tape is spent no faster than the kill ledger accepts kills', async () => {
  const f = fakeDb({ kills: 0 });
  await issueTape(f.pool, { characterId: 1, env: ENFORCE });
  f.db.ledger.kills_total = 0;
  const r = await claim(f, { kind: 'kill', n: SLACK.kills, index: 0, facts: killFacts() }, ENFORCE);   // one kill more than the slack allows, none reported
  assert.equal(r.body.success, false);
  assert.equal(f.db.audit[0].kind, 'drop_budget');
  assert.deepEqual(r.body.resync, { kind: 'kill', spent: 0 }, 'the client is told where the server\'s tape is, to go back there');
  f.db.ledger.kills_total = AHEAD.kill;   // the kill reports arrive
  const ok = firstDropping('kill', killFacts());
  const r2 = await claim(f, { kind: 'kill', n: ok.n, index: 0, facts: killFacts() }, ENFORCE);
  assert.equal(r2.body.success, true, JSON.stringify(r2.body));
});

test('a boss\'s first-kill drop comes once per character', async () => {
  const f = fakeDb();
  await issueTape(f.pool, { characterId: 1, env: ENV });
  const facts = { boss: 'gravedigger', level: 10, waveTier: 0, difficulty: 'medium', first: true };
  const info = rules.bossInfo('gravedigger');
  const first = roll('boss', 0, { ...facts, area: info.area, costShards: info.shards, characterLevel: 30, disciplineId: 'gravecaller', owned: [] });
  assert.ok(first.some((d) => d.source === 'first_kill'));
  await claim(f, { kind: 'boss', n: 0, index: 0, facts });
  await claim(f, { kind: 'boss', n: 1, index: 0, facts });
  assert.ok(f.db.audit.some((a) => a.kind === 'drop_first'), 'the second "first kill" is not believed');
  assert.equal(JSON.parse(f.db.events.get('1|boss|1').facts).first, true, 'audit: logged, the roll unchanged');
  const e = fakeDb();
  await issueTape(e.pool, { characterId: 1, env: ENFORCE });
  await claim(e, { kind: 'boss', n: 0, index: 0, facts }, ENFORCE);
  const refused = await claim(e, { kind: 'boss', n: 1, index: 0, facts }, ENFORCE);
  assert.equal(refused.body.success, false, 'enforce: refused');
});

test('gear lands as a new instance carrying the server roll\'s item level and affixes', async () => {
  const f = fakeDb({ level: 60 });
  await issueTape(f.pool, { characterId: 1, env: ENV });
  const facts = { area: 'ossuary', level: 40 };
  const items = roll('surge', 0, { ...facts, characterLevel: 60, disciplineId: 'gravecaller', owned: [] });
  const r = await claim(f, { kind: 'surge', n: 0, index: 0, facts });
  assert.equal(r.body.success, true, JSON.stringify(r.body));
  if (items[0].instance) {
    assert.equal(f.db.instances.length, 1);
    assert.equal(f.db.instances[0].ilvl, items[0].instance.ilvl);
    assert.deepEqual(JSON.parse(f.db.instances[0].affixes), items[0].instance.affixes);
    assert.equal(f.db.inv[0].instance_id, 1);
  }
});

test('a rune the character already has is not granted (it never dropped for them)', async () => {
  const facts = { def: 'robber', area: 'graves', level: 12, waveTier: 0, difficulty: 'medium', itemChanceMult: 1.3, runePity: 1 };
  const ctx = { characterLevel: 30, disciplineId: 'gravecaller', owned: [] };
  // a tape in which some elite sheds a rune
  const { env, hit } = huntTape((rollIn) => {
    for (let n = 0; n < AHEAD.elite; n++) {
      const items = rollIn('elite', n, { ...facts, ...ctx });
      const i = items.findIndex((d) => d.item_id.startsWith('rune_'));
      if (i >= 0) return { n, i, rune: items[i].item_id };
    }
    return null;
  });
  const f = fakeDb({ unlocked: ['chapterhouse', 'graves', 'ossuary', 'nave', 'sanctum', 'cloister', 'pyre', 'fen'] });
  await issueTape(f.pool, { characterId: 1, env });
  f.db.runes.push(hit.rune);
  const r = await claim(f, { kind: 'elite', n: hit.n, index: hit.i, facts }, env);
  assert.equal(r.body.success, false);
  assert.match(r.body.error, /already have that rune/);
  assert.ok(!f.db.inv.some((row) => row.item_id === hit.rune));
});

/** The strongest rising rune chance the rules reach (its multiplier of the base chance, after enough dry elites). */
const MAX_PITY = rules.runePityMult(1e6);

/** The first elite index whose roll at the strongest rising chance sheds a rune but would not at the bound `atPity`, in the tape `rollIn` reads. */
function runeOnlyWithPity(rollIn, atPity, facts) {
  const ctx = { characterLevel: 30, disciplineId: 'gravecaller', owned: [] };
  for (let n = 0; n < AHEAD.elite; n++) {
    const hi = rollIn('elite', n, { ...facts, ...ctx, runePity: MAX_PITY });
    const lo = rollIn('elite', n, { ...facts, ...ctx, runePity: atPity });
    const i = hi.findIndex((d) => d.item_id.startsWith('rune_'));
    if (i >= 0 && !lo.some((d) => d.item_id.startsWith('rune_'))) return { n, i, rune: hi[i].item_id };
  }
  return null;
}

test('audit never changes what dropped: a rising rune chance past the bound is logged, and the rune the client showed is granted', async () => {
  const facts = { def: 'robber', area: 'graves', level: 12, waveTier: 0, difficulty: 'medium', itemChanceMult: 1 };
  const { env, hit } = huntTape((rollIn) => runeOnlyWithPity(rollIn, rules.runePityMult(0), facts));
  const f = fakeDb();
  await issueTape(f.pool, { characterId: 1, env });
  // Bound for index n with no rune before it: n elites dry. Claim at the strongest chance where the bound is lower: audit grants the client's roll.
  const r = await claim(f, { kind: 'elite', n: hit.n, index: hit.i, facts: { ...facts, runePity: MAX_PITY }, expect: hit.rune }, env);
  if (rules.runePityMult(hit.n) < MAX_PITY) assert.ok(f.db.audit.some((a) => a.kind === 'drop_pity'));
  assert.equal(r.body.success, true, JSON.stringify(r.body));
  assert.equal(r.body.data.item.item_id, hit.rune);
  assert.ok(!f.db.audit.some((a) => a.kind === 'drop_mismatch'));
});

test('the rising rune chance follows roll order: a rune picked up later does not shorten an earlier elite\'s bound', async () => {
  const facts = { def: 'robber', area: 'graves', level: 12, waveTier: 0, difficulty: 'medium', itemChanceMult: 1 };
  const ctx = { characterLevel: 30, disciplineId: 'gravecaller', owned: [] };
  const withPity = (n) => ({ ...facts, runePity: rules.runePityMult(n) });
  // A tape with a rune at a later elite, and an earlier one (already ten dry) that drops something too.
  const { env, hit } = huntTape((rollIn) => {
    for (let n = 20; n < AHEAD.elite; n++) {
      const i = rollIn('elite', n, { ...withPity(n), ...ctx }).findIndex((d) => d.item_id.startsWith('rune_'));
      if (i < 0) continue;
      for (let early = 10; early < n; early++) if (rollIn('elite', early, { ...withPity(early), ...ctx }).length) return { later: { n, i }, early };
    }
    return null;
  }, {});
  const f = fakeDb();
  await issueTape(f.pool, { characterId: 1, env });
  // The rune at the later elite, claimed first.
  const r1 = await claim(f, { kind: 'elite', n: hit.later.n, index: hit.later.i, facts: withPity(hit.later.n) }, env);
  assert.equal(r1.body.success, true, JSON.stringify(r1.body));
  // Then the earlier elite whose drop is picked up afterwards: its bound counts from before it, not from the later rune.
  const r2 = await claim(f, { kind: 'elite', n: hit.early, index: 0, facts: withPity(hit.early) }, env);
  assert.equal(r2.body.success, true, JSON.stringify(r2.body));
  assert.ok(!f.db.audit.some((a) => a.kind === 'drop_pity'), JSON.stringify(f.db.audit));
});

test('the Catacomb Depths: a floor clear and a fifth floor\'s chest come from the tape, within the floors the ledger proved', async () => {
  const PROVED = 12;
  const ctx = { characterLevel: 30, disciplineId: 'gravecaller', owned: [] };
  const depths = Array.from({ length: PROVED }, (_, i) => i + 1);
  const chestDepth = depths.find((d) => rules.hasChest(d));
  const bareDepth = depths.find((d) => !rules.hasChest(d) && d > chestDepth);
  const floorDepth = depths.find((d) => !rules.hasChest(d)) ?? 1;
  assert.ok(chestDepth && bareDepth, 'the proved floors include one with a chest and a later one without');
  // a tape in which some floor clear drops an item
  const { env, hit: floorN } = huntTape((rollIn) => {
    for (let n = 0; n < AHEAD.floor; n++) if (rollIn('floor', n, { area: 'depths', depth: floorDepth, level: 20, ...ctx }).length) return n;
    return null;
  }, {});
  const f = fakeDb({ depth: PROVED, floors: 40 });
  await issueTape(f.pool, { characterId: 1, env });
  const r = await claim(f, { kind: 'floor', n: floorN, index: 0, facts: { depth: floorDepth, level: 20 } }, env);
  assert.equal(r.body.success, true, JSON.stringify(r.body));
  const chest = roll('chest', 0, { area: 'depths', depth: chestDepth, level: 20, ...ctx }, env);
  const c = await claim(f, { kind: 'chest', n: 0, index: 0, facts: { depth: chestDepth, level: 20 } }, env);
  assert.equal(c.body.data.item.item_id, chest[0].item_id, 'the chest\'s first drop is its gear');
  assert.match((await claim(f, { kind: 'chest', n: 1, index: 0, facts: { depth: bareDepth, level: 20 } }, env)).body.error, /could not be found/, `no chest on floor ${bareDepth}`);
  const deep = await claim(f, { kind: 'floor', n: floorN + 1, index: 0, facts: { depth: PROVED + 18, level: 20 } }, env);
  assert.equal(deep.body.success, false, 'a floor far below what the ledger proved is refused');
  assert.ok(f.db.audit.some((a) => a.kind === 'drop_depth'));
});

test('boss drops are backed by paid summons, with no limit on how fast: a summon spree pays even when the kill ledger believed none', async () => {
  const f = fakeDb({ bosses: 10 });
  await issueTape(f.pool, { characterId: 1, env: ENFORCE });
  f.db.ledger.bosses_total = 10;   // the ledger refused every Prelate of the spree (its rate), so it backs none
  const facts = { boss: 'prelate', level: 40, waveTier: 0, difficulty: 'medium', first: false };
  const info = rules.bossInfo('prelate');
  const ctx = { area: info.area, costShards: info.shards, characterLevel: 30, disciplineId: 'gravecaller', owned: [] };
  const pick = (n) => roll('boss', n, { ...facts, ...ctx }).length > 0;
  let n = SLACK.bosses;   // one boss more than the slack allows is over budget without a summon
  while (!pick(n)) n++;
  assert.ok(n < AHEAD.boss, 'the boss is inside the dealt tape');
  const refused = await claim(f, { kind: 'boss', n, index: 0, facts }, ENFORCE);
  assert.equal(refused.body.success, false, 'no summons yet: over budget');
  f.db.tape.boss_credit = n + 1;   // the summons were paid (summonCredits)
  const ok = await claim(f, { kind: 'boss', n, index: 0, facts }, ENFORCE);
  assert.equal(ok.body.success, true, JSON.stringify(ok.body));
});

test('a paid summon credits the summoner and every active member of the live party it hosts', async () => {
  const calls = [];
  const pool = {
    execute: async (sql, p) => (/FROM party_sessions s JOIN party_session_members/.test(sql) ? [[{ character_id: 20 }, { character_id: 21 }]] : [[]]),
    query: async (sql, p) => { calls.push({ sql, p }); return [{}]; },
  };
  await creditSummon(pool, 10, 1_000_000, { error() {} });
  assert.match(calls[0].sql, /SET boss_credit = boss_credit \+ 1/);
  assert.deepEqual(calls[0].p[0], [10, 20, 21]);
  // The middleware credits only a summon the route answered with success.
  const seen = [];
  const mw = summonCredits({ execute: async () => [[]], query: async (sql, p) => { seen.push(p[0]); return [{}]; } });
  for (const success of [true, false]) {
    const res = { statusCode: 200, json(b) { return b; } };
    await new Promise((next) => mw({ method: 'POST', path: '/api/necro-progress/summon-prelate', body: { characterId: 7 } }, res, next));
    res.json({ success });
  }
  await new Promise((r) => setTimeout(r, 5));
  assert.deepEqual(seen, [[7]]);
});
