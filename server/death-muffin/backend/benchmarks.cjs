/**
 * Benchmark history (owner 2026-10-13): the Godot client uploads every finished in-game benchmark run; anyone can read the history on
 * site/benchmarks.html. Table benchmark_runs, migration 048.
 *
 *   POST   /api/benchmarks        (auth) one run, see parseRun            -> { success, data: { id } }   a repeated clientRunId answers the first id
 *   GET    /api/benchmarks        (public) newest first; filters room, discipline, size, length, version, gpu, account, standard=1,
 *                                  includeFlagged=1, limit (200, max 1000), before (id)  -> { success, runs: [...] }
 *   GET    /api/benchmarks/:id    (public) one run with metrics, breakdown and the text report
 *   DELETE /api/benchmarks/:id    (auth, staff only) players cannot delete
 *
 * Each route is also mounted without the /api prefix: nginx strips /death-muffin/api, so the site page calls `api/benchmarks` (backend
 * /benchmarks, like /leaderboard) and the game, whose base is /death-muffin/api, calls /api/benchmarks.
 * Everything in a POST is untrusted client data: strings are trimmed, stripped of control characters and capped, numbers must be finite,
 * unknown keys are dropped. Runs that were vsync-capped or cancelled are stored with `flagged` set and left out of the default list.
 * Nothing private (email, account id) is ever returned.
 */
const DAILY_CAP = 60;
const REPORT_MAX = 24000;
const METRIC_KEYS_MAX = 60;
const BREAKDOWN_KEYS_MAX = 40;
const BREAKDOWN_ROWS_MAX = 40;
const LIST_DEFAULT = 200;
const LIST_MAX = 1000;
const PRESETS = ['low', 'medium', 'high', 'ultra'];
const SIZES = ['light', 'standard', 'heavy', 'full_party'];   // (the column is VARCHAR(12))
const LENGTHS = ['quick', 'full'];
const MAX_DISCIPLINE = 20;
const NUM_LIMIT = 1e9;

const CONTROL = /[\u0000-\u0008\u000b-\u001f\u007f]/g;
const CONTROL_LINE = /[\u0000-\u001f\u007f]/g;

/** A trimmed, control-free, length-capped string ('' for anything that is not a string). */
const text = (v, max) => (typeof v === 'string' ? v.replace(CONTROL_LINE, ' ').trim().slice(0, max) : '');
const num = (v) => (typeof v === 'number' && Number.isFinite(v) ? Math.max(-NUM_LIMIT, Math.min(NUM_LIMIT, v)) : null);

/** { key: finite number } with identifier-like keys only, at most `max` keys. */
function cleanNumbers(raw, max) {
  const out = {};
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return out;
  for (const [key, value] of Object.entries(raw)) {
    if (Object.keys(out).length >= max) break;
    if (!/^[a-zA-Z][a-zA-Z0-9_]{0,39}$/.test(key)) continue;
    const n = num(value);
    if (n !== null) out[key] = n;
  }
  return out;
}

function cleanBreakdown(raw) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
  const out = { base: cleanNumbers(raw.base, BREAKDOWN_KEYS_MAX), base_end: cleanNumbers(raw.base_end, BREAKDOWN_KEYS_MAX), rows: [] };
  if (Array.isArray(raw.rows)) {
    for (const r of raw.rows.slice(0, BREAKDOWN_ROWS_MAX)) {
      if (!r || typeof r !== 'object' || Array.isArray(r)) continue;
      const row = { what: text(r.what, 60) };
      Object.assign(row, cleanNumbers({ draws: r.draws, objects: r.objects, render_cpu_ms: r.render_cpu_ms, render_gpu_ms: r.render_gpu_ms, frame_ms: r.frame_ms }, 5));
      if (row.what) out.rows.push(row);
    }
  }
  return out;
}

/** "YYYY-MM-DDTHH:MM:SS" (client clock) -> "YYYY-MM-DD HH:MM:SS", or null. */
function cleanRanAt(v) {
  if (typeof v !== 'string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$/.test(v) || Number.isNaN(Date.parse(`${v}Z`))) return null;
  return v.replace('T', ' ');
}

/** Validate a POST body. Returns { error } or { run }. */
function parseRun(body) {
  const b = body && typeof body === 'object' && !Array.isArray(body) ? body : {};
  if (typeof b.clientRunId !== 'string' || !/^[A-Za-z0-9_-]{8,40}$/.test(b.clientRunId)) return { error: 'This benchmark run has no valid id.' };
  if (!PRESETS.includes(b.preset)) return { error: 'This benchmark run has an unknown graphics preset.' };
  if (typeof b.room !== 'string' || !/^[a-z_]{2,32}$/.test(b.room)) return { error: 'This benchmark run has an unknown room.' };
  if (!Number.isInteger(b.discipline) || b.discipline < 0 || b.discipline > MAX_DISCIPLINE) return { error: 'This benchmark run has an unknown class.' };
  if (!SIZES.includes(b.size) || !LENGTHS.includes(b.length)) return { error: 'This benchmark run has an unknown size or length.' };
  const metrics = cleanNumbers(b.metrics, METRIC_KEYS_MAX);
  if (!Number.isFinite(metrics.avg_fps)) return { error: 'This benchmark run has no frame rate result.' };
  const flagReason = b.cancelled === true ? 'cancelled' : b.vsyncCapped === true ? 'vsync' : null;
  const cores = Number.isInteger(b.cores) && b.cores > 0 ? Math.min(b.cores, 4096) : null;
  const hz = num(b.refreshHz);
  return {
    run: {
      clientRunId: b.clientRunId,
      ranAt: cleanRanAt(b.ranAt),
      version: text(b.version, 40), godot: text(b.godot, 60), gpu: text(b.gpu, 120), cpu: text(b.cpu, 120), os: text(b.os, 40),
      renderer: text(b.renderer, 80), resolution: text(b.resolution, 20),
      cores, refreshHz: hz !== null && hz > 0 ? hz : null,
      preset: b.preset, room: b.room, discipline: b.discipline, size: b.size, length: b.length,
      standard: b.standard === true,
      flagged: flagReason !== null, flagReason,
      metrics,
      breakdown: cleanBreakdown(b.breakdown),
      report: typeof b.report === 'string' ? b.report.replace(CONTROL, '').slice(0, REPORT_MAX) : '',
    },
  };
}

const asJson = (v) => {
  if (v == null) return null;
  if (typeof v !== 'string') return v;
  try { return JSON.parse(v); } catch { return null; }
};
const n = (v) => (v == null ? null : Number(v));
const iso = (d) => (d instanceof Date ? d.toISOString() : d == null ? null : String(d));

function summary(r) {
  return {
    id: Number(r.id), username: String(r.username), createdAt: iso(r.created_at), ranAt: iso(r.ran_at),
    version: r.version, gpu: r.gpu, cpu: r.cpu, cores: n(r.cores), os: r.os, renderer: r.renderer, resolution: r.resolution,
    preset: r.preset, room: r.room, discipline: n(r.discipline_index), size: r.size, length: r.length,
    standard: !!r.standard, flagged: !!r.flagged, flagReason: r.flag_reason || null,
    avgFps: n(r.avg_fps), p95Ms: n(r.p95_ms), p99Ms: n(r.p99_ms), worstMs: n(r.worst_ms), hitches: n(r.hitches),
    drawCalls: n(r.draw_calls), killsPerMin: n(r.kills_per_min),
  };
}

const SUMMARY_COLS = 'b.id, a.username, b.created_at, b.ran_at, b.version, b.gpu, b.cpu, b.cores, b.os, b.renderer, b.resolution, b.preset, b.room, ' +
  'b.discipline_index, b.size, b.length, b.standard, b.flagged, b.flag_reason, b.avg_fps, b.p95_ms, b.p99_ms, b.worst_ms, b.hitches, b.draw_calls, b.kills_per_min';

/** Query string -> { where, params } or { error }. */
function parseFilters(q) {
  const where = ['a.active = 1'];
  const params = [];
  const one = (v) => (typeof v === 'string' ? v : '');
  const room = one(q.room);
  if (room) { if (!/^[a-z_]{2,32}$/.test(room)) return { error: 'Unknown room.' }; where.push('b.room = ?'); params.push(room); }
  const disc = one(q.discipline);
  if (disc !== '') { if (!/^\d{1,2}$/.test(disc) || Number(disc) > MAX_DISCIPLINE) return { error: 'Unknown class.' }; where.push('b.discipline_index = ?'); params.push(Number(disc)); }
  const size = one(q.size);
  if (size) { if (!SIZES.includes(size)) return { error: 'Unknown size.' }; where.push('b.size = ?'); params.push(size); }
  const length = one(q.length);
  if (length) { if (!LENGTHS.includes(length)) return { error: 'Unknown length.' }; where.push('b.length = ?'); params.push(length); }
  const version = text(one(q.version), 40);
  if (version) { where.push('b.version = ?'); params.push(version); }
  const gpu = text(one(q.gpu), 120);
  if (gpu) { where.push("b.gpu LIKE ? ESCAPE '\\\\'"); params.push(`%${gpu.replace(/[\\%_]/g, (c) => `\\${c}`)}%`); }
  const account = text(one(q.account), 32);
  if (account) { where.push('a.username = ?'); params.push(account); }
  if (one(q.standard) === '1') where.push('b.standard = 1');
  if (one(q.includeFlagged) !== '1') where.push('b.flagged = 0');
  const before = one(q.before);
  if (before) { if (!/^\d{1,10}$/.test(before)) return { error: 'Bad paging cursor.' }; where.push('b.id < ?'); params.push(Number(before)); }
  let limit = LIST_DEFAULT;
  const lim = one(q.limit);
  if (lim) { if (!/^\d{1,5}$/.test(lim) || Number(lim) < 1) return { error: 'Bad limit.' }; limit = Math.min(Number(lim), LIST_MAX); }
  return { where: where.join(' AND '), params, limit };
}

module.exports = function mountBenchmarks(app, pool, { requireAuth, isStaff, limiter }) {
  // Every route on both paths (see the header). Express keeps first-match order, so the literal list comes before :id.
  const paths = (p) => [`/api${p}`, p];
  const write = limiter ? [requireAuth, limiter] : [requireAuth];
  const noTable = (res) => res.status(503).json({ success: false, error: 'Benchmark history is not available just yet. Please try again later.' });

  app.post(paths('/benchmarks'), ...write, async (req, res) => {
    const parsed = parseRun(req.body);
    if (parsed.error) return res.status(400).json({ success: false, error: parsed.error });
    const r = parsed.run;
    const account = req.user.accountId;
    try {
      const existing = async () => {
        const [rows] = await pool.execute('SELECT id FROM benchmark_runs WHERE account_id = ? AND client_run_id = ? LIMIT 1', [account, r.clientRunId]);
        return rows[0] ? Number(rows[0].id) : 0;
      };
      const had = await existing();
      if (had) return res.json({ success: true, data: { id: had } });
      const [[{ c }]] = await pool.execute('SELECT COUNT(*) AS c FROM benchmark_runs WHERE account_id = ? AND created_at > NOW() - INTERVAL 1 DAY', [account]);
      if (c >= DAILY_CAP) return res.status(429).json({ success: false, error: 'That is plenty of benchmark runs for one day. Please try again tomorrow.' });
      const m = r.metrics;
      try {
        const [result] = await pool.execute(
          `INSERT INTO benchmark_runs (account_id, client_run_id, ran_at, version, godot, gpu, cpu, cores, os, renderer, resolution, refresh_hz,
             preset, room, discipline_index, size, length, standard, flagged, flag_reason,
             avg_fps, p95_ms, p99_ms, worst_ms, hitches, draw_calls, kills_per_min, metrics, breakdown, report)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
          [account, r.clientRunId, r.ranAt, r.version, r.godot, r.gpu, r.cpu, r.cores, r.os, r.renderer, r.resolution, r.refreshHz,
            r.preset, r.room, r.discipline, r.size, r.length, r.standard ? 1 : 0, r.flagged ? 1 : 0, r.flagReason,
            m.avg_fps, m.p95_ms ?? null, m.p99_ms ?? null, m.worst_ms ?? null, m.hitches === undefined ? null : Math.round(m.hitches), m.draw_calls ?? null, m.kills_per_min ?? null,
            JSON.stringify(m), r.breakdown ? JSON.stringify(r.breakdown) : null, r.report],
        );
        res.json({ success: true, data: { id: Number(result.insertId) } });
      } catch (err) {
        if (err && err.code === 'ER_DUP_ENTRY') return res.json({ success: true, data: { id: await existing() } }); // a retry that raced the first upload
        throw err;
      }
    } catch (err) {
      if (err && err.code === 'ER_NO_SUCH_TABLE') return noTable(res);
      console.error('benchmark save error:', (err && (err.code || err.message)) || err);
      res.status(500).json({ success: false, error: 'The benchmark could not be saved. Please try again.' });
    }
  });

  app.get(paths('/benchmarks'), async (req, res) => {
    res.set('Cache-Control', 'public, max-age=30');
    const f = parseFilters(req.query || {});
    if (f.error) return res.status(400).json({ success: false, error: f.error });
    try {
      const [rows] = await pool.execute(
        `SELECT ${SUMMARY_COLS} FROM benchmark_runs b JOIN accounts a ON a.id = b.account_id WHERE ${f.where} ORDER BY b.id DESC LIMIT ${f.limit}`,
        f.params,
      );
      res.json({ success: true, runs: rows.map(summary) });
    } catch (err) {
      if (err && err.code === 'ER_NO_SUCH_TABLE') return res.json({ success: true, runs: [] });
      console.error('benchmark list error:', (err && (err.code || err.message)) || err);
      res.status(500).json({ success: false, error: 'The benchmark history could not be loaded.' });
    }
  });

  app.get(paths('/benchmarks/:id'), async (req, res) => {
    res.set('Cache-Control', 'public, max-age=30');
    const id = /^\d{1,10}$/.test(String(req.params.id)) ? Number(req.params.id) : 0;
    if (!id) return res.status(404).json({ success: false, error: 'That benchmark run was not found.' });
    try {
      const [rows] = await pool.execute(
        `SELECT ${SUMMARY_COLS}, b.godot, b.refresh_hz, b.metrics, b.breakdown, b.report FROM benchmark_runs b JOIN accounts a ON a.id = b.account_id WHERE b.id = ? AND a.active = 1 LIMIT 1`,
        [id],
      );
      if (!rows[0]) return res.status(404).json({ success: false, error: 'That benchmark run was not found.' });
      const r = rows[0];
      res.json({ success: true, run: { ...summary(r), godot: r.godot, refreshHz: n(r.refresh_hz), metrics: asJson(r.metrics) || {}, breakdown: asJson(r.breakdown), report: r.report || '' } });
    } catch (err) {
      if (err && err.code === 'ER_NO_SUCH_TABLE') return res.status(404).json({ success: false, error: 'That benchmark run was not found.' });
      console.error('benchmark read error:', (err && (err.code || err.message)) || err);
      res.status(500).json({ success: false, error: 'That benchmark run could not be loaded.' });
    }
  });

  app.delete(paths('/benchmarks/:id'), ...write, async (req, res) => {
    try {
      if (!(await isStaff(req))) return res.status(403).json({ success: false, error: 'Only staff can delete benchmark runs.' });
      const id = /^\d{1,10}$/.test(String(req.params.id)) ? Number(req.params.id) : 0;
      if (!id) return res.status(404).json({ success: false, error: 'That benchmark run was not found.' });
      const [result] = await pool.execute('DELETE FROM benchmark_runs WHERE id = ?', [id]);
      if (!result.affectedRows) return res.status(404).json({ success: false, error: 'That benchmark run was not found.' });
      res.json({ success: true });
    } catch (err) {
      if (err && err.code === 'ER_NO_SUCH_TABLE') return noTable(res);
      console.error('benchmark delete error:', (err && (err.code || err.message)) || err);
      res.status(500).json({ success: false, error: 'The benchmark run could not be deleted.' });
    }
  });
};

module.exports.parseRun = parseRun;
module.exports.parseFilters = parseFilters;
module.exports.DAILY_CAP = DAILY_CAP;
