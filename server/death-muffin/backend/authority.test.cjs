// Run: node --test server/death-muffin/backend/authority.test.cjs
// Every guard is exercised in both modes with the fake-connection pattern (authority-fake-db.cjs, bag-fake-db.cjs).
const test = require('node:test');
const assert = require('node:assert');
const authority = require('./authority.cjs');
const rules = require('./gathering/authority-rules.cjs');
const { fakeDb } = require('./bag-fake-db.cjs');
const { authorityFake, quietLog } = require('./authority-fake-db.cjs');
const mountLoot = require('./loot.cjs');
const { harness } = require('./bag-fake-db.cjs');

const T0 = Date.UTC(2026, 9, 2, 12, 0, 0);
const MIN = 60_000;
// The bag-save item budget (ground items at a believable pace) is what a save may add while drops are only audited; with server-decided drops
// enforced (the default) a save adds no drop item at all (the 'drop_unclaimed' tests below).
const REPORT = { AUTHORITY_MODE: 'report', DROPS_MODE: 'audit' };
const ENFORCE = { AUTHORITY_MODE: 'enforce', DROPS_MODE: 'audit' };
const MODES = [['report', REPORT], ['enforce', ENFORCE]];

const char = (over = {}) => ({ id: 1, account_id: 7, level: 10, experience: 0, gold: 1000, stat_str: 5, stat_agi: 5, stat_int: 5, stat_vit: 10, ...over });
const nextOf = (c, over = {}) => ({ level: c.level, xp: c.experience, gold: c.gold, stat_str: c.stat_str, stat_agi: c.stat_agi, stat_int: c.stat_int, stat_vit: c.stat_vit, ...over });
const GRAVES = { unlockedAreas: ['chapterhouse', 'graves'], ascension: 0 };

async function save(auth, c, next, now, env, extra = {}) {
  const log = quietLog();
  const v = await authority.guardProgress(auth.db, { char: c, next, now, env, log, ...extra });
  return { ...v, log };
}

test('mode is report unless the env says enforce exactly', () => {
  assert.equal(authority.authorityMode({}), 'report');
  assert.equal(authority.authorityMode({ AUTHORITY_MODE: 'enforce' }), 'enforce');
  assert.equal(authority.authorityMode({ AUTHORITY_MODE: ' ENFORCE ' }), 'enforce');
  assert.equal(authority.authorityMode({ AUTHORITY_MODE: 'enforced' }), 'report');
  assert.equal(authority.authorityMode({ AUTHORITY_MODE: 'off' }), 'report');
});

test('experience arithmetic matches the game curve and round-trips', () => {
  assert.equal(rules.totalXp(1, 0), 0);
  assert.equal(rules.totalXp(2, 0), 100);
  assert.equal(rules.totalXp(3, 50), 350);
  for (const t of [0, 99, 100, 5000, 904520, 3_000_000]) assert.equal(rules.totalXp(rules.splitXp(t).level, rules.splitXp(t).xp), t);
  assert.equal(rules.splitXp(1e12).level, 999);
  assert.equal(rules.LEVEL_CAP, 999);
});

// ── XP and level ─────────────────────────────────────────────────────────────────────────────────────────────────────

for (const [name, env] of MODES) {
  test(`${name}: honest XP gains pass untouched and are never flagged`, async () => {
    const auth = authorityFake({ necro: GRAVES });
    const c = char();
    // A real session: 45 s of play, a few hundred XP.
    let now = T0;
    assert.deepEqual((await save(auth, c, nextOf(c, { xp: 40 }), now, env)).write, nextOf(c, { xp: 40 }));
    now += 45_000;
    const r = await save(auth, { ...c, experience: 40 }, nextOf(c, { xp: 480, gold: 1300 }), now, env);
    assert.deepEqual(r.findings, []);
    assert.equal(r.write.xp, 480);
    assert.equal(auth.audit.length, 0);
    assert.equal(r.message, '');
  });

  test(`${name}: a level-1-to-200 jump is flagged; enforce clamps it to what the allowance explains`, async () => {
    const auth = authorityFake({ necro: GRAVES });
    const c = char({ level: 1, experience: 0, gold: 0 });
    const next = nextOf(c, { level: 200, xp: 0, gold: 5_000_000 });
    const r = await save(auth, c, next, T0, env);
    const kinds = r.findings.map((f) => f.kind).sort();
    assert.deepEqual(kinds, ['gold_rate', 'xp_rate']);
    assert.equal(auth.audit.length, 2);
    assert.ok(auth.audit.every((a) => a.mode === name && a.account_id === 7 && a.character_id === 1));
    assert.ok(r.log.lines.some((l) => l.includes('[AUTHORITY]') && l.includes('xp_rate')));
    if (name === 'report') {
      assert.deepEqual(r.write, next, 'report mode never changes a save');
      assert.equal(r.message, '');
      assert.ok(auth.audit.every((a) => a.action === 'report'));
    } else {
      const ceil = rules.ceilingsFor(GRAVES.unlockedAreas, 0, 1);
      assert.equal(rules.totalXp(r.write.level, r.write.xp), Math.floor(ceil.xpPerMin * rules.AUTHORITY.FIRST_MINUTES + rules.AUTHORITY.XP_BURST));
      assert.ok(r.write.level < 60, `clamped to level ${r.write.level}`);
      assert.equal(r.write.gold, Math.floor(ceil.goldPerMin * rules.AUTHORITY.FIRST_MINUTES + rules.AUTHORITY.GOLD_BURST));
      assert.match(r.message, /faster than play can explain/);
      assert.ok(auth.audit.every((a) => a.action === 'clamp'));
    }
  });

  test(`${name}: saving in a loop does not mint more than the clock allows`, async () => {
    const auth = authorityFake({ necro: GRAVES });
    let c = char({ level: 1, experience: 0, gold: 0 });
    let now = T0;
    const target = { level: 255, xp: 0, gold: 2_000_000_000 };
    let written = c;
    for (let i = 0; i < 40; i++) {
      const r = await save(auth, written, nextOf(c, target), now, env);
      written = { ...c, level: r.write.level, experience: r.write.xp, gold: r.write.gold };
      now += 1000; // a save a second for 40 seconds
    }
    const ceil = rules.ceilingsFor(GRAVES.unlockedAreas, 0, 1);
    const earned = rules.totalXp(written.level, written.experience);
    if (name === 'enforce') {
      const bound = ceil.xpPerMin * (rules.AUTHORITY.FIRST_MINUTES + 40 / 60) + rules.AUTHORITY.XP_BURST + 1;
      assert.ok(earned <= bound, `${earned} <= ${Math.floor(bound)}`);
    } else {
      assert.equal(written.level, 255, 'report mode lets everything through');
    }
  });

  test(`${name}: the allowance refills with real time`, async () => {
    const auth = authorityFake({ necro: GRAVES });
    const c = char({ level: 1, experience: 0, gold: 0 });
    const ceil = rules.ceilingsFor(GRAVES.unlockedAreas, 0, 1);
    await save(auth, c, nextOf(c), T0, env); // first sight: starts the clock
    const gain = Math.floor(ceil.xpPerMin * 5); // five minutes of the best honest play
    const ok = await save(auth, c, nextOf(c, { level: rules.splitXp(gain).level, xp: rules.splitXp(gain).xp }), T0 + 5 * MIN, env);
    assert.equal(ok.findings.filter((f) => f.kind === 'xp_rate').length, 0, 'five minutes of allowance covers five minutes of top play');
  });

  test(`${name}: a stale save never lowers level or XP (enforce keeps the newer value)`, async () => {
    const auth = authorityFake({ necro: GRAVES });
    const c = char({ level: 30, experience: 500, gold: 100 });
    const stale = nextOf(c, { level: 12, xp: 20 });
    const r = await save(auth, c, stale, T0, env);
    assert.deepEqual(r.findings.map((f) => f.kind), ['xp_stale']);
    if (name === 'report') assert.deepEqual(r.write, stale);
    else {
      assert.equal(r.write.level, 30);
      assert.equal(r.write.xp, 500);
      assert.match(r.message, /older than your latest progress/);
    }
  });

  test(`${name}: stat points cannot be raised by a save`, async () => {
    const auth = authorityFake({ necro: GRAVES });
    const c = char();
    const r = await save(auth, c, nextOf(c, { stat_int: 500, stat_vit: 4 }), T0, env);
    assert.deepEqual(r.findings.map((f) => f.kind), ['stat_raise']);
    if (name === 'report') assert.equal(r.write.stat_int, 500);
    else {
      assert.equal(r.write.stat_int, 5);
      assert.equal(r.write.stat_vit, 4, 'lowering is not a gain');
    }
  });
}

test('staff accounts skip every guard', async () => {
  const auth = authorityFake({ necro: GRAVES });
  const c = char({ level: 1, experience: 0 });
  const r = await save(auth, c, nextOf(c, { level: 255, gold: 2e9 }), T0, ENFORCE, { account: { staff: true } });
  assert.equal(r.write.level, 255);
  assert.equal(auth.audit.length, 0);
});

test('guards fail closed: a guard that cannot run refuses the save (503, the client retries) instead of saving unchecked', async () => {
  const boom = Object.assign(new Error("Table 'character_authority' doesn't exist"), { code: 'ER_NO_SUCH_TABLE' });
  for (const [, env] of MODES) {
    const auth = authorityFake({ necro: GRAVES, failWith: boom });
    const c = char({ level: 1 });
    await assert.rejects(save(auth, c, nextOf(c, { level: 99 }), T0, env), (err) => err.unavailable === true && err.status === 503);
  }
});

test('ceilings follow progress: an unlocked deeper ground, a higher Ascension rank or a scaling ground raises the rate', () => {
  const start = rules.ceilingsFor(['chapterhouse', 'graves'], 0, 1);
  const deep = rules.ceilingsFor(['chapterhouse', 'graves', 'ossuary', 'nave', 'sanctum'], 0, 1);
  const ranked = rules.ceilingsFor(['chapterhouse', 'graves'], 6, 1);
  const cloisterLow = rules.ceilingsFor(['cloister'], 0, 20);
  const cloisterHigh = rules.ceilingsFor(['cloister'], 0, 120);
  assert.ok(deep.xpPerMin > start.xpPerMin);
  assert.ok(ranked.xpPerMin > start.xpPerMin);
  assert.ok(cloisterHigh.xpPerMin > cloisterLow.xpPerMin * 4, 'level-scaled ground pays more to a higher character');
  assert.equal(rules.ceilingsFor(['chapterhouse', 'acre'], 0, 1).xpPerMin, 0);
  assert.equal(rules.ceilingsFor(['chapterhouse', 'acre'], 0, 1).goldPerMin, rules.AUTHORITY.NONCOMBAT_GOLD_PER_MIN);
});

// ── Items ────────────────────────────────────────────────────────────────────────────────────────────────────────────

test('add-item uses the same per-item allowance', async () => {
  for (const [name, env] of MODES) {
    const auth = authorityFake();
    const log = quietLog();
    const ok = await authority.guardAddItem(auth.db, { characterId: 1, accountId: 7, itemId: 'ore_copper', quantity: 20, now: T0, env, log });
    assert.equal(ok.allowed, true);
    const bad = await authority.guardAddItem(auth.db, { characterId: 1, accountId: 7, itemId: 'ichor_regent', quantity: 500, now: T0, env, log });
    assert.equal(bad.allowed, name === 'report');
    assert.equal(auth.audit.length, 1);
    assert.equal(auth.audit[0].action, name === 'report' ? 'report' : 'refuse');
    const server = await authority.guardAddItem(auth.db, { characterId: 1, accountId: 7, itemId: 'plank_oak', quantity: 1, now: T0, env, log });
    assert.equal(server.allowed, name === 'report');
  }
});

test('roll-gear only rolls items that exist in a drop table', async () => {
  for (const [name, env] of MODES) {
    const auth = authorityFake();
    const db = fakeDb({ extra: auth.handler });
    const call = harness((app, pool, opts) => mountLoot(app, pool, { ...opts, guardRoll: (req, conn, args) => authority.guardRollGear(conn, { ...args, env, log: quietLog() }) }), db);
    const fine = await call('POST /api/loot/roll-gear', { body: { characterId: 1, drops: [{ item_id: 'helm_iron', level: 5, source: 'kill' }] } });
    assert.equal(fine.json.success, true);
    // wand_iron/staff_moon are droppable; craftable-only gear is not. plank_oak is a material nothing drops.
    const forged = await call('POST /api/loot/roll-gear', { body: { characterId: 1, drops: [{ item_id: 'plank_oak', level: 5, source: 'kill' }] } });
    if (name === 'report') assert.equal(forged.json.success, true);
    else {
      assert.equal(forged.json.success, false);
      assert.equal(forged.json.error, 'That drop could not be rolled.');
    }
    assert.equal(auth.audit.filter((a) => a.kind === 'roll_gear').length, 1);
  }
});

// ── Offline full sync ────────────────────────────────────────────────────────────────────────────────────────────────

const snapshot = (level, experience, gold, over = {}) => ({
  character: { level, experience, gold, class_index: 1 },
  slots: [], necro: { unlockedAreas: ['chapterhouse', 'graves', 'ossuary'], ascension: 0 },
  chronicle: { life: { playSeconds: 3600 } }, ...over,
});

test('offline load: a believable session is not flagged, a 1 to 200 jump is', () => {
  const online = snapshot(10, 0, 500);
  const honest = snapshot(14, 20, 2500, { chronicle: { life: { playSeconds: 3600 + 2 * 3600 } } });
  assert.deepEqual(authority.evaluateOffline({ online, offline: honest }).findings, []);
  const forged = snapshot(200, 0, 2_000_000_000, { slots: [{ slot_index: 0, item_id: 'ichor_regent', quantity: 99 }] });
  const kinds = authority.evaluateOffline({ online, offline: forged }).findings.map((f) => f.kind).sort();
  assert.deepEqual(kinds, ['gold_rate', 'item_intro', 'xp_rate']);
  // Going down, or staying level, is the player's choice and never flagged.
  assert.deepEqual(authority.evaluateOffline({ online: forged, offline: online }).findings, []);
});

test('offline load: report mode logs and never asks; enforce asks once and audits the confirmed load', async () => {
  const online = snapshot(10, 0, 500);
  const forged = snapshot(200, 0, 500);
  const base = { characterId: 1, accountId: 7, online, offline: forged, log: quietLog() };

  const a1 = authorityFake();
  const report = await authority.guardOfflineLoad(a1.db, { ...base, env: REPORT });
  assert.equal(report.needsConfirm, false);
  assert.equal(report.message, '');
  assert.deepEqual(a1.audit.map((a) => a.action), ['report']);

  const a2 = authorityFake();
  const asked = await authority.guardOfflineLoad(a2.db, { ...base, env: ENFORCE });
  assert.equal(asked.needsConfirm, true);
  assert.match(asked.message, /Load it anyway\?/);
  assert.deepEqual(a2.audit.map((a) => a.action), ['refuse']);

  const confirmed = await authority.guardOfflineLoad(a2.db, { ...base, env: ENFORCE, confirmed: true });
  assert.equal(confirmed.needsConfirm, false);
  assert.deepEqual(a2.audit.map((a) => a.action), ['refuse', 'confirm']);

  const clean = await authority.guardOfflineLoad(authorityFake().db, { ...base, offline: snapshot(10, 5, 600), env: ENFORCE });
  assert.equal(clean.needsConfirm, false);
});

test('offline stats sync: a bare level claim is judged by the minimum window', async () => {
  const a = authorityFake();
  const common = { characterId: 1, accountId: 7, online: { level: 5, experience: 0 }, log: quietLog() };
  assert.equal((await authority.guardOfflineStats(a.db, { ...common, level: 6, experience: 10, env: ENFORCE })).needsConfirm, false);
  assert.equal((await authority.guardOfflineStats(a.db, { ...common, level: 200, experience: 0, env: REPORT })).needsConfirm, false);
  assert.equal((await authority.guardOfflineStats(a.db, { ...common, level: 200, experience: 0, env: ENFORCE })).needsConfirm, true);
});

// ── The Catacomb Depths: a new source of XP, gold and items that honest runs must not trip ───────────────────────────────────────────

const WARREN_OPEN = { unlockedAreas: ['chapterhouse', 'graves', 'warren'], ascension: 0 };

test('depths: the ceilings count the Depths once the Warren is open, and follow the deepest floor in the Chronicle', async () => {
  const before = rules.ceilingsFor(['chapterhouse', 'graves'], 0, 30, 0);
  const shallow = rules.ceilingsFor(WARREN_OPEN.unlockedAreas, 0, 30, 0);
  const deep = rules.ceilingsFor(WARREN_OPEN.unlockedAreas, 0, 30, 25);
  assert.equal(shallow.area, 'depths');
  assert.ok(shallow.xpPerMin > before.xpPerMin, 'opening the Warren opens the Depths');
  assert.ok(deep.xpPerMin > shallow.xpPerMin, 'a deeper record raises the ceiling');
  assert.ok(deep.goldPerMin > shallow.goldPerMin);
  // A character that has not opened the Warren gets nothing from a (forged) depth record.
  assert.deepEqual(rules.ceilingsFor(['chapterhouse', 'graves'], 0, 30, 25), before);
  assert.equal(rules.depthBound(0), rules.DEPTHS_AUTHORITY.slack);
});

for (const [name, env] of MODES) {
  test(`${name}: a long honest Depths session (deep floors, level-scaled XP) passes where a bare Warren record would have been flagged`, async () => {
    const c = char({ level: 40, experience: 0 });
    // Twenty minutes at the deepest ceiling's pace is far inside the bank (60 minutes); the same haul at the Warren's own pace is not.
    const rate = rules.ceilingsFor(WARREN_OPEN.unlockedAreas, 0, 40, 18).xpPerMin / rules.AUTHORITY.HEADROOM;
    const gain = Math.floor(rate * 20);
    const next = nextOf(c, { xp: 0, level: rules.splitXp(rules.totalXp(40, 0) + gain).level, ...{ xp: rules.splitXp(rules.totalXp(40, 0) + gain).xp } });

    const withRecord = authorityFake({ necro: WARREN_OPEN, chronicle: { 'peak.depth': 18, playSeconds: 4000 } });
    await withRecord.db.execute('INSERT IGNORE INTO character_authority (character_id) VALUES (?)', [1]);
    const ok = await save(withRecord, c, next, T0, env);
    // First save: the bank starts at FIRST_MINUTES, so the honest hour must have accrued first.
    await authority.guardProgress(withRecord.db, { char: c, next: nextOf(c), now: T0 - 40 * MIN, env, log: quietLog() });
    const later = await save(withRecord, c, next, T0, env);
    assert.deepEqual(later.findings.filter((f) => f.kind === 'xp_rate'), [], 'honest Depths XP is not flagged');
    assert.ok(ok);

    // The same haul on a character that has opened only the Warren, with no Chronicle record and level 40, is judged by the (smaller) depth-3 ceiling.
    const bare = authorityFake({ necro: { unlockedAreas: ['chapterhouse', 'graves'], ascension: 0 } });
    await authority.guardProgress(bare.db, { char: c, next: nextOf(c), now: T0 - 40 * MIN, env, log: quietLog() });
    const flagged = await save(bare, c, next, T0, env);
    assert.ok(flagged.findings.some((f) => f.kind === 'xp_rate'), 'without access to the Depths the same haul is not believable');
  });
}

test('depths: the necro summary carries the deepest recorded floor, and tolerates a missing Chronicle', async () => {
  const withChron = authorityFake({ necro: WARREN_OPEN, chronicle: { 'peak.depth': 22 } });
  assert.equal((await authority.necroSummary(withChron.db, 1)).deepest, 22);
  const without = authorityFake({ necro: WARREN_OPEN });
  assert.equal((await authority.necroSummary(without.db, 1)).deepest, 0);
  const broken = authorityFake({ necro: WARREN_OPEN, failWith: null });
  broken.db.execute = async (sql) => { if (/character_chronicle/.test(sql)) throw new Error('no such table'); return [[{ state: JSON.stringify(WARREN_OPEN) }]]; };
  assert.equal((await authority.necroSummary(broken.db, 1)).deepest, 0);
});

test('depths: every drop a floor, a kill, a chest or a rune can hand out may be rolled and kept; honest chests are not flagged', async () => {
  // A chest on a deep floor: ascended armour from the Fen, a moon-tier weapon, a rune, a finds roll and a floor-clear item.
  const chest = ['set_gravecaller_ascended_chest', 'staff_moon', 'rune_requiem', 'gem_void_sapphire', 'ore_moon', 'flask_hp_grand'];
  for (const id of chest) assert.equal(rules.isGroundItem(id), true, id);
  assert.ok(rules.itemRatePerMin('rune_requiem') > 0 && rules.itemCap('rune_requiem') >= 1);
  for (const [name, env] of MODES) {
    const auth = authorityFake({ necro: WARREN_OPEN });
    const db = fakeDb({ extra: auth.handler });
    const call = harness((app, pool, opts) => mountLoot(app, pool, { ...opts, guardRoll: (req, conn, args) => authority.guardRollGear(conn, { ...args, env, log: quietLog() }) }), db);
    const r = await call('POST /api/loot/roll-gear', { body: { characterId: 1, drops: chest.map((item_id) => ({ item_id, level: 40, source: 'boss' })) } });
    assert.equal(r.json.success, true, `${name}: a chest's drops can be rolled`);
    assert.equal(auth.audit.filter((a) => a.kind === 'roll_gear').length, 0, `${name}: nothing flagged`);
  }
});

test('depths: the offline edition\'s deepest floor bounds the offline ceilings the same way', () => {
  const online = snapshot(30, 0, 500, { necro: { unlockedAreas: ['chapterhouse', 'graves', 'warren'], ascension: 0 } });
  const deepHour = (depth) => snapshot(31, 0, 500, { necro: online.necro, chronicle: { life: { playSeconds: 3600 + 3600, 'peak.depth': depth } } });
  const f = (depth) => authority.evaluateOffline({ online, offline: deepHour(depth) });
  assert.deepEqual(f(20).findings.filter((x) => x.kind === 'xp_rate'), [], 'a level in two hours of deep-floor play is believable');
});

