/**
 * In-memory stand-in for the tables kills.cjs touches (character_kill_ledger plus the characters row it locks), layered on
 * authority-fake-db.cjs for progress_audit, the necromancer record and the Chronicle. Test helper only (not a test file).
 *
 *   const fake = killsFake({ necro: {...}, characters: { 1: { id: 1, level: 10 } } });
 *   fake.db.execute / fake.pool.getConnection()      the same fake behind both, like a mysql2 pool
 *   fake.ledger(id)  fake.audit
 */
const { authorityFake } = require('./authority-fake-db.cjs');

const COLS = ['seq', 'bucket_at', 'kill_bucket', 'boss_bucket', 'floor_bucket', 'xp_credit', 'gold_credit', 'shard_credit', 'kill_credit',
  'lump_xp', 'lump_gold', 'lump_at', 'play_bucket', 'play_at', 'depth_proved', 'max_cleared', 'kills_base', 'kills_total', 'bosses_total', 'floors_total',
  'xp_total', 'gold_total', 'shards_total', 'xp_used', 'gold_used', 'reports'];

function killsFake({ necro = null, chronicle = null, characters = { 1: { id: 1, level: 10 } }, failWith = null } = {}) {
  const base = authorityFake({ necro, chronicle });
  const ledgers = new Map();
  const blank = (id, depth = 0, kills = 0) => {
    const r = { character_id: id, rejected_kills: 0, last_report_at: null };
    for (const c of COLS) r[c] = ['bucket_at', 'lump_at', 'play_at', 'kill_credit'].includes(c) ? null : 0;
    r.depth_proved = depth; r.max_cleared = depth; r.kills_base = kills;
    return r;
  };
  const handler = (sql, p = []) => {
    sql = sql.trim().replace(/\s+/g, ' ');
    if (failWith && /character_kill_ledger/.test(sql)) throw failWith;
    if (sql.startsWith('SELECT id, level FROM characters WHERE id = ? FOR UPDATE')) return [characters[p[0]] ? [{ ...characters[p[0]] }] : []];
    if (sql.startsWith('SELECT seq, bucket_at')) return [ledgers.has(p[0]) ? [{ ...ledgers.get(p[0]) }] : []];
    if (sql.startsWith('INSERT IGNORE INTO character_kill_ledger')) {
      if (!ledgers.has(p[0])) ledgers.set(p[0], blank(p[0], p[1], p[3]));
      return [{}];
    }
    if (sql.startsWith('INSERT INTO character_kill_ledger') && sql.includes('ON DUPLICATE KEY UPDATE')) {
      const r = ledgers.get(p[0]);
      if (!r) ledgers.set(p[0], blank(p[0], p[1], p[3]));
      else Object.assign(r, { kills_base: p[3], kills_total: 0, kill_credit: null, depth_proved: Math.max(r.depth_proved, p[1]), max_cleared: Math.max(r.max_cleared, p[2]) });
      return [{}];
    }
    if (sql.startsWith('UPDATE character_kill_ledger SET seq = ?')) {
      const r = ledgers.get(p[19]);
      Object.assign(r, { seq: p[0], bucket_at: p[1], kill_bucket: p[2], boss_bucket: p[3], floor_bucket: p[4] });
      r.xp_credit += p[5]; r.gold_credit += p[6]; r.shard_credit += p[7]; r.kill_credit = p[8];
      r.depth_proved = Math.max(r.depth_proved, p[9]); r.max_cleared = Math.max(r.max_cleared, p[10]);
      r.kills_total += p[11]; r.bosses_total += p[12]; r.floors_total += p[13];
      r.xp_total += p[14]; r.gold_total += p[15]; r.shards_total += p[16]; r.reports += 1; r.rejected_kills += p[17]; r.last_report_at = p[18];
      return [{}];
    }
    if (sql.startsWith('UPDATE character_kill_ledger SET lump_xp = ?')) {
      const r = ledgers.get(p[7]);
      Object.assign(r, { lump_xp: p[0], lump_gold: p[1], lump_at: p[2] });
      r.xp_credit = Math.max(0, r.xp_credit - p[3]); r.gold_credit = Math.max(0, r.gold_credit - p[4]); r.xp_used += p[5]; r.gold_used += p[6];
      return [{}];
    }
    if (sql.startsWith('SELECT kill_credit, shard_credit FROM character_kill_ledger')) return [ledgers.has(p[0]) ? [{ ...ledgers.get(p[0]) }] : []];
    if (sql.startsWith('UPDATE character_kill_ledger SET kill_credit = ?, shard_credit')) {
      const r = ledgers.get(p[2]);
      r.kill_credit = p[0]; r.shard_credit = Math.max(0, r.shard_credit - p[1]);
      return [{}];
    }
    if (sql.startsWith('UPDATE character_kill_ledger SET play_bucket = ?')) { Object.assign(ledgers.get(p[2]), { play_bucket: p[0], play_at: p[1] }); return [{}]; }
    return base.handler(sql, p);
  };
  const run = async (sql, p) => {
    const r = handler(sql, p);
    if (r === undefined) throw new Error(`unexpected SQL: ${sql.trim().slice(0, 100)}`);
    if (r[0] && Array.isArray(r[0]) && r[0].length === 0) return [[], []];
    return r;
  };
  const conn = { execute: run, query: run, beginTransaction: async () => {}, commit: async () => {}, rollback: async () => {}, release: () => {} };
  const pool = { execute: run, query: run, getConnection: async () => conn };
  return {
    db: pool, pool, audit: base.audit, authority: base,
    ledger: (id) => ledgers.get(id),
    setNecro: base.setNecro, setChronicle: base.setChronicle,
  };
}

module.exports = { killsFake };
