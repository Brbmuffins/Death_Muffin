/**
 * The Chronicle: lifetime stats that Ascension never resets, plus one archived row per finished run.
 * The client accumulates counters and posts them as deltas; this module validates and merges them. The numbers are
 * cosmetic (a friends-only leaderboard), so validation is about bounds and shape, not anti-cheat.
 *
 *   GET  /api/chronicle/:characterId   -> { life, run, runNo, runStartedAt, runs: [...] }
 *   POST /api/chronicle/add            -> { characterId, deltas: {key: n}, maxes: {key: n} }
 *   POST /api/chronicle/ascend         -> { characterId, ascension }  archives the current run, starts the next
 */

const AREAS = ['chapterhouse', 'acre', 'graves', 'ossuary', 'nave', 'sanctum', 'cloister', 'pyre', 'warren', 'coliseum', 'fen'];
const BOSSES = ['gravedigger', 'abbess', 'congregation', 'prelate', 'saint', 'regent', 'mire'];
const SKILLS = ['woodcutting', 'mining', 'fishing', 'gravedigging', 'gardening'];

/** Counters that add up. Dotted keys group related numbers (kills.graves, boss.saint, gathered.mining). */
const SUM_KEYS = new Set([
  'kills', 'deaths', 'sold', 'crafted', 'contracts', 'playSeconds', 'afkSeconds', 'gold.earned', 'gold.spent',
  ...AREAS.map((a) => `kills.${a}`),
  ...BOSSES.map((b) => `boss.${b}`),
  ...SKILLS.map((s) => `gathered.${s}`),
]);
/** Counters that keep the best value seen. */
const MAX_KEYS = new Set(['peak.level', 'peak.wave']);

const MAX_DELTA = 50_000_000;
/** Interpolated, not bound: mysql2's execute() sends a bound numeric LIMIT as a double and MySQL 8 rejects it (ER_WRONG_ARGUMENTS). */
const MAX_RUNS_RETURNED = 50;

function sanitize(input, allowed) {
  const out = {};
  if (!input || typeof input !== 'object') return out;
  for (const [key, value] of Object.entries(input)) {
    if (!allowed.has(key)) continue;
    const n = Number(value);
    if (!Number.isFinite(n) || n < 0) continue;
    out[key] = Math.min(MAX_DELTA, Math.floor(n));
  }
  return out;
}

/** Fold sanitized deltas/maxes into a counter object (returns a new object). */
function merge(base, deltas, maxes) {
  const out = { ...(base && typeof base === 'object' ? base : {}) };
  for (const [k, v] of Object.entries(deltas)) out[k] = (Number(out[k]) || 0) + v;
  for (const [k, v] of Object.entries(maxes)) out[k] = Math.max(Number(out[k]) || 0, v);
  return out;
}

const parse = (v) => (typeof v === 'string' ? JSON.parse(v) : v) || {};

module.exports = function mountChronicle(app, pool, { requireAuth, ownsCharacter, invalidateLeaderboard }) {
  const ownedId = async (req, res, raw) => {
    const id = parseInt(raw, 10);
    if (!id || !(await ownsCharacter(req, id))) {
      res.status(403).json({ success: false, error: 'character not found or not owned by this account' });
      return null;
    }
    return id;
  };

  /** Read-or-create the row under a lock, run `fn(row)`, and write back what it returns. */
  async function withRow(conn, id, fn) {
    await conn.execute('INSERT IGNORE INTO character_chronicle (character_id, life, run) VALUES (?, ?, ?)', [id, '{}', '{}']);
    const [[row]] = await conn.execute('SELECT * FROM character_chronicle WHERE character_id = ? FOR UPDATE', [id]);
    return fn({ life: parse(row.life), run: parse(row.run), runNo: row.run_no, runStartedAt: row.run_started_at });
  }

  app.get('/api/chronicle/:characterId', requireAuth, async (req, res) => {
    try {
      const id = await ownedId(req, res, req.params.characterId);
      if (!id) return;
      const [rows] = await pool.execute('SELECT * FROM character_chronicle WHERE character_id = ?', [id]);
      const [runs] = await pool.execute(
        `SELECT run_no, started_at, ended_at, ascension_after, stats FROM character_runs WHERE character_id = ? ORDER BY run_no DESC LIMIT ${MAX_RUNS_RETURNED}`,
        [id],
      );
      const row = rows[0];
      res.json({
        success: true,
        data: {
          life: row ? parse(row.life) : {},
          run: row ? parse(row.run) : {},
          runNo: row ? row.run_no : 1,
          runStartedAt: row ? row.run_started_at : null,
          runs: runs.map((r) => ({ runNo: r.run_no, startedAt: r.started_at, endedAt: r.ended_at, ascensionAfter: r.ascension_after, stats: parse(r.stats) })),
        },
      });
    } catch (err) {
      console.error('GET /api/chronicle:', err.code || err.message);
      res.status(500).json({ success: false, error: 'internal server error' });
    }
  });

  app.post('/api/chronicle/add', requireAuth, async (req, res) => {
    const conn = await pool.getConnection();
    try {
      const id = await ownedId(req, res, req.body && req.body.characterId);
      if (!id) return;
      const deltas = sanitize(req.body.deltas, SUM_KEYS);
      const maxes = sanitize(req.body.maxes, MAX_KEYS);
      await conn.beginTransaction();
      await withRow(conn, id, async (row) => {
        await conn.execute('UPDATE character_chronicle SET life = ?, run = ? WHERE character_id = ?', [
          JSON.stringify(merge(row.life, deltas, maxes)),
          JSON.stringify(merge(row.run, deltas, maxes)),
          id,
        ]);
      });
      await conn.commit();
      invalidateLeaderboard && invalidateLeaderboard();
      res.json({ success: true });
    } catch (err) {
      await conn.rollback().catch(() => {});
      console.error('POST /api/chronicle/add:', err.code || err.message);
      if (!res.headersSent) res.status(500).json({ success: false, error: 'internal server error' });
    } finally {
      conn.release();
    }
  });

  app.post('/api/chronicle/ascend', requireAuth, async (req, res) => {
    const conn = await pool.getConnection();
    try {
      const id = await ownedId(req, res, req.body && req.body.characterId);
      if (!id) return;
      const ascension = Math.min(255, Math.max(0, Math.trunc(Number(req.body.ascension)) || 0));
      await conn.beginTransaction();
      const archived = await withRow(conn, id, async (row) => {
        // A double-tap (or a retry) must not archive an empty run: the run needs some activity to count.
        if (!Object.keys(row.run).length) return false;
        await conn.execute(
          'INSERT INTO character_runs (character_id, run_no, started_at, ascension_after, stats) VALUES (?, ?, ?, ?, ?)',
          [id, row.runNo, row.runStartedAt, ascension, JSON.stringify(row.run)],
        );
        await conn.execute(
          "UPDATE character_chronicle SET run = '{}', run_no = run_no + 1, run_started_at = CURRENT_TIMESTAMP WHERE character_id = ?",
          [id],
        );
        return true;
      });
      await conn.commit();
      res.json({ success: true, data: { archived } });
    } catch (err) {
      await conn.rollback().catch(() => {});
      console.error('POST /api/chronicle/ascend:', err.code || err.message);
      if (!res.headersSent) res.status(500).json({ success: false, error: 'internal server error' });
    } finally {
      conn.release();
    }
  });
};

module.exports.sanitize = sanitize;
module.exports.merge = merge;
module.exports.SUM_KEYS = SUM_KEYS;
module.exports.MAX_KEYS = MAX_KEYS;
