'use strict';
/**
 * Host-reported party sessions (SESSION-REPORTS.md; Godot rebuild decision D1).
 *
 * A host's game runs a session for 1-4 players. The host reports the kills of each member in batches; this module checks WHO may be
 * credited (only characters whose owner attached with their own JWT, and who are still present) and then hands each member's part to
 * kills.handleReport, the existing kill ledger, with the member's own character, level, unlocked grounds and refilling buckets. So a
 * host's report can never earn a member more than that member could have reported alone. Loot is NOT rolled here: it stays the
 * member's own POST /api/loot/roll-gear (server-rolled, existing guards).
 *
 *   POST /api/sessions                 host   { characterId }                          -> { sessionId, ... }
 *   POST /api/sessions/:id/join        member { characterId }
 *   POST /api/sessions/:id/heartbeat   member { characterId, kills? }                  "I was there"
 *   POST /api/sessions/:id/leave       member or host { characterId }
 *   POST /api/sessions/:id/report      host   { batch, members: [{ characterId, groups, bosses }] }
 *   POST /api/sessions/:id/end         host   { batch?, members?, summary? }
 *   GET  /api/sessions/:id             member or host
 *
 * Everything takes `pool` (or a connection) and an optional `now`/`env`/`log`, like kills.cjs. Time is always the server's.
 */
const crypto = require('crypto');
const kills = require('./kills.cjs');
const { audit } = require('./authority.cjs');

const LIMITS = Object.freeze({
  MAX_MEMBERS: 4,                    // D2: party of four (host included)
  HEARTBEAT_TTL_MS: 120_000,         // a member not seen for this long is not credited until it heartbeats again
  HEARTBEAT_MIN_MS: 5_000,           // heartbeats faster than this are throttled
  SESSION_IDLE_MS: 10 * 60_000,      // a host silent this long ends the session
  MAX_GROUPS_PER_MEMBER: 80,         // tighter than the ledger's own 160: four members must fit one request body
  MAX_BOSSES_PER_MEMBER: 12,
  MAX_BATCH_NUMBER: 1e9,
  MAX_BATCHES_PER_SESSION: 20_000,   // lifetime hard stop (a 6 h session at one batch per second)
  REPORTS_PER_SESSION_MIN: 30,       // sliding window, per session
  REPORTS_PER_HOST_MIN: 90,          // sliding window, per host account across its sessions
  OPENS_PER_HOST_HOUR: 12,
  JOINS_PER_ACCOUNT_MIN: 30,
  SEEN_FACTOR: 2,                    // end-of-session cross-check: accepted > seen * 2 + SEEN_SLACK is audited
  SEEN_SLACK: 25,
  SUMMARY_MAX_BYTES: 2048,
});

const ID_RE = /^[0-9a-f]{32}$/;
const num = (v, d = 0) => (Number.isFinite(Number(v)) ? Number(v) : d);
const fail = (status, code, error, extra = {}) => ({ status, body: { success: false, code, error, ...extra } });
const okRes = (data) => ({ status: 200, body: { success: true, data } });

// ── In-memory sliding-window limiter (one API process; a restart forgets, which only loosens it for a minute) ────────────────────────

function createLimiter() {
  const hits = new Map();
  /** Count one hit for `key`; false (and not counted) when the window already holds `max`. */
  function take(key, max, windowMs, now) {
    const list = (hits.get(key) || []).filter((t) => now - t < windowMs);
    if (list.length >= max) { hits.set(key, list); return false; }
    list.push(now);
    hits.set(key, list);
    if (hits.size > 5000) for (const [k, v] of hits) if (!v.length || now - v[v.length - 1] > 3_600_000) hits.delete(k);
    return true;
  }
  return { take, reset: () => hits.clear() };
}
const defaultLimiter = createLimiter();
const tooMany = () => fail(429, 'rate_limited', 'Too many requests for this session. Slow down.');

// ── Rows ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────

const SESSION_COLS = 'id, host_account_id, host_character_id, status, created_at, last_host_at, last_batch, batches, ended_at';
const MEMBER_COLS = 'character_id, account_id, status, joined_at, last_seen_at, last_seq, seen_kills, reported_kills, accepted_kills, accepted_bosses';

const sessionRow = (r) => r && ({
  id: String(r.id), hostAccountId: num(r.host_account_id), hostCharacterId: num(r.host_character_id), status: String(r.status),
  createdAt: num(r.created_at), lastHostAt: num(r.last_host_at), lastBatch: num(r.last_batch), batches: num(r.batches), endedAt: r.ended_at == null ? null : num(r.ended_at),
});
const memberRow = (r) => ({
  characterId: num(r.character_id), accountId: num(r.account_id), status: String(r.status), joinedAt: num(r.joined_at), lastSeenAt: num(r.last_seen_at),
  lastSeq: num(r.last_seq), seenKills: num(r.seen_kills), reportedKills: num(r.reported_kills), acceptedKills: num(r.accepted_kills), acceptedBosses: num(r.accepted_bosses),
});

async function loadSession(db, id, lock = false) {
  const [[row]] = await db.execute(`SELECT ${SESSION_COLS} FROM party_sessions WHERE id = ?${lock ? ' FOR UPDATE' : ''}`, [id]);
  return sessionRow(row);
}
async function loadMembers(db, id) {
  const [rows] = await db.execute(`SELECT ${MEMBER_COLS} FROM party_session_members WHERE session_id = ?`, [id]);
  return rows.map(memberRow);
}

/** A session is live while it is open and its host has been heard from recently. */
const isLive = (s, now) => !!s && s.status === 'open' && now - s.lastHostAt <= LIMITS.SESSION_IDLE_MS;

const publicMember = (m) => ({ characterId: m.characterId, status: m.status, joinedAt: m.joinedAt, lastSeenAt: m.lastSeenAt, reportedKills: m.reportedKills, acceptedKills: m.acceptedKills, acceptedBosses: m.acceptedBosses });
const publicSession = (s, members, now) => ({
  sessionId: s.id, status: isLive(s, now) ? 'open' : 'ended', hostCharacterId: s.hostCharacterId, createdAt: s.createdAt, lastBatch: s.lastBatch, batches: s.batches,
  members: members.map(publicMember), limits: { maxMembers: LIMITS.MAX_MEMBERS, heartbeatTtlMs: LIMITS.HEARTBEAT_TTL_MS, heartbeatMinMs: LIMITS.HEARTBEAT_MIN_MS, idleMs: LIMITS.SESSION_IDLE_MS },
});

async function withTx(pool, fn, log) {
  const conn = await pool.getConnection();
  try {
    await conn.beginTransaction();
    const out = await fn(conn);
    await conn.commit();
    return out;
  } catch (err) {
    await conn.rollback().catch(() => {});
    throw err;
  } finally {
    conn.release();
  }
}

function unavailable(err, log, what) {
  log.error(`[SESSIONS] ${what} unavailable: ${err.code || err.message}`);
  return fail(503, 'unavailable', 'Party sessions are not available right now.');
}

// ── Lifecycle ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────

/** The host opens a session with one of its own characters. Its previous open sessions end; the character leaves any other session. */
async function openSession(pool, { accountId, characterId, now = Date.now(), limiter = defaultLimiter, log = console }) {
  const cid = Math.trunc(num(characterId));
  if (!(cid > 0)) return fail(400, 'bad_request', 'invalid characterId');
  if (!limiter.take(`open:${accountId}`, LIMITS.OPENS_PER_HOST_HOUR, 3_600_000, now)) return tooMany();
  try {
    return await withTx(pool, async (conn) => {
      const [[c]] = await conn.execute('SELECT id, account_id FROM characters WHERE id = ? FOR UPDATE', [cid]);
      if (!c || num(c.account_id) !== num(accountId)) return fail(403, 'not_owner', 'character not found or not owned by this account');
      await conn.execute("UPDATE party_sessions SET status = 'ended', ended_at = ?, ended_reason = 'superseded' WHERE host_account_id = ? AND status = 'open'", [now, accountId]);
      await conn.execute("UPDATE party_session_members SET status = 'left', left_at = ? WHERE character_id = ? AND status = 'active'", [now, cid]);
      const id = crypto.randomBytes(16).toString('hex');
      await conn.execute('INSERT INTO party_sessions (id, host_account_id, host_character_id, created_at, last_host_at) VALUES (?, ?, ?, ?, ?)', [id, accountId, cid, now, now]);
      await conn.execute('INSERT INTO party_session_members (session_id, character_id, account_id, joined_at, last_seen_at) VALUES (?, ?, ?, ?, ?)', [id, cid, accountId, now, now]);
      return okRes(publicSession({ id, hostCharacterId: cid, createdAt: now, lastBatch: 0, batches: 0, status: 'open', lastHostAt: now }, [{ characterId: cid, status: 'active', joinedAt: now, lastSeenAt: now, reportedKills: 0, acceptedKills: 0, acceptedBosses: 0 }], now));
    }, log);
  } catch (err) { return unavailable(err, log, 'open'); }
}

/** A member proves, with its own JWT and a character it owns, that it is in the session. */
async function joinSession(pool, { sessionId, accountId, characterId, now = Date.now(), limiter = defaultLimiter, log = console }) {
  const cid = Math.trunc(num(characterId));
  if (!ID_RE.test(String(sessionId)) || !(cid > 0)) return fail(400, 'bad_request', 'invalid session or character');
  if (!limiter.take(`join:${accountId}`, LIMITS.JOINS_PER_ACCOUNT_MIN, 60_000, now)) return tooMany();
  try {
    return await withTx(pool, async (conn) => {
      const [[c]] = await conn.execute('SELECT id, account_id FROM characters WHERE id = ? FOR UPDATE', [cid]);
      if (!c || num(c.account_id) !== num(accountId)) return fail(403, 'not_owner', 'character not found or not owned by this account');
      const s = await loadSession(conn, sessionId, true);
      if (!s) return fail(404, 'no_session', 'session not found');
      if (!isLive(s, now)) return fail(409, 'session_ended', 'That session has ended.');
      const members = await loadMembers(conn, sessionId);
      const mine = members.find((m) => m.characterId === cid);
      if (mine && mine.status === 'left') return fail(409, 'left', 'This character left the session and cannot rejoin it.');
      if (!mine) {
        if (members.filter((m) => m.status === 'active').length >= LIMITS.MAX_MEMBERS) return fail(409, 'full', `A session holds ${LIMITS.MAX_MEMBERS} players.`);
        // One session at a time per character: the newest attach wins.
        await conn.execute("UPDATE party_session_members SET status = 'left', left_at = ? WHERE character_id = ? AND status = 'active'", [now, cid]);
        await conn.execute('INSERT INTO party_session_members (session_id, character_id, account_id, joined_at, last_seen_at) VALUES (?, ?, ?, ?, ?)', [sessionId, cid, accountId, now, now]);
      }
      return okRes(publicSession(s, await loadMembers(conn, sessionId), now));
    }, log);
  } catch (err) { return unavailable(err, log, 'join'); }
}

/** "I was there": refreshes the member's presence and records the kills it saw itself (cumulative, monotonic). */
async function heartbeat(pool, { sessionId, accountId, characterId, seenKills, now = Date.now(), log = console }) {
  const cid = Math.trunc(num(characterId));
  if (!ID_RE.test(String(sessionId)) || !(cid > 0)) return fail(400, 'bad_request', 'invalid session or character');
  try {
    const s = await loadSession(pool, sessionId);
    if (!s) return fail(404, 'no_session', 'session not found');
    if (!isLive(s, now)) return fail(409, 'session_ended', 'That session has ended.');
    const m = (await loadMembers(pool, sessionId)).find((x) => x.characterId === cid);
    // The member row carries the owner's account: a heartbeat only counts when it comes from that account's JWT.
    if (!m || m.accountId !== num(accountId)) return fail(403, 'not_member', 'This character is not in that session.');
    if (m.status === 'left') return fail(409, 'left', 'This character left the session.');
    if (now - m.lastSeenAt < LIMITS.HEARTBEAT_MIN_MS) return okRes({ throttled: true });
    const seen = Math.max(0, Math.min(1e7, Math.trunc(num(seenKills))));
    await pool.execute('UPDATE party_session_members SET last_seen_at = ?, seen_kills = GREATEST(seen_kills, ?) WHERE session_id = ? AND character_id = ?', [now, seen, sessionId, cid]);
    return okRes({ ok: true, status: 'open' });
  } catch (err) { return unavailable(err, log, 'heartbeat'); }
}

/** A member leaves; the host may also remove a member. A host leaves by ending the session. */
async function leaveSession(pool, { sessionId, accountId, characterId, now = Date.now(), log = console }) {
  const cid = Math.trunc(num(characterId));
  if (!ID_RE.test(String(sessionId)) || !(cid > 0)) return fail(400, 'bad_request', 'invalid session or character');
  try {
    return await withTx(pool, async (conn) => {
      const s = await loadSession(conn, sessionId, true);
      if (!s) return fail(404, 'no_session', 'session not found');
      const m = (await loadMembers(conn, sessionId)).find((x) => x.characterId === cid);
      if (!m) return fail(403, 'not_member', 'This character is not in that session.');
      const byHost = s.hostAccountId === num(accountId);
      if (!byHost && m.accountId !== num(accountId)) return fail(403, 'not_member', 'This character is not in that session.');
      if (cid === s.hostCharacterId) return fail(400, 'host_cannot_leave', 'The host ends the session instead of leaving it.');
      if (m.status === 'active') await conn.execute("UPDATE party_session_members SET status = 'left', left_at = ? WHERE session_id = ? AND character_id = ?", [now, sessionId, cid]);
      return okRes({ left: true });
    }, log);
  } catch (err) { return unavailable(err, log, 'leave'); }
}

async function viewSession(pool, { sessionId, accountId, now = Date.now(), log = console }) {
  if (!ID_RE.test(String(sessionId))) return fail(400, 'bad_request', 'invalid session');
  try {
    const s = await loadSession(pool, sessionId);
    if (!s) return fail(404, 'no_session', 'session not found');
    const members = await loadMembers(pool, sessionId);
    if (s.hostAccountId !== num(accountId) && !members.some((m) => m.accountId === num(accountId))) return fail(403, 'not_member', 'You are not in that session.');
    return okRes(publicSession(s, members, now));
  } catch (err) { return unavailable(err, log, 'view'); }
}

// ── The report ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────

/** Shape-check one member's part and build the report body the kill ledger takes. Pure. Returns { body } or { error }. */
function memberBody(entry, seq) {
  if (!entry || typeof entry !== 'object') return { error: 'bad member entry' };
  const groups = Array.isArray(entry.groups) ? entry.groups : [];
  const bosses = Array.isArray(entry.bosses) ? entry.bosses : [];
  if (groups.length > LIMITS.MAX_GROUPS_PER_MEMBER || bosses.length > LIMITS.MAX_BOSSES_PER_MEMBER) return { error: 'member report too large' };
  // Depths floors and chests are a solo activity (the party steps out to run them): never accepted from a host.
  return { body: { seq, groups, bosses, floors: [] }, floorsDropped: Array.isArray(entry.floors) ? entry.floors.length : 0 };
}

async function accountIsStaff(db, accountId) {
  try {
    const [[acct]] = await db.execute('SELECT role, gm_enabled FROM accounts WHERE id = ? LIMIT 1', [accountId]);
    return !!acct && (acct.role === 'admin' || acct.role === 'gm' || !!acct.gm_enabled);
  } catch { return false; }
}

/**
 * Judge each member's part with the kill ledger. `session` is the locked, already batch-claimed session. Returns the per-member results.
 * A member is credited only when it is an ACTIVE member, seen within the heartbeat window, and the session is live; everything the
 * ledger would refuse for that member (rate, mix, elite, level, ground, boss caps) it refuses here, per member.
 */
async function creditMembers(pool, { session, entries, now, env, log, isStaff }) {
  const members = await loadMembers(pool, session.id);
  const byId = new Map(members.map((m) => [m.characterId, m]));
  const results = [];
  for (const entry of entries) {
    const cid = Math.trunc(num(entry && entry.characterId));
    const m = byId.get(cid);
    const r = { characterId: cid, credited: false };
    results.push(r);
    if (!m) { r.reason = 'not_member'; continue; }
    if (m.status !== 'active') { r.reason = 'left'; continue; }
    // The host is present by definition (it is calling); everyone else must have heartbeated recently.
    if (cid !== session.hostCharacterId && now - m.lastSeenAt > LIMITS.HEARTBEAT_TTL_MS) { r.reason = 'stale_heartbeat'; continue; }
    const seq = Math.max(now, m.lastSeq + 1);
    const built = memberBody(entry, seq);
    if (built.error) { r.reason = 'bad_report'; continue; }
    if (built.floorsDropped) r.floorsDropped = built.floorsDropped;
    const claimed = built.body.groups.reduce((n, g) => n + Math.max(0, Math.trunc(num(g && g.n))), 0);
    const out = await kills.handleReport(pool, {
      char: { id: cid }, accountId: m.accountId, body: built.body, account: { staff: await isStaff(m.accountId) }, now, env, log,
    });
    if (out.status >= 400) { r.reason = 'rejected'; r.error = out.body && out.body.error; continue; }
    const d = (out.body && out.body.data) || {};
    r.credited = !d.unavailable;
    r.mode = d.mode;
    if (d.duplicate) r.duplicate = true;
    if (d.unavailable) r.reason = 'unavailable';
    const acc = d.accepted || { kills: 0, bosses: 0 };
    r.accepted = { kills: num(acc.kills), bosses: num(acc.bosses) };
    r.claimedKills = claimed;
    // In `off` mode the ledger writes nothing and answers only the mode: nothing is counted, nothing is credited.
    await pool.execute('UPDATE party_session_members SET last_seq = ?, reported_kills = reported_kills + ?, accepted_kills = accepted_kills + ?, accepted_bosses = accepted_bosses + ? WHERE session_id = ? AND character_id = ?',
      [seq, claimed, r.accepted.kills, r.accepted.bosses, session.id, cid]);
    if (out.body && out.body.authority && out.body.authority.message) r.notice = out.body.authority.message;
  }
  return results;
}

/** Validate the report envelope. Pure. Returns { batch, entries } or { error }. */
function parseReport(body) {
  if (!body || typeof body !== 'object') return { error: 'bad report' };
  const batch = Math.trunc(Number(body.batch));
  if (!Number.isFinite(batch) || batch < 1 || batch > LIMITS.MAX_BATCH_NUMBER) return { error: 'batch must be a positive integer' };
  const entries = Array.isArray(body.members) ? body.members : null;
  if (!entries || !entries.length) return { error: 'members must be a non-empty array' };
  if (entries.length > LIMITS.MAX_MEMBERS) return { error: `at most ${LIMITS.MAX_MEMBERS} members per report` };
  const ids = entries.map((e) => Math.trunc(num(e && e.characterId)));
  if (ids.some((i) => !(i > 0)) || new Set(ids).size !== ids.length) return { error: 'each member needs a distinct characterId' };
  for (const e of entries) {
    const mb = memberBody(e, 1);
    if (mb.error) return { error: mb.error };
  }
  return { batch, entries };
}

/** A host's kill batch for its session. Idempotent on `batch`: a repeat or older number is acknowledged and ignored. */
async function reportBatch(pool, { sessionId, accountId, body, now = Date.now(), env = process.env, log = console, limiter = defaultLimiter, isStaff }) {
  if (!ID_RE.test(String(sessionId))) return fail(400, 'bad_request', 'invalid session');
  const parsed = parseReport(body);
  if (parsed.error) return fail(400, 'bad_request', parsed.error);
  const staff = isStaff || ((id) => accountIsStaff(pool, id));
  try {
    // Claim the batch number under the session lock first: a retry or a concurrent twin sees it taken and credits nothing twice.
    // (A crash after the claim loses that batch: the cheaper failure than crediting it twice.)
    const claim = await withTx(pool, async (conn) => {
      const s = await loadSession(conn, sessionId, true);
      if (!s) return { res: fail(404, 'no_session', 'session not found') };
      if (s.hostAccountId !== num(accountId)) return { res: fail(403, 'not_host', 'Only the session host reports for it.') };
      if (!isLive(s, now)) return { res: fail(409, 'session_ended', 'That session has ended.') };
      if (parsed.batch <= s.lastBatch) return { res: okRes({ batch: parsed.batch, duplicate: true, members: [] }) };
      if (s.batches >= LIMITS.MAX_BATCHES_PER_SESSION) return { res: fail(429, 'session_full', 'This session reached its report limit.') };
      if (!limiter.take(`rs:${sessionId}`, LIMITS.REPORTS_PER_SESSION_MIN, 60_000, now) || !limiter.take(`rh:${accountId}`, LIMITS.REPORTS_PER_HOST_MIN, 60_000, now)) return { res: tooMany() };
      await conn.execute('UPDATE party_sessions SET last_batch = ?, batches = batches + 1, last_host_at = ? WHERE id = ?', [parsed.batch, now, sessionId]);
      await conn.execute('UPDATE party_session_members SET last_seen_at = ? WHERE session_id = ? AND character_id = ?', [now, sessionId, s.hostCharacterId]);
      return { session: s };
    }, log);
    if (claim.res) return claim.res;
    const members = await creditMembers(pool, { session: claim.session, entries: parsed.entries, now, env, log, isStaff: staff });
    return okRes({ batch: parsed.batch, mode: kills.killsMode(env), members });
  } catch (err) { return unavailable(err, log, 'report'); }
}

/** Keep only small numeric fields of a host summary; it is informational and never credits anything. */
function cleanSummary(raw) {
  const out = {};
  if (raw && typeof raw === 'object' && !Array.isArray(raw)) {
    for (const [k, v] of Object.entries(raw).slice(0, 24)) {
      if (/^[a-zA-Z][a-zA-Z0-9_]{0,31}$/.test(k) && Number.isFinite(Number(v)) && typeof v !== 'boolean') out[k] = Math.max(-1e12, Math.min(1e12, Number(v)));
    }
  }
  const s = JSON.stringify(out);
  return s.length > LIMITS.SUMMARY_MAX_BYTES ? {} : out;
}

/** The host ends the session (optionally with a final batch). The member totals are then cross-checked with what members saw. */
async function endSession(pool, { sessionId, accountId, body, now = Date.now(), env = process.env, log = console, limiter = defaultLimiter, isStaff }) {
  if (!ID_RE.test(String(sessionId))) return fail(400, 'bad_request', 'invalid session');
  const b = body && typeof body === 'object' ? body : {};
  let finalOut = null;
  try {
    const s0 = await loadSession(pool, sessionId);
    if (!s0) return fail(404, 'no_session', 'session not found');
    if (s0.hostAccountId !== num(accountId)) return fail(403, 'not_host', 'Only the session host ends it.');
    if (s0.status === 'ended') return okRes({ ended: true, already: true });
    if (b.batch != null || b.members != null) {
      finalOut = await reportBatch(pool, { sessionId, accountId, body: b, now, env, log, limiter, isStaff });
      if (finalOut.status >= 400 && finalOut.body.code !== 'session_ended') return finalOut;
    }
    const summary = cleanSummary(b.summary);
    const mode = kills.killsMode(env);
    const res = await withTx(pool, async (conn) => {
      const s = await loadSession(conn, sessionId, true);
      if (s.status === 'ended') return okRes({ ended: true, already: true });
      await conn.execute("UPDATE party_sessions SET status = 'ended', ended_at = ?, ended_reason = 'host_end', summary = ? WHERE id = ?", [now, JSON.stringify(summary), sessionId]);
      const members = await loadMembers(conn, sessionId);
      // Cross-check (audit only): a host that reported far more than a member's own client saw is worth a look.
      for (const m of members) {
        if (m.seenKills > 0 && m.acceptedKills > m.seenKills * LIMITS.SEEN_FACTOR + LIMITS.SEEN_SLACK) {
          await audit(conn, { characterId: m.characterId, accountId: m.accountId, kind: 'session_kill_mismatch', mode, action: 'report', detail: { session: sessionId, accepted: m.acceptedKills, seen: m.seenKills } }, log);
        }
      }
      return okRes({ ended: true, members: members.map(publicMember), ...(finalOut && finalOut.body.data ? { final: finalOut.body.data } : {}) });
    }, log);
    return res;
  } catch (err) { return unavailable(err, log, 'end'); }
}

// ── Routes ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────

/**
 * Mount the routes. `requireAuth` is server.js's requireJWT (sets req.user.accountId); `limiter` an optional express-rate-limit
 * middleware in front of every route (the per-session and per-host limits above work without it).
 */
function mountPartySessions(app, pool, { requireAuth, limiter, env = process.env, now = () => Date.now(), log = console } = {}) {
  const pre = limiter ? [limiter] : [];
  const send = (res, out) => res.status(out.status).json(out.body);
  const route = (method, path, fn) => app[method](path, ...pre, requireAuth, async (req, res) => {
    try { send(res, await fn(req)); } catch (err) {
      log.error(`${req.method} ${req.path}: ${err.message}`);
      if (!res.headersSent) res.status(500).json({ success: false, error: 'internal server error' });
    }
  });
  const base = (req) => ({ sessionId: req.params && req.params.id, accountId: req.user.accountId, characterId: req.body && req.body.characterId, now: now(), log });
  route('post', '/api/sessions', (req) => openSession(pool, { accountId: req.user.accountId, characterId: req.body && req.body.characterId, now: now(), log }));
  route('post', '/api/sessions/:id/join', (req) => joinSession(pool, base(req)));
  route('post', '/api/sessions/:id/heartbeat', (req) => heartbeat(pool, { ...base(req), seenKills: req.body && req.body.kills }));
  route('post', '/api/sessions/:id/leave', (req) => leaveSession(pool, base(req)));
  route('post', '/api/sessions/:id/report', (req) => reportBatch(pool, { ...base(req), body: req.body, env }));
  route('post', '/api/sessions/:id/end', (req) => endSession(pool, { ...base(req), body: req.body, env }));
  route('get', '/api/sessions/:id', (req) => viewSession(pool, base(req)));
}

module.exports = {
  mountPartySessions, openSession, joinSession, heartbeat, leaveSession, viewSession, reportBatch, endSession,
  parseReport, memberBody, cleanSummary, createLimiter, isLive, LIMITS,
};
