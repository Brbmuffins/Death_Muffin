'use strict';
// node --test server/death-muffin/backend/drops.test.cjs
const test = require('node:test');
const assert = require('node:assert/strict');
const rules = require('./gathering/loot-rules.cjs');
const { issueTape, claimDrop, seedFor, tapeKey, AHEAD } = require('./drops.cjs');

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
      db.tape ??= { issued: p[1], spent: p[2], base_kills: p[3], base_bosses: p[4], base_floors: p[5], last_rune_elite: -1, last_surge_at: 0 };
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
    if (q.startsWith('SELECT id, slot_index, item_id, quantity, instance_id FROM inventory')) return [db.inv.filter((r) => r.slot_index < 48)];
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

const roll = (kind, n, facts) => rules.rollEvent(kind, facts, rules.eventStreams(kind, seedFor(tapeKey(ENV), 1, kind, n))).items;
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
  const b = await issueTape(f.pool, { characterId: 1, next: { kill: 100 }, env: ENV });
  assert.equal(b.tape.kill.from, 100, 'the client says where it is');
  const c = await issueTape(f.pool, { characterId: 1, next: { kill: 99999 }, env: ENV });
  assert.ok(c.tape.kill.from <= 228, 'never past what was dealt');
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
  for (const [env, ok] of [[ENV, true], [ENFORCE, false]]) {
    const f = fakeDb({ unlocked: ['chapterhouse', 'graves'] });
    await issueTape(f.pool, { characterId: 1, env });
    const facts = killFacts({ area: 'nave', def: 'robber', itemChanceMult: 5, waveTier: 8 });   // the Nave needs the Ossuary open (the Graves alone open only the Ossuary's seal)
    const server = { ...facts, itemChanceMult: 1.3, waveTier: 0 };
    const { n } = firstDropping('kill', server);
    const r = await claim(f, { kind: 'kill', n, index: 0, facts }, env);
    assert.equal(r.body.success, ok, JSON.stringify(r.body));
    assert.deepEqual(f.db.audit.map((a) => a.kind).sort(), ['drop_area', 'drop_fortune', 'drop_wave']);
    if (!ok) assert.equal(f.db.inv.length, 0, 'enforce: nothing granted');
  }
});

test('the tape is spent no faster than the kill ledger accepts kills', async () => {
  const f = fakeDb({ kills: 0 });
  await issueTape(f.pool, { characterId: 1, env: ENFORCE });
  f.db.ledger.kills_total = 0;
  const r = await claim(f, { kind: 'kill', n: 100, index: 0, facts: killFacts() }, ENFORCE);   // 101 kills spent, none reported
  assert.equal(r.body.success, false);
  assert.equal(f.db.audit[0].kind, 'drop_budget');
  f.db.ledger.kills_total = 200;   // the kill reports arrive
  const ok = firstDropping('kill', killFacts());
  const r2 = await claim(f, { kind: 'kill', n: ok.n, index: 0, facts: killFacts() }, ENFORCE);
  assert.equal(r2.body.success, true, JSON.stringify(r2.body));
});

test('a boss\'s first-kill drop comes once per character', async () => {
  const f = fakeDb();
  await issueTape(f.pool, { characterId: 1, env: ENV });
  const facts = { boss: 'gravedigger', level: 10, waveTier: 0, difficulty: 'medium', first: true };
  const first = roll('boss', 0, { ...facts, area: 'graves', costShards: 2, characterLevel: 30, disciplineId: 'gravecaller', owned: [] });
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
  const f = fakeDb({ unlocked: ['chapterhouse', 'graves', 'ossuary', 'nave', 'sanctum', 'cloister', 'pyre', 'fen'] });
  await issueTape(f.pool, { characterId: 1, env: ENV });
  let hit = null;
  for (let n = 0; n < AHEAD.elite && !hit; n++) {
    const facts = { def: 'robber', area: 'graves', level: 12, waveTier: 0, difficulty: 'medium', itemChanceMult: 1.3, runePity: 1 };
    const items = roll('elite', n, { ...facts, characterLevel: 30, disciplineId: 'gravecaller', owned: [] });
    const i = items.findIndex((d) => d.item_id.startsWith('rune_'));
    if (i >= 0) hit = { n, i, facts, rune: items[i].item_id };
  }
  assert.ok(hit, 'some elite in the tape sheds a rune');
  f.db.runes.push(hit.rune);
  const r = await claim(f, { kind: 'elite', n: hit.n, index: hit.i, facts: hit.facts });
  assert.equal(r.body.success, false);
  assert.match(r.body.error, /already have that rune/);
  assert.ok(!f.db.inv.some((row) => row.item_id === hit.rune));
});

/** The first elite index from `from` whose roll at full rising chance (3x) sheds a rune but would not at the bound `atPity`. */
function runeOnlyWithPity(from, atPity, facts) {
  const ctx = { characterLevel: 30, disciplineId: 'gravecaller', owned: [] };
  for (let n = from; n < AHEAD.elite; n++) {
    const hi = roll('elite', n, { ...facts, ...ctx, runePity: 3 });
    const lo = roll('elite', n, { ...facts, ...ctx, runePity: atPity });
    const i = hi.findIndex((d) => d.item_id.startsWith('rune_'));
    if (i >= 0 && !lo.some((d) => d.item_id.startsWith('rune_'))) return { n, i, rune: hi[i].item_id };
  }
  return null;
}

test('audit never changes what dropped: a rising rune chance past the bound is logged, and the rune the client showed is granted', async () => {
  const f = fakeDb();
  await issueTape(f.pool, { characterId: 1, env: ENV });
  const facts = { def: 'robber', area: 'graves', level: 12, waveTier: 0, difficulty: 'medium', itemChanceMult: 1 };
  const hit = runeOnlyWithPity(0, rules.runePityMult(0), facts);
  assert.ok(hit, 'some elite sheds a rune only at the higher chance');
  // Bound for index n with no rune before it: n elites dry. Claim with 3x where the bound is lower: audit grants the client's roll.
  const r = await claim(f, { kind: 'elite', n: hit.n, index: hit.i, facts: { ...facts, runePity: 3 }, expect: hit.rune });
  if (rules.runePityMult(hit.n) < 3) assert.ok(f.db.audit.some((a) => a.kind === 'drop_pity'));
  assert.equal(r.body.success, true, JSON.stringify(r.body));
  assert.equal(r.body.data.item.item_id, hit.rune);
  assert.ok(!f.db.audit.some((a) => a.kind === 'drop_mismatch'));
});

test('the rising rune chance follows roll order: a rune picked up later does not shorten an earlier elite\'s bound', async () => {
  const f = fakeDb();
  await issueTape(f.pool, { characterId: 1, env: ENFORCE });
  const facts = { def: 'robber', area: 'graves', level: 12, waveTier: 0, difficulty: 'medium', itemChanceMult: 1 };
  const ctx = { characterLevel: 30, disciplineId: 'gravecaller', owned: [] };
  // A rune at a later elite, claimed first.
  let later = null;
  for (let n = 20; n < AHEAD.elite && !later; n++) {
    const items = roll('elite', n, { ...facts, ...ctx, runePity: rules.runePityMult(n) });
    const i = items.findIndex((d) => d.item_id.startsWith('rune_'));
    if (i >= 0) later = { n, i };
  }
  assert.ok(later, 'a later elite sheds a rune');
  const r1 = await claim(f, { kind: 'elite', n: later.n, index: later.i, facts: { ...facts, runePity: rules.runePityMult(later.n) } }, ENFORCE);
  assert.equal(r1.body.success, true, JSON.stringify(r1.body));
  // Then an earlier elite (dry 10) whose drop is picked up afterwards: its bound counts from before it, not from the later rune.
  let early = null;
  for (let n = 10; n < later.n && !early; n++) if (roll('elite', n, { ...facts, ...ctx, runePity: rules.runePityMult(n) }).length) early = n;
  assert.ok(early != null);
  const r2 = await claim(f, { kind: 'elite', n: early, index: 0, facts: { ...facts, runePity: rules.runePityMult(early) } }, ENFORCE);
  assert.equal(r2.body.success, true, JSON.stringify(r2.body));
  assert.ok(!f.db.audit.some((a) => a.kind === 'drop_pity'), JSON.stringify(f.db.audit));
});

test('the Catacomb Depths: a floor clear and a fifth floor\'s chest come from the tape, within the floors the ledger proved', async () => {
  const f = fakeDb({ depth: 12, floors: 40 });
  await issueTape(f.pool, { characterId: 1, env: ENFORCE });
  const ctx = { characterLevel: 30, disciplineId: 'gravecaller', owned: [] };
  let floorN = -1;
  for (let n = 0; n < AHEAD.floor && floorN < 0; n++) if (roll('floor', n, { area: 'depths', depth: 7, level: 20, ...ctx }).length) floorN = n;
  assert.ok(floorN >= 0, 'some floor clear drops an item');
  const r = await claim(f, { kind: 'floor', n: floorN, index: 0, facts: { depth: 7, level: 20 } }, ENFORCE);
  assert.equal(r.body.success, true, JSON.stringify(r.body));
  const chest = roll('chest', 0, { area: 'depths', depth: 10, level: 20, ...ctx });
  const c = await claim(f, { kind: 'chest', n: 0, index: 0, facts: { depth: 10, level: 20 } }, ENFORCE);
  assert.equal(c.body.data.item.item_id, chest[0].item_id, 'the chest\'s first drop is its gear');
  assert.match((await claim(f, { kind: 'chest', n: 1, index: 0, facts: { depth: 11, level: 20 } }, ENFORCE)).body.error, /could not be found/, 'no chest on floor 11');
  const deep = await claim(f, { kind: 'floor', n: floorN + 1, index: 0, facts: { depth: 30, level: 20 } }, ENFORCE);
  assert.equal(deep.body.success, false, 'a floor far below what the ledger proved is refused');
  assert.ok(f.db.audit.some((a) => a.kind === 'drop_depth'));
});
