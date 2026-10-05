/**
 * In-memory stand-in for party_sessions / party_session_members (+ the characters and accounts rows party-sessions.cjs reads), layered on
 * kills-fake-db.cjs so the kill ledger, the necromancer record and progress_audit behave as in kills.test.cjs. Test helper only.
 *
 *   const fake = sessionsFake({ characters: { 1: { id: 1, level: 10, account_id: 7 } }, necro: {...} });
 *   fake.pool / fake.sessions / fake.members / fake.ledger(id) / fake.audit
 */
const { killsFake } = require('./kills-fake-db.cjs');

function sessionsFake({ characters = {}, accounts = {}, failWith = null, ...rest } = {}) {
  const kf = killsFake({ ...rest, characters });
  const sessions = new Map();
  const members = [];
  const handler = (sql, p = []) => {
    sql = sql.trim().replace(/\s+/g, ' ');
    if (failWith && /party_session/.test(sql)) throw failWith;
    if (sql.startsWith('SELECT id, account_id FROM characters WHERE id = ? FOR UPDATE')) return [characters[p[0]] ? [{ ...characters[p[0]] }] : []];
    if (sql.startsWith('SELECT role, gm_enabled FROM accounts')) return [[{ role: 'player', gm_enabled: 0, ...(accounts[p[0]] || {}) }]];
    if (sql.startsWith("UPDATE party_sessions SET status = 'ended', ended_at = ?, ended_reason = 'superseded'")) {
      for (const s of sessions.values()) if (s.host_account_id === p[1] && s.status === 'open') Object.assign(s, { status: 'ended', ended_at: p[0], ended_reason: 'superseded' });
      return [{}];
    }
    if (sql.startsWith("UPDATE party_session_members SET status = 'left', left_at = ? WHERE character_id = ?")) {
      for (const m of members) if (m.character_id === p[1] && m.status === 'active') Object.assign(m, { status: 'left', left_at: p[0] });
      return [{}];
    }
    if (sql.startsWith('INSERT INTO party_sessions')) {
      sessions.set(p[0], { id: p[0], host_account_id: p[1], host_character_id: p[2], status: 'open', created_at: p[3], last_host_at: p[4], last_batch: 0, batches: 0, ended_at: null, summary: null });
      return [{}];
    }
    if (sql.startsWith('INSERT INTO party_session_members')) {
      members.push({ session_id: p[0], character_id: p[1], account_id: p[2], status: 'active', joined_at: p[3], left_at: null, last_seen_at: p[4], seen_kills: 0, last_seq: 0, reported_kills: 0, accepted_kills: 0, accepted_bosses: 0 });
      return [{}];
    }
    if (sql.startsWith('SELECT id, host_account_id')) return [sessions.has(p[0]) ? [{ ...sessions.get(p[0]) }] : []];
    if (sql.startsWith('SELECT character_id, account_id, status')) return [members.filter((m) => m.session_id === p[0]).map((m) => ({ ...m }))];
    if (sql.startsWith('UPDATE party_session_members SET last_seen_at = ?, seen_kills')) {
      const m = members.find((x) => x.session_id === p[2] && x.character_id === p[3]);
      m.last_seen_at = p[0]; m.seen_kills = Math.max(m.seen_kills, p[1]);
      return [{}];
    }
    if (sql.startsWith('UPDATE party_session_members SET last_seen_at = ? WHERE')) {
      members.find((x) => x.session_id === p[1] && x.character_id === p[2]).last_seen_at = p[0];
      return [{}];
    }
    if (sql.startsWith("UPDATE party_session_members SET status = 'left', left_at = ? WHERE session_id")) {
      Object.assign(members.find((x) => x.session_id === p[1] && x.character_id === p[2]), { status: 'left', left_at: p[0] });
      return [{}];
    }
    if (sql.startsWith('UPDATE party_sessions SET last_batch = ?')) {
      const s = sessions.get(p[2]);
      s.last_batch = p[0]; s.batches += 1; s.last_host_at = p[1];
      return [{}];
    }
    if (sql.startsWith('UPDATE party_session_members SET last_seq = ?')) {
      const m = members.find((x) => x.session_id === p[4] && x.character_id === p[5]);
      m.last_seq = p[0]; m.reported_kills += p[1]; m.accepted_kills += p[2]; m.accepted_bosses += p[3];
      return [{}];
    }
    if (sql.startsWith("UPDATE party_sessions SET status = 'ended', ended_at = ?, ended_reason = 'host_end'")) {
      Object.assign(sessions.get(p[2]), { status: 'ended', ended_at: p[0], ended_reason: 'host_end', summary: p[1] });
      return [{}];
    }
    return undefined;
  };
  const wrap = (inner) => async (sql, p) => {
    const r = handler(sql, p);
    if (r === undefined) return inner(sql, p);
    if (r[0] && Array.isArray(r[0]) && r[0].length === 0) return [[], []];
    return r;
  };
  const run = wrap(kf.pool.execute);
  const conn = { execute: run, query: run, beginTransaction: async () => {}, commit: async () => {}, rollback: async () => {}, release: () => {} };
  const pool = { execute: run, query: run, getConnection: async () => conn };
  return { pool, db: pool, sessions, members, kills: kf, audit: kf.audit, ledger: kf.ledger };
}

module.exports = { sessionsFake };
