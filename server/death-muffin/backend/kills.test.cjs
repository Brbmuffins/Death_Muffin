// Run: node --test server/death-muffin/backend/kills.test.cjs
// Server authority step 2 (the kill ledger): the pure rules, then every route-level piece against the fake database, in each mode.
const test = require('node:test');
const assert = require('node:assert');
const kills = require('./kills.cjs');
const authority = require('./authority.cjs');
const rules = require('./gathering/kill-rules.cjs');
const arules = require('./gathering/authority-rules.cjs');
const mountLeaderboard = require('./leaderboard.cjs');
const mountChronicle = require('./chronicle.cjs');
const { killsFake } = require('./kills-fake-db.cjs');
const { quietLog } = require('./authority-fake-db.cjs');

const T0 = Date.UTC(2026, 9, 3, 12, 0, 0);
const MIN = 60_000;
const OFF = {};
const AUDIT = { AUTHORITY_KILLS: 'audit' };
const ENFORCE = { AUTHORITY_KILLS: 'enforce' };
const NECRO = { unlockedAreas: ['chapterhouse', 'graves'], ascension: 0 };
const NAVE = { unlockedAreas: ['chapterhouse', 'graves', 'ossuary', 'nave', 'warren'], ascension: 0, totalKills: 500 };
const ACCOUNT = { staff: false };

const char = (over = {}) => ({ id: 1, account_id: 7, level: 10, experience: 0, gold: 1000, stat_str: 5, stat_agi: 5, stat_int: 5, stat_vit: 10, ...over });
const nextOf = (c, over = {}) => ({ level: c.level, xp: c.experience, gold: c.gold, stat_str: c.stat_str, stat_agi: c.stat_agi, stat_int: c.stat_int, stat_vit: c.stat_vit, ...over });
/** An honest group of kills in the Hollow Graves (level 1 dead, medium difficulty, no multipliers). */
const group = (over = {}) => ({ area: 'graves', def: 'robber', level: 1, elite: false, tier: 0, diff: 'medium', rank: 0, xpMult: 1, goldMult: 1, shardMult: 1, n: 50, ...over });
/** A believable stretch of Hollow Graves play: `k` x 100 kills spread over the ground's usual dead. */
const mixed = (k, over = {}) => [['robber', 30], ['hound', 25], ['penitent', 20], ['bat', 10], ['moth', 10], ['rat', 5]].map(([def, n]) => group({ def, n: n * k, ...over }));
const mixedXp = (k, level = 1) => [['robber', 30], ['hound', 25], ['penitent', 20], ['bat', 10], ['moth', 10], ['rat', 5]].reduce((sum, [def, n]) => sum + n * k * Math.round(rules.killXpBase(def, level, false, 0, 'medium')), 0);
const report = (seq, groups, extra = {}) => ({ seq, groups, bosses: [], floors: [], ...extra });
const ctx = (over = {}) => ({ unlocked: NECRO.unlockedAreas, ascension: 0, heroLevel: 10, deepest: 0, killBucket: 5000, bossBucket: 5, floorBucket: 20, maxCleared: 0, staff: false, ...over });
const unbacked = (fake) => fake.audit.map((a) => a.kind).filter((k) => k.startsWith('unbacked_')).sort();
const evaluate = (rep, c = ctx()) => rules.evaluateKillReport(rules.parseKillReport(rep), c);

async function send(fake, rep, now, env, opts = {}) {
  const log = quietLog();
  const out = await kills.handleReport(fake.pool, { char: char(), accountId: 7, body: rep, account: ACCOUNT, now, env, log, ...opts });
  return { ...out, log };
}
async function saveProgress(fake, c, next, now, env, account = ACCOUNT) {
  const log = quietLog();
  const v = await authority.guardProgress(fake.db, { char: c, next, now, env, log, account });
  return { ...v, log };
}

// ── Mode and shape ────────────────────────────────────────────────────────────────────────────────────────────────────

test('the kills mode is off unless the env says audit or enforce exactly', () => {
  assert.equal(kills.killsMode({}), 'off');
  assert.equal(kills.killsMode({ AUTHORITY_KILLS: 'audit' }), 'audit');
  assert.equal(kills.killsMode({ AUTHORITY_KILLS: ' ENFORCE ' }), 'enforce');
  assert.equal(kills.killsMode({ AUTHORITY_KILLS: 'enforced' }), 'off');
  assert.equal(kills.killsMode({ AUTHORITY_KILLS: 'on' }), 'off');
});

test('parseKillReport keeps shape and bounds only: junk and negative counts vanish', () => {
  assert.equal(rules.parseKillReport(null), null);
  assert.equal(rules.parseKillReport({ seq: 'x' }), null);
  assert.equal(rules.parseKillReport({ seq: -4 }), null);
  const r = rules.parseKillReport({ seq: 5, groups: [group({ n: -3 }), group({ n: 1e12 }), { area: 3 }, null, group({ level: 1e9, xpMult: 1e9 })], bosses: [{ boss: 'prelate', n: 99 }], floors: [{ depth: 3, level: 20, clear: false, chest: false }] });
  assert.equal(r.groups.length, 2);
  assert.equal(r.groups[0].n, rules.KILLS.MAX_PER_GROUP);
  assert.equal(r.groups[1].level, 2000);
  assert.equal(r.groups[1].xpMult, 50);
  assert.equal(r.bosses[0].n, 20);
  assert.equal(r.floors.length, 0, 'a floor entry that neither clears nor opens a chest is nothing');
});

// ── What a kill is worth ──────────────────────────────────────────────────────────────────────────────────────────────

test('an honest batch is credited at the game\'s own XP, the best gold roll and elite shards', () => {
  const e = evaluate(report(1, [...mixed(1), group({ elite: true, n: 4, level: 2 })]));
  assert.deepEqual(e.findings, []);
  assert.equal(e.killsAccepted, 104);
  assert.equal(e.credits.kills.graves, 104);
  const xp = (def, level, elite) => Math.round(rules.killXpBase(def, level, elite, 0, 'medium'));
  assert.equal(e.credits.xp, mixedXp(1) + 4 * xp('robber', 2, true));
  assert.equal(e.credits.shards, 4 * rules.ELITE_SHARDS_MAX, 'only elites shed shards');
  assert.ok(e.credits.gold > 0);
});

test('claimed multipliers are capped at what play can reach, never trusted', () => {
  const honest = evaluate(report(1, [group({ xpMult: 1.2, goldMult: 1.2, n: 10 })]));
  const cheat = evaluate(report(1, [group({ xpMult: 40, goldMult: 40, n: 10 })]));
  const caps = rules.multCaps(0, 10);
  assert.ok(cheat.credits.xp < honest.credits.xp * (caps.xp / 1.2) * 1.05, 'the XP multiplier is clamped to the cap');
  assert.ok(cheat.credits.gold <= Math.round(honest.credits.gold / 1.2 * caps.gold) + 10);
  assert.ok(cheat.credits.xp < evaluate(report(1, [group({ xpMult: 1, n: 10 })])).credits.xp * 3, 'a forged 40x is worth under 3x');
});

test('a higher difficulty and wave tier pay more, an unknown difficulty pays nothing', () => {
  const base = evaluate(report(1, [group()])).credits.xp;
  assert.ok(evaluate(report(1, [group({ diff: 'hard', tier: 8 })])).credits.xp > base);
  const e = evaluate(report(1, [group({ diff: 'nightmare' })]));
  assert.equal(e.credits.xp, 0);
  assert.equal(e.findings[0].kind, 'kill_invalid');
});

// ── Tampering: kills, rates, grounds, kinds ───────────────────────────────────────────────────────────────────────────

test('inflated kill counts stop at the time bucket', () => {
  const e = evaluate(report(1, [group({ n: 6000 }), group({ def: 'hound', n: 6000 })]), ctx({ killBucket: 800 }));
  assert.equal(e.killsAccepted, 800);
  assert.ok(e.findings.some((f) => f.kind === 'kill_rate' && f.dropped > 0));
});

test('the bucket refills with real time and banks for at most BANK_MINUTES', () => {
  const ledger = { bucketAt: T0, killBucket: 0, bossBucket: 0, floorBucket: 0 };
  const perMin = rules.killsPerMin(NECRO.unlockedAreas);
  const one = kills.refill(ledger, NECRO.unlockedAreas, T0 + MIN);
  assert.equal(Math.round(one.killBucket), perMin);
  const day = kills.refill(ledger, NECRO.unlockedAreas, T0 + 24 * 60 * MIN);
  assert.equal(day.killBucket, perMin * rules.KILLS.BANK_MINUTES, 'a day of idling banks only the cap');
  const fresh = kills.refill({ ...ledger, bucketAt: null }, NECRO.unlockedAreas, T0);
  assert.equal(fresh.killBucket, perMin * rules.KILLS.FIRST_MINUTES);
});

test('the rate follows the best ground the character has open: deeper grounds allow more', () => {
  assert.ok(rules.killsPerMin(NAVE.unlockedAreas) > rules.killsPerMin(NECRO.unlockedAreas));
});

test('kills in a sealed ground, an unknown ground or a safe ground are dropped, one step ahead is allowed', () => {
  const e = evaluate(report(1, [group({ area: 'pyre', n: 10 }), group({ area: 'nowhere', n: 10 }), group({ area: 'acre', n: 10 }), group({ area: 'ossuary', def: 'robber', n: 10 })]));
  const why = e.findings.filter((f) => f.kind === 'kill_invalid').map((f) => f.why);
  assert.ok(why.includes('ground'));
  assert.equal(e.credits.kills.pyre, undefined);
  assert.equal(e.credits.kills.nowhere, undefined);
  assert.equal(e.credits.kills.acre, undefined);
  assert.equal(e.credits.kills.ossuary, 10, 'the ground the Hollow Graves unlocks is one step ahead and counts');
});

test('an enemy that does not live in the ground, or is inert, is dropped', () => {
  const e = evaluate(report(1, [group({ def: 'fen_wisp', n: 10 }), group({ def: 'niche', n: 10 }), group({ def: 'made_up', n: 10 }), group({ def: 'risen', n: 10 })]));
  assert.equal(e.killsAccepted, 10, 'only the Risen (raised in any ground) survive');
  assert.equal(e.findings.find((f) => f.kind === 'kill_invalid').why, 'kind');
});

test('an enemy level above what the ground can serve is dropped', () => {
  const top = rules.maxEnemyLevel('graves', 10, 0);
  assert.equal(evaluate(report(1, [group({ level: top })])).killsAccepted, 50);
  const e = evaluate(report(1, [group({ level: top + 1 })]));
  assert.equal(e.killsAccepted, 0);
  assert.equal(e.findings[0].why, 'level');
});

test('Ascension ages the dead: the level cap rises with the character\'s own rank plus the co-op allowance', () => {
  const rank0 = rules.maxEnemyLevel('graves', 10, 0);
  assert.equal(rules.maxEnemyLevel('graves', 10, 3), rank0 + 9, 'three ranks, three levels each');
  // A guest fights in the host\'s world: rank 2 above their own is believed, rank 8 above is not.
  assert.equal(evaluate(report(1, [group({ level: 1 + 2 * 3, rank: 2 })])).killsAccepted, 50);
  assert.equal(evaluate(report(1, [group({ level: 1 + 8 * 3, rank: 8 })])).killsAccepted, 0);
});

test('the kind mix cannot lean on the richest enemy: a ground\'s own spawn weights bound each kind', () => {
  const total = 600;
  const mix = rules.mixAllowance('graves', total);
  const [rarest, allowed] = [...mix].filter(([id]) => id !== 'risen' && id !== 'penitent').sort((a, b) => a[1] - b[1])[0];
  assert.ok(allowed < total, 'the rarest spawn is bounded well below the whole batch');
  const e = evaluate(report(1, [group({ def: rarest, n: total })]), ctx({ killBucket: 9000 }));
  assert.equal(e.killsAccepted, allowed);
  assert.ok(e.findings.some((f) => f.kind === 'kill_mix' && f.dropped === total - allowed));
  // A batch that follows the spawn weights passes whole.
  const weights = [...mix].filter(([id]) => id !== 'risen' && id !== 'penitent');
  const honest = evaluate(report(1, weights.map(([id]) => group({ def: id, n: 20 }))), ctx({ killBucket: 9000 }));
  assert.equal(honest.killsAccepted, 20 * weights.length);
});

test('elites are bounded by the ground\'s elite chance: an all-elite batch is cut down', () => {
  const e = evaluate(report(1, [group({ elite: true, n: 500 })]), ctx({ killBucket: 9000 }));
  const share = rules.maxEliteShare('graves');
  assert.ok(e.killsAccepted < 500 * share * rules.KILLS.ELITE_FACTOR + rules.KILLS.ELITE_FLAT + 1);
  assert.ok(e.findings.some((f) => f.kind === 'kill_elite' || f.kind === 'kill_mix'));
  // Honest mix: a few elites among plain kills pass whole.
  const honest = evaluate(report(1, [...mixed(2), group({ elite: true, n: 12 })]));
  assert.equal(honest.killsAccepted, 212);
});

test('staff reports are credited whole (dev access) and still named', () => {
  const e = evaluate(report(1, [group({ n: 6000 }), group({ elite: true, n: 6000 })]), ctx({ staff: true, killBucket: 0 }));
  assert.equal(e.killsAccepted, 12000);
});

// ── Bosses and Depths floors ──────────────────────────────────────────────────────────────────────────────────────────

test('boss kills pay the boss\'s own gold, XP and shards and are bounded by their own bucket', () => {
  const NAVE_CTX = ctx({ unlocked: NAVE.unlockedAreas });
  const rep = report(1, [], { bosses: [{ boss: 'abbess', tier: 0, diff: 'medium', first: true, n: 1 }] });
  const e = evaluate(rep, NAVE_CTX);
  assert.equal(e.bossesAccepted, 1);
  assert.equal(e.credits.shards, 2 + 2, 'a cost-3 boss gives 2 shards back, its first kill 2 more');
  const spam = evaluate(report(1, [], { bosses: [{ boss: 'abbess', tier: 0, diff: 'medium', first: false, n: 20 }] }), { ...NAVE_CTX, bossBucket: 2 });
  assert.equal(spam.bossesAccepted, 2);
  assert.ok(spam.findings.some((f) => f.kind === 'boss_rate'));
  assert.equal(evaluate(report(1, [], { bosses: [{ boss: 'pyre_king', tier: 0, diff: 'medium', first: false, n: 1 }] })).bossesAccepted, 0);
  // A boss of a sealed ground is refused.
  assert.equal(evaluate(report(1, [], { bosses: [{ boss: 'mire', tier: 0, diff: 'medium', first: false, n: 1 }] })).bossesAccepted, 0);
});

test('Depths floors: a clear proves the next depth, depths cannot be skipped, the Warren must be open', () => {
  const WARREN = ctx({ unlocked: NAVE.unlockedAreas, heroLevel: 40, maxCleared: 0 });
  const clear = (depth) => ({ depth, level: 40 + depth, clear: true, chest: false, mult: 1 });
  const ok = evaluate(report(1, [], { floors: [clear(1), clear(2), clear(3)] }), WARREN);
  assert.equal(ok.floorsAccepted, 3);
  assert.equal(ok.depthProved, 4);
  const leap = evaluate(report(1, [], { floors: [clear(40)] }), WARREN);
  assert.equal(leap.floorsAccepted, 0);
  assert.equal(leap.depthProved, 0);
  assert.equal(leap.findings[0].why, 'skipped floors');
  const sealed = evaluate(report(1, [], { floors: [clear(1)] }), ctx({ heroLevel: 40 }));
  assert.equal(sealed.floorsAccepted, 0);
  const rate = evaluate(report(1, [], { floors: Array.from({ length: 30 }, (_, i) => clear(i + 1)) }), { ...WARREN, floorBucket: 5 });
  assert.equal(rate.floorsAccepted, 5);
  assert.equal(rate.depthProved, 6, 'the rate bucket stops a script from walking a hundred floors in a minute');
});

test('Depths: the chest of a chest floor pays once; a floor with no chest pays nothing for the claim', () => {
  const WARREN = ctx({ unlocked: NAVE.unlockedAreas, heroLevel: 40, maxCleared: 4 });
  const withChest = evaluate(report(1, [], { floors: [{ depth: 5, level: 45, clear: true, chest: true, mult: 1 }] }), WARREN);
  const without = evaluate(report(1, [], { floors: [{ depth: 5, level: 45, clear: true, chest: false, mult: 1 }] }), WARREN);
  assert.ok(withChest.credits.gold > without.credits.gold);
  const fake = evaluate(report(1, [], { floors: [{ depth: 4, level: 44, clear: true, chest: true, mult: 1 }] }), WARREN);
  const plain = evaluate(report(1, [], { floors: [{ depth: 4, level: 44, clear: true, chest: false, mult: 1 }] }), WARREN);
  assert.equal(fake.credits.gold, plain.credits.gold, 'depth 4 has no chest');
});

// ── The ledger: off / audit / enforce, replay, fail open ──────────────────────────────────────────────────────────────

test('off: a report is acknowledged and nothing is written', async () => {
  const fake = killsFake({ necro: NECRO });
  const r = await send(fake, report(T0, [group()]), T0, OFF);
  assert.equal(r.status, 200);
  assert.equal(r.body.data.mode, 'off');
  assert.equal(fake.ledger(1), undefined);
  assert.equal(fake.audit.length, 0);
});

for (const [name, env] of [['audit', AUDIT], ['enforce', ENFORCE]]) {
  test(`${name}: a valid report becomes credits; the ledger starts from the existing record`, async () => {
    const fake = killsFake({ necro: { ...NECRO, totalKills: 321 }, chronicle: { 'peak.depth': 7 } });
    const r = await send(fake, report(T0, mixed(1)), T0, env);
    assert.equal(r.body.data.accepted.kills, 100);
    const l = fake.ledger(1);
    assert.equal(l.kills_base, 321, 'grandfathered');
    assert.equal(l.depth_proved, 7);
    assert.equal(l.kills_total, 100);
    assert.deepEqual(JSON.parse(l.kill_credit), { graves: 100 });
    assert.ok(l.xp_credit > 0 && l.gold_credit > 0);
    assert.equal(fake.audit.length, 0, 'honest play leaves no audit rows');
  });

  test(`${name}: a replayed or older report is never counted twice`, async () => {
    const fake = killsFake({ necro: NECRO });
    await send(fake, report(T0 + 10, mixed(0.4)), T0, env);
    const xp = fake.ledger(1).xp_credit;
    const dup = await send(fake, report(T0 + 10, mixed(0.4)), T0 + 1000, env);
    assert.equal(dup.body.data.duplicate, true);
    const old = await send(fake, report(T0 + 5, mixed(0.4)), T0 + 2000, env);
    assert.equal(old.body.data.duplicate, true);
    assert.equal(fake.ledger(1).xp_credit, xp);
    assert.equal(fake.ledger(1).kills_total, 40);
    assert.deepEqual(fake.audit.map((a) => a.kind), ['kill_replay'], 'an exact retry is silent, an older sequence is audited');
  });

  test(`${name}: a sequence number from the future is refused`, async () => {
    const fake = killsFake({ necro: NECRO });
    const r = await send(fake, report(T0 + 24 * 60 * MIN, [group()]), T0, env);
    assert.equal(r.status, 400);
    assert.equal(fake.ledger(1), undefined);
  });

  test(`${name}: reporting the same kills in many small reports cannot beat the bucket`, async () => {
    const fake = killsFake({ necro: NECRO });
    const cap = rules.killsPerMin(NECRO.unlockedAreas) * rules.KILLS.FIRST_MINUTES;
    let accepted = 0;
    for (let i = 1; i <= 40; i++) {
      const r = await send(fake, report(T0 + i, mixed(1)), T0 + i * 1000, env);
      accepted += r.body.data.accepted.kills;
    }
    // 40 s of real time: the first-sight bank plus 40 s of refill, however the report is chopped up.
    const allowed = cap + (rules.killsPerMin(NECRO.unlockedAreas) * 40) / 60;
    assert.ok(accepted <= allowed + 1, `accepted ${accepted} of ${allowed}`);
    assert.ok(accepted < 4000);
  });
}

test('enforce tells the player when kills were not counted; audit stays quiet to them but logs it', async () => {
  const bad = report(T0, [group({ area: 'pyre', n: 50 })]);
  const e = await send(killsFake({ necro: NECRO }), bad, T0, ENFORCE);
  assert.equal(e.body.authority.message, kills.ENFORCE_NOTICE);
  const fake = killsFake({ necro: NECRO });
  const a = await send(fake, bad, T0, AUDIT);
  assert.equal(a.body.authority, undefined);
  assert.equal(fake.audit[0].kind, 'kill_invalid');
  assert.equal(fake.audit[0].action, 'report');
});

test('fail open: a broken ledger table never costs the client an answer or a save', async () => {
  const fake = killsFake({ necro: NECRO, failWith: Object.assign(new Error('no table'), { code: 'ER_NO_SUCH_TABLE' }) });
  const r = await send(fake, report(T0, [group()]), T0, ENFORCE);
  assert.equal(r.status, 200);
  assert.equal(r.body.data.unavailable, true);
  const c = char();
  const v = await saveProgress(fake, c, nextOf(c, { xp: 5000 }), T0, ENFORCE);
  assert.equal(v.write.xp, 5000, 'credits unavailable: the save goes through unchecked');
  assert.ok(v.log.lines.some((l) => l.includes('unavailable')));
});

// ── Saves paid out of credits ─────────────────────────────────────────────────────────────────────────────────────────

test('enforce: honest XP and gold from reported kills are paid in full, and the credit is used up', async () => {
  const fake = killsFake({ necro: NECRO });
  await send(fake, report(T0, mixed(2)), T0, ENFORCE);
  const credit = fake.ledger(1).xp_credit;
  const gold = fake.ledger(1).gold_credit;
  const c = char({ experience: 0 });
  const earnedXp = mixedXp(2);
  const v = await saveProgress(fake, c, nextOf(c, { xp: earnedXp, gold: c.gold + 400 }), T0 + 30_000, ENFORCE);
  assert.equal(v.write.xp, earnedXp);
  assert.equal(v.write.gold, c.gold + 400);
  assert.equal(v.message, '');
  assert.equal(fake.audit.length, 0);
  assert.ok(fake.ledger(1).xp_used === earnedXp);
  assert.ok(credit >= earnedXp && gold >= 400);
});

test('enforce: inflated XP, gold and levels are clamped to what the reports back (plus the small lump)', async () => {
  const fake = killsFake({ necro: NECRO });
  await send(fake, report(T0, mixed(1)), T0, ENFORCE);
  const ledger = fake.ledger(1);
  const c = char();
  const cheat = nextOf(c, { level: 200, xp: 5, gold: 50_000_000 });
  const v = await saveProgress(fake, c, cheat, T0 + 30_000, ENFORCE);
  const backedXp = ledger.xp_used;
  assert.ok(v.write.level < 20, `level ${v.write.level}`);
  assert.equal(arules.totalXp(v.write.level, v.write.xp) - arules.totalXp(c.level, c.experience), backedXp);
  assert.ok(v.write.gold < c.gold + 200_000, 'gold held to the credit plus the lump');
  assert.match(v.message, /verified kills/);
  // Gold is held to the step-1 bucket (enforce of step 2 implies it) and then fits inside the lump, so XP is the unbacked claim.
  assert.ok(unbacked(fake).includes('unbacked_xp'));
  // It catches up as more kills are verified: the client keeps resending its absolute numbers.
  await send(fake, report(T0 + 40_000, mixed(30)), T0 + 40_000, ENFORCE);
  const again = await saveProgress(fake, { ...c, level: v.write.level, experience: v.write.xp, gold: v.write.gold }, cheat, T0 + 60_000, ENFORCE);
  assert.ok(arules.totalXp(again.write.level, again.write.xp) > arules.totalXp(v.write.level, v.write.xp));
});

test('enforce: a client that never reports earns nothing beyond the lump and is told to reload', async () => {
  const fake = killsFake({ necro: NECRO });
  const c = char();
  const v = await saveProgress(fake, c, nextOf(c, { xp: 90_000 }), T0, ENFORCE);
  assert.ok(arules.totalXp(v.write.level, v.write.xp) - arules.totalXp(c.level, c.experience) <= rules.KILLS.LUMP_XP_CAP);
  assert.match(v.message, /Reload the page/);
});

test('enforce: the lump allowance refills with time, so non-kill income (contracts, labour) keeps flowing', async () => {
  const fake = killsFake({ necro: NECRO });
  const c = char();
  const first = await saveProgress(fake, c, nextOf(c, { gold: c.gold + 20_000 }), T0, ENFORCE);
  assert.equal(first.write.gold, c.gold + 20_000, 'a labour payout well inside the lump');
  const drained = await saveProgress(fake, { ...c, gold: first.write.gold }, nextOf(c, { gold: first.write.gold + rules.KILLS.LUMP_GOLD_CAP }), T0 + 1000, ENFORCE);
  assert.ok(drained.write.gold < first.write.gold + rules.KILLS.LUMP_GOLD_CAP);
  const later = await saveProgress(fake, { ...c, gold: drained.write.gold }, nextOf(c, { gold: drained.write.gold + 3000 }), T0 + 10 * MIN, ENFORCE);
  assert.equal(later.write.gold, drained.write.gold + 3000, 'ten minutes later the refilled lump covers it');
});

test('audit: nothing is held back, but unbacked gains are logged and the balances still move', async () => {
  const fake = killsFake({ necro: NECRO });
  const c = char();
  const v = await saveProgress(fake, c, nextOf(c, { xp: 900_000, gold: 9_000_000 }), T0, AUDIT);
  assert.equal(v.write.xp, nextOf(c, { xp: 900_000 }).xp, 'audit never changes a save');
  assert.equal(v.write.gold, 9_000_000);
  assert.equal(v.message, '');
  assert.deepEqual(fake.audit.filter((a) => a.kind.startsWith('unbacked_')).map((a) => [a.kind, a.mode, a.action]).sort(), [['unbacked_gold', 'audit', 'report'], ['unbacked_xp', 'audit', 'report']]);
  assert.ok(fake.ledger(1).xp_used > 0, 'the ledger tracks what was claimed so audit shows the same balances enforce would');
});

test('off: step 1 is exactly as before and no ledger exists', async () => {
  const fake = killsFake({ necro: NECRO });
  const c = char();
  const v = await saveProgress(fake, c, nextOf(c, { xp: 40, gold: 1300 }), T0, { AUTHORITY_MODE: 'report' });
  assert.deepEqual(v.write, nextOf(c, { xp: 40, gold: 1300 }));
  assert.equal(fake.ledger(1), undefined);
});

test('staff are exempt from every clamp', async () => {
  const fake = killsFake({ necro: NECRO });
  const c = char();
  const v = await saveProgress(fake, c, nextOf(c, { level: 255, xp: 0, gold: 2_000_000_000 }), T0, ENFORCE, { staff: true });
  assert.equal(v.write.level, 255);
  assert.equal(v.write.gold, 2_000_000_000);
});

test('step 1 and step 2 stack: the stricter limit wins and both messages reach the player', async () => {
  const fake = killsFake({ necro: NECRO });
  const c = char();
  const v = await saveProgress(fake, c, nextOf(c, { xp: 50_000_000 }), T0, { AUTHORITY_MODE: 'enforce', AUTHORITY_KILLS: 'enforce' });
  assert.ok(arules.totalXp(v.write.level, v.write.xp) - arules.totalXp(c.level, c.experience) <= rules.KILLS.LUMP_XP_CAP);
  assert.match(v.message, /faster than/);
});

// ── Necromancer saves: kills, shards, Ascension ───────────────────────────────────────────────────────────────────────

function necroRequest(fake, body, env) {
  const guard = kills.necroGuard({ pool: fake.pool, ownsCharacter: async () => true, isStaff: async () => false, env, log: quietLog() });
  const req = { body: { characterId: 1, ...body }, user: { accountId: 7 } };
  let finish = () => {};
  const res = { statusCode: 200, on: (ev, fn) => { if (ev === 'finish') finish = fn; } };
  return { req, run: async () => { await guard(req, res, () => {}); }, finish: async (status = 200) => { res.statusCode = status; finish(); await new Promise((r) => setImmediate(r)); } };
}

test('enforce: a necromancer save can only claim kills, shards and Prelate kills the ledger credits', async () => {
  const fake = killsFake({ necro: { ...NECRO, unlockedAreas: [...NAVE.unlockedAreas, 'sanctum'] } });
  await send(fake, report(T0, [...mixed(1), group({ elite: true, n: 6, level: 1 })], { bosses: [{ boss: 'prelate', tier: 0, diff: 'medium', first: false, n: 1 }] }), T0, ENFORCE);
  const n = necroRequest(fake, { areaKills: { graves: 900, pyre: 400 }, shards: 30, prelateKills: 3 }, ENFORCE);
  await n.run();
  assert.deepEqual(n.req.body.areaKills, { graves: 106 });
  assert.equal(n.req.body.shards, 6 * rules.ELITE_SHARDS_MAX + 3, 'the elites\' shards plus the Prelate\'s own three');
  assert.equal(n.req.body.prelateKills, 1, 'one reported Prelate, three claimed');
  await n.finish();
  assert.deepEqual(JSON.parse(fake.ledger(1).kill_credit || '{}'), {});
  assert.equal(fake.ledger(1).shard_credit, 0);
  const kinds = fake.audit.map((a) => a.kind).sort();
  assert.deepEqual(kinds, ['unbacked_kills', 'unbacked_prelate', 'unbacked_shards']);
  // Nothing left to claim: the same boss cannot be claimed twice.
  const again = necroRequest(fake, { prelateKills: 1 }, ENFORCE);
  await again.run();
  assert.equal(again.req.body.prelateKills, 0);
});

test('enforce: boss kills on the board are bounded by time, however many summons the shards could buy', async () => {
  const fake = killsFake({ necro: { ...NECRO, unlockedAreas: [...NAVE.unlockedAreas, 'sanctum'] } });
  const r = await send(fake, report(T0, [], { bosses: [{ boss: 'prelate', tier: 0, diff: 'medium', first: false, n: 20 }] }), T0, ENFORCE);
  assert.equal(r.body.data.accepted.bosses, Math.floor(rules.bucketCaps(['sanctum']).bossPerMin * rules.KILLS.FIRST_MINUTES), 'only the first-sight bank');
  const n = necroRequest(fake, { prelateKills: 20 }, ENFORCE);
  await n.run();
  assert.ok(n.req.body.prelateKills <= 7);
});

test('enforce: a failed necromancer save keeps its credits so the retry is not short', async () => {
  const fake = killsFake({ necro: NECRO });
  await send(fake, report(T0, mixed(1)), T0, ENFORCE);
  const n = necroRequest(fake, { areaKills: { graves: 100 } }, ENFORCE);
  await n.run();
  await n.finish(500);
  assert.deepEqual(JSON.parse(fake.ledger(1).kill_credit), { graves: 100 });
  const retry = necroRequest(fake, { areaKills: { graves: 100 } }, ENFORCE);
  await retry.run();
  assert.deepEqual(retry.req.body.areaKills, { graves: 100 });
});

test('the leaderboard\'s kill count cannot be pushed by saving the same claim over and over', async () => {
  const fake = killsFake({ necro: NECRO });
  await send(fake, report(T0, mixed(1)), T0, ENFORCE);
  let total = 0;
  for (let i = 0; i < 20; i++) {
    const n = necroRequest(fake, { areaKills: { graves: 900 } }, ENFORCE);
    await n.run();
    total += n.req.body.areaKills.graves || 0;
    await n.finish();
  }
  assert.equal(total, 100, 'twenty saves of 900 are still the 100 kills that were reported');
});

test('audit: a necromancer save is compared but never changed', async () => {
  const fake = killsFake({ necro: NECRO });
  const n = necroRequest(fake, { areaKills: { graves: 900 }, shards: 30 }, AUDIT);
  await n.run();
  assert.deepEqual(n.req.body.areaKills, { graves: 900 });
  assert.equal(n.req.body.shards, 30);
  assert.deepEqual(fake.audit.map((a) => a.kind).sort(), ['unbacked_kills', 'unbacked_shards']);
});

test('off: the necromancer guard passes the request through untouched', async () => {
  const fake = killsFake({ necro: NECRO });
  const n = necroRequest(fake, { areaKills: { graves: 900 }, shards: 30 }, OFF);
  await n.run();
  assert.deepEqual(n.req.body.areaKills, { graves: 900 });
  assert.equal(fake.ledger(1), undefined);
});

// ── Chronicle: play time, deepest floor, runs ─────────────────────────────────────────────────────────────────────────

test('enforce: play time rises no faster than the clock, however many flushes claim it', async () => {
  const fake = killsFake({ necro: NECRO });
  const log = quietLog();
  const claim = async (deltas, maxes, now) => kills.guardChronicleAdd(fake.pool, { characterId: 1, accountId: 7, deltas, maxes, account: ACCOUNT, now, env: ENFORCE, log });
  let total = 0;
  let r = await claim({ playSeconds: 30 }, {}, T0);
  total += r.deltas.playSeconds;
  assert.equal(r.deltas.playSeconds, 30, 'an honest 30 s flush');
  r = await claim({ playSeconds: 9_999_999 }, {}, T0 + 30_000);
  total += r.deltas.playSeconds;
  assert.ok(r.deltas.playSeconds <= rules.KILLS.PLAY_FIRST_SECONDS + 30, `claimed seconds are capped, got ${r.deltas.playSeconds}`);
  for (let i = 1; i <= 10; i++) total += (await claim({ playSeconds: 3600 }, {}, T0 + 30_000 + i * 1000)).deltas.playSeconds;
  assert.ok(total < rules.KILLS.PLAY_FIRST_SECONDS + 60 + 20, `a minute of wall clock cannot be 99 hours (${total}s)`);
  assert.ok(fake.audit.some((a) => a.kind === 'play_rate'));
});

test('enforce: the deepest floor on the board needs floor clears behind it; honest descents pass', async () => {
  const fake = killsFake({ necro: NAVE, chronicle: { 'peak.depth': 3 } });
  const log = quietLog();
  const claim = async (maxes, now) => (await kills.guardChronicleAdd(fake.pool, { characterId: 1, accountId: 7, deltas: {}, maxes, account: ACCOUNT, now, env: ENFORCE, log })).maxes;
  assert.equal((await claim({ 'peak.depth': 1 }, T0))['peak.depth'], 1, 'entering the stair at depth 1');
  assert.equal((await claim({ 'peak.depth': 999 }, T0 + 1000))['peak.depth'], 4, 'forged 999: the grandfathered 3 plus the flush-race slack');
  await send(fake, report(T0 + 2000, [], { floors: [{ depth: 4, level: 60, clear: true, chest: false, mult: 1 }, { depth: 5, level: 61, clear: true, chest: false, mult: 1 }] }), T0 + 2000, ENFORCE, { char: char({ level: 40 }) });
  assert.equal(fake.ledger(1).depth_proved, 6);
  assert.equal((await claim({ 'peak.depth': 6 }, T0 + 3000))['peak.depth'], 6);
});

test('audit: chronicle claims are compared and logged but pass unchanged', async () => {
  const fake = killsFake({ necro: NECRO });
  const r = await kills.guardChronicleAdd(fake.pool, { characterId: 1, accountId: 7, deltas: { playSeconds: 1e7 }, maxes: { 'peak.depth': 500 }, account: ACCOUNT, now: T0, env: AUDIT, log: quietLog() });
  assert.equal(r.deltas.playSeconds, 1e7);
  assert.equal(r.maxes['peak.depth'], 500);
  assert.deepEqual(fake.audit.map((a) => a.kind).sort(), ['depth_peak', 'play_rate']);
});

test('enforce: runs cannot outnumber Ascensions (the leaderboard\'s runs column)', async () => {
  const fake = killsFake({ necro: { ...NECRO, ascension: 1 } });
  const ok = (runNo, env = ENFORCE) => kills.mayArchiveRun(fake.pool, { characterId: 1, runNo, accountId: 7, account: ACCOUNT, env, log: quietLog() });
  assert.equal(await ok(1), true);
  assert.equal(await ok(2), true, 'the Chronicle call may arrive one ahead of the necromancer record');
  assert.equal(await ok(40), false);
  assert.equal(await ok(40, AUDIT), true);
  assert.equal(await ok(40, OFF), true);
});

test('the chronicle route applies both guards through its optional hooks', async () => {
  const handlers = new Map();
  const app = { get: (p, ...f) => handlers.set(`GET ${p}`, f), post: (p, ...f) => handlers.set(`POST ${p}`, f) };
  const conn = { executed: [], execute: async (sql, p) => { conn.executed.push([sql.trim().replace(/\s+/g, ' '), p]); return sql.includes('SELECT * FROM character_chronicle') ? [[{ life: '{}', run: '{"kills":1}', run_no: 3, run_started_at: null }]] : [{}]; },
    beginTransaction: async () => {}, commit: async () => {}, rollback: async () => {}, release: () => {} };
  const pool = { getConnection: async () => conn, execute: conn.execute };
  const seen = [];
  mountChronicle(app, pool, {
    requireAuth: (_q, _s, n) => n(), ownsCharacter: async () => true, invalidateLeaderboard: () => {},
    guardAdd: async (_req, _c, args) => { seen.push(['add', args]); return { deltas: { playSeconds: 1 }, maxes: {} }; },
    guardAscend: async (_req, _c, args) => { seen.push(['ascend', args]); return false; },
  });
  const res = () => { const r = { code: 200, json: (b) => { r.body = b; return r; }, status: (c) => { r.code = c; return r; } }; return r; };
  const add = handlers.get('POST /api/chronicle/add').at(-1);
  await add({ body: { characterId: 1, deltas: { playSeconds: 99999 }, maxes: {} } }, res());
  const written = conn.executed.find(([sql]) => sql.startsWith('UPDATE character_chronicle SET life'));
  assert.equal(JSON.parse(written[1][0]).playSeconds, 1, 'the hook\'s answer is what gets merged');
  const asc = res();
  await handlers.get('POST /api/chronicle/ascend').at(-1)({ body: { characterId: 1, ascension: 5 } }, asc);
  assert.equal(asc.body.data.archived, false);
  assert.deepEqual(seen.map((s) => s[0]), ['add', 'ascend']);
  assert.equal(seen[1][1].runNo, 3);
});

// ── Leaderboard ───────────────────────────────────────────────────────────────────────────────────────────────────────

test('the leaderboard caps total kills at what the ledger believes in enforce mode, and fails open without the table', async () => {
  const queries = [];
  const handlers = new Map();
  const app = { get: (p, fn) => handlers.set(p, fn) };
  let broken = true;
  const pool = { query: async (sql) => {
    queries.push(sql);
    if (/character_kill_ledger/.test(sql) && broken) throw Object.assign(new Error('no table'), { code: 'ER_NO_SUCH_TABLE' });
    return [[{ username: 'a', class_index: 1, has_discipline: 1, level: 5, ascension: 0, bossKills: 0, totalKills: '12', playSeconds: 0, bestDepth: 0, runs: 0 }]];
  } };
  let mode = 'enforce';
  const invalidate = mountLeaderboard(app, pool, { killsMode: () => mode });
  const send = async () => { const r = { headers: {}, set: (k, v) => { r.headers[k] = v; }, json: (b) => { r.body = b; }, status: (c) => { r.code = c; return r; } }; await handlers.get('/leaderboard')({}, r); invalidate(); return r; };
  const failOpen = await send();
  assert.equal(failOpen.body.players[0].totalKills, 12, 'ledger table missing: the record as stored');
  assert.ok(queries.some((q) => /LEAST/.test(q)), 'enforce tried the ledger join first');
  broken = false;
  queries.length = 0;
  await send();
  assert.ok(/LEAST\(COALESCE\(p\.total_kills, 0\), l\.kills_base \+ l\.kills_total\)/.test(queries[0]));
  mode = 'audit';
  queries.length = 0;
  await send();
  assert.ok(!/LEAST/.test(queries[0]) && !/character_kill_ledger/.test(queries[0]), 'only enforce changes what the board reads');
});

// ── Offline sync, co-op and the rest of the world ─────────────────────────────────────────────────────────────────────

test('offline load: the ledger is re-based on the loaded record, so the loaded XP is not clamped and old credits survive', async () => {
  const fake = killsFake({ necro: { ...NECRO, totalKills: 100 } });
  await send(fake, report(T0, [group({ n: 100 })]), T0, ENFORCE);
  assert.equal(fake.ledger(1).kills_base, 100);
  // The offline snapshot lands: level 60, 40,000 kills, depth 12.
  fake.setNecro({ ...NECRO, totalKills: 40_000 });
  fake.setChronicle({ 'peak.depth': 12 });
  await kills.rebase(fake.pool, 1, quietLog());
  const l = fake.ledger(1);
  assert.equal(l.kills_base, 40_000);
  assert.equal(l.kills_total, 0);
  assert.equal(l.depth_proved, 12);
  // The online character row now holds the loaded XP: the next save echoes it and is a no-gain save.
  const c = char({ level: 60, experience: 300 });
  const v = await saveProgress(fake, c, nextOf(c), T0 + 60_000, ENFORCE);
  assert.equal(v.write.level, 60);
  assert.deepEqual(v.findings, []);
  // The leaderboard bound for it is the new base, so offline kills show.
  assert.equal(l.kills_base + l.kills_total, 40_000);
});

test('co-op guest: kills in the host\'s world are judged at the guest\'s own record plus the rank allowance', async () => {
  const fake = killsFake({ necro: NECRO });
  // The host is Ascension 2: level 7 dead in the Graves. A guest at rank 0 is allowed +2.
  const ok = await send(fake, report(T0, [group({ level: 1 + 2 * 3, rank: 2, xpMult: 1.1, goldMult: 1.1, n: 60 })]), T0, ENFORCE);
  assert.equal(ok.body.data.accepted.kills, 60);
  assert.equal(ok.body.authority, undefined);
  // The guest's save then claims the XP those kills were worth.
  const c = char();
  const xp = 60 * Math.round(Math.round(rules.killXpBase('robber', 7, false, 0, 'medium')) * 1.1);
  const v = await saveProgress(fake, c, nextOf(c, { xp }), T0 + 20_000, ENFORCE);
  assert.equal(arules.totalXp(v.write.level, v.write.xp) - arules.totalXp(c.level, c.experience), xp);
  // A host at rank 9 is not believed for a rank-0 guest.
  const bad = await send(fake, report(T0 + 1000, [group({ level: 1 + 9 * 3, rank: 9, n: 60 })]), T0 + 1000, ENFORCE);
  assert.equal(bad.body.data.accepted.kills, 0);
});

test('co-op guest: a guest\'s kill reward is the host\'s difficulty and wave tier, which the report carries and the server caps', () => {
  const easy = evaluate(report(1, [group({ diff: 'easy' })])).credits.xp;
  const hard = evaluate(report(1, [group({ diff: 'hard', tier: 8 })])).credits.xp;
  assert.ok(hard > easy);
  const forged = evaluate(report(1, [group({ diff: 'hard', tier: 99 })])).credits.xp;
  assert.equal(forged, hard, 'a forged wave tier is capped at the highest tier a player can dial');
});

test('every audit kind the ledger writes fits the progress_audit columns', () => {
  const kinds = ['unbacked_prelate', 'kill_invalid', 'kill_mix', 'kill_elite', 'kill_rate', 'kill_replay', 'boss_invalid', 'boss_rate', 'floor_invalid', 'floor_rate', 'unbacked_xp', 'unbacked_gold', 'unbacked_kills', 'unbacked_shards', 'play_rate', 'depth_peak', 'run_count'];
  for (const k of kinds) assert.ok(k.length <= 24, k);
  for (const m of ['audit', 'enforce', 'report']) assert.ok(m.length <= 8);
  for (const a of ['report', 'clamp', 'drop', 'refuse']) assert.ok(a.length <= 8);
});

// ── The real routes in server.js, through the harness ─────────────────────────────────────────────────────────────────

const { loadServer } = require('./server-harness.cjs');

/** server.js with a pool that knows account 1 owning character 1 (level 10, no XP) on top of the ledger fake. */
function routeServer(necro = NECRO) {
  const fake = killsFake({ necro, characters: { 1: { id: 1, level: 10 } } });
  const owned = { id: 1, account_id: 1, level: 10, experience: 0, gold: 1000, stat_str: 5, stat_agi: 5, stat_int: 5, stat_vit: 10 };
  const run = async (sql, p = []) => {
    const q = sql.trim().replace(/\s+/g, ' ');
    if (/^SELECT \* FROM characters WHERE id = \? AND account_id = \?/.test(q)) return p[0] === 1 && p[1] === 1 ? [[{ ...owned }]] : [[]];
    if (/^SELECT \* FROM characters WHERE id = \?$/.test(q)) return [[{ ...owned }]];
    if (/FROM accounts WHERE id/.test(q)) return [[{ role: 'player', gm_enabled: 0 }]];
    if (/^UPDATE characters SET level=\?, experience=\?, gold=\?/.test(q)) { Object.assign(owned, { level: p[0], experience: p[1], gold: p[2] }); return [{}]; }
    return fake.pool.execute(sql, p);
  };
  const pool = { execute: run, query: run, getConnection: fake.pool.getConnection };
  return { fake, owned, srv: loadServer({ pool }) };
}
async function withEnv(env, fn) {
  const saved = {};
  for (const [k, v] of Object.entries(env)) { saved[k] = process.env[k]; process.env[k] = v; }
  try { return await fn(); } finally { for (const [k, v] of Object.entries(saved)) { if (v === undefined) delete process.env[k]; else process.env[k] = v; } }
}
const quiet = async (fn) => { const w = console.warn; const e = console.error; const l = console.log; console.warn = console.error = console.log = () => {}; try { return await fn(); } finally { console.warn = w; console.error = e; console.log = l; } };

test('route: save-progress carries its kill reports, so the credit is there before the gain is judged', async () => {
  const { srv, owned, fake } = routeServer();
  const earned = mixedXp(2);
  const body = { characterId: 1, level: 10, xp: earned, gold: 1400, stat_str: 5, stat_agi: 5, stat_int: 5, stat_vit: 10, killReports: [report(T0, mixed(2))] };
  const r = await quiet(() => withEnv(ENFORCE, () => srv.call('POST /api/character/save-progress', { body })));
  assert.equal(r.status, 200);
  assert.equal(owned.experience, earned, 'paid in full, in one request');
  assert.equal(r.json.authority, undefined);
  assert.equal(fake.ledger(1).kills_total, 200);
});

test('route: the same save without reports is clamped in enforce, paid in audit, and exactly as before when off', async () => {
  const claim = { characterId: 1, level: 10, xp: 80_000, gold: 9_000_000, stat_str: 5, stat_agi: 5, stat_int: 5, stat_vit: 10 };
  const enforced = routeServer();
  const e = await quiet(() => withEnv(ENFORCE, () => enforced.srv.call('POST /api/character/save-progress', { body: claim })));
  assert.ok(enforced.owned.experience <= rules.KILLS.LUMP_XP_CAP);
  assert.ok(enforced.owned.gold < 1000 + 200_000);
  assert.match(e.json.authority.message, /verified kills|Reload the page/);
  const audited = routeServer();
  await quiet(() => withEnv(AUDIT, () => audited.srv.call('POST /api/character/save-progress', { body: claim })));
  assert.equal(audited.owned.experience, 80_000);
  assert.equal(audited.owned.gold, 9_000_000);
  assert.ok(audited.fake.audit.some((a) => a.kind === 'unbacked_xp'));
  const off = routeServer();
  const o = await quiet(() => withEnv({}, () => off.srv.call('POST /api/character/save-progress', { body: claim })));
  assert.equal(off.owned.experience, 80_000);
  assert.equal(o.json.authority, undefined);
  assert.equal(off.fake.ledger(1), undefined, 'off never touches the ledger');
});

test('route: POST /api/kills/report takes one report or a list, needs a character you own, and answers off quickly', async () => {
  const { srv, fake } = routeServer();
  const ok = await quiet(() => withEnv(AUDIT, () => srv.call('POST /api/kills/report', { body: { characterId: 1, reports: [report(T0, mixed(1)), report(T0 + 1, mixed(1))] } })));
  assert.equal(ok.status, 200);
  assert.equal(ok.json.data.mode, 'audit');
  assert.equal(fake.ledger(1).reports, 2);
  const single = await quiet(() => withEnv(AUDIT, () => srv.call('POST /api/kills/report', { body: { characterId: 1, ...report(T0 + 2, mixed(1)) } })));
  assert.equal(single.json.data.accepted.kills, 100);
  const stranger = await quiet(() => withEnv(AUDIT, () => srv.call('POST /api/kills/report', { body: { characterId: 2, reports: [report(T0 + 3, mixed(1))] } })));
  assert.equal(stranger.status, 403);
  const off = routeServer();
  const o = await quiet(() => withEnv({}, () => off.srv.call('POST /api/kills/report', { body: { characterId: 1, reports: [report(T0, mixed(1))] } })));
  assert.equal(o.json.data.mode, 'off');
  assert.equal(off.fake.ledger(1), undefined);
});

test('route: a malformed report is a 400, not a 500', async () => {
  const { srv } = routeServer();
  const r = await quiet(() => withEnv(AUDIT, () => srv.call('POST /api/kills/report', { body: { characterId: 1, reports: [{ seq: 'nope' }] } })));
  assert.equal(r.status, 400);
});

// ── Gold sinks: an Empowered boss's kill report stamps its bound summon (boss-key.cjs) ───────────────────────────────────

test('a boss kill report that names a summon stamps it in audit and enforce, and not when the mode is off', async () => {
  const seen = [];
  const mk = () => {
    const fake = killsFake({ necro: NAVE });
    const orig = fake.pool.getConnection;
    fake.pool.getConnection = async () => {
      const conn = await orig();
      const run = conn.execute;
      conn.execute = async (sql, p) => (/empowered_summons/.test(sql) ? (seen.push(p), [{}]) : run(sql, p));
      return conn;
    };
    return fake;
  };
  const rep = (seq) => report(seq, [], { bosses: [{ boss: 'abbess', tier: 0, diff: 'medium', first: false, summon: 42, n: 1 }] });
  assert.equal(rules.parseKillReport(rep(5)).bosses[0].summon, 42, 'the summon id survives parsing');
  assert.equal(rules.parseKillReport({ seq: 5, groups: [], floors: [], bosses: [{ boss: 'abbess', summon: -3, n: 1 }] }).bosses[0].summon, undefined, 'junk ids vanish');
  await send(mk(), rep(T0), T0, OFF);
  assert.equal(seen.length, 0, 'off: acknowledged and ignored');
  await send(mk(), rep(T0), T0, AUDIT);
  assert.deepEqual(seen.pop(), [42, 1, 'abbess']);
  await send(mk(), rep(T0), T0, ENFORCE);
  assert.deepEqual(seen.pop(), [42, 1, 'abbess']);
});

test('Depths: a run resumed at the deepest floor is accepted at that depth, and no deeper than one past it', () => {
  // The ledger proved depth 17 (the character cleared 16): max_cleared 16, deepest 17.
  const RESUMED = ctx({ unlocked: NAVE.unlockedAreas, heroLevel: 40, deepest: 17, maxCleared: 16 });
  const clear = (depth) => ({ depth, level: 40 + depth, clear: true, chest: false, mult: 1 });
  const ok = evaluate(report(1, [], { floors: [clear(17), clear(18)] }), RESUMED);
  assert.equal(ok.floorsAccepted, 2, 'floor 17 (the resume point) and the next are both honest');
  assert.equal(ok.depthProved, 19);
  const leap = evaluate(report(1, [], { floors: [clear(19)] }), RESUMED);
  assert.equal(leap.floorsAccepted, 0, 'resuming never lets a run skip past the deepest floor');
  // The dead of depth 17 (level hero + 17, the roster that depth fields) are believable kills for that character.
  const honest = ['robber', 'penitent', 'deacon', 'hound', 'rat'].map((def) => group({ area: 'depths', def, level: 40 + 17, n: 4 }));
  const kill = evaluate(report(2, honest), RESUMED);
  assert.equal(kill.killsAccepted, 20, 'kills at the resumed depth are plausible');
  // The same kills from a character with no record of depth 17 are not.
  const forged = evaluate(report(2, honest), ctx({ unlocked: NAVE.unlockedAreas, heroLevel: 40, deepest: 1 }));
  assert.ok(forged.killsAccepted < 20, 'a character with no record of depth 17 does not get its level-57 dead');
});

for (const [name, vows] of [['no vows sworn', {}], ['vows sworn', { elder_dead: 2, famished: 1 }]]) {
  test(`audit: a character whose save holds vows (${name}) is credited, not NaN (2026-10-06 ER_DATA_OUT_OF_RANGE)`, async () => {
    const fake = killsFake({ necro: { ...NECRO, vows } });
    const r = await send(fake, report(T0, mixed(1)), T0, AUDIT);
    assert.equal(r.body.success, true);
    assert.notEqual(r.body.data.unavailable, true);
    const l = fake.ledger(1);
    assert.ok(Number.isFinite(l.xp_credit) && l.xp_credit > 0, 'xp credit is a number');
    assert.ok(Number.isFinite(l.gold_credit) && l.gold_credit > 0, 'gold credit is a number');
  });
}
