'use strict';
/**
 * Play reports (ROADMAP Phase 1, "New: play reports"): when a play session ends the game sends one small summary of how it ran; the public
 * page site/play-reports.html shows the numbers per release, beside the server's own numbers. Table play_reports, migration 056.
 *
 *   POST /api/play-reports                (auth) one report, see parseReport  -> { success, data: { id } }   a repeated reportId answers the first id
 *   GET  /api/play-reports/releases       (public) -> { success, releases: [{ version, reports, players, hours, first, last }] }   newest first
 *   GET  /api/play-reports/summary?version=<v>  (public) -> { success, summary }   see summarize and serverNumbers
 *
 * Each route is also mounted without the /api prefix, like benchmarks.cjs: nginx strips /death-muffin/api, so the site calls `api/play-reports/...`
 * (backend /play-reports/...) and the game, whose base is /death-muffin/api, calls /api/play-reports.
 * Errors are { success: false, code, error }: 400 bad_request, 401 unauthorized, 429 rate_limited (50 reports a day per account), 503 unavailable
 * (the table is missing; apply migration 056 first), 500 server_error.
 * Everything in a POST is untrusted client data: unknown keys are dropped, strings are trimmed, stripped of control characters and capped,
 * numbers must be finite and are clamped. The account id is kept only to count players and cap spam; the party session ids a report names are
 * invites to live sessions. Neither is ever returned, and nothing else personal is stored.
 */
const DAILY_CAP = 50;
const SUMMARY_ROWS_MAX = 20000;   // newest reports of one release the summary reads
const RELEASES_MAX = 200;
const GPU_TOP = 15;
const LIST_MAX = 40;              // distinct areas / end areas the summary lists
const SESSIONS_MAX = 5000;        // party sessions the server numbers read
const CHUNK = 500;
const CACHE_MS = 60 * 1000;
const CACHE_ENTRIES = 64;

const END_REASONS = ['quit', 'logout', 'switch', 'crash', 'disconnect', 'unknown'];
const PRESETS = ['low', 'medium', 'high', 'ultra', 'custom'];
const REPORT_ID_RE = /^[A-Za-z0-9_-]{16,64}$/;
const VERSION_RE = /^[A-Za-z0-9][A-Za-z0-9._+~-]{0,39}$/;
const NAME_RE = /^[A-Za-z0-9_-]{1,64}$/;      // a party session id as the game sends it (the server's own are 32 hex characters)
const PARTY_ID_RE = /^[0-9a-f]{32}$/;
const AREA_RE = /^[A-Za-z0-9_-]{1,24}$/;
const MS_MAX = 600000;                         // a frame time over ten minutes is not a frame time
const COUNT_MAX = 1e9;
const HIDDEN = /[\u0000-\u001f\u007f-\u009f\u200b-\u200f\u2028-\u202e\u2066-\u2069\ufeff]/g;

const isObject = (v) => !!v && typeof v === 'object' && !Array.isArray(v);
const finite = (v) => typeof v === 'number' && Number.isFinite(v);
/** A trimmed, control-free, length-capped string ('' for anything that is not a string). Tabs and line breaks become a space first. */
const text = (v, max) => (typeof v === 'string' ? v.replace(/[\t\n\r]+/g, ' ').replace(HIDDEN, '').trim().slice(0, max).trim() : '');
const clampNum = (v, lo, hi) => (finite(v) ? Math.min(hi, Math.max(lo, v)) : null);
const clampInt = (v, lo, hi) => (finite(v) ? Math.min(hi, Math.max(lo, Math.round(v))) : null);

function cleanFrames(raw) {
  const f = isObject(raw) ? raw : {};
  const ms = (v) => clampNum(v, 0, MS_MAX);
  const hist = Array.isArray(f.hist) && f.hist.length === 9 && f.hist.every(finite) ? f.hist.map((v) => clampInt(v, 0, COUNT_MAX)) : null;
  return { count: clampInt(f.count, 0, COUNT_MAX) ?? 0, avgMs: ms(f.avgMs), p50Ms: ms(f.p50Ms), p99Ms: ms(f.p99Ms), worstMs: ms(f.worstMs), hitches: clampInt(f.hitches, 0, COUNT_MAX) ?? 0, hist };
}

/** { "<area id>": { seconds, deaths, avgMs } }: at most 24 areas, identifier-like ids, a finite play time each. */
function cleanAreas(raw) {
  const out = {};
  if (!isObject(raw)) return out;
  for (const [id, a] of Object.entries(raw)) {
    if (Object.keys(out).length >= 24) break;
    if (!AREA_RE.test(id) || !isObject(a) || !finite(a.seconds)) continue;
    out[id] = { seconds: clampNum(a.seconds, 0, 86400), deaths: clampInt(a.deaths, 0, 100000) ?? 0, avgMs: clampNum(a.avgMs, 0, MS_MAX) };
  }
  return out;
}

function cleanSessionIds(raw) {
  const out = [];
  if (!Array.isArray(raw)) return out;
  for (const v of raw) {
    const id = typeof v === 'string' ? v.trim() : '';
    if (NAME_RE.test(id) && !out.includes(id)) out.push(id);
    if (out.length >= 20) break;
  }
  return out;
}

/**
 * Validate a POST body. Returns { error } or { report }. Three things make a report unusable: no valid reportId, version or play time.
 * Anything else that is missing or wrong is cleaned to its safe value (a crash found at the next start may know very little).
 */
function parseReport(body) {
  const b = isObject(body) ? body : {};
  const reportId = typeof b.reportId === 'string' ? b.reportId.trim() : '';
  if (!REPORT_ID_RE.test(reportId)) return { error: 'This play report has no valid id.' };
  const version = text(b.version, 40);
  if (!VERSION_RE.test(version)) return { error: 'This play report has no valid game version.' };
  if (!finite(b.seconds)) return { error: 'This play report has no play time.' };
  const preset = typeof b.preset === 'string' ? b.preset.trim() : '';
  return {
    report: {
      reportId, version,
      seconds: clampNum(b.seconds, 0, 86400),
      endReason: END_REASONS.includes(b.endReason) ? b.endReason : 'unknown',
      endArea: text(b.endArea, 24),
      discipline: clampInt(b.discipline, 0, 20),
      level: clampInt(b.level, 0, 200),
      partySize: clampInt(b.partySize, 1, 4),
      host: b.host === true,
      preset: PRESETS.includes(preset) ? preset : null,
      gpu: text(b.gpu, 120), driver: text(b.driver, 60), os: text(b.os, 40), resolution: text(b.resolution, 20),
      cpuCores: clampInt(b.cpuCores, 1, 512),
      ramMb: clampInt(b.ramMb, 0, 4194304),
      vsync: typeof b.vsync === 'boolean' ? b.vsync : null,
      fpsCap: clampInt(b.fpsCap, 0, 1000),
      frames: cleanFrames(b.frames),
      areas: cleanAreas(b.areas),
      sessionIds: cleanSessionIds(b.sessionIds),
    },
  };
}

// ── The numbers ──────────────────────────────────────────────────────────────────────────────────────────────────────────

const asJson = (v) => {
  if (v == null) return null;
  if (typeof v !== 'string') return v;
  try { return JSON.parse(v); } catch { return null; }
};
const num = (v) => (v == null || v === '' || !Number.isFinite(Number(v)) ? null : Number(v));
const iso = (d) => (d instanceof Date ? d.toISOString() : d == null ? null : String(d));
const sum = (xs) => xs.reduce((a, b) => a + b, 0);
const round2 = (v) => (v == null || !Number.isFinite(v) ? null : Math.round(v * 100) / 100);
const perHour = (total, hours) => (hours > 0 ? round2(total / hours) : null);

function median(xs) {
  const s = xs.filter((v) => v != null && Number.isFinite(v)).sort((a, b) => a - b);
  if (!s.length) return null;
  const mid = s.length >> 1;
  return s.length % 2 ? s[mid] : (s[mid - 1] + s[mid]) / 2;
}

/** A play_reports row (the columns the summary reads) as plain numbers. */
function readRow(r) {
  return {
    account: Number(r.account_id), seconds: Number(r.seconds) || 0, endReason: String(r.end_reason || 'unknown'), endArea: r.end_area ? String(r.end_area) : '',
    preset: r.preset ? String(r.preset) : 'unknown', gpu: r.gpu ? String(r.gpu) : 'Unknown graphics card',
    frames: Number(r.frames_count) || 0, avgMs: num(r.avg_ms), p99Ms: num(r.p99_ms), worstMs: num(r.worst_ms), hitches: Number(r.hitches) || 0,
    areas: asJson(r.areas) || {}, sessionIds: Array.isArray(asJson(r.session_ids)) ? asJson(r.session_ids) : [],
  };
}

/**
 * The frame numbers of a group of reports. avgMs is the frame-weighted mean of the sessions' own averages; p99Ms and worstMedianMs are the
 * median over the sessions of their own 99th-percentile and worst frame (percentiles cannot be merged, the median is what a typical session saw).
 * hitchesPerHour is every frame over 50 ms divided by the play time of the sessions that timed frames. Sessions without frames count in
 * `reports` and the hours but not in these.
 */
function frameStats(list) {
  const timed = list.filter((r) => r.frames > 0);
  const weighted = timed.filter((r) => r.avgMs != null);
  const frames = sum(weighted.map((r) => r.frames));
  return {
    reports: list.length,
    avgMs: frames > 0 ? round2(sum(weighted.map((r) => r.avgMs * r.frames)) / frames) : null,
    p99Ms: round2(median(timed.map((r) => r.p99Ms))),
    worstMedianMs: round2(median(timed.map((r) => r.worstMs))),
    hitchesPerHour: perHour(sum(timed.map((r) => r.hitches)), sum(timed.map((r) => r.seconds)) / 3600),
  };
}

const counts = (values, key) => {
  const m = new Map();
  for (const v of values) m.set(v, (m.get(v) || 0) + 1);
  return [...m.entries()].sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : 1)).map(([k, count]) => ({ [key]: k, count }));
};

const NO_SERVER = Object.freeze({ sessions: 0, members: 0, hours: 0, kills: 0, bosses: 0, xp: 0, gold: 0, killsPerHour: null, bossesPerHour: null, xpPerHour: null, goldPerHour: null, dropsPerHour: null });

/** The summary of one release from its reports (readRow shape) and the server's own numbers. Pure. */
function summarize(version, rows, server = NO_SERVER, truncated = false) {
  const minutes = rows.map((r) => r.seconds / 60);
  const hours = sum(rows.map((r) => r.seconds)) / 3600;
  const byGroup = (keyOf) => {
    const m = new Map();
    for (const r of rows) { const k = keyOf(r); if (!m.has(k)) m.set(k, []); m.get(k).push(r); }
    return m;
  };
  const presetOrder = [...PRESETS, 'unknown'];
  const presets = [...byGroup((r) => r.preset)].map(([preset, list]) => ({ preset, ...frameStats(list) }))
    .sort((a, b) => presetOrder.indexOf(a.preset) - presetOrder.indexOf(b.preset));
  const gpus = [...byGroup((r) => r.gpu)].map(([gpu, list]) => { const s = frameStats(list); return { gpu, reports: s.reports, avgMs: s.avgMs, p99Ms: s.p99Ms }; })
    .sort((a, b) => b.reports - a.reports || (a.gpu < b.gpu ? -1 : 1)).slice(0, GPU_TOP);
  const areaSums = new Map();
  for (const r of rows) {
    for (const [id, a] of Object.entries(r.areas)) {
      if (!a || !Number.isFinite(Number(a.seconds))) continue;
      const s = areaSums.get(id) || { seconds: 0, deaths: 0, msTime: 0, msSeconds: 0 };
      s.seconds += Number(a.seconds);
      s.deaths += Number(a.deaths) || 0;
      if (a.avgMs != null && Number.isFinite(Number(a.avgMs))) { s.msTime += Number(a.avgMs) * Number(a.seconds); s.msSeconds += Number(a.seconds); }
      areaSums.set(id, s);
    }
  }
  const areas = [...areaSums].map(([area, s]) => ({
    area, hours: round2(s.seconds / 3600), deaths: s.deaths, deathsPerHour: perHour(s.deaths, s.seconds / 3600), avgMs: s.msSeconds > 0 ? round2(s.msTime / s.msSeconds) : null,
  })).sort((a, b) => b.hours - a.hours || (a.area < b.area ? -1 : 1)).slice(0, LIST_MAX);
  return {
    version, truncated,
    reports: rows.length,
    players: new Set(rows.map((r) => r.account)).size,
    hours: round2(hours),
    medianMinutes: round2(median(minutes)),
    averageMinutes: rows.length ? round2(sum(minutes) / rows.length) : null,
    presets, gpus,
    endReasons: counts(rows.map((r) => r.endReason), 'reason'),
    endAreas: counts(rows.map((r) => r.endArea).filter(Boolean), 'area').slice(0, LIST_MAX),
    areas,
    server,
  };
}

const chunks = (list, size) => {
  const out = [];
  for (let i = 0; i < list.length; i += size) out.push(list.slice(i, i + size));
  return out;
};

/**
 * The server's own numbers over the party sessions the reports name (SESSION-REPORTS.md): per player-hour, for each member from joining to leaving
 * (or to the end of the session). A session counts only if an account that named it was a member of it, so a report cannot pull in someone
 * else's session. Kills and boss kills are the members' accepted counters (party_session_members). XP and gold are what the members' progress
 * saves paid (value_ledger, reason 'save', gains only) between joining and leaving: the kill ledger keeps XP and gold only as lifetime totals.
 * Drops are not included: the drop rows carry no party session (README "Play reports").
 */
async function serverNumbers(pool, rows) {
  const named = new Map();   // party session id -> the accounts whose reports name it
  for (const r of rows) {
    for (const id of r.sessionIds) {
      if (typeof id !== 'string' || !PARTY_ID_RE.test(id)) continue;
      if (!named.has(id)) { if (named.size >= SESSIONS_MAX) continue; named.set(id, new Set()); }
      named.get(id).add(r.account);
    }
  }
  if (!named.size) return { ...NO_SERVER };
  const members = [];
  for (const ids of chunks([...named.keys()], CHUNK)) {
    const [found] = await pool.query(
      'SELECT m.session_id, m.account_id, m.joined_at, m.left_at, m.accepted_kills, m.accepted_bosses, s.ended_at, s.last_host_at ' +
      'FROM party_session_members m JOIN party_sessions s ON s.id = m.session_id WHERE m.session_id IN (?)', [ids]);
    members.push(...found);
  }
  const valid = new Set();
  for (const m of members) if (named.get(String(m.session_id))?.has(Number(m.account_id))) valid.add(String(m.session_id));
  const counted = members.filter((m) => valid.has(String(m.session_id)));
  let hours = 0;
  for (const m of counted) {
    const end = num(m.left_at) ?? num(m.ended_at) ?? num(m.last_host_at);
    const start = num(m.joined_at);
    if (end != null && start != null) hours += Math.max(0, end - start) / 3600000;
  }
  const kills = sum(counted.map((m) => Number(m.accepted_kills) || 0));
  const bosses = sum(counted.map((m) => Number(m.accepted_bosses) || 0));
  let xp = 0;
  let gold = 0;
  for (const ids of chunks([...valid], CHUNK)) {
    const [paid] = await pool.query(
      'SELECT l.currency AS currency, SUM(l.delta) AS total FROM party_session_members m ' +
      'JOIN party_sessions s ON s.id = m.session_id ' +
      "JOIN value_ledger l ON l.character_id = m.character_id AND l.reason = 'save' AND l.currency IN ('xp', 'gold') AND l.delta > 0 " +
      'AND l.created_at >= m.joined_at AND l.created_at <= COALESCE(m.left_at, s.ended_at, s.last_host_at) ' +
      'WHERE m.session_id IN (?) GROUP BY l.currency', [ids]);
    for (const p of paid) { if (p.currency === 'xp') xp += Number(p.total) || 0; else if (p.currency === 'gold') gold += Number(p.total) || 0; }
  }
  return {
    sessions: valid.size, members: counted.length, hours: round2(hours), kills, bosses, xp, gold,
    killsPerHour: perHour(kills, hours), bossesPerHour: perHour(bosses, hours), xpPerHour: perHour(xp, hours), goldPerHour: perHour(gold, hours),
    dropsPerHour: null,
  };
}

// ── Routes ───────────────────────────────────────────────────────────────────────────────────────────────────────────────

const SUMMARY_COLS = 'id, account_id, seconds, end_reason, end_area, preset, gpu, frames_count, avg_ms, p99_ms, worst_ms, hitches, areas, session_ids';

module.exports = function mountPlayReports(app, pool, { requireAuth, limiter, cacheMs = CACHE_MS } = {}) {
  // Every route on both paths (see the header).
  const paths = (p) => [`/api${p}`, p];
  const fail = (res, status, code, error) => res.status(status).json({ success: false, code, error });
  // requireJWT answers its 401 without a code; the game reads `code`.
  const auth = (req, res, next) => {
    const json = res.json.bind(res);
    res.json = (body) => json(res.statusCode === 401 && isObject(body) && !body.code ? { ...body, code: 'unauthorized' } : body);
    return requireAuth(req, res, next);
  };
  const write = limiter ? [auth, limiter] : [auth];
  const noTable = (res) => fail(res, 503, 'unavailable', 'Play reports are not available just yet. Please try again later.');
  const cache = new Map();   // version -> { at, body }

  app.post(paths('/play-reports'), ...write, async (req, res) => {
    const parsed = parseReport(req.body);
    if (parsed.error) return fail(res, 400, 'bad_request', parsed.error);
    const r = parsed.report;
    const account = req.user.accountId;
    try {
      const existing = async () => {
        const [rows] = await pool.execute('SELECT id FROM play_reports WHERE account_id = ? AND report_id = ? LIMIT 1', [account, r.reportId]);
        return rows[0] ? Number(rows[0].id) : 0;
      };
      const had = await existing();
      if (had) return res.json({ success: true, data: { id: had } });
      const [[{ c }]] = await pool.execute('SELECT COUNT(*) AS c FROM play_reports WHERE account_id = ? AND created_at > NOW() - INTERVAL 1 DAY', [account]);
      if (c >= DAILY_CAP) return fail(res, 429, 'rate_limited', 'That is plenty of play reports for one day. Please try again tomorrow.');
      const f = r.frames;
      try {
        const [result] = await pool.execute(
          `INSERT INTO play_reports (account_id, report_id, version, seconds, end_reason, end_area, discipline_index, level, party_size, host, preset,
             gpu, driver, os, cpu_cores, ram_mb, resolution, vsync, fps_cap, frames_count, avg_ms, p50_ms, p99_ms, worst_ms, hitches,
             frame_hist, areas, session_ids)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
          [account, r.reportId, r.version, r.seconds, r.endReason, r.endArea || null, r.discipline, r.level, r.partySize, r.host ? 1 : 0, r.preset,
            r.gpu || null, r.driver || null, r.os || null, r.cpuCores, r.ramMb, r.resolution || null, r.vsync === null ? null : r.vsync ? 1 : 0, r.fpsCap,
            f.count, f.avgMs, f.p50Ms, f.p99Ms, f.worstMs, f.hitches,
            f.hist ? JSON.stringify(f.hist) : null, JSON.stringify(r.areas), JSON.stringify(r.sessionIds)],
        );
        res.json({ success: true, data: { id: Number(result.insertId) } });
      } catch (err) {
        if (err && err.code === 'ER_DUP_ENTRY') return res.json({ success: true, data: { id: await existing() } }); // a resend that raced the first
        throw err;
      }
    } catch (err) {
      if (err && err.code === 'ER_NO_SUCH_TABLE') return noTable(res);
      console.error('play report save error:', (err && (err.code || err.message)) || err);
      fail(res, 500, 'server_error', 'The play report could not be saved. Please try again.');
    }
  });

  app.get(paths('/play-reports/releases'), async (req, res) => {
    res.set('Cache-Control', 'public, max-age=60');
    try {
      const [rows] = await pool.execute(
        `SELECT version, COUNT(*) AS reports, COUNT(DISTINCT account_id) AS players, SUM(seconds) AS seconds, MIN(created_at) AS first_at, MAX(created_at) AS last_at
           FROM play_reports GROUP BY version ORDER BY first_at DESC, version DESC LIMIT ${RELEASES_MAX}`,
      );
      res.json({
        success: true,
        releases: rows.map((r) => ({ version: String(r.version), reports: Number(r.reports), players: Number(r.players), hours: round2((Number(r.seconds) || 0) / 3600), first: iso(r.first_at), last: iso(r.last_at) })),
      });
    } catch (err) {
      if (err && err.code === 'ER_NO_SUCH_TABLE') return res.json({ success: true, releases: [] });
      console.error('play report releases error:', (err && (err.code || err.message)) || err);
      fail(res, 500, 'server_error', 'The play reports could not be loaded.');
    }
  });

  app.get(paths('/play-reports/summary'), async (req, res) => {
    const version = text(typeof req.query.version === 'string' ? req.query.version : '', 40);
    if (!VERSION_RE.test(version)) return fail(res, 400, 'bad_request', 'Pick a game version.');
    res.set('Cache-Control', 'public, max-age=60');
    const hit = cacheMs > 0 ? cache.get(version) : null;
    if (hit && Date.now() - hit.at < cacheMs) return res.json(hit.body);
    try {
      const [found] = await pool.execute(`SELECT ${SUMMARY_COLS} FROM play_reports WHERE version = ? ORDER BY id DESC LIMIT ${SUMMARY_ROWS_MAX}`, [version]);
      const rows = found.map(readRow);
      let server = { ...NO_SERVER };
      try {
        server = await serverNumbers(pool, rows);
      } catch (err) {   // the reports still show without the server's side
        console.error('play report server numbers error:', (err && (err.code || err.message)) || err);
      }
      const body = { success: true, summary: summarize(version, rows, server, found.length >= SUMMARY_ROWS_MAX) };
      if (cacheMs > 0) {
        if (cache.size >= CACHE_ENTRIES) cache.delete(cache.keys().next().value);
        cache.set(version, { at: Date.now(), body });
      }
      res.json(body);
    } catch (err) {
      if (err && err.code === 'ER_NO_SUCH_TABLE') return res.json({ success: true, summary: summarize(version, []) });
      console.error('play report summary error:', (err && (err.code || err.message)) || err);
      fail(res, 500, 'server_error', 'The play reports could not be loaded.');
    }
  });
};

module.exports.parseReport = parseReport;
module.exports.summarize = summarize;
module.exports.readRow = readRow;
module.exports.DAILY_CAP = DAILY_CAP;
