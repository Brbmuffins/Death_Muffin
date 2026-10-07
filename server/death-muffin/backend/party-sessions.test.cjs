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
  assert.equal((await t.join(sid, 2, 12)).status, 409, 'a member that left cannot rejoin');
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
  assert.ok(m.claimedKills === 100_000 && m.accepted.kills < 2_000, `rate cap cut ${m.claimedKills} to ${m.accepted.kills}`);
  assert.ok(t.fake.audit.some((a) => a.kind === 'kill_rate' && a.character_id === 12));
  // Ground and level plausibility: the Drowned Nave is locked for 13; a level-900 robber is not plausible.
  const r2 = await t.report(sid, 1, { batch: 2, members: [entry(13, [group({ area: 'nave', def: 'robber', n: 20 }), group({ level: 900, n: 20 })])] });
  assert.equal(r2.body.data.members[0].accepted.kills, 0);
  assert.ok(t.fake.audit.filter((a) => a.kind === 'kill_invalid' && a.character_id === 13).length >= 1);
  // Elites are capped by share.
  const r3 = await t.report(sid, 1, { batch: 3, members: [entry(11, [group({ def: 'robber', n: 20 }), group({ def: 'robber', elite: true, n: 400 })])] });
  assert.ok(r3.body.data.members[0].accepted.kills < 420);
  assert.ok(t.fake.audit.some((a) => (a.kind === 'kill_elite' || a.kind === 'kill_mix') && a.character_id === 11), 'elite/mix cap fired');
  // Bosses: rate-limited to the member's own boss bucket.
  const r4 = await t.report(sid, 1, { batch: 4, members: [entry(12, [], { bosses: [{ boss: 'gravedigger_king', tier: 0, diff: 'medium', first: true, n: 20 }] })] });
  assert.ok(r4.body.data.members[0].accepted.bosses < 20);
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

test('batches interleave with the member\'s own solo reports (ledger sequence stays monotonic)', async () => {
  const { t, sid } = await party();
  const kills = require('./kills.cjs');
  await t.report(sid, 1, { batch: 1, members: [entry(12, mixed(1))] });
  const seq = t.fake.ledger(12).seq;
  assert.ok(seq >= T0);
  // The member's own client reports with an older seq: replay, ignored, nothing breaks.
  const out = await kills.handleReport(t.fake.pool, { char: { id: 12 }, accountId: 2, body: { seq: seq - 1, groups: mixed(1), bosses: [], floors: [] }, account: { staff: false }, now: T0, env: ENFORCE, log: quietLog() });
  assert.equal(out.body.data.duplicate, true);
  t.advance(10_000);
  const r = await t.report(sid, 1, { batch: 2, members: [entry(12, mixed(1))] });
  assert.ok(t.fake.ledger(12).seq > seq);
  assert.equal(r.body.data.members[0].credited, true);
});

test('bounds: malformed, oversized and repeated-member reports are refused whole', async () => {
  const { t, sid } = await party();
  const bad = async (body, why) => { const r = await t.report(sid, 1, body); assert.equal(r.status, 400, why); assert.equal(t.fake.ledger(12), undefined, why); };
  await bad(null, 'no body');
  await bad({ batch: 0, members: [entry(12, mixed(1))] }, 'batch must be positive');
  await bad({ batch: 'x', members: [entry(12, mixed(1))] }, 'batch must be a number');
  await bad({ batch: 1, members: [] }, 'empty');
  await bad({ batch: 1, members: [entry(12, mixed(1)), entry(12, mixed(1))] }, 'duplicate member');
  await bad({ batch: 1, members: [1, 2, 3, 4, 5].map((i) => entry(10 + i, mixed(1)))}, 'five members');
  await bad({ batch: 1, members: [entry(12, Array.from({ length: 81 }, () => group()))] }, 'too many groups');
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
  assert.equal(limited, 5, 'the 31st..35th report in a minute are refused');
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
