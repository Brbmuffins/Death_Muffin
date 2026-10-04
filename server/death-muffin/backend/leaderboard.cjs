/**
 * Server authority step 2: with AUTHORITY_KILLS=enforce the kill count on the board is the necromancer record's, but never more than the kill
 * ledger believes (its base, grandfathered at first sight or after an offline load, plus the kills it has validated since). Level, boss kills and
 * Ascension are paid out of ledger credits by their own routes (save-progress, necro save), and play time, deepest floor and runs are bounded
 * in the Chronicle, so no column on this page is a number the browser can simply assert. A character the ledger has not seen keeps its record.
 */
const ENFORCED_KILLS = 'CASE WHEN l.character_id IS NULL THEN COALESCE(p.total_kills, 0) ELSE LEAST(COALESCE(p.total_kills, 0), l.kills_base + l.kills_total) END';
const PLAIN_KILLS = 'COALESCE(p.total_kills, 0)';

module.exports = function mountLeaderboard(app, pool, { killsMode = () => 'off' } = {}) {
  let cached = null;
  let cachedAt = 0;
  app.get('/leaderboard', async (_req, res) => {
    res.set('Cache-Control', 'public, max-age=30');
    try {
      if (!cached || Date.now() - cachedAt > 30000) {
        const sql = (kills, join) => `
          SELECT a.username, COALESCE(c.discipline_index, c.class_index) AS class_index,
                 c.discipline_index IS NOT NULL AS has_discipline, c.level,
                 COALESCE(p.ascension, 0) AS ascension,
                 COALESCE(p.boss_kills, 0) AS bossKills,
                 ${kills} AS totalKills,
                 COALESCE(CAST(JSON_EXTRACT(cc.life, '$.playSeconds') AS UNSIGNED), 0) AS playSeconds,
                 COALESCE(CAST(JSON_EXTRACT(cc.life, '$."peak.depth"') AS UNSIGNED), 0) AS bestDepth,
                 COALESCE(cc.run_no, 1) - 1 AS runs
          FROM characters c JOIN accounts a ON a.id = c.account_id
          LEFT JOIN character_necro_progress p ON p.character_id = c.id
          LEFT JOIN character_chronicle cc ON cc.character_id = c.id
          ${join}
          WHERE a.active = 1
          ORDER BY ascension DESC, bossKills DESC, totalKills DESC, c.level DESC, c.id ASC
          LIMIT 25
        `;
        let rows;
        if (killsMode() === 'enforce') {
          try {
            [rows] = await pool.query(sql(ENFORCED_KILLS, 'LEFT JOIN character_kill_ledger l ON l.character_id = c.id'));
          } catch (err) {
            // Migration 036 not applied: fail open to the record as stored.
            console.error('Leaderboard ledger unavailable:', err.code || err.message);
          }
        }
        if (!rows) [rows] = await pool.query(sql(PLAIN_KILLS, ''));
        cached = rows.map((row, index) => ({ rank: index + 1, username: row.username, classIndex: row.class_index, hasDiscipline: !!row.has_discipline, level: row.level, ascension: row.ascension, bossKills: row.bossKills, totalKills: Number(row.totalKills) || 0, playSeconds: Number(row.playSeconds) || 0, runs: Number(row.runs) || 0, bestDepth: Number(row.bestDepth) || 0 }));
        cachedAt = Date.now();
      }
      res.json({ players: cached, updatedAt: new Date(cachedAt).toISOString() });
    } catch (err) {
      console.error('Leaderboard error:', err.code || err.message);
      res.status(503).json({ error: 'Leaderboard is temporarily unavailable.' });
    }
  });
  return () => { cached = null; };
};
