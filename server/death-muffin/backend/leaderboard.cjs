module.exports = function mountLeaderboard(app, pool) {
  let cached = null;
  let cachedAt = 0;
  app.get('/leaderboard', async (_req, res) => {
    res.set('Cache-Control', 'public, max-age=30');
    try {
      if (!cached || Date.now() - cachedAt > 30000) {
        const [rows] = await pool.query(`
          SELECT a.username, COALESCE(c.discipline_index, c.class_index) AS class_index,
                 c.discipline_index IS NOT NULL AS has_discipline, c.level,
                 COALESCE(p.ascension, 0) AS ascension,
                 COALESCE(p.boss_kills, 0) AS bossKills,
                 COALESCE(p.total_kills, 0) AS totalKills,
                 COALESCE(CAST(JSON_EXTRACT(cc.life, '$.playSeconds') AS UNSIGNED), 0) AS playSeconds,
                 COALESCE(CAST(JSON_EXTRACT(cc.life, '$."peak.depth"') AS UNSIGNED), 0) AS bestDepth,
                 COALESCE(cc.run_no, 1) - 1 AS runs
          FROM characters c JOIN accounts a ON a.id = c.account_id
          LEFT JOIN character_necro_progress p ON p.character_id = c.id
          LEFT JOIN character_chronicle cc ON cc.character_id = c.id
          WHERE a.active = 1
          ORDER BY ascension DESC, bossKills DESC, totalKills DESC, c.level DESC, c.id ASC
          LIMIT 25
        `);
        cached = rows.map((row, index) => ({ rank: index + 1, username: row.username, classIndex: row.class_index, hasDiscipline: !!row.has_discipline, level: row.level, ascension: row.ascension, bossKills: row.bossKills, totalKills: row.totalKills, playSeconds: Number(row.playSeconds) || 0, runs: Number(row.runs) || 0, bestDepth: Number(row.bestDepth) || 0 }));
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
