// Run: node --test server/death-muffin/backend/party-sessions.test.cjs
// Host-reported party sessions: lifecycle, member auth, per-member kill-ledger caps, idempotency, limits, session end. Fake DB only.
const test = require('node:test');
const assert = require('node:assert');
const ps = require('./party-sessions.cjs');
const rules = require('./gathering/kill-rules.cjs');
const { sessionsFake } = require('./party-sessions-fake-db.cjs');
const { quietLog } = require('./authority-fake-db.cjs');
const { loadServer } = require('./server-harness.cjs');

const T0 = Date.UTC(2026, 9, 5, 12, 0, 0);
const MIN = 60_000;
const ENFORCE = { AUTHORITY_KILLS: 'enforce' };
const AUDIT = { AUTHORITY_KILLS: 'audit' };
const NECRO = { unlockedAreas: ['chapterhouse', 'graves'], ascension: 0 };

// accounts 1..5 own characters 11..15 (level 10); account 9 owns character 19.
const CHARS = { 11: { id: 11, account_id: 1, level: 10 }, 12: { id: 12, account_id: 2, level: 10 }, 13: { id: 13, account_id: 3, level: 10 }, 14: { id: 14, account_id: 4, level: 10 }, 15: { id: 15, account_id: 5, level: 10 }, 19: { id: 19, account_id: 9, level: 10 } };
const group = (over = {}) => ({ area: 'graves', def: 'robber', level: 1, elite: false, tier: 0, diff: 'medium', rank: 0, xpMult: 1, goldMult: 1, shardMult: 1, n: 50, ...over });
const mixed = (k) => [['robber', 30], ['hound', 25], ['penitent', 20], ['bat', 10], ['moth', 10], ['rat', 5]].map(([def, n]) => group({ def, n: n * k }));
/** A batch small enough for any kind to pass the kill ledger's mix rule whole. */
const FEW = Math.min(10, rules.KILLS.MIX_FLAT);
const mixedXp = (k) => [['robber', 30], ['hound', 25], ['penitent', 20], ['bat', 10], ['moth', 10], ['rat', 5]].reduce((s, [def, n]) => s + n * k * Math.round(rules.killXpBase(def, 1, false, 0, 'medium')), 0);

function setup(env = ENFORCE, extra = {}) {
  const fake = sessionsFake({ characters: CHARS, necro: NECRO, ...extra });
  const log = quietLog();
  const limiter = ps.createLimiter();
  let now = T0;
  const base = () => ({ now, env, log, limiter });
  const api = {
    fake, log, limiter,
    at: (t) => { now = t; },
    advance: (ms) => { now += ms; },
    now: () => now,
    open: (accountId, characterId) => ps.openSession(fake.pool, { ...base(), accountId, characterId }),
    join: (sessionId, accountId, characterId) => ps.joinSession(fake.pool, { ...base(), sessionId, accountId, characterId }),
    beat: (sessionId, accountId, characterId, seenKills) => ps.heartbeat(fake.pool, { ...base(), sessionId, accountId, characterId, seenKills }),
    leave: (sessionId, accountId, characterId) => ps.leaveSession(fake.pool, { ...base(), sessionId, accountId, characterId }),
    report: (sessionId, accountId, body) => ps.reportBatch(fake.pool, { ...base(), sessionId, accountId, body }),
    end: (sessionId, accountId, body) => ps.endSession(fake.pool, { ...base(), sessionId, accountId, body }),
    view: (sessionId, accountId) => ps.viewSession(fake.pool, { ...base(), sessionId, accountId }),
  };
  return api;
}
/** A host (account 1, char 11) with members 12 and 13 attached. */
async function party(env) {
  const t = setup(env);
  const o = await t.open(1, 11);
  const sid = o.body.data.sessionId;
  assert.equal((await t.join(sid, 2, 12)).status, 200);
  assert.equal((await t.join(sid, 3, 13)).status, 200);
  return { t, sid };
}
const entry = (characterId, groups, extra = {}) => ({ characterId, groups, bosses: [], ...extra });

test('lifecycle: open, join, heartbeat, view, leave, end', async () => {
  const t = setup();
  const o = await t.open(1, 11);
  assert.equal(o.status, 200);
  const sid = o.body.data.sessionId;
  assert.match(sid, /^[0-9a-f]{32}$/);
  assert.deepEqual(o.body.data.members.map((m) => m.characterId), [11]);
  assert.equal(o.body.data.limits.maxMembers, 4);
  assert.equal((await t.join(sid, 2, 12)).body.data.members.length, 2);
  t.advance(6_000);
  assert.deepEqual((await t.beat(sid, 2, 12, 3)).body.data, { ok: true, status: 'open' });
  const v = await t.view(sid, 2);
  assert.equal(v.body.data.status, 'open');
  assert.equal((await t.view(sid, 9)).status, 403, 'a stranger cannot read the session');
  assert.equal((await t.leave(sid, 2, 12)).status, 200);
  const back = await t.join(sid, 2, 12);
  assert.equal(back.status, 200, 'a member that left can rejoin');
  assert.deepEqual(back.body.data.members.map((m) => [m.characterId, m.status]), [[11, 'active'], [12, 'active']], 'its old row, active again');
  assert.equal((await t.leave(sid, 2, 12)).status, 200);
  assert.equal((await t.end(sid, 1, {})).body.data.ended, true);
  assert.equal((await t.end(sid, 1, {})).body.data.already, true, 'ending twice is harmless');
  assert.equal((await t.join(sid, 3, 13)).status, 409, 'no joining an ended session');
});

test('member auth: only the character\'s owner can attach or heartbeat', async () => {
  const t = setup();
  const sid = (await t.open(1, 11)).body.data.sessionId;
  assert.equal((await t.join(sid, 2, 13)).status, 403, 'account 2 does not own character 13');
  assert.equal((await t.join(sid, 2, 999)).status, 403);
  assert.equal((await t.open(2, 11)).status, 403, 'a host opens only with its own character');
  await t.join(sid, 2, 12);
  t.advance(10_000);
  assert.equal((await t.beat(sid, 3, 12)).status, 403, 'a heartbeat for someone else\'s character is refused');
  assert.equal((await t.beat('f'.repeat(32), 2, 12)).status, 404);
  assert.equal((await t.join('nothex', 2, 12)).status, 400);
});

test('the party holds four: a fifth is refused, a leaver frees the slot', async () => {
  const t = setup();
  const sid = (await t.open(1, 11)).body.data.sessionId;
  for (const [a, c] of [[2, 12], [3, 13], [4, 14]]) assert.equal((await t.join(sid, a, c)).status, 200);
  const full = await t.join(sid, 5, 15);
  assert.equal(full.status, 409);
  assert.equal(full.body.code, 'full');
  await t.leave(sid, 4, 14);
  assert.equal((await t.join(sid, 5, 15)).status, 200);
  assert.equal((await t.join(sid, 5, 15)).status, 200, 'joining twice is idempotent');
});

test('the host credits each attached member through the kill ledger', async () => {
  const { t, sid } = await party();
  const r = await t.report(sid, 1, { batch: 1, members: [entry(11, mixed(1)), entry(12, mixed(1)), entry(13, mixed(2))] });
  assert.equal(r.status, 200);
  const by = Object.fromEntries(r.body.data.members.map((m) => [m.characterId, m]));
  assert.equal(by[11].accepted.kills, 100);
  assert.equal(by[13].accepted.kills, 200);
  assert.equal(t.fake.ledger(11).xp_credit, mixedXp(1));
  assert.equal(t.fake.ledger(12).xp_credit, mixedXp(1));
  assert.equal(t.fake.ledger(13).xp_credit, mixedXp(2));
  assert.equal(t.fake.ledger(13).kill_credit, JSON.stringify({ graves: 200 }));
  const v = (await t.view(sid, 1)).body.data;
  assert.equal(v.members.find((m) => m.characterId === 13).acceptedKills, 200);
  assert.equal(v.lastBatch, 1);
});

test('a host cannot credit a character whose owner never joined, or who left', async () => {
  const { t, sid } = await party();
  const r = await t.report(sid, 1, { batch: 1, members: [entry(14, mixed(1)), entry(19, mixed(1)), entry(11, mixed(1))] });
  const by = Object.fromEntries(r.body.data.members.map((m) => [m.characterId, m]));
  assert.equal(by[14].reason, 'not_member');
  assert.equal(by[19].reason, 'not_member');
  assert.equal(by[11].credited, true, 'the legitimate member is still paid');
  assert.equal(t.fake.ledger(14), undefined, 'no ledger row was even created for the outsider');
  assert.equal(t.fake.ledger(19), undefined);
  await t.leave(sid, 3, 13);
  const r2 = await t.report(sid, 1, { batch: 2, members: [entry(13, mixed(1))] });
  assert.equal(r2.body.data.members[0].reason, 'left');
  assert.equal(t.fake.ledger(13), undefined);
});

test('a member that left and rejoins keeps its counters and is paid again, once per batch', async () => {
  const { t, sid } = await party();
  assert.equal((await t.report(sid, 1, { batch: 1, members: [entry(13, mixed(1))] })).body.data.members[0].credited, true);
  const before = t.fake.ledger(13).xp_credit;
  const kills1 = (await t.view(sid, 1)).body.data.members.find((m) => m.characterId === 13).acceptedKills;
  assert.ok(kills1 > 0);
  await t.leave(sid, 3, 13);
  assert.equal((await t.join(sid, 3, 13)).status, 200);
  let v = (await t.view(sid, 1)).body.data;
  assert.equal(v.members.filter((m) => m.characterId === 13).length, 1, 'no second row');
  assert.equal(v.members.find((m) => m.characterId === 13).acceptedKills, kills1, 'its counters carried over');
  assert.equal((await t.report(sid, 1, { batch: 1, members: [entry(13, mixed(1))] })).body.data.duplicate, true, 'an old batch is still ignored');
  assert.equal(t.fake.ledger(13).xp_credit, before);
  const r = await t.report(sid, 1, { batch: 2, members: [entry(13, mixed(1))] });
  assert.equal(r.body.data.members[0].credited, true, 'paid again after rejoining');
  v = (await t.view(sid, 1)).body.data;
  assert.equal(v.members.find((m) => m.characterId === 13).acceptedKills, kills1 * 2);
});

test('only the host reports and ends', async () => {
  const { t, sid } = await party();
  const r = await t.report(sid, 2, { batch: 1, members: [entry(12, mixed(1))] });
  assert.equal(r.status, 403);
  assert.equal(r.body.code, 'not_host');
  assert.equal((await t.end(sid, 2, {})).status, 403);
  assert.equal((await t.report(sid, 9, { batch: 1, members: [entry(12, mixed(1))] })).status, 403);
  assert.equal(t.fake.ledger(12), undefined);
});

test('members must have heartbeated recently: a host cannot invent presence', async () => {
  const { t, sid } = await party();
  t.advance(ps.LIMITS.HEARTBEAT_TTL_MS + 1000);
  await t.beat(sid, 2, 12);                // 12 is back, 13 is silent
  const r = await t.report(sid, 1, { batch: 1, members: [entry(11, mixed(1)), entry(12, mixed(1)), entry(13, mixed(1))] });
  const by = Object.fromEntries(r.body.data.members.map((m) => [m.characterId, m]));
  assert.equal(by[11].credited, true, 'the host is present because it is calling');
  assert.equal(by[12].credited, true);
  assert.equal(by[13].reason, 'stale_heartbeat');
  assert.equal(t.fake.ledger(13), undefined);
});

test('caps apply per member exactly as for a solo report: rate, level, ground, elite, boss', async () => {
  const { t, sid } = await party();
  // Rate: a fresh ledger starts with a few minutes in the bank; 100k kills in one batch is cut to the bucket.
  const r = await t.report(sid, 1, { batch: 1, members: [entry(12, mixed(1000))] });
  const m = r.body.data.members[0];
  const firstBank = rules.killsPerMin(NECRO.unlockedAreas) * rules.KILLS.FIRST_MINUTES;
  assert.ok(m.claimedKills === 100_000 && m.accepted.kills <= firstBank, `rate cap cut ${m.claimedKills} to ${m.accepted.kills}`);
  assert.ok(t.fake.audit.some((a) => a.kind === 'kill_rate' && a.character_id === 12));
  // Level plausibility: a robber one level above what the ground can field is not plausible (a locked ground is no longer a reason: a carried member's kills count, see below).
  const r2 = await t.report(sid, 1, { batch: 2, members: [entry(13, [group({ level: rules.maxEnemyLevel('graves', CHARS[13].level, 0) + 1, n: 20 })])] });
  assert.equal(r2.body.data.members[0].accepted.kills, 0);
  assert.ok(t.fake.audit.filter((a) => a.kind === 'kill_invalid' && a.character_id === 13).length >= 1);
  // Elites are capped by share.
  const r3 = await t.report(sid, 1, { batch: 3, members: [entry(11, [group({ def: 'robber', n: 20 }), group({ def: 'robber', elite: true, n: 400 })])] });
  assert.ok(r3.body.data.members[0].accepted.kills < 420);
  assert.ok(t.fake.audit.some((a) => (a.kind === 'kill_elite' || a.kind === 'kill_mix') && a.character_id === 11), 'elite/mix cap fired');
  // Bosses: rate-limited to the member's own boss bucket.
  const r4 = await t.report(sid, 1, { batch: 4, members: [entry(12, [], { bosses: [{ boss: 'gravedigger', tier: 0, diff: 'medium', first: true, n: 20 }] })] });
  assert.ok(r4.body.data.members[0].accepted.bosses > 0 && r4.body.data.members[0].accepted.bosses < 20);
  // The same member alone, same claims, gets the same verdict from the ledger directly.
  const solo = sessionsFake({ characters: CHARS, necro: NECRO });
  const kills = require('./kills.cjs');
  const out = await kills.handleReport(solo.pool, { char: { id: 12 }, accountId: 2, body: { seq: T0 + 1, groups: mixed(1000), bosses: [], floors: [] }, account: { staff: false }, now: T0, env: ENFORCE, log: quietLog() });
  assert.equal(out.body.data.accepted.kills, m.accepted.kills, 'a host report earns exactly what the member could have reported alone');
});

test('Depths floors from a host are dropped (solo activity)', async () => {
  const { t, sid } = await party();
  const r = await t.report(sid, 1, { batch: 1, members: [entry(12, mixed(1), { floors: [{ depth: 5, level: 5, clear: true }] })] });
  assert.equal(r.body.data.members[0].floorsDropped, 1);
  assert.equal(t.fake.ledger(12).floors_total, 0);
});

test('batches are idempotent: a replay or an older number credits nothing', async () => {
  const { t, sid } = await party();
  const body = { batch: 5, members: [entry(12, mixed(1))] };
  const a = await t.report(sid, 1, body);
  assert.equal(a.body.data.members[0].accepted.kills, 100);
  const xp = t.fake.ledger(12).xp_credit;
  const b = await t.report(sid, 1, body);
  assert.equal(b.body.data.duplicate, true);
  assert.equal(t.fake.ledger(12).xp_credit, xp);
  const c = await t.report(sid, 1, { batch: 3, members: [entry(12, mixed(1))] });
  assert.equal(c.body.data.duplicate, true);
  assert.equal(t.fake.ledger(12).xp_credit, xp);
  t.advance(30_000);
  const d = await t.report(sid, 1, { batch: 6, members: [entry(12, mixed(1))] });
  assert.equal(d.body.data.members[0].credited, true);
  assert.ok(t.fake.ledger(12).xp_credit > xp);
  assert.equal((await t.view(sid, 1)).body.data.batches, 2);
});

test('batches interleave with the member\'s own solo reports (each keeps its own order)', async () => {
  const { t, sid } = await party();
  const kills = require('./kills.cjs');
  const solo = (seq) => kills.handleReport(t.fake.pool, { char: { id: 12 }, accountId: 2, body: { seq, groups: mixed(1), bosses: [], floors: [] }, account: { staff: false }, now: T0, env: ENFORCE, log: quietLog() });
  assert.equal((await solo(T0 - 5000)).body.data.accepted.kills > 0, true);
  await t.report(sid, 1, { batch: 1, members: [entry(12, mixed(1))] });
  // A session batch is stamped by the server and deduplicated by its batch number: it does not move the solo order.
  assert.equal(t.fake.ledger(12).seq, T0 - 5000);
  // The member's own client report, behind the server's clock, still counts; its own replay does not.
  assert.equal((await solo(T0 - 1000)).body.data.duplicate, undefined);
  assert.equal((await solo(T0 - 2000)).body.data.duplicate, true);
  t.advance(10_000);
  const r = await t.report(sid, 1, { batch: 2, members: [entry(12, mixed(1))] });
  assert.equal(r.body.data.members[0].credited, true);
  assert.equal(t.fake.ledger(12).seq, T0 - 1000);
});

test('bounds: malformed, oversized and repeated-member reports are refused whole', async () => {
  const { t, sid } = await party();
  const bad = async (body, why) => { const r = await t.report(sid, 1, body); assert.equal(r.status, 400, why); assert.equal(t.fake.ledger(12), undefined, why); };
  await bad(null, 'no body');
  await bad({ batch: 0, members: [entry(12, mixed(1))] }, 'batch must be positive');
  await bad({ batch: 'x', members: [entry(12, mixed(1))] }, 'batch must be a number');
  await bad({ batch: 1, members: [] }, 'empty');
  await bad({ batch: 1, members: [entry(12, mixed(1)), entry(12, mixed(1))] }, 'duplicate member');
  await bad({ batch: 1, members: Array.from({ length: ps.LIMITS.MAX_MEMBERS + 1 }, (_, i) => entry(11 + i, mixed(1))) }, 'more members than a party holds');
  await bad({ batch: 1, members: [entry(12, Array.from({ length: ps.LIMITS.MAX_GROUPS_PER_MEMBER + 1 }, () => group()))] }, 'too many groups');
  await bad({ batch: 1, members: [{ groups: mixed(1) }] }, 'no characterId');
  assert.equal((await t.report('zzz', 1, { batch: 1, members: [entry(12, mixed(1))] })).status, 400);
  assert.equal((await t.report('a'.repeat(32), 1, { batch: 1, members: [entry(12, mixed(1))] })).status, 404);
});

test('rate limits: per session and per host', async () => {
  const { t, sid } = await party();
  let limited = 0;
  for (let i = 1; i <= ps.LIMITS.REPORTS_PER_SESSION_MIN + 5; i++) {
    const r = await t.report(sid, 1, { batch: i, members: [entry(12, [group({ n: 1 })])] });
    if (r.status === 429) limited++;
  }
  assert.equal(limited, 5, 'the five reports past the minute\'s limit are refused');
  const refused = await t.report(sid, 1, { batch: 99, members: [entry(12, [group({ n: 1 })])] });
  assert.equal(refused.body.code, 'rate_limited');
  assert.equal((await t.view(sid, 1)).body.data.lastBatch, ps.LIMITS.REPORTS_PER_SESSION_MIN, 'a refused batch is not consumed: the host may resend it');
  t.advance(61_000);
  assert.equal((await t.report(sid, 1, { batch: 99, members: [entry(12, [group({ n: 1 })])] })).status, 200);

  // A host cannot dodge the per-session limit by opening many sessions: opens are limited per hour.
  const t2 = setup();
  let opens = 0;
  for (let i = 0; i < ps.LIMITS.OPENS_PER_HOST_HOUR + 3; i++) if ((await t2.open(1, 11)).status === 200) opens++;
  assert.equal(opens, ps.LIMITS.OPENS_PER_HOST_HOUR);
  // Per-host report window across two sessions of the same account.
  const t3 = setup();
  const a = (await t3.open(1, 11)).body.data.sessionId;
  let host429 = 0;
  for (let i = 1; i <= ps.LIMITS.REPORTS_PER_HOST_MIN + 3; i++) {
    const r = await t3.report(a, 1, { batch: i, members: [entry(11, [])] });
    if (r.status === 429) host429++;
  }
  assert.ok(host429 >= 3);
});

test('heartbeats are throttled and the host keeps the session alive; an idle session ends itself', async () => {
  const { t, sid } = await party();
  t.advance(6_000);
  assert.equal((await t.beat(sid, 2, 12)).body.data.ok, true);
  assert.equal((await t.beat(sid, 2, 12)).body.data.throttled, true);
  t.advance(ps.LIMITS.SESSION_IDLE_MS / 2);
  assert.equal((await t.report(sid, 1, { batch: 1, members: [entry(11, [])] })).status, 200);
  t.advance(ps.LIMITS.SESSION_IDLE_MS - 1000);
  assert.equal((await t.report(sid, 1, { batch: 1, members: [entry(11, [])] })).status, 200, 'a host report refreshes the idle clock');
  t.advance(ps.LIMITS.SESSION_IDLE_MS + 1000);
  const late = await t.report(sid, 1, { batch: 2, members: [entry(11, mixed(1))] });
  assert.equal(late.status, 409);
  assert.equal(late.body.code, 'session_ended');
  assert.equal((await t.beat(sid, 2, 12)).status, 409);
  assert.equal((await t.join(sid, 4, 14)).status, 409);
});

test('session end: final batch credited, then no more reports; summary kept small; mismatch audited', async () => {
  const { t, sid } = await party(AUDIT);
  t.advance(6_000);
  await t.beat(sid, 2, 12, 5);   // member 12's own client saw 5 kills
  const e = await t.end(sid, 1, { batch: 1, members: [entry(12, mixed(1))], summary: { seconds: 900, waves: 7, evil: 'x'.repeat(5000), nested: { a: 1 }, flag: true } });
  assert.equal(e.status, 200);
  assert.equal(e.body.data.ended, true);
  assert.equal(e.body.data.final.members[0].accepted.kills, 100, 'the final batch is judged like any other');
  const row = t.fake.sessions.get(sid);
  assert.equal(row.status, 'ended');
  assert.deepEqual(JSON.parse(row.summary), { seconds: 900, waves: 7 });
  const mismatch = t.fake.audit.filter((a) => a.kind === 'session_kill_mismatch');
  assert.equal(mismatch.length, 1, 'only the member whose own count disagrees');
  assert.equal(mismatch[0].character_id, 12);
  const after = await t.report(sid, 1, { batch: 2, members: [entry(12, mixed(1))] });
  assert.equal(after.status, 409);
  assert.equal(t.fake.ledger(12).reports, 1);
});

test('a new session supersedes the host\'s old one; a character is in one session at a time', async () => {
  const t = setup();
  const s1 = (await t.open(1, 11)).body.data.sessionId;
  await t.join(s1, 2, 12);
  const s2 = (await t.open(1, 11)).body.data.sessionId;
  assert.equal(t.fake.sessions.get(s1).status, 'ended');
  assert.equal((await t.report(s1, 1, { batch: 1, members: [entry(12, mixed(1))] })).status, 409);
  assert.equal((await t.open(3, 13)).status, 200);
  const s3 = (await t.open(3, 13)).body.data.sessionId;
  await t.join(s2, 2, 12);
  await t.join(s3, 2, 12);   // 12 moves to s3
  const r = await t.report(s2, 1, { batch: 1, members: [entry(12, mixed(1))] });
  assert.equal(r.body.data.members[0].reason, 'left', 'the old host can no longer credit a character that moved on');
});

test('AUTHORITY_KILLS=off: sessions work but nothing is credited; the fake DB failing answers 503', async () => {
  const { t, sid } = await party({});
  const r = await t.report(sid, 1, { batch: 1, members: [entry(12, mixed(1))] });
  assert.equal(r.status, 200);
  assert.equal(r.body.data.mode, 'off');
  assert.equal(t.fake.ledger(12), undefined);
  const dead = setup(ENFORCE, { failWith: Object.assign(new Error('x'), { code: 'ER_NO_SUCH_TABLE' }) });
  assert.equal((await dead.open(1, 11)).status, 503);
});

test('routes: wired through requireAuth with the account from the token', async (tc) => {
  const t_cleanup = (fn) => tc.after(fn);
  const fake = sessionsFake({ characters: CHARS, necro: NECRO });
  const srv = loadServer({ pool: fake.pool });
  process.env.AUTHORITY_KILLS = 'enforce';   // read live on every call, like the kill ledger's own route
  t_cleanup(() => { delete process.env.AUTHORITY_KILLS; });
  const user = (accountId) => ({ accountId, username: `u${accountId}` });
  const o = await srv.call('POST /api/sessions', { body: { characterId: 11 }, user: user(1) });
  assert.equal(o.status, 200, JSON.stringify(o.json));
  const sid = o.json.data.sessionId;
  assert.equal((await srv.call('POST /api/sessions/:id/join', { params: { id: sid }, body: { characterId: 12 }, user: user(2) })).status, 200);
  assert.equal((await srv.call('POST /api/sessions/:id/join', { params: { id: sid }, body: { characterId: 13 }, user: user(2) })).status, 403);
  const r = await srv.call('POST /api/sessions/:id/report', { params: { id: sid }, body: { batch: 1, members: [entry(12, mixed(1))] }, user: user(1) });
  assert.equal(r.status, 200, JSON.stringify(r.json));
  assert.equal(r.json.data.members[0].accepted.kills, 100);
  assert.equal((await srv.call('POST /api/sessions/:id/report', { params: { id: sid }, body: { batch: 2, members: [entry(12, mixed(1))] }, user: user(2) })).status, 403);
  assert.equal((await srv.call('GET /api/sessions/:id', { params: { id: sid }, user: user(2) })).json.data.members.length, 2);
  assert.equal((await srv.call('POST /api/sessions/:id/end', { params: { id: sid }, body: {}, user: user(1) })).json.data.ended, true);
});

test('a carried member earns kills in a ground it has not opened; the Depths and a bad enemy are still refused', async () => {
  const { t, sid } = await party();
  const nave = [group({ area: 'nave', def: 'robber', level: 9, n: FEW })];
  const r = await t.report(sid, 1, { batch: 1, members: [entry(13, nave)] });
  assert.equal(r.body.data.members[0].accepted.kills, FEW, "13 has only the Graves open and still gets the Nave kills");
  assert.equal(JSON.parse(t.fake.ledger(13).kill_credit).nave, FEW, 'and the ledger backs them for its next necromancer save');
  const d = await t.report(sid, 1, { batch: 2, members: [entry(13, [group({ area: 'depths', def: 'robber', n: 5 })])] });
  assert.equal(d.body.data.members[0].accepted.kills, 0, 'the Depths stay a solo descent');
  const solo = sessionsFake({ characters: CHARS, necro: NECRO });
  const out = await require('./kills.cjs').handleReport(solo.pool, { char: { id: 13 }, accountId: 3, body: { seq: T0 + 1, groups: nave, bosses: [], floors: [] }, account: { staff: false }, now: T0, env: ENFORCE, log: quietLog() });
  assert.equal(out.body.data.accepted.kills, 0, 'the same kills reported alone (not carried) are still refused');
});

test('an objective group (a party kill the member was not paid for) counts kills and earns no XP, gold or shards', async () => {
  const { t, sid } = await party();
  const paid = await t.report(sid, 1, { batch: 1, members: [entry(12, [group({ def: 'robber', elite: true, n: 10 })])] });
  const eliteRoom = Math.ceil(10 * rules.maxEliteShare('graves') * rules.KILLS.ELITE_FACTOR) + rules.KILLS.ELITE_FLAT;
  const paidKills = paid.body.data.members[0].accepted.kills;
  assert.equal(paidKills, Math.min(10, eliteRoom), 'the elite share caps the batch');
  const xp1 = t.fake.ledger(12).xp_credit;
  const gold1 = t.fake.ledger(12).gold_credit;
  const shards1 = t.fake.ledger(12).shard_credit;
  assert.ok(xp1 > 0 && shards1 > 0);
  const o = await t.report(sid, 1, { batch: 2, members: [entry(12, [group({ def: 'robber', n: FEW, objective: true })])] });
  assert.equal(o.body.data.members[0].accepted.kills, FEW);
  assert.equal(JSON.parse(t.fake.ledger(12).kill_credit).graves, paidKills + FEW, 'the area tally moves');
  assert.equal(t.fake.ledger(12).xp_credit, xp1, 'no xp');
  assert.equal(t.fake.ledger(12).gold_credit, gold1, 'no gold');
  assert.equal(t.fake.ledger(12).shard_credit, shards1, 'no shards');
});

// ── a member's first kill of a boss is the server's call (a guest never got the first-kill bonus or trophy) ────────────────────────────

test('a member\'s first kill of a boss: the server decides from the Chronicle, pays the +2 shards once and counts the trophy', async () => {
  const { t, sid } = await party();
  const bossEntry = (id, over = {}) => entry(id, [], { bosses: [{ boss: 'saint', tier: 0, diff: 'medium', first: false, n: 1, ...over }] });
  const shards = (id) => (t.fake.ledger(id) || { shard_credit: 0 }).shard_credit;
  const life = () => t.fake.chronicle().life || {};
  // an old client claims its own first kill (13) and a plain one does not (12): what the first-kill bonus is worth, whatever it is tuned to
  const b1 = await t.report(sid, 1, { batch: 1, members: [bossEntry(11, { askFirst: true }), bossEntry(12), bossEntry(13, { first: true })] });
  const by = Object.fromEntries(b1.body.data.members.map((m) => [m.characterId, m]));
  const bonus = shards(13) - shards(12);
  assert.ok(bonus > 0, 'the old claim still pays the first-kill shards');
  assert.deepEqual(by[11].accepted.firstBosses, ['saint'], 'the host asked about member 11 and the server says it is the first');
  assert.equal(shards(11), shards(13), 'and pays it the same bonus');
  assert.equal(by[12].accepted.firstBosses, undefined);
  assert.equal(life()['boss.saint'], 1, 'the trophy: the Chronicle counts the kill (the old claims leave the Chronicle to their clients)');
  assert.equal(t.fake.chronicle().run['boss.saint'], 1, 'in the current run too');
  // the next kill is not a first one
  t.advance(30_000);
  const before = [shards(11), shards(12)];
  const b2 = await t.report(sid, 1, { batch: 2, members: [bossEntry(11, { askFirst: true }), bossEntry(12)] });
  assert.equal(b2.body.data.members[0].accepted.firstBosses, undefined, 'a second kill is no first kill');
  assert.equal(shards(11) - before[0], shards(12) - before[1], 'and pays no bonus');
  assert.equal(life()['boss.saint'], 2);
  // two kills in one entry: one first and one plain
  t.fake.setChronicle({});
  t.advance(30_000);
  const before3 = [shards(11), shards(12)];
  const b3 = await t.report(sid, 1, { batch: 3, members: [bossEntry(11, { askFirst: true, n: 2 }), bossEntry(12, { n: 2 })] });
  assert.deepEqual(b3.body.data.members[0].accepted.firstBosses, ['saint']);
  assert.equal(shards(11) - before3[0], shards(12) - before3[1] + bonus, 'the bonus is paid once for the two kills');
  assert.equal(life()['boss.saint'], 2, 'both kills are counted');
  // a character that killed it before (as a host, say) is not first, and the counter keeps counting
  t.fake.setChronicle({ 'boss.saint': 5 });
  t.advance(30_000);
  const before4 = [shards(11), shards(12)];
  const b4 = await t.report(sid, 1, { batch: 4, members: [bossEntry(11, { askFirst: true }), bossEntry(12)] });
  assert.equal(b4.body.data.members[0].accepted.firstBosses, undefined);
  assert.equal(shards(11) - before4[0], shards(12) - before4[1]);
  assert.equal(life()['boss.saint'], 6);
});

test('asking about a first kill is idempotent, and only for the bosses that have a trophy', async () => {
  const { t, sid } = await party();
  const ask = (boss, over = {}) => entry(12, [], { bosses: [{ boss, tier: 0, diff: 'medium', first: false, askFirst: true, n: 1, ...over }] });
  const life = () => t.fake.chronicle().life || {};
  const a = await t.report(sid, 1, { batch: 1, members: [ask('saint')] });
  assert.deepEqual(a.body.data.members[0].accepted.firstBosses, ['saint']);
  const again = await t.report(sid, 1, { batch: 1, members: [ask('saint')] });
  assert.equal(again.body.data.duplicate, true, 'the same batch again is the replay of a lost answer');
  assert.equal(life()['boss.saint'], 1, 'and counts nothing twice');
  // the Prelate has no first-kill trophy (it is the run\'s boss), and a name that is no boss is ignored
  t.advance(30_000);
  const p = await t.report(sid, 1, { batch: 2, members: [ask('prelate'), ] });
  assert.equal(p.body.data.members[0].accepted.firstBosses, undefined);
  assert.equal(life()['boss.prelate'], undefined);
  t.advance(30_000);
  const junk = await t.report(sid, 1, { batch: 3, members: [ask('constructor')] });
  assert.equal(junk.status, 200);
  assert.equal(junk.body.data.members[0].accepted.firstBosses, undefined);
  // an old client\'s own claim, with no question, is judged as before and leaves the Chronicle alone
  t.advance(30_000);
  const claim = await t.report(sid, 1, { batch: 4, members: [entry(12, [], { bosses: [{ boss: 'regent', tier: 0, diff: 'medium', first: true, n: 1 }] })] });
  assert.equal(claim.body.data.members[0].accepted.bosses, 1);
  assert.equal(claim.body.data.members[0].accepted.firstBosses, undefined);
  assert.equal(life()['boss.regent'], undefined);
});

test('a Chronicle that cannot be written decides nothing and never costs the report', async () => {
  const t = setup();
  const sid = (await t.open(1, 11)).body.data.sessionId;
  const inner = t.fake.pool;
  const failing = async (sql, p) => {
    if (/character_chronicle/.test(sql)) throw Object.assign(new Error('gone'), { code: 'ER_NO_SUCH_TABLE' });
    return inner.execute(sql, p);
  };
  const conn = { ...(await inner.getConnection()), execute: failing, query: failing };
  const pool = { execute: failing, query: failing, getConnection: async () => conn };
  const out = await ps.reportBatch(pool, { sessionId: sid, accountId: 1, body: { batch: 1, members: [entry(11, [], { bosses: [{ boss: 'saint', tier: 0, diff: 'medium', first: false, askFirst: true, n: 1 }] })] }, now: T0, env: ENFORCE, log: quietLog(), limiter: ps.createLimiter() });
  assert.equal(out.status, 200);
  assert.equal(out.body.data.members[0].credited, true);
  assert.equal(out.body.data.members[0].accepted.bosses, 1, 'the kill is still counted');
  assert.equal(out.body.data.members[0].accepted.firstBosses, undefined, 'only no first kill is decided');
});

// ── a member's build (the host builds the guest's hero from the server's record) ─────────────────────────────────────────────────────

test('only the host of a live session reads an active member\'s build: character, worn slots and progression', async () => {
  const { memberBuild } = require('./party-sessions.cjs');
  const SID = 'a'.repeat(32);
  const now = 1_000_000;
  const pool = {
    execute: async (sql, p) => {
      if (/FROM party_sessions WHERE id/.test(sql)) return [[{ id: SID, host_account_id: 1, host_character_id: 10, status: 'open', created_at: now - 1000, last_host_at: now - 1000, last_batch: 0, batches: 0, ended_at: null }]];
      if (/FROM party_session_members WHERE session_id/.test(sql)) return [[{ character_id: 20, account_id: 2, status: 'active', joined_at: now - 500, last_seen_at: now - 100, last_seq: 0, seen_kills: 0, reported_kills: 0, accepted_kills: 0, accepted_bosses: 0 }]];
      if (/FROM characters WHERE id/.test(sql)) return [[{ id: 20, level: 367, experience: 5, class_index: 0, discipline_index: 1, stat_str: 5, stat_agi: 5, stat_int: 9, stat_vit: 12 }]];
      if (/FROM inventory inv/.test(sql)) return [[{ slot_index: 3, item_id: 'ore_copper', equipped: 0 }, { slot_index: 101, item_id: 'set_ossuary_chest', equipped: 1 }, { slot_index: 130, item_id: 'rune_splinter', equipped: 1 }]];
      if (/FROM character_necro_progress/.test(sql)) return [[{ state: JSON.stringify({ boons: { vigil: 2 }, vows: { frail_vessel: 1 }, damageTier: 7, legionTier: 2, shards: 99 }) }]];
      throw new Error(`unexpected ${sql}`);
    },
  };
  const ok = await memberBuild(pool, { sessionId: SID, accountId: 1, memberId: 20, now, log: { error() {} } });
  assert.equal(ok.status, 200);
  assert.equal(ok.body.data.character.level, 367);
  assert.equal(ok.body.data.character.class_index, 1, 'the discipline index');
  assert.deepEqual(ok.body.data.slots.map((r) => r.slot_index), [101, 130], 'worn slots only, not the bag');
  assert.deepEqual(ok.body.data.local, { boons: { vigil: 2 }, vows: { frail_vessel: 1 }, damageTier: 7, legionTier: 2 });
  assert.equal((await memberBuild(pool, { sessionId: SID, accountId: 2, memberId: 20, now, log: { error() {} } })).status, 403, 'a member cannot read another member');
  assert.equal((await memberBuild(pool, { sessionId: SID, accountId: 1, memberId: 99, now, log: { error() {} } })).status, 404, 'only members');
});

// ── a guest's summon in its host's world (DECISIONS B68) ─────────────────────────────────────────────────────────────────────────────

test('partyHostOf / partyOpenAreas: the host of a live party the character is an active guest in, and the areas open in that host\'s world', async () => {
  const SID = 'ab'.repeat(16);
  const now = T0;
  let row = { host_character_id: 11, status: 'open', last_host_at: now - MIN };
  let hostState = JSON.stringify({ unlockedAreas: ['chapterhouse', 'graves', 'cloister'] });
  const seen = [];
  const db = {
    execute: async (sql, p) => {
      seen.push(p);
      if (sql.includes('FROM party_sessions s JOIN party_session_members m')) return [[row && p[0] === SID && p[1] === 12 ? row : undefined].filter(Boolean)];
      if (sql.startsWith('SELECT state FROM character_necro_progress')) return [[p[0] === 11 && hostState != null ? { state: hostState } : undefined].filter(Boolean)];
      throw new Error(`unexpected ${sql}`);
    },
  };
  assert.equal(await ps.partyHostOf(db, SID, 12, now), 11, 'an active guest of a live party: its host');
  assert.deepEqual(await ps.partyOpenAreas(db, SID, 12, now), ['chapterhouse', 'graves', 'cloister'], 'the host\'s open areas');
  assert.equal(await ps.partyHostOf(db, SID, 13, now), 0, 'not a member (or left): none');
  assert.equal(await ps.partyHostOf(db, 'not-a-session', 12, now), 0, 'a malformed id is not looked up');
  assert.equal(seen.filter((p) => p[0] === 'not-a-session').length, 0);
  row = { host_character_id: 12, status: 'open', last_host_at: now };
  assert.equal(await ps.partyHostOf(db, SID, 12, now), 0, 'the host itself is no guest: its own world counts');
  row = { host_character_id: 11, status: 'ended', last_host_at: now };
  assert.equal(await ps.partyHostOf(db, SID, 12, now), 0, 'an ended session');
  row = { host_character_id: 11, status: 'open', last_host_at: now - ps.LIMITS.SESSION_IDLE_MS - 1 };
  assert.equal(await ps.partyHostOf(db, SID, 12, now), 0, 'a host silent too long');
  assert.deepEqual(await ps.partyOpenAreas(db, SID, 12, now), [], 'and no areas');
  row = { host_character_id: 11, status: 'open', last_host_at: now };
  hostState = null;
  assert.deepEqual(await ps.partyOpenAreas(db, SID, 12, now), [], 'a host without a record opens nothing extra');
  const broken = { execute: async () => { throw new Error('db down'); } };
  assert.equal(await ps.partyHostOf(broken, SID, 12, now), 0, 'fails closed');
});
