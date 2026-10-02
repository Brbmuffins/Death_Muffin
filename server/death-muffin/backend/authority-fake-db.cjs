/**
 * In-memory stand-in for the tables authority.cjs touches (character_authority, progress_audit, character_necro_progress and the
 * items' sell values), dispatched on the SQL text like bag-fake-db.cjs. Test helper only (not a test file).
 *
 *   const auth = authorityFake({ necro: { unlockedAreas: [...], ascension: 0 } });
 *   auth.db            a pool-like { execute, query } on its own
 *   auth.handler       (sql, params) => result | undefined, for bag-fake-db's `extra` hook
 *   auth.rows / auth.audit / auth.state(id)
 */
function authorityFake({ necro = null, sell = {}, failWith = null } = {}) {
  const rows = new Map(); // character_id -> row
  const audit = [];
  const blank = (id) => ({ character_id: id, xp_bucket: 0, gold_bucket: 0, bucket_at: null, gold_credit: 0, item_budget: null, last_progress_at: null, last_bag_at: null, xp_accepted: 0, gold_accepted: 0, flags: 0 });
  let necroState = necro;

  const handler = (sql, p = []) => {
    sql = sql.trim().replace(/\s+/g, ' ');
    if (failWith && /character_authority|progress_audit/.test(sql)) throw failWith;
    if (sql.startsWith('INSERT IGNORE INTO character_authority')) {
      if (!rows.has(p[0])) rows.set(p[0], blank(p[0]));
      return [{}];
    }
    if (sql.startsWith('SELECT xp_bucket, gold_bucket, bucket_at, gold_credit, item_budget, flags FROM character_authority')) return [[{ ...rows.get(p[0]) }]];
    if (sql.startsWith('UPDATE character_authority SET xp_bucket = ?')) {
      const r = rows.get(p[8]);
      Object.assign(r, { xp_bucket: p[0], gold_bucket: p[1], bucket_at: p[2], last_progress_at: p[3], gold_credit: Math.max(0, r.gold_credit - p[4]) });
      r.xp_accepted += p[5]; r.gold_accepted += p[6]; r.flags += p[7];
      return [{}];
    }
    if (sql.startsWith('UPDATE character_authority SET item_budget = ?, last_bag_at = ?')) {
      const r = rows.get(p[5]);
      Object.assign(r, { item_budget: p[0], last_bag_at: p[1], gold_credit: Math.min(p[2], r.gold_credit + p[3]) });
      r.flags += p[4];
      return [{}];
    }
    if (sql.startsWith('UPDATE character_authority SET item_budget = ?, flags = flags + 1')) {
      const r = rows.get(p[1]);
      r.item_budget = p[0]; r.flags += 1;
      return [{}];
    }
    if (sql.startsWith('UPDATE character_authority SET item_budget = ? WHERE')) { rows.get(p[1]).item_budget = p[0]; return [{}]; }
    if (sql.startsWith('UPDATE character_authority SET flags = flags + 1')) { rows.get(p[0]).flags += 1; return [{}]; }
    if (sql.startsWith('INSERT INTO progress_audit')) {
      audit.push({ character_id: p[0], account_id: p[1], kind: p[2], mode: p[3], action: p[4], detail: JSON.parse(p[5]) });
      return [{}];
    }
    if (sql.startsWith('SELECT state FROM character_necro_progress')) return [necroState ? [{ state: JSON.stringify(necroState) }] : []];
    if (sql.startsWith('SELECT id, sell_value FROM items')) return [p[0].map((id) => ({ id, sell_value: sell[id] ?? 10 }))];
    return undefined;
  };
  const run = async (sql, p) => {
    const r = handler(sql, p);
    if (r === undefined) throw new Error(`unexpected SQL: ${sql.trim().slice(0, 90)}`);
    // mysql2 returns [rows]; `const [[row]] = ...` on an empty result gets undefined, as in production.
    if (r[0] && Array.isArray(r[0]) && r[0].length === 0) return [[], []];
    return r;
  };
  return {
    handler, audit, rows,
    state: (id) => rows.get(id),
    setNecro: (n) => { necroState = n; },
    db: { execute: run, query: run },
  };
}

/** A `log` that records instead of printing. */
const quietLog = () => { const lines = []; return { lines, warn: (m) => lines.push(m), error: (m) => lines.push(m), log: (m) => lines.push(m) }; };

module.exports = { authorityFake, quietLog };
