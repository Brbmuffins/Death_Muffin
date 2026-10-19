// Run: node --test server/death-muffin/backend/team-jobs.test.cjs
// No database, no network and no real folders: the tables are in memory (keyed on the SQL team-jobs.cjs issues) and result files go to a temp folder.
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { Readable } = require('node:stream');
const mountTeamJobs = require('./team-jobs.cjs');
const { parseHeartbeat, parseNewJob, checkPng, checkMjpeg, ffmpegArgs, runFfmpeg, mp4HoldsVideo, cleanLog, readsOwnBody, FILE_MAX_BYTES, CLIP_MAX_BYTES, MP4_MAX_BYTES, FILES_PER_JOB, OPEN_JOBS_MAX, DONE_BODY_MAX } = mountTeamJobs;

const T0 = 1_760_000_000_000;                 // the fake clock, epoch ms
const MIN = 60 * 1000;
const SECRET = 'team-secret-0123456789-abcdefghij';
const MUFFINS = 58;
const HELIX = 100;
const WAR = 149;
const OUTSIDER = 7;                           // a real account that is not on the team
const PC_A = 'pc-muffins-0001';
const PC_A2 = 'pc-muffins-0002';              // a second PC of the same account
const PC_B = 'pc-helix-0002';
const PC_W = 'pc-war-0003';
const PC_OF = { [MUFFINS]: PC_A, [HELIX]: PC_B, [WAR]: PC_W, [OUTSIDER]: 'pc-stranger-0004' };   // the PC an account's calls come from unless a test says otherwise
const HEX12 = /^[0-9a-f]{12}$/;
const sha256Hex = (v) => crypto.createHash('sha256').update(v).digest('hex');
const SIGNED_OUT = { success: false, code: 'signed_out', error: 'Signed out: sign in to the team app again.' };

// ── Fixtures ─────────────────────────────────────────────────────────────────────────────────────────────────────────────

const crc32 = (buf) => {
  let c = ~0;
  for (const b of buf) { c ^= b; for (let k = 0; k < 8; k++) c = (c >>> 1) ^ (0xedb88320 & -(c & 1)); }
  return ~c >>> 0;
};
const chunk = (type, data) => {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, 'latin1'), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body));
  return Buffer.concat([len, body, crc]);
};
/** A PNG with real signature, IHDR, one IDAT of `pad` bytes and IEND (the pixels are not valid, the server checks the frame). */
const png = (w = 1600, h = 900, pad = 100) => {
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0);
  ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8;
  ihdr[9] = 2;
  return Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), chunk('IHDR', ihdr), chunk('IDAT', Buffer.alloc(pad, 7)), chunk('IEND', Buffer.alloc(0))]);
};

const SHOTS = { rev: 'abcdef123456', godotVersion: '4.7.2.stable', files: [{ name: 'DeathMuffin.pck', url: 'https://example.invalid/x.pck', sha256: 'aa', bytes: 1 }], plan: { shots: [] }, presets: ['low', 'ultra'], args: ['--dev-offline', '--qa'] };
const newJob = (over = {}) => ({ kind: 'shots', title: 'Screenshots of a change, about 1 minute', weightS: 60, payload: SHOTS, ttlS: 3600, ...over });
const BENCH = { version: '20261019.120000-abc1234', rev: 'abc123456789', files: [{ name: 'DeathMuffin.exe', url: 'https://example.invalid/x.exe', sha256: 'aa', bytes: 1 }],
  setups: [{ preset: 'low', room: 'graves', class: 2, size: 'full_party', length: 'full' }, { preset: 'medium', room: 'graves', class: 2, size: 'full_party', length: 'full' }], args: [] };
const newBench = (over = {}) => ({ kind: 'bench', title: 'Benchmark of the new release, about 6 minutes', weightS: 360, payload: BENCH, ttlS: 3 * 86400, ...over });
/** One benchmark payload as DmApi.post_benchmark sends it (the game's DmBenchHistory.payload). */
const benchRun = (over = {}) => ({
  clientRunId: '1760000000123456', ranAt: '2026-10-19T12:30:05', version: '20261019.120000-abc1234', godot: '4.7.2.stable', gpu: 'NVIDIA GeForce GTX 970', cpu: 'Intel Core i7', os: 'Windows',
  renderer: 'forward_plus / vulkan', resolution: '1600x900', cores: 8, refreshHz: 60, preset: 'low', room: 'graves', discipline: 2, size: 'full_party', length: 'full', standard: false,
  vsyncCapped: false, cancelled: false, metrics: { avg_fps: 61.5, p95_ms: 18.2, p99_ms: 25, worst_ms: 60, hitches: 2, draw_calls: 1400 }, breakdown: {}, report: 'BENCHMARK report line', ...over,
});
const CLIP = { rev: 'abcdef123456', godotVersion: '4.7.2.stable', files: SHOTS.files, plan: { discipline: 'reaper', clips: [{ name: 'wraith', area: 'graves', cast: 'haunting_wraith', at: 'pack', enemies: 6, seconds: 5, camera: 'follow' }] },
  variants: [{ label: 'slow', tune: {} }, { label: 'fast', tune: {} }], presets: ['high'], args: ['--dev-offline', '--qa'] };
const newClip = (over = {}) => ({ kind: 'clip', title: 'Short videos of a change, about 2 minutes', weightS: 120, payload: CLIP, ttlS: 3600, ...over });
const beat = (over = {}) => ({ pcId: PC_A, name: 'Muffins PC', version: '0.1.0', gpu: 'NVIDIA GeForce RTX 4070', mode: 'ask', state: { gameRunning: false, fullscreen: false, onBattery: false, busy: false, paused: false }, ...over });

/**
 * The team tables in memory, keyed on the SQL team-jobs.cjs issues (each statement checks its own parameter count), plus a tiny Express stand-in.
 * `call` runs an app route as an account (no token with anon), `internal` runs the runner's routes from an address with a secret.
 */
function harness({ missingTable = false, members = [MUFFINS, HELIX, WAR], resultsDir, mount = {} } = {}) {
  let clock = T0;
  const memberSet = new Set(members);
  const accounts = new Map([[MUFFINS, 'Brbmuffins'], [HELIX, 'Helix'], [WAR, 'bogar1'], [OUTSIDER, 'Stranger']].map(([id, username]) => [id, {
    id, username, email: `${username.toLowerCase()}@example.invalid`, password_hash: `hash:pw-${username}`, active: 1, active_session: null,
  }]));
  const tokenRows = [];     // team_tokens
  let tokenSeq = 0;
  const pcs = new Map();   // "account/pc" -> row
  const jobs = [];
  const sqlLog = [];
  const flat = (sql) => sql.replace(/\s+/g, ' ').trim();
  const secs = (ms) => (ms == null ? null : Math.floor(ms / 1000));
  const byId = (id) => jobs.find((j) => j.id === id);
  const need = (p, n, sql) => assert.strictEqual(p.length, n, `parameter count of ${sql.slice(0, 60)}`);
  const json = (v) => (v == null ? null : JSON.parse(v));   // mysql2 hands a JSON column back parsed
  const quietBefore = (minutes) => clock - minutes * MIN;
  const quiet = (j, minutes) => (j.heartbeat_at ?? j.claimed_at) < quietBefore(minutes);

  const pool = {
    execute: async (rawSql, p = []) => {
      const sql = flat(rawSql);
      sqlLog.push(sql);
      if (missingTable) throw Object.assign(new Error("Table doesn't exist"), { code: 'ER_NO_SUCH_TABLE' });
      const affected = (n) => [{ affectedRows: n }];
      if (sql === 'SELECT account_id FROM team_members WHERE account_id = ? LIMIT 1') return [memberSet.has(p[0]) ? [{ account_id: p[0] }] : []];
      if (sql === 'SELECT id, username, password_hash, active FROM accounts WHERE username = ? OR email = ? LIMIT 1') {
        need(p, 2, sql);
        const a = [...accounts.values()].find((x) => x.username === p[0] || x.email === p[1]);
        return [a ? [{ id: a.id, username: a.username, password_hash: a.password_hash, active: a.active }] : []];
      }
      if (sql.startsWith('SELECT t.account_id, t.pc_id, a.username, (t.last_used IS NULL OR t.last_used < NOW() - INTERVAL 1 MINUTE) AS stale FROM team_tokens t JOIN team_members m')) {
        need(p, 1, sql);
        const t = tokenRows.find((r) => r.token_hash === p[0] && !r.revoked && r.expires_at > clock);
        const a = t && accounts.get(t.account_id);
        if (!t || !a || !memberSet.has(t.account_id) || !a.active) return [[]];
        return [[{ account_id: t.account_id, pc_id: t.pc_id, username: a.username, stale: t.last_used === null || t.last_used < clock - MIN ? 1 : 0 }]];
      }
      if (sql === 'UPDATE team_tokens SET last_used = NOW() WHERE token_hash = ?') {
        const t = tokenRows.find((r) => r.token_hash === p[0]);
        if (t) t.last_used = clock;
        return affected(t ? 1 : 0);
      }
      if (sql === 'UPDATE team_tokens SET revoked = 1 WHERE account_id = ? AND pc_id = ? AND revoked = 0') {
        let n = 0;
        for (const t of tokenRows) if (t.account_id === p[0] && t.pc_id === p[1] && !t.revoked) { t.revoked = 1; n++; }
        return affected(n);
      }
      if (sql === 'UPDATE team_tokens SET revoked = 1 WHERE token_hash = ?') {
        const t = tokenRows.find((r) => r.token_hash === p[0]);
        if (t) t.revoked = 1;
        return affected(t ? 1 : 0);
      }
      if (sql.startsWith('INSERT INTO team_tokens')) {
        need(p, 5, sql);
        assert.ok(sql.includes('NOW(3), NOW(), NOW() + INTERVAL ? DAY'));
        tokenRows.push({ token_hash: p[0], account_id: p[1], pc_id: p[2], pc_name: p[3], created_at: clock * 1000 + tokenSeq++, last_used: clock, expires_at: clock + p[4] * 86400_000, revoked: 0 });
        return affected(1);
      }
      if (sql === 'SELECT token_hash FROM team_tokens WHERE account_id = ? AND revoked = 0 AND expires_at > NOW() ORDER BY created_at ASC, token_hash ASC') {
        return [tokenRows.filter((t) => t.account_id === p[0] && !t.revoked && t.expires_at > clock).sort((a, b) => a.created_at - b.created_at).map((t) => ({ token_hash: t.token_hash }))];
      }
      if (sql === 'SELECT UNIX_TIMESTAMP(expires_at) AS expires_ts FROM team_tokens WHERE token_hash = ?') {
        const t = tokenRows.find((r) => r.token_hash === p[0]);
        return [t ? [{ expires_ts: secs(t.expires_at) }] : []];
      }
      if (sql.startsWith('INSERT INTO team_pcs')) {
        need(p, 12, sql);
        const key = `${p[0]}/${p[1]}`;
        const row = pcs.get(key) || { account_id: p[0], pc_id: p[1] };
        Object.assign(row, { name: p[7], version: p[8], gpu: p[9], mode: p[10], state: p[11], last_seen: clock });
        pcs.set(key, row);
        return affected(1);
      }
      if (sql === "UPDATE team_jobs SET heartbeat_at = NOW() WHERE status = 'running' AND claimed_account = ? AND claimed_pc = ?") {
        need(p, 2, sql);
        let n = 0;
        for (const j of jobs) if (j.status === 'running' && j.claimed_account === p[0] && j.claimed_pc === p[1]) { j.heartbeat_at = clock; n++; }
        return affected(n);
      }
      if (sql === "UPDATE team_jobs SET heartbeat_at = NOW() WHERE id = ? AND status = 'running'") {
        const j = byId(p[0]);
        if (j && j.status === 'running') { j.heartbeat_at = clock; return affected(1); }
        return affected(0);
      }
      if (sql.startsWith("UPDATE team_jobs SET status = 'failed', error = ?, finished_at = NOW() WHERE status = 'running' AND tries >= 1")) {
        need(p, 2, sql);
        let n = 0;
        for (const j of jobs) if (j.status === 'running' && j.tries >= 1 && quiet(j, p[1])) { Object.assign(j, { status: 'failed', error: p[0], finished_at: clock }); n++; }
        return affected(n);
      }
      if (sql.startsWith("UPDATE team_jobs SET status = 'queued', tries = tries + 1")) {
        need(p, 1, sql);
        let n = 0;
        for (const j of jobs) {
          if (j.status === 'running' && j.tries < 1 && quiet(j, p[0])) { Object.assign(j, { status: 'queued', tries: j.tries + 1, claimed_account: null, claimed_pc: null, claimed_at: null, heartbeat_at: null }); n++; }
        }
        return affected(n);
      }
      if (sql === "UPDATE team_jobs SET status = 'expired', finished_at = NOW() WHERE status = 'queued' AND expires_at <= NOW()") {
        let n = 0;
        for (const j of jobs) if (j.status === 'queued' && j.expires_at <= clock) { Object.assign(j, { status: 'expired', finished_at: clock }); n++; }
        return affected(n);
      }
      if (sql.startsWith("SELECT id, kind, title, weight_s, result, UNIX_TIMESTAMP(expires_at) AS expires_ts FROM team_jobs WHERE status = 'queued' AND expires_at > NOW() AND (target_pc IS NULL OR target_pc = ?) ORDER BY CASE kind WHEN 'shots' THEN 0 WHEN 'clip' THEN 1 WHEN 'release' THEN 2 WHEN 'bench' THEN 3 ELSE 4 END ASC, created_at ASC, id ASC LIMIT 50")) {
        need(p, 1, sql);
        const rank = (j) => ['shots', 'clip', 'release', 'bench'].indexOf(j.kind) === -1 ? 4 : ['shots', 'clip', 'release', 'bench'].indexOf(j.kind);
        const open = jobs.filter((j) => j.status === 'queued' && j.expires_at > clock && (j.target_pc == null || j.target_pc === p[0])).sort((a, b) => rank(a) - rank(b) || a.created_at - b.created_at || (a.id < b.id ? -1 : 1));
        return [open.slice(0, 50).map((j) => ({ id: j.id, kind: j.kind, title: j.title, weight_s: j.weight_s, result: json(j.result), expires_ts: secs(j.expires_at) }))];
      }
      if (sql.startsWith("SELECT id FROM team_jobs WHERE status = 'cancelled' AND claimed_account = ? AND claimed_pc = ? AND finished_at > NOW() - INTERVAL ? MINUTE ORDER BY finished_at DESC, id ASC LIMIT 20")) {
        need(p, 3, sql);
        const mine = jobs.filter((j) => j.status === 'cancelled' && j.claimed_account === p[0] && j.claimed_pc === p[1] && j.finished_at > clock - p[2] * MIN)
          .sort((a, b) => b.finished_at - a.finished_at || (a.id < b.id ? -1 : 1));
        return [mine.slice(0, 20).map((j) => ({ id: j.id }))];
      }
      if (sql.startsWith('SELECT id FROM team_jobs WHERE finished_at IS NOT NULL AND finished_at < NOW() - INTERVAL ? DAY AND id IN (')) {
        const ids = p.slice(1);
        need(p, 1 + ids.length, sql);
        assert.strictEqual(sql.match(/\?/g).length, p.length, 'one placeholder per value');
        assert.ok(sql.endsWith(`IN (${ids.map(() => '?').join(', ')})`));
        return [jobs.filter((j) => ids.includes(j.id) && j.finished_at != null && j.finished_at < clock - p[0] * 86400_000).map((j) => ({ id: j.id }))];
      }
      if (sql === 'SELECT id, kind, status, claimed_account, claimed_pc, target_pc, result FROM team_jobs WHERE id = ? LIMIT 1') {
        const j = byId(p[0]);
        return [j ? [{ id: j.id, kind: j.kind, status: j.status, claimed_account: j.claimed_account, claimed_pc: j.claimed_pc, target_pc: j.target_pc, result: json(j.result) }] : []];
      }
      if (sql.startsWith("UPDATE team_jobs SET status = 'running', claimed_account = ?, claimed_pc = ?")) {
        need(p, 4, sql);
        assert.ok(sql.endsWith("AND (target_pc IS NULL OR target_pc = ?)"));
        const j = byId(p[2]);
        if (j && j.status === 'queued' && j.expires_at > clock && (j.target_pc == null || j.target_pc === p[3])) { Object.assign(j, { status: 'running', claimed_account: p[0], claimed_pc: p[1], claimed_at: clock, heartbeat_at: clock }); return affected(1); }
        return affected(0);
      }
      if (sql === 'SELECT id, kind, title, payload FROM team_jobs WHERE id = ? LIMIT 1') {
        const j = byId(p[0]);
        return [j ? [{ id: j.id, kind: j.kind, title: j.title, payload: json(j.payload) }] : []];
      }
      if (sql === "UPDATE team_jobs SET result = ? WHERE id = ? AND status = 'queued'") {
        const j = byId(p[1]);
        if (j && j.status === 'queued') { j.result = p[0]; return affected(1); }
        return affected(0);
      }
      if (sql.startsWith("UPDATE team_jobs SET status = 'done', finished_at = NOW(), result = ?, error = NULL")) {
        need(p, 3, sql);
        const j = byId(p[1]);
        if (j && j.status === 'running' && j.claimed_account === p[2]) { Object.assign(j, { status: 'done', finished_at: clock, result: p[0], error: null }); return affected(1); }
        return affected(0);
      }
      if (sql.startsWith("UPDATE team_jobs SET status = 'failed', finished_at = NOW(), result = ?, error = ?")) {
        need(p, 4, sql);
        const j = byId(p[2]);
        if (j && j.status === 'running' && j.claimed_account === p[3]) { Object.assign(j, { status: 'failed', finished_at: clock, result: p[0], error: p[1] }); return affected(1); }
        return affected(0);
      }
      if (sql === "SELECT COUNT(*) AS n FROM team_jobs WHERE status IN ('queued', 'running')") return [[{ n: jobs.filter((j) => j.status === 'queued' || j.status === 'running').length }]];
      if (sql.startsWith('INSERT INTO team_jobs')) {
        need(p, 7, sql);
        assert.ok(sql.includes("'queued', NOW(3), NOW() + INTERVAL ? SECOND, ?)"));
        if (byId(p[0])) throw Object.assign(new Error('dup'), { code: 'ER_DUP_ENTRY' });
        jobs.push({
          id: p[0], kind: p[1], title: p[2], weight_s: p[3], payload: p[4], status: 'queued', created_at: clock + jobs.length, expires_at: clock + p[5] * 1000,
          claimed_account: null, claimed_pc: null, claimed_at: null, heartbeat_at: null, finished_at: null, result: null, error: null, tries: 0, target_pc: p[6],
        });
        return affected(1);
      }
      if (sql.startsWith('SELECT id, kind, title, weight_s, payload, status, target_pc, UNIX_TIMESTAMP(created_at) AS created_ts')) {
        const row = (j) => ({ ...j, payload: json(j.payload), result: json(j.result), created_ts: secs(j.created_at), expires_ts: secs(j.expires_at), claimed_ts: secs(j.claimed_at), heartbeat_ts: secs(j.heartbeat_at), finished_ts: secs(j.finished_at), reported_ts: secs(j.reported_at) });
        if (sql.includes('ORDER BY COALESCE(finished_at, created_at) ASC, id ASC LIMIT ')) {   // the reporter's list
          let at = 0;
          let rows = [...jobs];
          if (sql.includes(' WHERE kind = ?')) { const kind = p[at++]; rows = rows.filter((j) => j.kind === kind); }
          const st = /status IN \(([^)]*)\)/.exec(sql);
          if (st) { const wanted = st[1].split(',').map((x) => x.trim().replace(/'/g, '')); rows = rows.filter((j) => wanted.includes(j.status)); }
          if (sql.includes('reported_at IS NULL')) rows = rows.filter((j) => j.reported_at == null);
          need(p, at, sql);
          const key = (j) => j.finished_at ?? j.created_at;
          rows.sort((a, b) => key(a) - key(b) || (a.id < b.id ? -1 : 1));
          return [rows.slice(0, Number(/LIMIT (\d+)$/.exec(sql)[1])).map(row)];
        }
        const j = byId(p[0]);
        return [j ? [row(j)] : []];
      }
      if (sql.startsWith('UPDATE team_jobs SET reported_at = NOW() WHERE id = ? AND reported_at IS NULL AND status IN (')) {
        need(p, 1, sql);
        const j = byId(p[0]);
        const wanted = /status IN \(([^)]*)\)/.exec(sql)[1].split(',').map((x) => x.trim().replace(/'/g, ''));
        if (j && j.reported_at == null && wanted.includes(j.status)) { j.reported_at = clock; return affected(1); }
        return affected(0);
      }
      if (sql === 'SELECT UNIX_TIMESTAMP(reported_at) AS reported_ts FROM team_jobs WHERE id = ? LIMIT 1') {
        const j = byId(p[0]);
        return [j ? [{ reported_ts: secs(j.reported_at) }] : []];
      }
      if (sql === "UPDATE team_jobs SET status = 'cancelled', finished_at = NOW() WHERE kind = ? AND target_pc = ? AND status = 'queued' AND id <> ?") {
        need(p, 3, sql);
        let n = 0;
        for (const j of jobs) if (j.kind === p[0] && j.target_pc === p[1] && j.status === 'queued' && j.id !== p[2]) { Object.assign(j, { status: 'cancelled', finished_at: clock }); n++; }
        return affected(n);
      }
      if (sql === "UPDATE team_jobs SET status = 'cancelled', finished_at = NOW() WHERE id = ? AND status IN ('queued', 'running')") {
        const j = byId(p[0]);
        if (j && (j.status === 'queued' || j.status === 'running')) { Object.assign(j, { status: 'cancelled', finished_at: clock }); return affected(1); }
        return affected(0);
      }
      if (sql.startsWith('SELECT p.account_id, a.username, p.pc_id')) {
        need(p, 1, sql);
        const seen = [...pcs.values()].filter((r) => r.last_seen > clock - p[0] * MIN).sort((a, b) => b.last_seen - a.last_seen);
        return [seen.map((r) => ({ ...r, username: accounts.get(r.account_id)?.username ?? null, state: json(r.state), seen_ts: secs(r.last_seen) }))];
      }
      // benchmark_runs, as benchmarks.cjs's saveRun issues it (a bench job's runs are stored there)
      if (sql === 'SELECT id FROM benchmark_runs WHERE account_id = ? AND client_run_id = ? LIMIT 1') return [benchRows.filter((r) => r.account_id === p[0] && r.client_run_id === p[1]).map((r) => ({ id: r.id }))];
      if (sql === 'SELECT COUNT(*) AS c FROM benchmark_runs WHERE account_id = ? AND created_at > NOW() - INTERVAL 1 DAY') return [[{ c: benchRows.filter((r) => r.account_id === p[0]).length + (benchPadding.get(p[0]) || 0) }]];
      if (sql.startsWith('INSERT INTO benchmark_runs')) {
        need(p, 32, sql);
        assert.ok(sql.includes('report, source, source_pc)'));
        benchRows.push({ id: benchRows.length + 1, account_id: p[0], client_run_id: p[1], version: p[3], gpu: p[5], preset: p[12], room: p[13], discipline_index: p[14], size: p[15], length: p[16], flagged: p[18], avg_fps: p[20], report: p[29], source: p[30], source_pc: p[31] });
        return [{ insertId: benchRows.length }];
      }
      throw new Error(`unexpected SQL ${sql}`);
    },
  };
  const benchRows = [];                // benchmark_runs
  const benchPadding = new Map();      // account id -> runs already counted today (the daily cap)

  const routes = {};
  const reg = (m) => (path_, ...fns) => { for (const p of [].concat(path_)) routes[`${m} ${p}`] = fns; };
  const app = { post: reg('POST'), get: reg('GET'), put: reg('PUT') };
  const limits = { login: 0, calls: 0 };   // how often the login limiter and the per-account limiter ran
  const loginLimiter = (req, res, next) => { limits.login++; return next(); };
  const limiter = (req, res, next) => { limits.calls++; assert.ok(req.user && req.user.accountId, 'the per-account limiter runs after the sign-in check'); return next(); };
  const comparePassword = async (password, hash) => hash === `hash:${password}`;
  const secretFile = path.join(resultsDir, '..', `secret-${path.basename(resultsDir)}`);
  fs.writeFileSync(secretFile, `${SECRET}\n`);
  mountTeamJobs(app, pool, { limiter, loginLimiter, comparePassword, resultsDir, secretFile, ...mount });   // `mount`: a test's own transcoder settings (a fake ffmpeg, a short limit)

  const fakeRes = () => ({
    statusCode: 200, body: null, headers: {}, headersSent: false, listeners: {},
    set(k, v) { this.headers[k] = v; }, status(c) { this.statusCode = c; return this; }, json(b) { this.body = b; this.headersSent = true; return this; },
    on(event, fn) { (this.listeners[event] ||= []).push(fn); return this; },
    off(event, fn) { this.listeners[event] = (this.listeners[event] || []).filter((f) => f !== fn); return this; },
    emit(event) { for (const fn of [...(this.listeners[event] || [])]) fn(); },   // a test hangs up with res.emit('close')
  });
  const run = async (route, req, res = fakeRes()) => {
    const fns = routes[route];
    assert.ok(fns, `no such route ${route}`);
    let i = 0;
    const next = async () => { const fn = fns[i++]; if (fn) await fn(req, res, next); };
    await next();
    return res;
  };
  /** Sign in as `accountId` on `pcId` (the account's usual PC unless told otherwise); the answer, with the token in body.data. */
  const loginRaw = (body, headers = {}) => run('POST /api/team/login', { body, params: {}, query: {}, headers, socket: { remoteAddress: '203.0.113.9' } });
  const login = (accountId, { pcId = PC_OF[accountId], pcName = 'Test PC', password, username } = {}) => loginRaw({
    username: username ?? accounts.get(accountId).username, password: password ?? `pw-${accounts.get(accountId).username}`, pcId, pcName,
  });
  const tokens = new Map();   // "account/pc" -> the token of the first sign-in
  const tokenOf = async (accountId, pcId) => {
    const key = `${accountId}/${pcId}`;
    if (!tokens.has(key)) {
      const r = await login(accountId, { pcId });
      assert.strictEqual(r.statusCode, 200, `sign-in of ${key}: ${JSON.stringify(r.body)}`);
      tokens.set(key, r.body.data.token);
    }
    return tokens.get(key);
  };
  /**
   * An app route as `accountId` on `pcId`, signed in with that PC's team token (`token` or `authorization` say another; anon sends none).
   * `raw` or `chunks` make the request a stream, the way a PNG upload arrives.
   */
  const call = async (route, { body, accountId = MUFFINS, pcId = PC_OF[accountId], params = {}, query = {}, headers = {}, anon = false, token, authorization, raw, chunks, res } = {}) => {
    const auth = anon ? undefined : authorization ?? `Team ${token ?? await tokenOf(accountId, pcId)}`;
    const base = { body, params, query, headers: auth === undefined ? headers : { authorization: auth, ...headers }, socket: { remoteAddress: '203.0.113.9' } };
    if (raw === undefined && chunks === undefined) return run(route, base, res);
    const stream = Readable.from(chunks || [raw]);
    return run(route, Object.assign(stream, base, { body: undefined }), res);
  };
  const internal = (route, { body, params = {}, query = {}, addr = '127.0.0.1', secret = SECRET, headers = {} } = {}) => run(route, {
    body, params, query, socket: { remoteAddress: addr }, headers: { ...(secret === null ? {} : { 'x-team-secret': secret }), ...headers },
  });

  /** Make a job through the runner's route and return its id. */
  const makeJob = async (over) => {
    const r = await internal('POST /internal/team/jobs', { body: newJob(over) });
    assert.strictEqual(r.statusCode, 200, JSON.stringify(r.body));
    return r.body.data.id;
  };
  /** Make a job and have `pcId` of `accountId` claim it. */
  const runningJob = async ({ accountId = MUFFINS, pcId = PC_OF[accountId], over } = {}) => {
    const id = await makeJob(over);
    const r = await call('POST /api/team/jobs/:id/claim', { accountId, pcId, params: { id }, body: { pcId } });
    assert.strictEqual(r.statusCode, 200, JSON.stringify(r.body));
    return id;
  };
  const upload = (id, name, buf, { accountId = MUFFINS, pcId, headers = {}, query = {}, type = 'image/png' } = {}) => call('PUT /api/team/jobs/:id/files/:name', {
    accountId, pcId, params: { id, name }, raw: buf, query, headers: { 'content-type': type, 'content-length': String(buf.length), ...headers },
  });
  const uploadClip = (id, name, buf, opts = {}) => upload(id, name, buf, { type: 'video/x-motion-jpeg', ...opts });
  const jobFolder = (id) => path.join(resultsDir, id);

  return {
    fakeRes, pool, jobs, pcs, benchRows, benchPadding, accounts, tokenRows, memberSet, limits, sqlLog, routes, call, login, loginRaw, tokenOf, internal, makeJob, runningJob, upload, uploadClip, jobFolder, resultsDir,
    advance: (ms) => { clock += ms; },
    now: () => clock,
  };
}

/** A harness with its own temp results folder, removed afterwards. */
async function withHarness(opts, fn) {
  if (typeof opts === 'function') { fn = opts; opts = {}; }
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'team-jobs-test-'));
  const resultsDir = path.join(root, 'results');
  try {
    await fn(harness({ ...opts, resultsDir }));
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
}

// ── Parsing ──────────────────────────────────────────────────────────────────────────────────────────────────────────────

test('parseHeartbeat accepts the contract body, trims and caps strings, defaults the mode and drops unknown keys', () => {
  const { pc } = parseHeartbeat(beat());
  assert.deepStrictEqual(pc, { pcId: PC_A, name: 'Muffins PC', version: '0.1.0', gpu: 'NVIDIA GeForce RTX 4070', mode: 'ask', state: { gameRunning: false, fullscreen: false, onBattery: false, busy: false, paused: false } });
  const messy = parseHeartbeat(beat({
    pcId: `  ${PC_B}  `, name: `${'N'.repeat(200)}\u0000\n`, gpu: 42, version: 'v'.repeat(80), mode: 'turbo', extra: 'x',
    state: { gameRunning: true, onBattery: 'yes', busy: 1, paused: true, secret: 1 },
  })).pc;
  assert.strictEqual(messy.pcId, PC_B);
  assert.strictEqual(messy.name.length, 64);
  assert.ok(!/[\u0000-\u001f]/.test(messy.name));
  assert.strictEqual(messy.gpu, '');
  assert.strictEqual(messy.version.length, 32);
  assert.strictEqual(messy.mode, 'ask', 'an unknown mode becomes ask');
  assert.deepStrictEqual(messy.state, { gameRunning: true, fullscreen: false, onBattery: false, busy: false, paused: true }, 'only true counts, unknown keys are dropped');
  for (const mode of ['auto', 'yes']) assert.strictEqual(parseHeartbeat(beat({ mode })).pc.mode, mode);
  assert.deepStrictEqual(Object.keys(parseHeartbeat({ pcId: PC_A }).pc.state).sort(), ['busy', 'fullscreen', 'gameRunning', 'onBattery', 'paused']);
});

test('parseHeartbeat refuses a malformed pc id with a readable reason and takes none (the token names the PC)', () => {
  for (const bad of [beat({ pcId: 'short' }), beat({ pcId: 'has space in it' }), beat({ pcId: 'x'.repeat(65) }), beat({ pcId: 12345678 }), beat({ pcId: null }), beat({ pcId: '../../etc/passwd' })]) {
    const r = parseHeartbeat(bad);
    assert.ok(r.error && r.error.length > 10 && !r.pc, JSON.stringify(bad));
  }
  for (const none of [null, [], 'x', {}]) assert.strictEqual(parseHeartbeat(none).pc.pcId, '', 'a body that names no PC is the token\'s PC');
});

test('parseNewJob checks kind, title and payload and clamps weight and time to live', () => {
  const ok = parseNewJob(newJob()).job;
  assert.deepStrictEqual([ok.kind, ok.weightS, ok.ttlS], ['shots', 60, 3600]);
  assert.deepStrictEqual(JSON.parse(ok.payload), SHOTS);
  const clamped = parseNewJob(newJob({ weightS: 1e9, ttlS: 1 })).job;
  assert.deepStrictEqual([clamped.weightS, clamped.ttlS], [86400, 60]);
  assert.strictEqual(parseNewJob(newJob({ ttlS: 1e12 })).job.ttlS, 7 * 86400);
  const defaults = parseNewJob({ kind: 'shots', title: 't', payload: {} }).job;
  assert.deepStrictEqual([defaults.weightS, defaults.ttlS], [60, 3600]);
  for (const bad of [null, {}, newJob({ kind: 'Shots' }), newJob({ kind: '1shots' }), newJob({ kind: 'x'.repeat(25) }), newJob({ kind: 7 }), newJob({ title: '  ' }), newJob({ title: undefined }),
    newJob({ payload: undefined }), newJob({ payload: [] }), newJob({ payload: 'x' }), newJob({ payload: { big: 'x'.repeat(200001) } })]) {
    const r = parseNewJob(bad);
    assert.ok(r.error && r.error.length > 10 && !r.job, JSON.stringify(bad).slice(0, 80));
  }
});

test('checkPng reads width and height and refuses anything that is not a whole PNG of a sane size', () => {
  assert.deepStrictEqual(checkPng(png(1600, 900)), { width: 1600, height: 900 });
  assert.deepStrictEqual(checkPng(png(16, 4096)), { width: 16, height: 4096 });
  const bad = {
    'empty': Buffer.alloc(0), 'text': Buffer.from('definitely not a picture, but long enough to pass a length check'), 'jpeg': Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), Buffer.alloc(100)]),
    'signature only': png().subarray(0, 8), 'cut off': png().subarray(0, png().length - 12), 'too narrow': png(15, 900), 'too short': png(1600, 15), 'too wide': png(4097, 900), 'too tall': png(1600, 4097), 'zero': png(0, 0),
  };
  for (const [what, buf] of Object.entries(bad)) assert.ok(checkPng(buf).error, what);
  const noIhdr = png();
  noIhdr.write('IDAT', 12, 'latin1');
  assert.ok(checkPng(noIhdr).error, 'IHDR must come first');
  assert.match(checkPng(png(5000, 900)).error, /5000 by 900/);
  assert.ok(checkPng('a string').error && checkPng(null).error);
});

test('cleanLog keeps line breaks, drops control characters and holds 64 KB', () => {
  assert.strictEqual(cleanLog('line 1\nline 2\ttab\r\n'), 'line 1\nline 2\ttab\r\n');
  assert.strictEqual(cleanLog('a\u0000b\u001b[31mc\u007fd'), 'ab[31mcd');
  assert.strictEqual(cleanLog(42), '');
  assert.strictEqual(cleanLog('x'.repeat(100000)).length, 65536);
  const wide = cleanLog('é'.repeat(100000));   // two bytes each
  assert.ok(Buffer.byteLength(wide) <= 65536 && wide.length > 30000);
});

// ── Membership and wiring ────────────────────────────────────────────────────────────────────────────────────────────────

test('both route spellings exist and the runner routes are mounted only under /internal', async () => {
  await withHarness(async (h) => {
    for (const [m, p] of [['GET', '/team/me'], ['POST', '/team/heartbeat'], ['POST', '/team/jobs/:id/claim'], ['POST', '/team/jobs/:id/decline'], ['PUT', '/team/jobs/:id/files/:name'], ['POST', '/team/jobs/:id/done'], ['POST', '/team/jobs/:id/fail']]) {
      assert.ok(h.routes[`${m} /api${p}`] && h.routes[`${m} ${p}`], `${m} ${p} on both paths`);
    }
    for (const [m, p] of [['POST', '/internal/team/jobs'], ['GET', '/internal/team/jobs/:id'], ['POST', '/internal/team/jobs/:id/cancel'], ['GET', '/internal/team/pcs']]) {
      assert.ok(h.routes[`${m} ${p}`], `${m} ${p}`);
      assert.ok(!h.routes[`${m} /api${p}`], `${m} /api${p} is not mounted`);
    }
  });
});

test('every app route needs a team token: none, a game login, garbage or a token that never existed is 401 signed_out', async () => {
  await withHarness(async (h) => {
    const id = await h.makeJob();
    const jwt = `Bearer ${Buffer.from('{"alg":"HS256"}').toString('base64url')}.${Buffer.from(`{"accountId":${MUFFINS},"username":"Brbmuffins","sid":"x"}`).toString('base64url')}.c2ln`;
    const routes = [
      ['GET', '/team/me', {}], ['POST', '/team/logout', {}], ['POST', '/team/heartbeat', { body: beat() }], ['POST', '/team/jobs/:id/claim', { params: { id }, body: { pcId: PC_A } }],
      ['POST', '/team/jobs/:id/decline', { params: { id }, body: { pcId: PC_A, reason: 'busy' } }], ['POST', '/team/jobs/:id/done', { params: { id }, body: { files: [] } }],
      ['POST', '/team/jobs/:id/fail', { params: { id }, body: { error: 'x' } }],
    ];
    const wrong = [undefined, '', 'Team', 'Team ', 'Team not-a-token', `Team ${'x'.repeat(43)}`, jwt, 'Basic abc', `Team ${'a b'}`, 'Bearer team', `Team ${'x'.repeat(300)}`];
    for (const prefix of ['/api', '']) {
      for (const [m, p, opts] of routes) {
        for (const authorization of wrong) {
          const r = await h.call(`${m} ${prefix}${p}`, { ...opts, anon: authorization === undefined, authorization });
          assert.strictEqual(r.statusCode, 401, `${m} ${p} with ${JSON.stringify(authorization)}`);
          assert.deepStrictEqual(r.body, SIGNED_OUT);
        }
      }
    }
    const put = await h.call('PUT /api/team/jobs/:id/files/:name', { anon: true, params: { id, name: 'a.png' }, raw: png(), headers: { 'content-type': 'image/png' } });
    assert.deepStrictEqual([put.statusCode, put.body], [401, SIGNED_OUT]);
    const jwtPut = await h.call('PUT /api/team/jobs/:id/files/:name', { authorization: jwt, params: { id, name: 'a.png' }, raw: png(), headers: { 'content-type': 'image/png' } });
    assert.strictEqual(jwtPut.statusCode, 401, 'a game token does not open the upload either');
    assert.strictEqual(h.jobs[0].status, 'queued', 'nothing changed');
    assert.strictEqual(h.pcs.size, 0);
    assert.strictEqual(h.limits.calls, 0, 'the per-account limiter never ran for a call with no sign-in');
    const ok = await h.call('GET /api/team/me', { accountId: HELIX });
    assert.deepStrictEqual(ok.body, { success: true, data: { accountId: HELIX, username: 'Helix' } });
    assert.strictEqual((await h.call('GET /team/me', { accountId: WAR })).body.data.username, 'bogar1');
    const lower = await h.call('GET /team/me', { authorization: `team ${await h.tokenOf(WAR, PC_W)}` });
    assert.strictEqual(lower.statusCode, 200, 'the scheme is not case-sensitive');
  });
});

test('login: a team member gets a token for their PC, kept only as a hash, and the game session is left alone', async () => {
  await withHarness(async (h) => {
    h.accounts.get(MUFFINS).active_session = 'the-games-own-session';
    const r = await h.login(MUFFINS, { pcName: `  Muffins' desktop\u0000 ` });
    assert.strictEqual(r.statusCode, 200, JSON.stringify(r.body));
    assert.deepStrictEqual(Object.keys(r.body), ['success', 'data']);
    const d = r.body.data;
    assert.deepStrictEqual(Object.keys(d).sort(), ['accountId', 'expiresAt', 'token', 'username']);
    assert.match(d.token, /^[A-Za-z0-9_-]{43}$/, '32 random bytes as base64url');
    assert.deepStrictEqual([d.accountId, d.username], [MUFFINS, 'Brbmuffins']);
    assert.strictEqual(d.expiresAt, new Date(Math.floor((T0 + 90 * 86400_000) / 1000) * 1000).toISOString(), 'good for 90 days');
    assert.strictEqual(h.limits.login, 1, 'the login rate limiter ran');
    assert.strictEqual(h.tokenRows.length, 1);
    const row = h.tokenRows[0];
    assert.deepStrictEqual([row.token_hash, row.account_id, row.pc_id, row.pc_name, row.revoked], [sha256Hex(d.token), MUFFINS, PC_A, "Muffins' desktop", 0]);
    assert.ok(!JSON.stringify(h.tokenRows).includes(d.token), 'the token itself is stored nowhere');
    assert.ok(!h.sqlLog.some((q) => q.includes(d.token) || /active_session|UPDATE accounts/i.test(q)), 'no SQL carries the token or touches the account\'s game session');
    assert.strictEqual(h.accounts.get(MUFFINS).active_session, 'the-games-own-session', 'signing in to the team app did not claim the game session');
    // the account's game login moves on afterwards: the app is not refused for it
    h.accounts.get(MUFFINS).active_session = 'a-newer-game-login';
    assert.strictEqual((await h.call('GET /api/team/me', { token: d.token })).statusCode, 200);
    assert.strictEqual((await h.call('POST /api/team/heartbeat', { token: d.token, body: beat() })).statusCode, 200);
    // another account's sign-in, the e-mail address as the user name, both route spellings
    const byMail = await h.loginRaw({ username: 'helix@example.invalid', password: 'pw-Helix', pcId: PC_B });
    assert.strictEqual(byMail.statusCode, 200);
    assert.strictEqual(byMail.body.data.username, 'Helix');
    assert.ok(h.routes['POST /team/login'] && h.routes['POST /api/team/login'] && h.routes['POST /api/team/logout'] && h.routes['POST /team/logout']);
  });
});

test('login refuses what /login refuses, in the same words, and a stranger learns nothing about who is on the team', async () => {
  await withHarness(async (h) => {
    for (const extra of [{ username: undefined }, { password: undefined }, { username: '' }, { password: '' }, { username: 7 }, { password: ['x'] }]) {
      const r = await h.loginRaw({ username: 'Brbmuffins', password: 'pw-Brbmuffins', pcId: PC_A, ...extra });
      assert.deepStrictEqual([r.statusCode, r.body.code, r.body.error], [400, 'bad_request', 'Username and password are required.'], JSON.stringify(extra));
    }
    for (const pcId of [undefined, '', 'short', 'has space in it', 'x'.repeat(65), 12345678]) {
      const r = await h.loginRaw({ username: 'Brbmuffins', password: 'pw-Brbmuffins', pcId });
      assert.deepStrictEqual([r.statusCode, r.body.code, r.body.error], [400, 'bad_request', 'This PC has no valid id.'], String(pcId));
    }
    const bad = [
      await h.login(MUFFINS, { password: 'wrong' }), await h.login(MUFFINS, { username: 'nobody' }), await h.login(OUTSIDER, { password: 'wrong' }),   // wrong password: a member or not, the same 401
    ];
    h.accounts.get(HELIX).active = 0;
    bad.push(await h.login(HELIX));   // a deactivated account
    for (const r of bad) assert.deepStrictEqual([r.statusCode, r.body.success, r.body.code, r.body.error], [401, false, 'bad_login', 'Invalid username or password.']);
    const stranger = await h.login(OUTSIDER);
    assert.deepStrictEqual([stranger.statusCode, stranger.body], [403, { success: false, code: 'not_team', error: 'This account is not on the team.' }], 'the right password of an account that is not on the team');
    assert.strictEqual(h.tokenRows.length, 0, 'no refused sign-in made a token');
    assert.strictEqual(h.limits.login, 17, 'every attempt went through the login rate limiter');
  });
});

test('a PC has one live sign-in and an account at most five, the oldest going first', async () => {
  await withHarness(async (h) => {
    const first = (await h.login(MUFFINS)).body.data.token;
    h.advance(1000);
    const second = (await h.login(MUFFINS)).body.data.token;   // the same PC again: the first token is revoked
    assert.notStrictEqual(first, second);
    assert.deepStrictEqual((await h.call('GET /api/team/me', { token: first })).body, SIGNED_OUT);
    assert.strictEqual((await h.call('GET /api/team/me', { token: second })).statusCode, 200);
    const helix = (await h.login(HELIX)).body.data.token;
    const others = [];
    for (let i = 1; i <= 5; i++) {
      h.advance(1000);
      others.push((await h.login(MUFFINS, { pcId: `pc-muffins-spare-${i}` })).body.data.token);
    }
    const live = h.tokenRows.filter((t) => t.account_id === MUFFINS && !t.revoked);
    assert.strictEqual(live.length, 5, 'five live sign-ins for the account');
    assert.deepStrictEqual((await h.call('GET /api/team/me', { token: second })).body, SIGNED_OUT, 'the oldest live one was revoked by the sixth');
    for (const t of others) assert.strictEqual((await h.call('GET /api/team/me', { token: t })).statusCode, 200);
    assert.strictEqual((await h.call('GET /api/team/me', { token: helix })).statusCode, 200, 'another account\'s sign-in is not touched');
    h.advance(1000);
    await h.login(MUFFINS, { pcId: 'pc-muffins-spare-6' });
    assert.strictEqual(h.tokenRows.filter((t) => t.account_id === MUFFINS && !t.revoked).length, 5);
    assert.deepStrictEqual((await h.call('GET /api/team/me', { token: others[0] })).body, SIGNED_OUT, 'and the next oldest goes with the seventh');
  });
});

test('a token ends when it expires, is revoked or logged out, its account leaves team_members or is deactivated', async () => {
  await withHarness(async (h) => {
    const a = (await h.login(MUFFINS)).body.data.token;
    const b = (await h.login(HELIX)).body.data.token;
    const c = (await h.login(WAR)).body.data.token;
    const works = async (token) => (await h.call('GET /api/team/me', { token })).statusCode === 200;
    assert.ok(await works(a) && await works(b) && await works(c));
    // logout revokes only the token it came with
    const out = await h.call('POST /api/team/logout', { token: a });
    assert.deepStrictEqual([out.statusCode, out.body], [200, { success: true }]);
    assert.strictEqual(h.tokenRows.filter((t) => t.revoked).length, 1);
    assert.deepStrictEqual((await h.call('POST /team/logout', { token: a })).body, SIGNED_OUT, 'a second logout has no sign-in to end');
    assert.ok(!await works(a) && await works(b));
    // taking an account off the team locks its tokens out at once; putting it back opens them again
    h.memberSet.delete(HELIX);
    for (const route of ['GET /api/team/me', 'POST /api/team/heartbeat']) assert.deepStrictEqual((await h.call(route, { token: b, body: beat({ pcId: PC_B }) })).body, SIGNED_OUT, route);
    assert.strictEqual((await h.login(HELIX)).statusCode, 403, 'and it cannot sign in again');
    h.memberSet.add(HELIX);
    assert.ok(await works(b));
    // a deactivated account
    h.accounts.get(WAR).active = 0;
    assert.ok(!await works(c));
    h.accounts.get(WAR).active = 1;
    assert.ok(await works(c));
    // revoked in the table
    h.tokenRows.find((t) => t.account_id === HELIX).revoked = 1;
    assert.ok(!await works(b));
    // 90 days
    h.advance(90 * 86400_000 - 1000);
    assert.ok(await works(c), 'still good a second before it ends');
    h.advance(2000);
    assert.ok(!await works(c), 'refused once it has expired');
    assert.deepStrictEqual((await h.call('POST /api/team/heartbeat', { token: c, body: beat({ pcId: PC_W }) })).body, SIGNED_OUT);
    assert.strictEqual(h.pcs.size, 0, 'a refused sign-in stored nothing');
  });
});

test('a call refreshes the token\'s last_used at most once a minute', async () => {
  await withHarness(async (h) => {
    const t = (await h.login(MUFFINS)).body.data.token;
    const row = h.tokenRows[0];
    assert.strictEqual(row.last_used, T0, 'set at sign-in');
    h.advance(30_000);
    await h.call('GET /api/team/me', { token: t });
    assert.strictEqual(row.last_used, T0, 'not touched inside a minute');
    h.advance(31_000);
    await h.call('GET /api/team/me', { token: t });
    assert.strictEqual(row.last_used, h.now());
    const writes = h.sqlLog.filter((q) => q === 'UPDATE team_tokens SET last_used = NOW() WHERE token_hash = ?').length;
    for (let i = 0; i < 5; i++) await h.call('GET /api/team/me', { token: t });
    assert.strictEqual(h.sqlLog.filter((q) => q === 'UPDATE team_tokens SET last_used = NOW() WHERE token_hash = ?').length, writes, 'five more calls in the same minute wrote nothing');
  });
});

test('a call that names another PC than its token is 403 wrong_pc, one that names none acts as the token\'s PC', async () => {
  await withHarness(async (h) => {
    const id = await h.runningJob();
    const other = PC_A2;
    const named = [
      ['POST /api/team/heartbeat', { body: beat({ pcId: other }) }],
      ['POST /api/team/jobs/:id/claim', { params: { id: await h.makeJob() }, body: { pcId: other } }],
      ['POST /api/team/jobs/:id/decline', { params: { id: await h.makeJob() }, body: { pcId: other, reason: 'busy' } }],
      ['POST /api/team/jobs/:id/done', { params: { id }, body: { files: [], pcId: other } }],
      ['POST /api/team/jobs/:id/fail', { params: { id }, body: { error: 'x', pcId: other } }],
      ['PUT /api/team/jobs/:id/files/:name', { params: { id, name: 'a.png' }, raw: png(), headers: { 'content-type': 'image/png', 'x-team-pc': other } }],
      ['PUT /api/team/jobs/:id/files/:name', { params: { id, name: 'a.png' }, raw: png(), query: { pcId: other }, headers: { 'content-type': 'image/png' } }],
    ];
    for (const [route, opts] of named) {
      const r = await h.call(route, opts);
      assert.deepStrictEqual([r.statusCode, r.body.success, r.body.code], [403, false, 'wrong_pc'], route);
      assert.ok(r.body.error.length > 20);
    }
    assert.strictEqual(h.pcs.size, 0, 'a heartbeat for another PC stored nothing');
    assert.deepStrictEqual(h.jobs.map((j) => j.status), ['running', 'queued', 'queued']);
    // naming no PC, or its own, is the token's PC
    const hb = await h.call('POST /api/team/heartbeat', { body: { mode: 'auto' } });
    assert.strictEqual(hb.statusCode, 200);
    assert.deepStrictEqual([...h.pcs.keys()], [`${MUFFINS}/${PC_A}`]);
    assert.strictEqual((await h.call('POST /api/team/heartbeat', { body: undefined })).statusCode, 200, 'a heartbeat with no body at all is the PC alive');
    assert.strictEqual((await h.call('POST /api/team/jobs/:id/claim', { params: { id: h.jobs[1].id }, body: {} })).statusCode, 200);
    assert.strictEqual(h.jobs[1].claimed_pc, PC_A);
  });
});

test('a missing table is a readable 503 unavailable, never a stack', async () => {
  await withHarness({ missingTable: true }, async (h) => {
    const someToken = { authorization: `Team ${'a'.repeat(43)}` };
    for (const [route, opts] of [['GET /api/team/me', someToken], ['POST /team/heartbeat', { ...someToken, body: beat() }], ['POST /api/team/logout', someToken]]) {
      const r = await h.call(route, opts);
      assert.strictEqual(r.statusCode, 503, route);
      assert.deepStrictEqual([r.body.success, r.body.code], [false, 'unavailable']);
      assert.ok(r.body.error.length > 20 && !/ER_|table|SQL/i.test(r.body.error));
    }
    const login = await h.login(MUFFINS);
    assert.deepStrictEqual([login.statusCode, login.body.code], [503, 'unavailable']);
    const runner = await h.internal('GET /internal/team/pcs');
    assert.strictEqual(runner.statusCode, 503);
    assert.strictEqual(runner.body.code, 'unavailable');
  });
});

// ── Heartbeat and offers ─────────────────────────────────────────────────────────────────────────────────────────────────

test('a heartbeat upserts the PC and a repeat updates the same row', async () => {
  await withHarness(async (h) => {
    const first = await h.call('POST /api/team/heartbeat', { body: beat({ state: { onBattery: true } }) });
    assert.strictEqual(first.statusCode, 200);
    assert.strictEqual(first.body.success, true);
    assert.strictEqual(first.body.data.offer, null);
    assert.ok(Math.abs(Date.parse(first.body.data.serverTime) - Date.now()) < 5000, 'serverTime is the server clock');
    assert.strictEqual(h.pcs.size, 1);
    const row = h.pcs.get(`${MUFFINS}/${PC_A}`);
    assert.deepStrictEqual([row.name, row.version, row.gpu, row.mode], ['Muffins PC', '0.1.0', 'NVIDIA GeForce RTX 4070', 'ask']);
    assert.strictEqual(JSON.parse(row.state).onBattery, true);
    h.advance(30_000);
    await h.call('POST /team/heartbeat', { body: beat({ mode: 'auto', gpu: 'Intel UHD', version: '0.1.1', state: { busy: true } }) });
    assert.strictEqual(h.pcs.size, 1, 'the same account and pc id is one row');
    assert.deepStrictEqual([row.mode, row.gpu, row.version, row.last_seen], ['auto', 'Intel UHD', '0.1.1', h.now()]);
    assert.deepStrictEqual(JSON.parse(row.state), { gameRunning: false, fullscreen: false, onBattery: false, busy: true, paused: false });
    await h.call('POST /api/team/heartbeat', { body: beat({ pcId: PC_B }), accountId: HELIX });
    await h.call('POST /api/team/heartbeat', { body: beat({ pcId: PC_A }), accountId: HELIX, pcId: PC_A });   // the same pc id under another account is another PC
    assert.strictEqual(h.pcs.size, 3);
  });
});

test('a bad heartbeat is 400 and stores nothing', async () => {
  await withHarness(async (h) => {
    for (const body of [beat({ pcId: 'no' }), beat({ pcId: 12345678 }), beat({ pcId: '../../etc/passwd' })]) {
      const r = await h.call('POST /api/team/heartbeat', { body });
      assert.strictEqual(r.statusCode, 400);
      assert.deepStrictEqual([r.body.success, r.body.code], [false, 'bad_request']);
      assert.ok(r.body.error.length > 10);
    }
    assert.strictEqual(h.pcs.size, 0);
  });
});

test('the heartbeat offers the oldest queued job that has not expired, to any team PC', async () => {
  await withHarness(async (h) => {
    const short = await h.makeJob({ title: 'short lived', ttlS: 60 });
    const oldest = await h.makeJob({ title: 'the oldest live one', weightS: 90, ttlS: 3600 });
    const newer = await h.makeJob({ title: 'newer', ttlS: 3600 });
    h.advance(2 * MIN);   // `short` ran out of time before anyone asked
    const r = await h.call('POST /api/team/heartbeat', { body: beat() });
    assert.deepStrictEqual(r.body.data.offer, { id: oldest, kind: 'shots', title: 'the oldest live one', weightS: 90, expiresAt: new Date(Math.floor((T0 + 3600_000) / 1000) * 1000).toISOString() });
    assert.strictEqual(h.jobs.find((j) => j.id === short).status, 'expired');
    const other = await h.call('POST /api/team/heartbeat', { body: beat({ pcId: PC_W }), accountId: WAR });
    assert.strictEqual(other.body.data.offer.id, oldest, 'every team PC is offered it until one claims it');
    await h.call('POST /api/team/jobs/:id/claim', { params: { id: oldest }, body: { pcId: PC_A } });
    const next = await h.call('POST /api/team/heartbeat', { body: beat({ pcId: PC_W }), accountId: WAR });
    assert.strictEqual(next.body.data.offer.id, newer, 'a claimed job is not offered again');
    assert.ok(!('payload' in next.body.data.offer), 'an offer is not the job: no payload');
  });
});

// ── Claim, decline ───────────────────────────────────────────────────────────────────────────────────────────────────────

test('claim answers the job and the second claim is 409 taken (also when both race)', async () => {
  await withHarness(async (h) => {
    const id = await h.makeJob();
    const [a, b] = await Promise.all([
      h.call('POST /api/team/jobs/:id/claim', { params: { id }, body: { pcId: PC_A } }),
      h.call('POST /api/team/jobs/:id/claim', { params: { id }, body: { pcId: PC_B }, accountId: HELIX }),
    ]);
    assert.deepStrictEqual([a.statusCode, b.statusCode].sort(), [200, 409]);
    const won = a.statusCode === 200 ? a : b;
    const lost = a.statusCode === 200 ? b : a;
    assert.deepStrictEqual(won.body, { success: true, data: { id, kind: 'shots', title: 'Screenshots of a change, about 1 minute', payload: SHOTS } });
    assert.deepStrictEqual([lost.body.success, lost.body.code], [false, 'taken']);
    assert.ok(lost.body.error.length > 10);
    const job = h.jobs[0];
    assert.strictEqual(job.status, 'running');
    assert.deepStrictEqual([job.claimed_account, job.claimed_pc], a.statusCode === 200 ? [MUFFINS, PC_A] : [HELIX, PC_B]);
    assert.strictEqual(job.claimed_at, h.now());
    const late = await h.call('POST /team/jobs/:id/claim', { params: { id }, body: { pcId: PC_W }, accountId: WAR });
    assert.strictEqual(late.statusCode, 409);
  });
});

test('claim refuses a job that expired, was cancelled or does not exist, and a bad pc id', async () => {
  await withHarness(async (h) => {
    const expiring = await h.makeJob({ ttlS: 60 });
    const cancelled = await h.makeJob();
    await h.internal('POST /internal/team/jobs/:id/cancel', { params: { id: cancelled } });
    h.advance(61_000);
    for (const id of [expiring, cancelled]) {
      const r = await h.call('POST /api/team/jobs/:id/claim', { params: { id }, body: { pcId: PC_A } });
      assert.strictEqual(r.statusCode, 409, id);
      assert.strictEqual(r.body.code, 'taken');
    }
    assert.strictEqual(h.jobs.find((j) => j.id === expiring).status, 'queued', 'the claim itself left it alone (the sweep marks it expired)');
    const missing = await h.call('POST /api/team/jobs/:id/claim', { params: { id: 'a'.repeat(12) }, body: { pcId: PC_A } });
    assert.deepStrictEqual([missing.statusCode, missing.body.code], [404, 'not_found']);
    for (const id of ['short', '../../x', 'A'.repeat(12), 'g'.repeat(12)]) assert.strictEqual((await h.call('POST /api/team/jobs/:id/claim', { params: { id }, body: { pcId: PC_A } })).statusCode, 404, id);
    const fresh = await h.makeJob();
    for (const pcId of ['short', 'bad id with spaces', 12345678]) {
      const r = await h.call('POST /api/team/jobs/:id/claim', { params: { id: fresh }, body: { pcId } });
      assert.strictEqual(r.statusCode, 400, String(pcId));
    }
    assert.strictEqual(h.jobs.find((j) => j.id === fresh).status, 'queued');
  });
});

test('the PC that holds a job may claim it again (a resent claim), no other PC may', async () => {
  await withHarness(async (h) => {
    const id = await h.runningJob();
    h.advance(MIN);
    const again = await h.call('POST /api/team/jobs/:id/claim', { params: { id }, body: { pcId: PC_A } });
    assert.strictEqual(again.statusCode, 200);
    assert.strictEqual(again.body.data.payload.rev, SHOTS.rev);
    assert.strictEqual(h.jobs[0].heartbeat_at, h.now(), 'it renewed the heartbeat');
    const samePcNewSignIn = await h.login(MUFFINS);   // signing in again on the same PC is still that PC
    assert.strictEqual((await h.call('POST /api/team/jobs/:id/claim', { params: { id }, body: {}, token: samePcNewSignIn.body.data.token })).statusCode, 200);
    const otherPcSameAccount = await h.call('POST /api/team/jobs/:id/claim', { params: { id }, body: { pcId: PC_A2 }, pcId: PC_A2 });
    assert.deepStrictEqual([otherPcSameAccount.statusCode, otherPcSameAccount.body.code], [409, 'taken']);
    assert.strictEqual((await h.call('POST /api/team/jobs/:id/claim', { params: { id }, body: { pcId: PC_B }, accountId: HELIX })).statusCode, 409);
  });
});

test('decline records why, keeps the job queued for the other PCs and one entry per PC', async () => {
  await withHarness(async (h) => {
    const id = await h.makeJob();
    const r = await h.call('POST /api/team/jobs/:id/decline', { params: { id }, body: { pcId: PC_A, reason: 'not_now' } });
    assert.deepStrictEqual(r.body, { success: true });
    assert.strictEqual(h.jobs[0].status, 'queued');
    let declines = JSON.parse(h.jobs[0].result).declines;
    assert.deepStrictEqual(declines.map((d) => [d.pcId, d.reason]), [[PC_A, 'not_now']]);
    assert.ok(Number.isFinite(Date.parse(declines[0].at)));
    await h.call('POST /team/jobs/:id/decline', { params: { id }, body: { pcId: PC_B, reason: 'paused' }, accountId: HELIX });
    await h.call('POST /team/jobs/:id/decline', { params: { id }, body: { pcId: PC_B, reason: 'busy' }, accountId: HELIX });   // the PC's newer answer replaces its older one
    await h.call('POST /team/jobs/:id/decline', { params: { id }, body: { reason: 'not_now' } });   // no pc id: the token's
    declines = JSON.parse(h.jobs[0].result).declines;
    assert.deepStrictEqual(declines.map((d) => [d.pcId, d.reason]), [[PC_B, 'busy'], [PC_A, 'not_now']], 'one entry per PC, the latest answer last');
    for (let i = 0; i < 25; i++) {   // a crowd of PCs: the list is capped
      const pcId = `pc-bulk-${String(i).padStart(4, '0')}`;
      const token = (await h.login(MUFFINS, { pcId })).body.data.token;
      await h.call('POST /api/team/jobs/:id/decline', { params: { id }, body: { pcId, reason: 'busy' }, token });
    }
    assert.strictEqual(JSON.parse(h.jobs[0].result).declines.length, 20, 'the list is capped');
    const claim = await h.call('POST /api/team/jobs/:id/claim', { params: { id }, body: { pcId: PC_W }, accountId: WAR });
    assert.strictEqual(claim.statusCode, 200, 'a decline does not stop the other PCs from taking it');
  });
});

test('the heartbeat does not offer a PC a job it declined, whatever the reason; the other PCs still get it', async () => {
  await withHarness(async (h) => {
    const first = await h.makeJob({ title: 'first' });
    const second = await h.makeJob({ title: 'second' });
    const offerOf = async (opts) => (await h.call('POST /api/team/heartbeat', { body: beat({ pcId: PC_OF[opts.accountId] }), ...opts })).body.data.offer;
    assert.strictEqual((await offerOf({ accountId: MUFFINS })).id, first);
    await h.call('POST /api/team/jobs/:id/decline', { params: { id: first }, body: { pcId: PC_A, reason: 'not_now' } });
    assert.strictEqual((await offerOf({ accountId: MUFFINS })).id, second, 'the next oldest job, not the one it declined');
    assert.strictEqual((await offerOf({ accountId: HELIX })).id, first, 'the other PCs are still offered the first');
    assert.strictEqual((await offerOf({ accountId: WAR })).id, first);
    await h.call('POST /api/team/jobs/:id/decline', { params: { id: second }, body: { pcId: PC_A, reason: 'paused' } });
    assert.strictEqual(await offerOf({ accountId: MUFFINS }), null, 'every job declined: nothing to offer');
    assert.strictEqual((await offerOf({ accountId: HELIX })).id, first);
    // a PC is not an account: the same account's other PC is offered what its first PC declined
    const a2 = (await h.call('POST /api/team/heartbeat', { body: beat({ pcId: PC_A2 }), pcId: PC_A2 })).body.data.offer;
    assert.strictEqual(a2.id, first);
    // declining is not a lock: the PC may still claim a job it declined, and a claimed job is offered to nobody
    assert.strictEqual((await h.call('POST /api/team/jobs/:id/claim', { params: { id: first }, body: { pcId: PC_A } })).statusCode, 200);
    assert.strictEqual((await offerOf({ accountId: HELIX })).id, second);
    h.jobs.find((j) => j.id === second).result = JSON.stringify({ declines: [{ pcId: PC_B, reason: 'busy', at: 'x' }, null, 'junk'] });   // a damaged result still reads
    assert.strictEqual(await offerOf({ accountId: HELIX }), null);
    assert.strictEqual((await offerOf({ accountId: WAR })).id, second);
  });
});

test('decline checks the reason and pc id, answers 404 for an unknown job and changes nothing on a job that is not queued', async () => {
  await withHarness(async (h) => {
    const id = await h.makeJob();
    for (const body of [{ pcId: PC_A }, { pcId: PC_A, reason: 'because' }, { pcId: 'x', reason: 'busy' }, undefined]) {
      assert.strictEqual((await h.call('POST /api/team/jobs/:id/decline', { params: { id }, body })).statusCode, 400, JSON.stringify(body));
    }
    assert.strictEqual((await h.call('POST /api/team/jobs/:id/decline', { params: { id }, body: { pcId: PC_A2, reason: 'busy' } })).statusCode, 403, 'another PC than the token\'s');
    assert.strictEqual(h.jobs[0].result, null);
    assert.strictEqual((await h.call('POST /api/team/jobs/:id/decline', { params: { id: 'b'.repeat(12) }, body: { pcId: PC_A, reason: 'busy' } })).statusCode, 404);
    const running = await h.runningJob();
    const r = await h.call('POST /api/team/jobs/:id/decline', { params: { id: running }, body: { pcId: PC_B, reason: 'busy' }, accountId: HELIX });
    assert.deepStrictEqual(r.body, { success: true });
    assert.strictEqual(h.jobs.find((j) => j.id === running).result, null);
    assert.strictEqual(h.jobs.find((j) => j.id === running).status, 'running');
  });
});

// ── Result files ─────────────────────────────────────────────────────────────────────────────────────────────────────────

test('an upload is stored under the job folder and answers its size', async () => {
  await withHarness(async (h) => {
    const id = await h.runningJob();
    const picture = png(1600, 900, 5000);
    const r = await h.upload(id, 'low_hero.png', picture);
    assert.strictEqual(r.statusCode, 200, JSON.stringify(r.body));
    assert.deepStrictEqual(r.body, { success: true, data: { name: 'low_hero.png', bytes: picture.length, width: 1600, height: 900 } });
    assert.ok(fs.readFileSync(path.join(h.jobFolder(id), 'low_hero.png')).equals(picture));
    assert.deepStrictEqual(fs.readdirSync(h.jobFolder(id)), ['low_hero.png'], 'no half-written part is left');
    const dirMode = fs.statSync(h.jobFolder(id)).mode & 0o777;
    assert.strictEqual(dirMode & 0o027, 0, `the folder is not writable by the group or readable by others (${dirMode.toString(8)})`);
    assert.strictEqual(fs.statSync(path.join(h.jobFolder(id), 'low_hero.png')).mode & 0o007, 0, 'not readable by others');
    const again = await h.upload(id, 'low_hero.png', png(800, 450), { headers: { 'x-team-pc': PC_A } });   // the same name again replaces it
    assert.strictEqual(again.statusCode, 200);
    assert.strictEqual(fs.readFileSync(path.join(h.jobFolder(id), 'low_hero.png')).length, png(800, 450).length);
    h.advance(MIN);
    await h.upload(id, 'ultra_hero.png', png(), { query: { pcId: PC_A } });
    assert.strictEqual(h.jobs[0].heartbeat_at, h.now(), 'an upload renews the heartbeat');
    assert.deepStrictEqual(fs.readdirSync(h.jobFolder(id)).sort(), ['low_hero.png', 'ultra_hero.png']);
  });
});

test('an upload with a bad name is 400 and writes nothing, whatever the name tries', async () => {
  await withHarness(async (h) => {
    const id = await h.runningJob();
    const bad = ['Low.png', 'low.PNG', 'low.jpg', 'low', '.png', 'a b.png', 'a/b.png', '../x.png', '..%2fx.png', 'a\\b.png', 'low.png.exe', 'low..png', `${'a'.repeat(61)}.png`, 'ü.png', 'a.png\u0000', '.hidden.png', '-', ''];
    for (const name of bad) {
      const r = await h.upload(id, name, png());
      assert.strictEqual(r.statusCode, 400, JSON.stringify(name));
      assert.strictEqual(r.body.code, 'bad_request');
    }
    assert.ok(!fs.existsSync(h.jobFolder(id)) || fs.readdirSync(h.jobFolder(id)).length === 0);
    assert.deepStrictEqual(fs.readdirSync(path.dirname(h.resultsDir)).filter((n) => !n.startsWith('secret-')), [path.basename(h.resultsDir)].filter((n) => fs.existsSync(h.resultsDir)), 'nothing was written next to the results folder');
    assert.strictEqual((await h.upload(id, `${'a'.repeat(60)}.png`, png())).statusCode, 200, '60 characters is allowed');
    assert.strictEqual((await h.upload(id, '0-9_az.png', png())).statusCode, 200);
    for (const jobId of ['../etc', 'x'.repeat(12), '..', `${'a'.repeat(11)}/`]) assert.strictEqual((await h.upload(jobId, 'a.png', png())).statusCode, 404, jobId);
  });
});

test('an upload must be image/png and no more than 8 MB, refused before the body is read when it says so', async () => {
  await withHarness(async (h) => {
    const id = await h.runningJob();
    for (const type of ['application/json', 'text/plain', 'image/jpeg', '', undefined]) {
      const r = await h.upload(id, 'a.png', png(), { type, headers: type === undefined ? { 'content-type': undefined } : {} });
      assert.strictEqual(r.statusCode, 415, String(type));
      assert.strictEqual(r.body.code, 'bad_type');
    }
    assert.strictEqual((await h.upload(id, 'a.png', png(), { type: 'IMAGE/PNG; charset=binary' })).statusCode, 200, 'media type is case-insensitive and may carry parameters');
    // declared too large: answered at once, the stream is never read
    const declared = await h.call('PUT /api/team/jobs/:id/files/:name', { params: { id, name: 'big.png' }, raw: png(), headers: { 'content-type': 'image/png', 'content-length': String(FILE_MAX_BYTES + 1) } });
    assert.strictEqual(declared.statusCode, 413);
    assert.strictEqual(declared.body.code, 'too_large');
    assert.strictEqual(declared.headers.Connection, 'close');
    // the limit itself passes the size check (the body is then judged as a PNG)
    const atLimit = png(1600, 900, FILE_MAX_BYTES - png(1600, 900, 0).length);
    assert.strictEqual(atLimit.length, FILE_MAX_BYTES);
    assert.strictEqual((await h.upload(id, 'limit.png', atLimit)).statusCode, 200);
    // no content-length (chunked): counted as it arrives, and reading stops at the cap
    let pulled = 0;
    const megabyte = Buffer.alloc(1024 * 1024, 1);
    function* flood() { for (let i = 0; i < 100; i++) { pulled++; yield megabyte; } }
    const chunked = await h.call('PUT /api/team/jobs/:id/files/:name', { params: { id, name: 'flood.png' }, chunks: flood(), headers: { 'content-type': 'image/png' } });
    assert.strictEqual(chunked.statusCode, 413);
    assert.ok(pulled < 40, `stopped reading early (${pulled} of 100 megabytes pulled)`);
    assert.ok(!fs.existsSync(path.join(h.jobFolder(id), 'flood.png')) && !fs.existsSync(path.join(h.jobFolder(id), 'big.png')));
    assert.deepStrictEqual(fs.readdirSync(h.jobFolder(id)).sort(), ['a.png', 'limit.png']);
  });
});

test('an upload that is not a whole PNG of a sane size is 400 with a reason', async () => {
  await withHarness(async (h) => {
    const id = await h.runningJob();
    const cases = {
      'not a png': Buffer.from('GIF89a this is not a PNG at all, only long enough to pass a length check'),
      'empty': Buffer.alloc(0), 'cut off': png().subarray(0, 60), 'too small': png(8, 8), 'too big': png(8000, 600), 'no ihdr': Buffer.concat([png().subarray(0, 8), Buffer.alloc(60)]),
    };
    for (const [what, buf] of Object.entries(cases)) {
      const r = await h.upload(id, 'p.png', buf);
      assert.strictEqual(r.statusCode, 400, what);
      assert.deepStrictEqual([r.body.success, r.body.code], [false, 'bad_request']);
      assert.ok(r.body.error.length > 10, what);
    }
    assert.ok(!fs.existsSync(path.join(h.jobFolder(id), 'p.png')));
  });
});

test('an upload is only for the PC that holds the job, and only while it runs', async () => {
  await withHarness(async (h) => {
    const id = await h.runningJob();
    const otherPc = await h.upload(id, 'a.png', png(), { pcId: PC_A2 });   // the same account, another PC
    assert.deepStrictEqual([otherPc.statusCode, otherPc.body.code], [403, 'not_your_job']);
    assert.ok(otherPc.body.error.length > 10);
    const otherAccount = await h.upload(id, 'a.png', png(), { accountId: HELIX });
    assert.deepStrictEqual([otherAccount.statusCode, otherAccount.body.code], [403, 'not_your_job']);
    assert.strictEqual((await h.upload(id, 'a.png', png(), { headers: { 'x-team-pc': 'bad id!' } })).statusCode, 400);
    assert.strictEqual((await h.upload(id, 'a.png', png(), { headers: { 'x-team-pc': PC_B } })).body.code, 'wrong_pc', 'a PC id of another PC than the token\'s');
    assert.strictEqual((await h.upload(id, 'a.png', png(), { headers: { 'x-team-pc': PC_A } })).statusCode, 200, 'the right PC');
    assert.strictEqual((await h.upload(id, 'b.png', png())).statusCode, 200, 'with no PC id the token\'s PC is the check');
    assert.deepStrictEqual(fs.readdirSync(h.jobFolder(id)).sort(), ['a.png', 'b.png']);

    const queued = await h.makeJob();
    const q = await h.upload(queued, 'a.png', png());
    assert.deepStrictEqual([q.statusCode, q.body.code], [409, 'not_running']);
    assert.strictEqual((await h.upload('c'.repeat(12), 'a.png', png())).statusCode, 404);
    await h.call('POST /api/team/jobs/:id/done', { params: { id }, body: { files: ['a.png'] } });
    const finished = await h.upload(id, 'c.png', png());
    assert.deepStrictEqual([finished.statusCode, finished.body.code], [409, 'not_running']);
    const cancelled = await h.runningJob({ pcId: PC_B, accountId: HELIX });
    await h.internal('POST /internal/team/jobs/:id/cancel', { params: { id: cancelled } });
    const c = await h.upload(cancelled, 'a.png', png(), { accountId: HELIX });
    assert.deepStrictEqual([c.statusCode, c.body.code, c.body.error], [409, 'not_running', 'This job was cancelled.']);
    assert.ok(!fs.existsSync(path.join(h.jobFolder(queued), 'a.png')) && !fs.existsSync(path.join(h.jobFolder(cancelled), 'a.png')));
  });
});

test('a job takes at most 40 pictures, but one may be replaced', async () => {
  await withHarness(async (h) => {
    const id = await h.runningJob();
    fs.mkdirSync(h.jobFolder(id), { recursive: true });
    for (let i = 0; i < FILES_PER_JOB; i++) fs.writeFileSync(path.join(h.jobFolder(id), `shot_${i}.png`), png());
    const extra = await h.upload(id, 'one_more.png', png());
    assert.deepStrictEqual([extra.statusCode, extra.body.code], [409, 'too_many']);
    assert.strictEqual((await h.upload(id, 'shot_3.png', png(800, 450))).statusCode, 200, 'replacing one is not adding one');
    assert.strictEqual(fs.readdirSync(h.jobFolder(id)).length, FILES_PER_JOB);
  });
});

test('a results folder that cannot be written is a clear error, not a crash', async () => {
  await withHarness(async (h) => {
    const id = await h.runningJob();
    fs.mkdirSync(path.dirname(h.resultsDir), { recursive: true });
    fs.writeFileSync(h.resultsDir, 'a file where the folder should be');
    const r = await h.upload(id, 'a.png', png());
    assert.strictEqual(r.statusCode, 500);
    assert.deepStrictEqual([r.body.success, r.body.code], [false, 'server_error']);
    assert.ok(r.body.error.length > 10 && !/ENOTDIR|\//.test(r.body.error), 'no path or error code in the reply');
    fs.rmSync(h.resultsDir);
  });
});

// ── Finishing ────────────────────────────────────────────────────────────────────────────────────────────────────────────

test('done checks the named pictures were uploaded and saves the result', async () => {
  await withHarness(async (h) => {
    const id = await h.runningJob();
    const low = png(1600, 900, 300);
    await h.upload(id, 'low_hero.png', low);
    await h.upload(id, 'ultra_hero.png', png(1600, 900, 400));
    h.advance(90_000);
    const missing = await h.call('POST /api/team/jobs/:id/done', { params: { id }, body: { files: ['low_hero.png', 'never_sent.png'] } });
    assert.deepStrictEqual([missing.statusCode, missing.body.code], [400, 'bad_request']);
    assert.match(missing.body.error, /never_sent\.png/);
    assert.strictEqual(h.jobs[0].status, 'running', 'a refused done leaves the job running');
    for (const files of [['../x.png'], ['A.png'], [7], Array.from({ length: 41 }, (_, i) => `s${i}.png`)]) {
      const bad = await h.call('POST /api/team/jobs/:id/done', { params: { id }, body: { files } });
      assert.strictEqual(bad.statusCode, 400, JSON.stringify(files).slice(0, 40));
    }
    assert.strictEqual(h.jobs[0].status, 'running');
    const done = await h.call('POST /api/team/jobs/:id/done', {
      params: { id }, body: { files: ['low_hero.png', 'ultra_hero.png', 'low_hero.png'], log: `ok\n${'x'.repeat(100000)}`, timings: { downloadS: 12.34, runS: 1e9, extra: 1 } },
    });
    assert.deepStrictEqual([done.statusCode, done.body], [200, { success: true, data: { id, status: 'done' } }]);
    const job = h.jobs[0];
    assert.deepStrictEqual([job.status, job.finished_at, job.error], ['done', h.now(), null]);
    const result = JSON.parse(job.result);
    assert.deepStrictEqual(result.files, [{ name: 'low_hero.png', bytes: low.length }, { name: 'ultra_hero.png', bytes: png(1600, 900, 400).length }]);
    assert.strictEqual(Buffer.byteLength(result.log) <= 65536, true);
    assert.ok(result.log.startsWith('ok\n'));
    assert.deepStrictEqual(result.timings, { downloadS: 12.3, runS: 86400 });
    // a resend of done (the answer got lost) is the same success; fail after done is refused
    assert.deepStrictEqual((await h.call('POST /team/jobs/:id/done', { params: { id }, body: { files: [] } })).body, { success: true, data: { id, status: 'done' } });
    const late = await h.call('POST /api/team/jobs/:id/fail', { params: { id }, body: { error: 'too late' } });
    assert.deepStrictEqual([late.statusCode, late.body.code], [409, 'not_running']);
    assert.strictEqual(h.jobs[0].status, 'done');
  });
});

test('done and fail are only for the PC that holds a running job', async () => {
  await withHarness(async (h) => {
    const id = await h.runningJob();
    for (const route of ['done', 'fail']) {
      const other = await h.call(`POST /api/team/jobs/:id/${route}`, { params: { id }, body: { files: [], error: 'x' }, accountId: HELIX });
      assert.deepStrictEqual([other.statusCode, other.body.code], [403, 'not_your_job'], route);
      const otherPc = await h.call(`POST /api/team/jobs/:id/${route}`, { params: { id }, body: { files: [], error: 'x' }, pcId: PC_A2 });   // the same account, another PC
      assert.deepStrictEqual([otherPc.statusCode, otherPc.body.code], [403, 'not_your_job'], `${route} from another PC of the account`);
      assert.strictEqual((await h.call(`POST /api/team/jobs/:id/${route}`, { params: { id }, body: { files: [], error: 'x', pcId: PC_B } })).body.code, 'wrong_pc', `${route} naming another PC`);
      assert.strictEqual((await h.call(`POST /api/team/jobs/:id/${route}`, { params: { id: 'd'.repeat(12) }, body: { files: [], error: 'x' } })).statusCode, 404);
    }
    assert.strictEqual(h.jobs[0].status, 'running');
    const queued = await h.makeJob();
    for (const route of ['done', 'fail']) assert.strictEqual((await h.call(`POST /api/team/jobs/:id/${route}`, { params: { id: queued }, body: { files: [], error: 'x' } })).statusCode, 409, route);
    assert.strictEqual(h.jobs.find((j) => j.id === queued).status, 'queued');
  });
});

test('fail records a capped player-readable error and the log, and a resend is the same success', async () => {
  await withHarness(async (h) => {
    const id = await h.runningJob();
    const r = await h.call('POST /api/team/jobs/:id/fail', { params: { id }, body: { error: `  Godot crashed\u0000 on start.\n${'!'.repeat(900)}`, log: 'line\n'.repeat(5) } });
    assert.deepStrictEqual([r.statusCode, r.body], [200, { success: true, data: { id, status: 'failed' } }]);
    const job = h.jobs[0];
    assert.strictEqual(job.status, 'failed');
    assert.strictEqual(job.finished_at, h.now());
    assert.strictEqual(job.error.length, 400);
    assert.ok(job.error.startsWith('Godot crashed on start.'));
    assert.strictEqual(JSON.parse(job.result).log, 'line\n'.repeat(5));
    assert.strictEqual((await h.call('POST /team/jobs/:id/fail', { params: { id }, body: { error: 'again' } })).body.data.status, 'failed');
    assert.strictEqual(h.jobs[0].error.startsWith('Godot crashed'), true, 'the first error is kept');
    const bare = await h.runningJob();
    await h.call('POST /api/team/jobs/:id/fail', { params: { id: bare }, body: {} });
    assert.ok(h.jobs.find((j) => j.id === bare).error.length > 10, 'a fail without a reason still says something');
  });
});

test('declines survive into the result of a finished job', async () => {
  await withHarness(async (h) => {
    const id = await h.makeJob();
    await h.call('POST /api/team/jobs/:id/decline', { params: { id }, body: { pcId: PC_B, reason: 'busy' }, accountId: HELIX });
    await h.call('POST /api/team/jobs/:id/claim', { params: { id }, body: { pcId: PC_A } });
    await h.call('POST /api/team/jobs/:id/done', { params: { id }, body: { files: [], log: 'fine' } });
    const result = JSON.parse(h.jobs[0].result);
    assert.deepStrictEqual(result.declines.map((d) => d.reason), ['busy']);
    assert.strictEqual(result.log, 'fine');
  });
});

// ── The quiet-PC sweep ───────────────────────────────────────────────────────────────────────────────────────────────────

test('a running job whose PC goes quiet is queued again once, then fails', async () => {
  await withHarness(async (h) => {
    const id = await h.runningJob();
    const job = h.jobs[0];
    await h.call('POST /api/team/heartbeat', { body: beat() });
    h.advance(2 * MIN + 59_000);
    await h.call('POST /api/team/heartbeat', { body: beat({ pcId: PC_B }), accountId: HELIX });
    assert.strictEqual(job.status, 'running', 'under 3 minutes of quiet is still running');
    h.advance(2_000);
    const other = await h.call('POST /api/team/heartbeat', { body: beat({ pcId: PC_B }), accountId: HELIX });
    assert.deepStrictEqual([job.status, job.tries, job.claimed_account, job.claimed_pc, job.claimed_at, job.heartbeat_at], ['queued', 1, null, null, null, null]);
    assert.strictEqual(other.body.data.offer.id, id, 'another PC is offered it');
    const claim = await h.call('POST /api/team/jobs/:id/claim', { params: { id }, body: { pcId: PC_B }, accountId: HELIX });
    assert.strictEqual(claim.statusCode, 200);
    // the first PC wakes up and tries to finish: the job is not its any more
    const stale = await h.call('POST /api/team/jobs/:id/done', { params: { id }, body: { files: [], pcId: PC_A } });
    assert.deepStrictEqual([stale.statusCode, stale.body.code], [403, 'not_your_job']);
    h.advance(4 * MIN);
    await h.call('POST /api/team/heartbeat', { body: beat({ pcId: PC_W }), accountId: WAR });
    assert.deepStrictEqual([job.status, job.tries, job.finished_at], ['failed', 1, h.now()]);
    assert.match(job.error, /went quiet/);
    const off = await h.call('POST /api/team/heartbeat', { body: beat({ pcId: PC_W }), accountId: WAR });
    assert.strictEqual(off.body.data.offer, null, 'a failed job is not offered');
  });
});

test('a heartbeat from the PC that runs the job keeps it alive, even after a long quiet spell', async () => {
  await withHarness(async (h) => {
    const id = await h.runningJob();
    const job = h.jobs[0];
    for (let i = 0; i < 10; i++) {
      h.advance(MIN + 30_000);
      await h.call('POST /api/team/heartbeat', { body: beat() });
    }
    assert.deepStrictEqual([job.status, job.tries, job.heartbeat_at], ['running', 0, h.now()]);
    h.advance(10 * MIN);   // the PC slept; its first heartbeat after waking renews before the sweep, so the job survives
    await h.call('POST /api/team/heartbeat', { body: beat() });
    assert.strictEqual(job.status, 'running');
    assert.strictEqual((await h.call('POST /api/team/jobs/:id/done', { params: { id }, body: { files: [] } })).statusCode, 200);
  });
});

test('the runner\'s routes sweep too, and a requeued job is not failed in the same sweep', async () => {
  await withHarness(async (h) => {
    const id = await h.runningJob();
    h.advance(10 * MIN);
    const got = await h.internal('GET /internal/team/jobs/:id', { params: { id } });
    assert.deepStrictEqual([got.body.data.status, got.body.data.tries], ['queued', 1]);
    h.advance(10 * MIN);
    const again = await h.internal('GET /internal/team/pcs');
    assert.strictEqual(again.statusCode, 200);
    assert.strictEqual(h.jobs[0].status, 'queued', 'nobody claimed it, so nobody went quiet');
  });
});

test('a queued job past its time becomes expired and is never offered or claimed', async () => {
  await withHarness(async (h) => {
    const id = await h.makeJob({ ttlS: 120 });
    h.advance(121_000);
    const hb = await h.call('POST /api/team/heartbeat', { body: beat() });
    assert.strictEqual(hb.body.data.offer, null);
    assert.deepStrictEqual([h.jobs[0].status, h.jobs[0].finished_at], ['expired', h.now()]);
    const r = await h.call('POST /api/team/jobs/:id/claim', { params: { id }, body: { pcId: PC_A } });
    assert.strictEqual(r.statusCode, 409);
    assert.match(r.body.error, /ran out of time/);
    assert.strictEqual((await h.internal('POST /internal/team/jobs/:id/cancel', { params: { id } })).statusCode, 409, 'a finished job cannot be cancelled');
  });
});

// ── The runner's routes ──────────────────────────────────────────────────────────────────────────────────────────────────

test('runner routes answer 404 to a request that is not from this machine, has no secret, or has the wrong one', async () => {
  await withHarness(async (h) => {
    const id = await h.makeJob();
    const calls = [
      ['POST /internal/team/jobs', { body: newJob() }], ['GET /internal/team/jobs/:id', { params: { id } }],
      ['POST /internal/team/jobs/:id/cancel', { params: { id } }], ['GET /internal/team/pcs', {}],
    ];
    const attempts = [
      { addr: '203.0.113.9' }, { addr: '10.0.0.4' }, { addr: '::ffff:203.0.113.9' }, { addr: null }, { addr: '127.0.0.2' }, { addr: '127.0.0.1.evil' },
      { secret: null }, { secret: '' }, { secret: 'wrong-secret-0123456789-abcdefghij' }, { secret: SECRET.slice(0, -1) }, { secret: `${SECRET}x` }, { secret: SECRET.toUpperCase() }, { secret: [SECRET] },
      // through nginx the request also comes from 127.0.0.1, but carries its forwarding headers
      { headers: { 'x-forwarded-for': '203.0.113.9' } }, { headers: { 'x-real-ip': '203.0.113.9' } }, { headers: { forwarded: 'for=203.0.113.9' } }, { headers: { 'x-forwarded-proto': 'https' } },
    ];
    for (const [route, base] of calls) {
      for (const a of attempts) {
        const r = await h.internal(route, { ...base, ...a });
        assert.strictEqual(r.statusCode, 404, `${route} ${JSON.stringify(a)}`);
        assert.strictEqual(r.body.success, false);
      }
      assert.strictEqual((await h.internal(route, { ...base, addr: '::1' })).statusCode, 200, `${route} from ::1`);
      assert.strictEqual((await h.internal(route, { ...base, addr: '::ffff:127.0.0.1' })).statusCode, 200);
    }
    assert.strictEqual(h.jobs.length, 1 + 2, 'only the two answered creates made a job');
    assert.strictEqual(h.jobs[0].status, 'cancelled', 'only the answered cancel (from ::1) changed it');
  });
});

test('runner routes refuse everything when the secret file is missing, empty or too short', async () => {
  await withHarness(async (h) => {
    const secretFile = path.join(path.dirname(h.resultsDir), `secret-${path.basename(h.resultsDir)}`);
    for (const content of [null, '', '\n', 'short']) {
      if (content === null) fs.rmSync(secretFile, { force: true }); else fs.writeFileSync(secretFile, content);
      for (const secret of [SECRET, '', 'short', undefined]) {
        const r = await h.internal('GET /internal/team/pcs', { secret: secret === undefined ? null : secret });
        assert.strictEqual(r.statusCode, 404, `${JSON.stringify(content)} / ${JSON.stringify(secret)}`);
      }
    }
    fs.writeFileSync(secretFile, `  ${SECRET}  \n`);
    assert.strictEqual((await h.internal('GET /internal/team/pcs')).statusCode, 200, 'the file is trimmed');
  });
});

test('the runner makes a job, reads it back with its files and cancels it', async () => {
  await withHarness(async (h) => {
    const made = await h.internal('POST /internal/team/jobs', { body: newJob({ title: '  Screenshots of "Fix the fen"  ', weightS: 45, ttlS: 600 }) });
    assert.strictEqual(made.statusCode, 200);
    const id = made.body.data.id;
    assert.match(id, HEX12);
    assert.deepStrictEqual(Object.keys(made.body), ['success', 'data']);
    const row = h.jobs[0];
    assert.deepStrictEqual([row.kind, row.title, row.weight_s, row.status, row.tries, row.expires_at - row.created_at], ['shots', 'Screenshots of "Fix the fen"', 45, 'queued', 0, 600_000]);
    assert.deepStrictEqual(JSON.parse(row.payload), SHOTS);

    const queued = await h.internal('GET /internal/team/jobs/:id', { params: { id } });
    assert.deepStrictEqual(queued.body.data, {
      id, kind: 'shots', title: 'Screenshots of "Fix the fen"', weightS: 45, payload: SHOTS, status: 'queued', tries: 0,
      targetPc: null, createdAt: new Date(T0).toISOString(), expiresAt: new Date(T0 + 600_000).toISOString(), claimedAccount: null, claimedPc: null, claimedAt: null, heartbeatAt: null, finishedAt: null, reportedAt: null,
      result: null, error: null, files: [],
    });

    await h.call('POST /api/team/jobs/:id/claim', { params: { id }, body: { pcId: PC_A } });
    await h.upload(id, 'low_hero.png', png(1600, 900, 50));
    await h.upload(id, 'ultra_hero.png', png(1600, 900, 70));
    await h.call('POST /api/team/jobs/:id/done', { params: { id }, body: { files: ['low_hero.png', 'ultra_hero.png'], log: 'all fine', timings: { downloadS: 5, runS: 40 } } });
    const done = (await h.internal('GET /internal/team/jobs/:id', { params: { id } })).body.data;
    assert.deepStrictEqual([done.status, done.claimedAccount, done.claimedPc, done.error], ['done', MUFFINS, PC_A, null]);
    assert.deepStrictEqual(done.result.timings, { downloadS: 5, runS: 40 });
    assert.strictEqual(done.result.log, 'all fine');
    assert.deepStrictEqual(done.files.map((f) => [f.name, f.bytes, f.path]), [
      ['low_hero.png', png(1600, 900, 50).length, path.join(h.resultsDir, id, 'low_hero.png')], ['ultra_hero.png', png(1600, 900, 70).length, path.join(h.resultsDir, id, 'ultra_hero.png')],
    ]);
    assert.ok(done.files.every((f) => path.isAbsolute(f.path) && fs.existsSync(f.path)));

    const second = await h.makeJob();
    const cancelled = await h.internal('POST /internal/team/jobs/:id/cancel', { params: { id: second } });
    assert.deepStrictEqual(cancelled.body, { success: true, data: { id: second, status: 'cancelled' } });
    assert.strictEqual(h.jobs[1].finished_at, h.now());
    assert.strictEqual((await h.internal('POST /internal/team/jobs/:id/cancel', { params: { id: second } })).statusCode, 200, 'cancelling twice is fine');
    const cancelDone = await h.internal('POST /internal/team/jobs/:id/cancel', { params: { id } });
    assert.deepStrictEqual([cancelDone.statusCode, cancelDone.body.code], [409, 'not_running']);
    assert.strictEqual(h.jobs[0].status, 'done');
    for (const route of ['GET /internal/team/jobs/:id', 'POST /internal/team/jobs/:id/cancel']) {
      assert.strictEqual((await h.internal(route, { params: { id: 'e'.repeat(12) } })).statusCode, 404);
      assert.strictEqual((await h.internal(route, { params: { id: '../../etc/passwd' } })).statusCode, 404);
    }
  });
});

test('cancelling a running job stops its PC: the next upload, done and fail are 409 "cancelled", and it is never offered', async () => {
  await withHarness(async (h) => {
    const id = await h.runningJob();
    await h.internal('POST /internal/team/jobs/:id/cancel', { params: { id } });
    assert.strictEqual(h.jobs[0].status, 'cancelled');
    for (const route of ['done', 'fail']) {
      const r = await h.call(`POST /api/team/jobs/:id/${route}`, { params: { id }, body: { files: [], error: 'x' } });
      assert.deepStrictEqual([r.statusCode, r.body.code, r.body.error], [409, 'not_running', 'This job was cancelled.'], route);
    }
    assert.strictEqual((await h.call('POST /api/team/heartbeat', { body: beat() })).body.data.offer, null);
    h.advance(10 * MIN);
    await h.call('POST /api/team/heartbeat', { body: beat() });
    assert.strictEqual(h.jobs[0].status, 'cancelled', 'the sweep leaves a cancelled job alone');
  });
});

test('the runner may not create a bad job and may not have more than 50 open ones', async () => {
  await withHarness(async (h) => {
    for (const body of [{}, newJob({ kind: 'No Way' }), newJob({ title: '' }), newJob({ payload: 'x' })]) {
      const r = await h.internal('POST /internal/team/jobs', { body });
      assert.strictEqual(r.statusCode, 400);
      assert.deepStrictEqual([r.body.success, r.body.code], [false, 'bad_request']);
      assert.ok(r.body.error.length > 10);
    }
    assert.strictEqual(h.jobs.length, 0);
    for (let i = 0; i < OPEN_JOBS_MAX; i++) await h.makeJob({ title: `job ${i}` });
    const over = await h.internal('POST /internal/team/jobs', { body: newJob() });
    assert.deepStrictEqual([over.statusCode, over.body.code], [429, 'too_many_jobs']);
    assert.strictEqual(h.jobs.length, OPEN_JOBS_MAX);
    await h.internal('POST /internal/team/jobs/:id/cancel', { params: { id: h.jobs[0].id } });
    assert.strictEqual((await h.internal('POST /internal/team/jobs', { body: newJob() })).statusCode, 200, 'a finished job makes room');
  });
});

test('a job id never repeats an existing one (a clash draws another)', async () => {
  await withHarness(async (h) => {
    const ids = new Set();
    for (let i = 0; i < 20; i++) ids.add(await h.makeJob({ title: `job ${i}` }));
    assert.strictEqual(ids.size, 20);
    assert.ok([...ids].every((id) => HEX12.test(id)));
  });
});

test('the runner sees the PCs seen in the last 2 minutes, with mode and state', async () => {
  await withHarness(async (h) => {
    await h.call('POST /api/team/heartbeat', { body: beat({ mode: 'auto', state: { fullscreen: true } }) });
    h.advance(90_000);
    await h.call('POST /api/team/heartbeat', { body: beat({ pcId: PC_B, name: 'Helix PC', mode: 'yes' }), accountId: HELIX });
    let r = await h.internal('GET /internal/team/pcs');
    assert.strictEqual(r.statusCode, 200);
    assert.deepStrictEqual(r.body.data.pcs.map((p) => [p.username, p.pcId, p.mode]), [['Helix', PC_B, 'yes'], ['Brbmuffins', PC_A, 'auto']], 'newest first');
    assert.deepStrictEqual(r.body.data.pcs[1].state, { gameRunning: false, fullscreen: true, onBattery: false, busy: false, paused: false });
    assert.deepStrictEqual(Object.keys(r.body.data.pcs[0]).sort(), ['accountId', 'gpu', 'lastSeen', 'mode', 'name', 'pcId', 'state', 'username', 'version']);
    h.advance(40_000);   // the first PC was last seen 130 s ago
    r = await h.internal('GET /internal/team/pcs');
    assert.deepStrictEqual(r.body.data.pcs.map((p) => p.pcId), [PC_B]);
    h.advance(2 * MIN);
    assert.deepStrictEqual((await h.internal('GET /internal/team/pcs')).body.data.pcs, []);
  });
});

test('every SQL statement is parameterised: nothing a PC or the runner sends is in the SQL text', async () => {
  await withHarness(async (h) => {
    const evil = "x'); DROP TABLE team_jobs; --";
    const id = await h.makeJob({ title: evil, payload: { evil } });
    await h.call('POST /api/team/heartbeat', { body: beat({ name: evil, gpu: evil, version: evil }) });
    await h.call('POST /api/team/jobs/:id/claim', { params: { id }, body: { pcId: PC_A } });
    await h.call('POST /api/team/jobs/:id/fail', { params: { id }, body: { error: evil, log: evil } });
    await h.internal('GET /internal/team/jobs/:id', { params: { id } });
    await h.internal('GET /internal/team/pcs');
    assert.ok(h.sqlLog.length > 10);
    assert.ok(h.sqlLog.every((sql) => !sql.includes('DROP') && !sql.includes(id) && !sql.includes(PC_A)), 'no value is inside the SQL');
    assert.strictEqual(h.jobs[0].title, evil.slice(0, 160), 'it is stored as text');
  });
});

// ── Target PC, the bench job, the PCs seen in the last days ───────────────────────────────────────────────────────────────

test('parseNewJob takes an optional target PC and refuses one that is not a PC id', () => {
  assert.strictEqual(parseNewJob(newJob()).job.targetPc, null);
  assert.strictEqual(parseNewJob(newJob({ targetPc: null })).job.targetPc, null);
  assert.strictEqual(parseNewJob(newJob({ targetPc: `  ${PC_W} ` })).job.targetPc, PC_W);
  for (const bad of ['', 'short', 'has space in it', 'pc/../etc', 'x'.repeat(65), 7, {}, []]) {
    const r = parseNewJob(newJob({ targetPc: bad }));
    assert.ok(r.error && /target PC/.test(r.error) && !r.job, JSON.stringify(bad));
  }
});

test('a job with a target PC is offered to and claimed by that PC only; a job without one still goes to every PC', async () => {
  await withHarness(async (h) => {
    const mine = await h.makeJob({ title: 'for the war PC', targetPc: PC_W });
    const any = await h.makeJob({ title: 'for any PC' });
    assert.strictEqual(h.jobs[0].target_pc, PC_W);
    assert.strictEqual(h.jobs[1].target_pc, null);
    const row = (await h.internal('GET /internal/team/jobs/:id', { params: { id: mine } })).body.data;
    assert.strictEqual(row.targetPc, PC_W);
    // the Muffins PC is offered the older job's successor, never the war PC's job
    const m = await h.call('POST /api/team/heartbeat', { body: beat() });
    assert.strictEqual(m.body.data.offer.id, any, 'another PC is offered the job without a target (the older job is not for it)');
    const w = await h.call('POST /api/team/heartbeat', { body: beat({ pcId: PC_W }), accountId: WAR });
    assert.strictEqual(w.body.data.offer.id, mine, 'its own PC is offered it, oldest first');
    // another PC (and another account) cannot claim it, and it stays queued
    for (const [accountId, pcId] of [[MUFFINS, PC_A], [MUFFINS, PC_A2], [HELIX, PC_B]]) {
      const r = await h.call('POST /api/team/jobs/:id/claim', { accountId, pcId, params: { id: mine }, body: { pcId } });
      assert.deepStrictEqual([r.statusCode, r.body.code, r.body.error], [403, 'not_your_job', 'This job is meant for another team PC.'], `${accountId}/${pcId}`);
    }
    assert.strictEqual(h.jobs[0].status, 'queued');
    const ok = await h.call('POST /api/team/jobs/:id/claim', { accountId: WAR, pcId: PC_W, params: { id: mine }, body: { pcId: PC_W } });
    assert.deepStrictEqual([ok.statusCode, ok.body.data.id], [200, mine]);
    assert.deepStrictEqual([h.jobs[0].claimed_account, h.jobs[0].claimed_pc], [WAR, PC_W]);
    // a job with no target can be claimed by anyone
    assert.strictEqual((await h.call('POST /api/team/jobs/:id/claim', { params: { id: any }, body: { pcId: PC_A } })).statusCode, 200);
  });
});

test('a job past the 50 listed for the offer does not hide a targeted job (the target is part of the query)', async () => {
  await withHarness(async (h) => {
    for (let i = 0; i < 49; i++) await h.makeJob({ title: `for helix ${i}`, targetPc: PC_B });
    const mine = await h.makeJob({ title: 'for muffins', targetPc: PC_A });
    const r = await h.call('POST /api/team/heartbeat', { body: beat() });
    assert.strictEqual(r.body.data.offer.id, mine);
  });
});

test('a bench job done: its runs are validated and stored for the claiming account, marked as a team PC\'s whatever the body says, and a resend stores nothing twice', async () => {
  await withHarness(async (h) => {
    const id = await h.runningJob({ accountId: WAR, over: newBench({ targetPc: PC_W }) });
    const runs = [benchRun(), benchRun({ clientRunId: '1760000000654321', preset: 'medium', source: 'player', sourcePc: 'pc-someone-else-9', accountId: 1, account_id: 1 })];
    const done = await h.call('POST /api/team/jobs/:id/done', { accountId: WAR, params: { id }, body: { runs, log: 'bench ok', timings: { downloadS: 3, runS: 301.26 } } });
    assert.deepStrictEqual([done.statusCode, done.body], [200, { success: true, data: { id, status: 'done' } }]);
    assert.strictEqual(h.benchRows.length, 2);
    assert.deepStrictEqual(h.benchRows.map((r) => [r.account_id, r.source, r.source_pc, r.preset, r.room, r.discipline_index, r.size, r.length, r.avg_fps]),
      [[WAR, 'team', PC_W, 'low', 'graves', 2, 'full_party', 'full', 61.5], [WAR, 'team', PC_W, 'medium', 'graves', 2, 'full_party', 'full', 61.5]]);
    const job = h.jobs[0];
    assert.deepStrictEqual([job.status, job.error], ['done', null]);
    const result = JSON.parse(job.result);
    assert.deepStrictEqual(result.runs, [{ clientRunId: '1760000000123456', id: 1 }, { clientRunId: '1760000000654321', id: 2 }]);
    assert.deepStrictEqual([result.files, result.log, result.timings], [[], 'bench ok', { downloadS: 3, runS: 301.3 }]);
    const row = (await h.internal('GET /internal/team/jobs/:id', { params: { id } })).body.data;
    assert.deepStrictEqual([row.status, row.result.runs.length, row.targetPc], ['done', 2, PC_W]);
    // the answer got lost: the same done again is the same success, and stores nothing twice
    assert.deepStrictEqual((await h.call('POST /api/team/jobs/:id/done', { accountId: WAR, params: { id }, body: { runs } })).body, { success: true, data: { id, status: 'done' } });
    assert.strictEqual(h.benchRows.length, 2);
  });
});

test('a bench job done with a run that does not validate fails the job with the readable reason, stores none of the runs and answers 400 with it', async () => {
  await withHarness(async (h) => {
    const id = await h.runningJob({ over: newBench({ targetPc: PC_A }) });
    const done = await h.call('POST /api/team/jobs/:id/done', { params: { id }, body: { runs: [benchRun(), benchRun({ clientRunId: '1760000000000002', preset: 'max' })], log: 'the log' } });
    assert.deepStrictEqual([done.statusCode, done.body.success, done.body.code], [400, false, 'bad_request']);
    assert.strictEqual(done.body.error, 'Run 2: This benchmark run has an unknown graphics preset.');
    assert.strictEqual(h.benchRows.length, 0, 'the valid first run is not stored either');
    const job = h.jobs[0];
    assert.deepStrictEqual([job.status, job.error, job.finished_at], ['failed', 'Run 2: This benchmark run has an unknown graphics preset.', h.now()]);
    assert.strictEqual(JSON.parse(job.result).log, 'the log');
    // the app's own fail call afterwards is the same success; a done after the failure is refused
    assert.deepStrictEqual((await h.call('POST /api/team/jobs/:id/fail', { params: { id }, body: { error: 'x' } })).body, { success: true, data: { id, status: 'failed' } });
    assert.strictEqual(h.jobs[0].error, 'Run 2: This benchmark run has an unknown graphics preset.');
    assert.strictEqual((await h.call('POST /api/team/jobs/:id/done', { params: { id }, body: { runs: [benchRun()] } })).statusCode, 409);
  });
});

test('a bench job done needs 1 to 6 readable runs of at most 64 KB each; a one-run job names no run number', async () => {
  const cases = [
    ['no runs', {}, 'A finished benchmark job must carry its runs.'],
    ['an empty list', { runs: [] }, 'A finished benchmark job must carry its runs.'],
    ['runs that are no list', { runs: 'many' }, 'A finished benchmark job must carry its runs.'],
    ['the pictures of a shots job', { files: ['low_hero.png'] }, 'A finished benchmark job must carry its runs.'],
    ['seven runs', { runs: Array.from({ length: 7 }, (_, i) => benchRun({ clientRunId: `run-number-000${i}` })) }, 'A benchmark job takes at most 6 runs.'],
    ['a run that is no object', { runs: [7] }, 'This benchmark run is not readable or is too large.'],
    ['a run over 64 KB', { runs: [benchRun({ extra: 'x'.repeat(65 * 1024) })] }, 'This benchmark run is not readable or is too large.'],
    ['a run without a frame rate', { runs: [benchRun({ metrics: {} })] }, 'This benchmark run has no frame rate result.'],
    ['a run with no id', { runs: [benchRun({ clientRunId: 'x' })] }, 'This benchmark run has no valid id.'],
  ];
  for (const [what, body, reason] of cases) {
    await withHarness(async (h) => {
      const id = await h.runningJob({ over: newBench() });
      const r = await h.call('POST /api/team/jobs/:id/done', { params: { id }, body });
      assert.deepStrictEqual([r.statusCode, r.body.code, r.body.error], [400, 'bad_request', reason], what);
      assert.deepStrictEqual([h.jobs[0].status, h.jobs[0].error, h.benchRows.length], ['failed', reason, 0], what);
    });
  }
  await withHarness(async (h) => {   // six runs and a run of 60 KB are fine
    const id = await h.runningJob({ over: newBench() });
    const runs = Array.from({ length: 6 }, (_, i) => benchRun({ clientRunId: `run-number-000${i}`, report: 'r'.repeat(20000) }));
    const r = await h.call('POST /api/team/jobs/:id/done', { params: { id }, body: { runs } });
    assert.strictEqual(r.statusCode, 200, JSON.stringify(r.body));
    assert.strictEqual(h.benchRows.length, 6);
  });
});

test('a bench run at the account\'s daily benchmark cap fails the job in the cap\'s own words', async () => {
  await withHarness(async (h) => {
    h.benchPadding.set(MUFFINS, 60);
    const id = await h.runningJob({ over: newBench() });
    const r = await h.call('POST /api/team/jobs/:id/done', { params: { id }, body: { runs: [benchRun()] } });
    assert.deepStrictEqual([r.statusCode, r.body.code, r.body.error], [429, 'rate_limited', 'That is plenty of benchmark runs for one day. Please try again tomorrow.']);
    assert.deepStrictEqual([h.jobs[0].status, h.benchRows.length], ['failed', 0]);
  });
});

test('a shots job done is unchanged by the bench kind: pictures, never runs', async () => {
  await withHarness(async (h) => {
    const id = await h.runningJob();
    const r = await h.call('POST /api/team/jobs/:id/done', { params: { id }, body: { runs: [benchRun()], files: [] } });
    assert.strictEqual(r.statusCode, 200);
    assert.deepStrictEqual([h.benchRows.length, JSON.parse(h.jobs[0].result).files, 'runs' in JSON.parse(h.jobs[0].result)], [0, [], false], 'a shots job stores no benchmark run');
  });
});

test('a bench job is for its own PC end to end: only that PC finishes it, a quiet PC gives it back to the same target', async () => {
  await withHarness(async (h) => {
    const id = await h.runningJob({ accountId: HELIX, over: newBench({ targetPc: PC_B }) });
    const other = await h.call('POST /api/team/jobs/:id/done', { params: { id }, body: { runs: [benchRun()] } });   // the Muffins PC
    assert.deepStrictEqual([other.statusCode, other.body.code], [403, 'not_your_job']);
    assert.strictEqual(h.benchRows.length, 0);
    h.advance(4 * MIN);   // the PC went quiet: the job is queued again, still for its PC
    await h.call('POST /api/team/heartbeat', { body: beat() });
    assert.deepStrictEqual([h.jobs[0].status, h.jobs[0].target_pc, h.jobs[0].tries], ['queued', PC_B, 1]);
    assert.strictEqual((await h.call('POST /api/team/heartbeat', { body: beat() })).body.data.offer, null, 'the Muffins PC is not offered it');
  });
});

test('the runner may ask for the PCs seen in the last N days', async () => {
  await withHarness(async (h) => {
    await h.call('POST /api/team/heartbeat', { body: beat() });
    h.advance(5 * 86400_000);
    await h.call('POST /api/team/heartbeat', { body: beat({ pcId: PC_B, name: 'Helix PC' }), accountId: HELIX });
    h.advance(10 * 86400_000);   // the Muffins PC was last seen 15 days ago, the Helix PC 10 days ago, nothing in the last 2 minutes
    assert.deepStrictEqual((await h.internal('GET /internal/team/pcs')).body.data.pcs, [], 'without days: the last 2 minutes, as before');
    assert.deepStrictEqual((await h.internal('GET /internal/team/pcs', { query: { days: '14' } })).body.data.pcs.map((p) => p.pcId), [PC_B]);
    assert.deepStrictEqual((await h.internal('GET /internal/team/pcs', { query: { days: '30' } })).body.data.pcs.map((p) => p.pcId), [PC_B, PC_A], 'newest first');
    assert.deepStrictEqual((await h.internal('GET /internal/team/pcs', { query: { days: '1' } })).body.data.pcs, []);
    for (const days of ['0', '-1', '1.5', 'x', '', '366', '9999', ['1', '2'], '1e2']) {
      const r = await h.internal('GET /internal/team/pcs', { query: { days } });
      assert.deepStrictEqual([r.statusCode, r.body.code], [400, 'bad_request'], JSON.stringify(days));
      assert.match(r.body.error, /1 to 365/);
    }
    assert.strictEqual((await h.internal('GET /internal/team/pcs', { query: { days: '14' }, secret: 'wrong-secret-0123456789-abcdefghij' })).statusCode, 404, 'the secret still guards it');
  });
});

// ── Cancel reaches the PC by its heartbeat, result folders are pruned ─────────────────────────────────────────────────────

test('the heartbeat names the jobs this PC claimed that were cancelled in the last 10 minutes, so a cancel reaches a running PC within a heartbeat', async () => {
  await withHarness(async (h) => {
    const none = await h.call('POST /api/team/heartbeat', { body: beat() });
    assert.deepStrictEqual(none.body.data.cancel, [], 'nothing cancelled: an empty list, always present');
    const running = await h.runningJob({ over: { title: 'running one' } });
    const second = await h.runningJob({ accountId: HELIX, over: { title: 'the helix PC\'s' } });
    const queued = await h.makeJob({ title: 'cancelled before anyone took it' });
    assert.deepStrictEqual((await h.call('POST /api/team/heartbeat', { body: beat() })).body.data.cancel, [], 'a job that runs is not cancelled');
    for (const id of [running, second, queued]) assert.strictEqual((await h.internal('POST /internal/team/jobs/:id/cancel', { params: { id } })).statusCode, 200);
    h.advance(20_000);
    const mine = await h.call('POST /api/team/heartbeat', { body: beat() });
    assert.deepStrictEqual(mine.body.data.cancel, [running], 'its own cancelled job only (not another PC\'s, not one that was never claimed)');
    assert.deepStrictEqual(Object.keys(mine.body.data).sort(), ['cancel', 'offer', 'serverTime']);
    assert.deepStrictEqual((await h.call('POST /api/team/heartbeat', { body: beat({ pcId: PC_B }), accountId: HELIX })).body.data.cancel, [second]);
    assert.deepStrictEqual((await h.call('POST /api/team/heartbeat', { body: beat({ pcId: PC_W }), accountId: WAR })).body.data.cancel, [], 'a PC that ran nothing hears nothing');
    assert.deepStrictEqual((await h.call('POST /api/team/heartbeat', { body: beat({ pcId: PC_A2 }), pcId: PC_A2 })).body.data.cancel, [], 'nor another PC of the same account');
    // still named at the next heartbeat (the app may have missed one), gone after 10 minutes
    h.advance(5 * MIN);
    assert.deepStrictEqual((await h.call('POST /api/team/heartbeat', { body: beat() })).body.data.cancel, [running]);
    h.advance(5 * MIN + 1000);
    assert.deepStrictEqual((await h.call('POST /api/team/heartbeat', { body: beat() })).body.data.cancel, []);
    assert.strictEqual(h.jobs.find((j) => j.id === running).status, 'cancelled');
  });
});

test('several cancelled jobs are named newest first (at most 20); a finished job and one that was requeued are never named', async () => {
  await withHarness(async (h) => {
    const ids = [];
    for (let i = 0; i < 22; i++) {
      ids.push(await h.runningJob({ over: { title: `job ${i}` } }));
      h.advance(1000);
      await h.internal('POST /internal/team/jobs/:id/cancel', { params: { id: ids[i] } });
      h.advance(1000);
    }
    const done = await h.runningJob();
    await h.call('POST /api/team/jobs/:id/done', { params: { id: done }, body: { files: [] } });
    const r = await h.call('POST /api/team/heartbeat', { body: beat() });
    assert.deepStrictEqual(r.body.data.cancel, ids.slice().reverse().slice(0, 20));
    assert.ok(!r.body.data.cancel.includes(done));
  });
  await withHarness(async (h) => {   // a job whose PC went quiet and was queued again, then cancelled: its claim is gone, so no PC is told
    const id = await h.runningJob();
    h.advance(4 * MIN);
    await h.call('POST /api/team/heartbeat', { body: beat({ pcId: PC_B }), accountId: HELIX });   // sweeps
    assert.strictEqual(h.jobs[0].status, 'queued');
    await h.internal('POST /internal/team/jobs/:id/cancel', { params: { id } });
    assert.deepStrictEqual((await h.call('POST /api/team/heartbeat', { body: beat() })).body.data.cancel, []);
  });
});

test('a cancelled job told to its PC by the heartbeat: its next upload, done and fail are still refused, so nothing it makes is kept', async () => {
  await withHarness(async (h) => {
    const id = await h.runningJob();
    await h.internal('POST /internal/team/jobs/:id/cancel', { params: { id } });
    const hb = await h.call('POST /api/team/heartbeat', { body: beat() });
    assert.deepStrictEqual(hb.body.data.cancel, [id]);
    assert.strictEqual((await h.call('POST /api/team/jobs/:id/done', { params: { id }, body: { files: [] } })).statusCode, 409);
    assert.strictEqual(h.jobs[0].status, 'cancelled');
  });
});

/** A result folder for job `id` holding one file. */
const resultFolder = (h, id, name = 'low_hero.png') => {
  const dir = path.join(h.resultsDir, id);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, name), 'x');
  return dir;
};

test('creating a job removes the result folders of jobs that finished more than 14 days ago, and only those', async () => {
  await withHarness(async (h) => {
    const mk = async (title, finishDaysAgo) => {   // a finished job with a result folder
      const id = await h.runningJob({ over: { title } });
      const job = h.jobs.find((j) => j.id === id);
      Object.assign(job, { status: 'done', finished_at: h.now() - finishDaysAgo * 86400_000, claimed_pc: PC_A });
      return { id, dir: resultFolder(h, id) };
    };
    const old = await mk('old', 15);
    const oldFailed = await mk('old failed', 30);
    oldFailed.job = h.jobs.find((j) => j.id === oldFailed.id);
    oldFailed.job.status = 'failed';
    const edge = await mk('13 days', 13);
    const fresh = await mk('fresh', 0);
    const runningId = await h.runningJob({ over: { title: 'still running' } });
    const running = resultFolder(h, runningId);
    h.jobs.find((j) => j.id === runningId).claimed_at = h.now() - 40 * 86400_000;   // old, but not finished
    const queuedId = await h.makeJob({ title: 'queued' });
    const queued = resultFolder(h, queuedId);
    const orphan = resultFolder(h, 'f'.repeat(12));   // no row: not this clean-up's to judge
    const notAnId = ['notes', 'ABCDEF123456', 'a'.repeat(13), 'a'.repeat(11), 'abcdefabcdez'].map((n) => resultFolder(h, n));
    const created = await h.internal('POST /internal/team/jobs', { body: newJob({ title: 'the create that cleans' }) });
    assert.strictEqual(created.statusCode, 200);
    assert.deepStrictEqual([old, oldFailed].map((f) => fs.existsSync(f.dir)), [false, false], 'finished more than 14 days ago: gone, whether done or failed');
    assert.deepStrictEqual([edge, fresh].map((f) => fs.existsSync(f.dir)), [true, true], '13 days and fresh: kept');
    assert.deepStrictEqual([running, queued, orphan, ...notAnId].map((d) => fs.existsSync(d)), Array(3 + notAnId.length).fill(true), 'running, queued, no row and not-a-job-id names: kept');
    assert.ok(h.jobs.some((j) => j.id === old.id), 'the job rows are kept');
    const row = (await h.internal('GET /internal/team/jobs/:id', { params: { id: old.id } })).body.data;
    assert.deepStrictEqual([row.status, row.files], ['done', []], 'a pruned job reads back with no files');
    // one day later the 13-day-old job has passed 14 days
    h.advance(2 * 86400_000);
    await h.makeJob({ title: 'another' });
    assert.deepStrictEqual([edge, fresh].map((f) => fs.existsSync(f.dir)), [false, true]);
  });
});

test('the clean-up never follows a symlink and never touches a file or a path outside the results folder', async () => {
  await withHarness(async (h) => {
    const id = await h.runningJob();
    Object.assign(h.jobs[0], { status: 'done', finished_at: h.now() - 20 * 86400_000 });
    const second = await h.runningJob({ over: { title: 'second' } });
    Object.assign(h.jobs[1], { status: 'done', finished_at: h.now() - 20 * 86400_000 });
    const outside = fs.mkdtempSync(path.join(path.dirname(h.resultsDir), 'victim-'));
    fs.writeFileSync(path.join(outside, 'precious.txt'), 'do not delete');
    fs.mkdirSync(h.resultsDir, { recursive: true });
    fs.symlinkSync(outside, path.join(h.resultsDir, id));                      // a symlink named like a finished job
    fs.writeFileSync(path.join(h.resultsDir, second), 'a file, not a folder'); // a file named like a finished job
    const inner = resultFolder(h, 'e'.repeat(12));
    h.jobs.push({ ...h.jobs[0], id: 'e'.repeat(12), status: 'failed' });       // an old finished job whose folder holds a symlink to the outside
    fs.symlinkSync(outside, path.join(inner, 'link'));
    assert.strictEqual((await h.internal('POST /internal/team/jobs', { body: newJob() })).statusCode, 200);
    assert.ok(fs.readFileSync(path.join(outside, 'precious.txt'), 'utf8') === 'do not delete', 'nothing outside was reached');
    assert.ok(fs.lstatSync(path.join(h.resultsDir, id)).isSymbolicLink(), 'the symlink is left as it is');
    assert.ok(fs.statSync(path.join(h.resultsDir, second)).isFile());
    assert.ok(!fs.existsSync(inner), 'the real folder went, with the link inside it (the link, not what it points at)');
    assert.ok(fs.existsSync(path.join(outside, 'precious.txt')));
    fs.rmSync(outside, { recursive: true, force: true });
  });
});

test('a clean-up that fails (no results folder, an unreadable one, a database error) never stops the job from being made', async () => {
  await withHarness(async (h) => {
    assert.ok(!fs.existsSync(h.resultsDir));
    assert.strictEqual((await h.internal('POST /internal/team/jobs', { body: newJob() })).statusCode, 200, 'no results folder yet');
    fs.mkdirSync(h.resultsDir, { recursive: true });
    fs.chmodSync(h.resultsDir, 0o000);
    try {
      assert.strictEqual((await h.internal('POST /internal/team/jobs', { body: newJob({ title: 'second' }) })).statusCode, 200, 'a folder that cannot be read');
    } finally {
      fs.chmodSync(h.resultsDir, 0o750);
    }
  });
  await withHarness({ missingTable: true }, async (h) => {
    fs.mkdirSync(path.join(h.resultsDir, 'a'.repeat(12)), { recursive: true });
    const r = await h.internal('POST /internal/team/jobs', { body: newJob() });
    assert.deepStrictEqual([r.statusCode, r.body.code], [503, 'unavailable'], 'the missing table is still the readable 503 the create always gave');
    assert.ok(fs.existsSync(path.join(h.resultsDir, 'a'.repeat(12))));
  });
});

test('a refused create, and every other route, leave the result folders alone', async () => {
  await withHarness(async (h) => {
    const id = await h.runningJob();
    Object.assign(h.jobs[0], { status: 'done', finished_at: h.now() - 20 * 86400_000 });
    const dir = resultFolder(h, id);
    assert.strictEqual((await h.internal('POST /internal/team/jobs', { body: {} })).statusCode, 400);
    await h.call('POST /api/team/heartbeat', { body: beat() });
    await h.internal('GET /internal/team/jobs/:id', { params: { id } });
    await h.internal('GET /internal/team/pcs');
    assert.ok(fs.existsSync(dir), 'only a valid create cleans up');
  });
});

// ── Offer priority, the 1 MB done body, supersede ──────────────────────────────────────────────────────────────────────────

test('the heartbeat offers shots before bench before any other kind, then the oldest: a waiting bench never hides a newer shots job', async () => {
  await withHarness(async (h) => {
    const bench1 = await h.makeJob({ kind: 'bench', title: 'old bench', payload: BENCH, targetPc: PC_A });
    const odd = await h.makeJob({ kind: 'stutter', title: 'a kind nobody knows yet' });
    const bench2 = await h.makeJob({ kind: 'bench', title: 'newer bench', payload: BENCH });
    const otherPcs = await h.makeJob({ kind: 'bench', title: 'bench for the helix PC', payload: BENCH, targetPc: PC_B });
    const offered = async (over = {}) => (await h.call('POST /api/team/heartbeat', { body: beat(), ...over })).body.data.offer;
    assert.strictEqual((await offered()).id, bench1, 'only benches and an odd kind wait: the bench comes first, the oldest');
    const shots1 = await h.makeJob({ title: 'newer shots' });
    const o = await offered();
    assert.deepStrictEqual([o.id, o.kind], [shots1, 'shots'], 'a shots job that came after the bench is offered first');
    const shots0 = await h.makeJob({ title: 'newest shots' });
    assert.strictEqual((await offered()).id, shots1, 'between two shots jobs, the oldest');
    // the same order for another PC, which has no bench of its own among the first
    assert.strictEqual((await offered({ accountId: WAR, pcId: PC_W, body: beat({ pcId: PC_W }) })).id, shots1);
    await h.call('POST /api/team/jobs/:id/claim', { params: { id: shots1 }, body: { pcId: PC_A } });
    assert.strictEqual((await offered({ accountId: HELIX, pcId: PC_B, body: beat({ pcId: PC_B }) })).id, shots0, 'a claimed job is not offered again');
    await h.call('POST /api/team/jobs/:id/decline', { params: { id: shots0 }, body: { pcId: PC_A, reason: 'busy' } });
    assert.strictEqual((await offered()).id, bench1, 'shots declined by this PC: the next kind');
    await h.call('POST /api/team/jobs/:id/claim', { params: { id: bench1 }, body: { pcId: PC_A } });
    assert.strictEqual((await offered()).id, bench2, 'then the untargeted bench, never the helix PC\'s');
    await h.call('POST /api/team/jobs/:id/claim', { params: { id: bench2 }, body: { pcId: PC_A } });
    assert.strictEqual((await offered()).id, odd, 'an unknown kind comes after both');
    assert.ok(![bench1, bench2, shots1, odd].includes(otherPcs));
    assert.strictEqual((await offered({ accountId: HELIX, pcId: PC_B, body: beat({ pcId: PC_B }) })).id, shots0, 'the helix PC is still offered the shots job it has not declined');
  });
  await withHarness(async (h) => {   // within a kind and across kinds the rank is part of the query, so it holds past the 50 listed
    for (let i = 0; i < 48; i++) await h.makeJob({ kind: 'bench', title: `bench ${i}`, payload: BENCH, targetPc: PC_B });
    await h.makeJob({ kind: 'bench', title: 'a bench for this PC', payload: BENCH, targetPc: PC_A });
    const shots = await h.makeJob({ title: 'shots, the newest of all' });
    assert.strictEqual((await h.call('POST /api/team/heartbeat', { body: beat() })).body.data.offer.id, shots);
  });
});

test('the ordering is the one SQL statement: a shots, clip, release, bench, other rank built from the kinds, and the oldest within each', async () => {
  await withHarness(async (h) => {
    await h.call('POST /api/team/heartbeat', { body: beat() });
    const q = h.sqlLog.find((sql) => sql.startsWith('SELECT id, kind, title, weight_s, result'));
    assert.ok(q.includes("ORDER BY CASE kind WHEN 'shots' THEN 0 WHEN 'clip' THEN 1 WHEN 'release' THEN 2 WHEN 'bench' THEN 3 ELSE 4 END ASC, created_at ASC, id ASC LIMIT 50"), q);
    assert.deepStrictEqual(mountTeamJobs.KIND_ORDER, ['shots', 'clip', 'release', 'bench']);
  });
});

/** A bench `done` body as a stream of chunks, the way the app's request arrives. */
const bodyOf = (obj) => Buffer.from(JSON.stringify(obj));
const streamed = (buf, { length = true, size = 64 * 1024 } = {}) => ({
  chunks: Array.from({ length: Math.ceil(buf.length / size) }, (_, i) => buf.subarray(i * size, (i + 1) * size)),
  headers: { 'content-type': 'application/json', ...(length ? { 'content-length': String(buf.length) } : {}) },
});

test('a bench done may carry 6 runs of 64 KB and a 64 KB log, far over the 512 KB the other routes take: the route reads its own body, up to 1 MB', async () => {
  await withHarness(async (h) => {
    const id = await h.runningJob({ over: newBench() });
    const runs = Array.from({ length: 6 }, (_, i) => benchRun({ clientRunId: `big-run-number-${i}`, extra: 'x'.repeat(60 * 1024) }));
    const buf = bodyOf({ files: [], runs, log: '\u0001'.repeat(100000), timings: { downloadS: 1, runS: 2 } });   // every control character is 6 bytes of JSON
    assert.ok(buf.length > 900 * 1024 && buf.length < DONE_BODY_MAX, `${buf.length} bytes`);
    const r = await h.call('POST /api/team/jobs/:id/done', { params: { id }, ...streamed(buf) });
    assert.deepStrictEqual([r.statusCode, r.body], [200, { success: true, data: { id, status: 'done' } }], JSON.stringify(r.body));
    assert.strictEqual(h.benchRows.length, 6);
    assert.ok(Buffer.byteLength(JSON.parse(h.jobs[0].result).log) <= 65536, 'the stored log is still capped');
    // the same without a Content-Length (chunked), and a shots done through the same reader
    const id2 = await h.runningJob({ over: newBench({ title: 'again' }) });
    const r2 = await h.call('POST /api/team/jobs/:id/done', { params: { id: id2 }, ...streamed(bodyOf({ runs: [benchRun({ clientRunId: 'chunked-run-0001' })] }), { length: false, size: 100 }) });
    assert.strictEqual(r2.statusCode, 200, JSON.stringify(r2.body));
    const id3 = await h.runningJob({ over: { title: 'shots' } });
    await h.upload(id3, 'low_hero.png', png(1600, 900, 50));
    const r3 = await h.call('POST /api/team/jobs/:id/done', { params: { id: id3 }, ...streamed(bodyOf({ files: ['low_hero.png'], log: 'ok' })) });
    assert.strictEqual(r3.statusCode, 200, JSON.stringify(r3.body));
    assert.deepStrictEqual(JSON.parse(h.jobs[2].result).files.map((f) => f.name), ['low_hero.png']);
  });
});

test('a done body over 1 MB is a readable 413 (refused before it is read when it says so), the job stays running and nothing is stored', async () => {
  await withHarness(async (h) => {
    const id = await h.runningJob({ over: newBench() });
    const filler = Buffer.alloc(DONE_BODY_MAX + 1, 0x20);   // 1 MB and a byte of valid JSON
    const text = (r) => [r.statusCode, r.body.success, r.body.code, r.body.error];
    // it says how big it is: refused at once, whatever follows (the request is answered with the connection closing)
    const big = await h.call('POST /api/team/jobs/:id/done', { params: { id }, ...streamed(filler) });
    assert.deepStrictEqual(text(big), [413, false, 'too_large', 'That result is too large (the limit is 1 MB).']);
    assert.strictEqual(big.headers.Connection, 'close');
    const chunked = await h.call('POST /api/team/jobs/:id/done', { params: { id }, ...streamed(filler, { length: false }) });
    assert.deepStrictEqual(text(chunked), [413, false, 'too_large', 'That result is too large (the limit is 1 MB).'], 'no Content-Length: it stops at the cap');
    const exactly = Buffer.concat([bodyOf({ runs: [benchRun()] }), Buffer.alloc(DONE_BODY_MAX - bodyOf({ runs: [benchRun()] }).length, 0x20)]);
    assert.strictEqual(exactly.length, DONE_BODY_MAX);
    assert.strictEqual((await h.call('POST /api/team/jobs/:id/done', { params: { id }, ...streamed(exactly) })).statusCode, 200, 'exactly 1 MB is fine');
  });
  await withHarness(async (h) => {
    const id = await h.runningJob({ over: newBench() });
    assert.strictEqual((await h.call('POST /api/team/jobs/:id/done', { params: { id }, ...streamed(Buffer.alloc(DONE_BODY_MAX + 5000, 0x20)) })).statusCode, 413);
    assert.deepStrictEqual([h.jobs[0].status, h.benchRows.length], ['running', 0], 'the job is left running for the app to fail or resend');
  });
});

test('a done that cannot be read is 400, one with no sign-in is refused before its body is read, and a body that was parsed already is used as it is', async () => {
  await withHarness(async (h) => {
    const id = await h.runningJob({ over: newBench() });
    const bad = await h.call('POST /api/team/jobs/:id/done', { params: { id }, ...streamed(Buffer.from('{"runs": [')) });
    assert.deepStrictEqual([bad.statusCode, bad.body.code, bad.body.error], [400, 'bad_request', 'That result could not be read.']);
    assert.strictEqual(h.jobs[0].status, 'running');
    const { Readable } = require('node:stream');
    let reads = 0;
    const lazy = Object.assign(new Readable({ read() { reads++; this.push(Buffer.from('{}')); this.push(null); } }), { headers: {}, params: { id }, query: {}, socket: { remoteAddress: '203.0.113.9' }, body: undefined });
    const run = async (r, route) => { const fns = h.routes[route]; const res = { statusCode: 200, body: null, headers: {}, set() {}, status(c) { this.statusCode = c; return this; }, json(b) { this.body = b; return this; } }; let i = 0; const next = async () => { const fn = fns[i++]; if (fn) await fn(r, res, next); }; await next(); return res; };
    const anon = await run(lazy, 'POST /api/team/jobs/:id/done');
    assert.deepStrictEqual([anon.statusCode, anon.body.code, reads], [401, 'signed_out', 0], 'no team token: refused, the body untouched');
    const parsed = await h.call('POST /api/team/jobs/:id/done', { params: { id }, body: { runs: [benchRun()] } });   // already parsed upstream (no stream)
    assert.strictEqual(parsed.statusCode, 200);
  });
});

test('server.js leaves the done route\'s body to the route (its own 1 MB reader) and keeps its 512 KB parser for every other route', () => {
  const { loadServer } = require('./server-harness.cjs');
  const srv = loadServer({ pool: { execute: async () => [[]], query: async () => [[]], getConnection: async () => ({}) } });
  const asked = (method, url) => { srv.jsonCalls.length = 0; srv.wrap({ method, url, path: url, originalUrl: url }); return srv.jsonCalls.map((c) => c.url); };
  const id = 'a1b2c3d4e5f6';
  for (const url of [`/api/team/jobs/${id}/done`, `/team/jobs/${id}/done`, `/api/team/jobs/${id}/done?x=1`]) assert.deepStrictEqual(asked('POST', url), [], `${url}: the global parser does not read it`);
  for (const [method, url] of [['POST', '/api/benchmarks'], ['POST', '/api/team/heartbeat'], ['POST', `/api/team/jobs/${id}/fail`], ['POST', `/api/team/jobs/${id}/claim`], ['POST', `/api/team/jobs/${id}/done/extra`], ['POST', '/api/team/jobs/not-a-job-id/done'], ['POST', '/internal/team/jobs']]) {
    assert.deepStrictEqual(asked(method, url), [url], `${method} ${url}: still read by the global parser`);
  }
  assert.strictEqual(srv.jsonCalls.length, 1);
  assert.strictEqual(srv.jsonCalls[0].limit, '512kb');
  assert.strictEqual(readsOwnBody({ method: 'POST', path: `/api/team/jobs/${id}/done` }), true);
  assert.strictEqual(readsOwnBody({ method: 'GET', url: `/api/team/jobs/${id}/done` }), false);
  assert.strictEqual(readsOwnBody({}), false);
  for (const url of [`/api/team/jobs/${id}/files/install.json`, `/team/jobs/${id}/files/low_bag.png`]) {
    assert.strictEqual(readsOwnBody({ method: 'PUT', path: url }), true, `${url}: an upload reads its own body (a .json result is application/json)`);
    assert.deepStrictEqual(asked('PUT', url), [], `PUT ${url}: the global parser does not read it`);
  }
  assert.strictEqual(readsOwnBody({ method: 'POST', path: `/api/team/jobs/${id}/files/install.json` }), false);
  assert.strictEqual(DONE_BODY_MAX, 1024 * 1024);
  assert.ok(srv.routes.has('POST /api/team/jobs/:id/done') && srv.routes.has('POST /team/jobs/:id/done'));
});

test('parseNewJob: supersede is true or false, and needs a target PC', () => {
  assert.strictEqual(parseNewJob(newJob()).job.supersede, false);
  assert.strictEqual(parseNewJob(newJob({ supersede: false })).job.supersede, false);
  assert.strictEqual(parseNewJob(newJob({ supersede: true, targetPc: PC_W })).job.supersede, true);
  for (const bad of [newJob({ supersede: true }), newJob({ supersede: 'yes', targetPc: PC_W }), newJob({ supersede: 1, targetPc: PC_W }), newJob({ supersede: null, targetPc: PC_W })]) {
    const r = parseNewJob(bad);
    assert.ok(r.error && !r.job, JSON.stringify(bad).slice(0, 60));
  }
});

test('a new job with supersede cancels the same kind\'s queued jobs for the same PC once it is stored, and nothing else', async () => {
  await withHarness(async (h) => {
    const mk = (over) => h.makeJob({ kind: 'bench', title: 'bench', payload: BENCH, ...over });
    const oldA = await mk({ targetPc: PC_W });
    const oldB = await mk({ targetPc: PC_W });
    const otherPc = await mk({ targetPc: PC_B });
    const anyPc = await mk({});
    const shotsForW = await h.makeJob({ title: 'shots', targetPc: PC_W });
    const running = await h.runningJob({ accountId: WAR, over: newBench({ targetPc: PC_W, title: 'running' }) });
    const requeued = await mk({ targetPc: PC_W });
    h.jobs.find((j) => j.id === requeued).tries = 1;
    const made = await h.internal('POST /internal/team/jobs', { body: newBench({ targetPc: PC_W, supersede: true }) });
    assert.strictEqual(made.statusCode, 200, JSON.stringify(made.body));
    const id = made.body.data.id;
    assert.deepStrictEqual(made.body.data, { id, superseded: 3 });
    const status = (jid) => h.jobs.find((j) => j.id === jid).status;
    assert.deepStrictEqual([oldA, oldB, requeued].map(status), ['cancelled', 'cancelled', 'cancelled'], 'the PC\'s queued benchmarks (a requeued one too)');
    assert.deepStrictEqual([otherPc, anyPc, shotsForW, running, id].map(status), ['queued', 'queued', 'queued', 'running', 'queued'], 'another PC\'s, an untargeted one, another kind, a running one and the new job itself are left');
    assert.strictEqual(h.jobs.find((j) => j.id === oldA).finished_at, h.now());
    const offer = (await h.call('POST /api/team/heartbeat', { body: beat({ pcId: PC_W }), accountId: WAR })).body.data;
    assert.strictEqual(offer.offer.id, shotsForW, 'shots first, as ever');
    await h.call('POST /api/team/jobs/:id/claim', { accountId: WAR, pcId: PC_W, params: { id: shotsForW }, body: { pcId: PC_W } });
    h.jobs.find((j) => j.id === running).status = 'done';
    const next = async () => (await h.call('POST /api/team/heartbeat', { body: beat({ pcId: PC_W }), accountId: WAR })).body.data.offer.id;
    assert.strictEqual(await next(), anyPc, 'then the untargeted benchmark (older, not this PC\'s to replace), never the cancelled ones');
    await h.call('POST /api/team/jobs/:id/claim', { accountId: WAR, pcId: PC_W, params: { id: anyPc }, body: { pcId: PC_W } });
    assert.strictEqual(await next(), id, 'and the newest one of its own');
    assert.deepStrictEqual(offer.cancel, [], 'a superseded job was never claimed, so no PC is told to stop it');
    // without supersede nothing is cancelled and the answer is as before
    const plain = await h.internal('POST /internal/team/jobs', { body: newBench({ targetPc: PC_W }) });
    assert.deepStrictEqual(Object.keys(plain.body.data), ['id']);
    assert.strictEqual(status(id), 'queued');
    // supersede with nothing to replace
    assert.deepStrictEqual((await h.internal('POST /internal/team/jobs', { body: newBench({ targetPc: "pc-nobody-9999", supersede: true }) })).body.data.superseded, 0);
    // supersede without a target is refused and cancels nothing
    const refused = await h.internal('POST /internal/team/jobs', { body: newBench({ supersede: true }) });
    assert.deepStrictEqual([refused.statusCode, refused.body.code], [400, 'bad_request']);
    assert.strictEqual(status(otherPc), 'queued');
    assert.strictEqual(status(id), 'queued');
  });
});

test('a job that cannot be stored supersedes nothing', async () => {
  await withHarness(async (h) => {
    const old = await h.makeJob({ kind: 'bench', title: 'bench', payload: BENCH, targetPc: PC_W });
    const refused = await h.internal('POST /internal/team/jobs', { body: newBench({ targetPc: PC_W, supersede: true, title: '' }) });
    assert.strictEqual(refused.statusCode, 400);
    assert.strictEqual(h.jobs.find((j) => j.id === old).status, 'queued');
    for (let i = 0; i < OPEN_JOBS_MAX - 1; i++) await h.makeJob({ title: `fill ${i}` });
    const full = await h.internal('POST /internal/team/jobs', { body: newBench({ targetPc: PC_W, supersede: true }) });
    assert.deepStrictEqual([full.statusCode, full.body.code], [429, 'too_many_jobs']);
    assert.strictEqual(h.jobs.find((j) => j.id === old).status, 'queued', 'the open-jobs limit refuses before anything is cancelled');
  });
});

// ── server.js wiring ─────────────────────────────────────────────────────────────────────────────────────────────────────

test('server.js mounts the team routes: the login on the game\'s password check, every other route on the team token alone', async () => {
  const { loadServer } = require('./server-harness.cjs');
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'team-jobs-wiring-'));
  try {
    const h = harness({ resultsDir: path.join(root, 'results') });
    const compares = [];
    const bcrypt = { hash: async () => 'hash', compare: async (password, hash) => { compares.push([password, hash]); return hash === `hash:${password}`; } };
    const srv = loadServer({ pool: h.pool, bcrypt });
    for (const route of ['POST /api/team/login', 'POST /team/login', 'POST /api/team/logout', 'GET /api/team/me', 'GET /team/me', 'POST /api/team/heartbeat', 'PUT /api/team/jobs/:id/files/:name', 'POST /internal/team/jobs', 'GET /internal/team/pcs']) {
      assert.ok(srv.routes.has(route), route);
    }
    h.accounts.get(MUFFINS).active_session = 'the-games-own-session';
    const bad = await srv.call('POST /api/team/login', { body: { username: 'Brbmuffins', password: 'not-it', pcId: PC_A, pcName: 'PC' } });
    assert.deepStrictEqual([bad.status, bad.json.code], [401, 'bad_login']);
    const outsider = await srv.call('POST /api/team/login', { body: { username: 'Stranger', password: 'pw-Stranger', pcId: PC_A } });
    assert.deepStrictEqual([outsider.status, outsider.json.code], [403, 'not_team']);
    const login = await srv.call('POST /api/team/login', { body: { username: 'Brbmuffins', password: 'pw-Brbmuffins', pcId: PC_A, pcName: 'PC' } });
    assert.strictEqual(login.status, 200, JSON.stringify(login.json));
    assert.deepStrictEqual(compares.at(-1), ['pw-Brbmuffins', 'hash:pw-Brbmuffins'], 'the password is checked with bcrypt.compare(password, hash), as /login does');
    const token = login.json.data.token;
    assert.ok(!h.sqlLog.some((q) => /active_session|UPDATE accounts/i.test(q)));
    assert.strictEqual(h.accounts.get(MUFFINS).active_session, 'the-games-own-session', 'the game session is not claimed');
    const me = await srv.call('GET /api/team/me', { headers: { authorization: `Team ${token}` } });
    assert.deepStrictEqual([me.status, me.json], [200, { success: true, data: { accountId: MUFFINS, username: 'Brbmuffins' } }]);
    const hb = await srv.call('POST /api/team/heartbeat', { headers: { authorization: `Team ${token}` }, body: beat() });
    assert.strictEqual(hb.status, 200, JSON.stringify(hb.json));
    // the game's own token (the harness's default Bearer) is not a team sign-in
    const game = await srv.call('GET /api/team/me', { user: { accountId: MUFFINS, username: 'Brbmuffins', sid: 'the-games-own-session' } });
    assert.deepStrictEqual([game.status, game.json], [401, SIGNED_OUT]);
    assert.strictEqual((await srv.call('POST /api/team/logout', { headers: { authorization: `Team ${token}` } })).status, 200);
    assert.strictEqual((await srv.call('GET /api/team/me', { headers: { authorization: `Team ${token}` } })).status, 401);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

// ── The release job: step results, how each step went, and the reporter's routes ────────────────────────────────────────────

const RELEASE = {
  version: '20261019.120000-abc1234', rev: 'abc123456789', godotVersion: '4.7.2.stable',
  builds: [{ label: 'release', files: BENCH.files }, { label: 'debug', files: SHOTS.files }], steps: ['install', 'quit-loading', 'screens', 'stutter', 'bench', 'soak'],
  setups: BENCH.setups, screens: { plan: { shots: [] }, resolutions: ['1920x1080'] }, soak: { minutes: 30 }, args: [],
};
const newRelease = (over = {}) => ({ kind: 'release', title: 'Release checks of 20261019.120000-abc1234, about 40 minutes', weightS: 2400, payload: RELEASE, ttlS: 3 * 86400, ...over });
const stepJson = (obj = { ok: true }) => Buffer.from(JSON.stringify(obj));
const doneRelease = (h, id, steps, extra = {}, callOpts = {}) => h.call('POST /api/team/jobs/:id/done', { params: { id }, body: { steps, files: [], log: 'the app log', timings: { downloadS: 30, runS: 2300 }, ...extra }, ...callOpts });
const uploadJson = (h, id, name, buf, opts = {}) => h.upload(id, name, buf, { type: 'application/json', ...opts });

test('checkJson takes any valid JSON and refuses the rest, and cleanSteps keeps what the report shows', () => {
  const { checkJson, cleanSteps, STEP_NAMES } = mountTeamJobs;
  for (const ok of ['{}', '[]', '{"a":[1,2,{"b":null}]}', '123', '"text"', 'null', 'true', '  {"x": 1}\n', '{"unicode":"é\\u00e9"}']) assert.deepStrictEqual(checkJson(Buffer.from(ok)), {}, ok);
  for (const bad of ['', '{', '{"a":}', 'not json', "{'a':1}", '{"a":1}{"b":2}', '\u0000{}', '{"a":1,}', '[1,2']) assert.ok(checkJson(Buffer.from(bad)).error, JSON.stringify(bad));
  assert.ok(checkJson(Buffer.alloc(0)).error && checkJson('{}').error && checkJson(null).error);
  assert.deepStrictEqual(STEP_NAMES, ['install', 'quit-loading', 'screens', 'stutter', 'bench', 'soak']);
  const c = cleanSteps([{ step: 'install', ok: true, ms: 812.6, extra: 'dropped' }, { step: 'quit-loading', ok: false, error: `  ${'e'.repeat(500)}\n`, ms: -5 }, { step: 'soak', ok: true, ms: 1e12, error: '   ' }, { step: 'bench', ok: true, ms: 'slow' }]);
  assert.deepStrictEqual(c.steps, [{ step: 'install', ok: true, ms: 813 }, { step: 'quit-loading', ok: false, error: 'e'.repeat(400), ms: 0 }, { step: 'soak', ok: true, ms: 86_400_000 }, { step: 'bench', ok: true }]);
  for (const bad of [undefined, null, 'install', {}, [], new Array(7).fill({ step: 'install', ok: true }), [{ step: 'install' }], [{ step: 'install', ok: 'yes' }], [{ step: 'install', ok: 1 }], [{ step: 'launch', ok: true }], [{ step: 7, ok: true }], ['install'], [null],
    [{ step: 'install', ok: true }, { step: 'install', ok: false }]]) assert.ok(cleanSteps(bad).error && cleanSteps(bad).error.length > 10, JSON.stringify(bad));
});

test('a release job is offered after shots and clip, before bench and any other kind', async () => {
  await withHarness(async (h) => {
    const bench = await h.makeJob({ kind: 'bench', title: 'a bench', payload: BENCH });
    const odd = await h.makeJob({ kind: 'stutter', title: 'a kind nobody knows' });
    const release = await h.makeJob(newRelease());
    const offered = async () => (await h.call('POST /api/team/heartbeat', { body: beat() })).body.data.offer;
    assert.deepStrictEqual([(await offered()).id, (await offered()).kind], [release, 'release'], 'a release job goes ahead of the older bench and the odd kind');
    const clip = await h.makeJob(newClip());
    assert.strictEqual((await offered()).id, clip, 'a clip job goes ahead of it');
    const shots = await h.makeJob({ title: 'shots, the newest of all' });
    assert.strictEqual((await offered()).id, shots, 'and shots go first');
    for (const id of [shots, clip]) await h.call('POST /api/team/jobs/:id/claim', { params: { id }, body: { pcId: PC_A } });
    assert.strictEqual((await offered()).id, release);
    await h.call('POST /api/team/jobs/:id/claim', { params: { id: release }, body: { pcId: PC_A } });
    assert.strictEqual((await offered()).id, bench);
    await h.call('POST /api/team/jobs/:id/claim', { params: { id: bench }, body: { pcId: PC_A } });
    assert.strictEqual((await offered()).id, odd);
    const c = await h.call('POST /api/team/jobs/:id/claim', { params: { id: release }, body: { pcId: PC_A } });
    assert.deepStrictEqual(c.body.data.payload, RELEASE, 'the claim hands the release payload as it was made');
  });
});

test('a step result (.json) is stored as it came for a release job and answers its size; the screens\' pictures go beside it', async () => {
  await withHarness(async (h) => {
    const id = await h.runningJob({ over: newRelease() });
    const body = stepJson({ ok: true, ms: 812, note: 'é' });
    const r = await uploadJson(h, id, 'install.json', body);
    assert.strictEqual(r.statusCode, 200, JSON.stringify(r.body));
    assert.deepStrictEqual([r.body.success, r.body.data.name, r.body.data.bytes, r.body.data.width, r.body.data.height], [true, 'install.json', body.length, undefined, undefined]);
    assert.ok(fs.readFileSync(path.join(h.jobFolder(id), 'install.json')).equals(body));
    assert.deepStrictEqual(fs.readdirSync(h.jobFolder(id)), ['install.json'], 'no half-written part is left');
    assert.strictEqual(fs.statSync(path.join(h.jobFolder(id), 'install.json')).mode & 0o007, 0, 'not readable by others');
    assert.strictEqual((await uploadJson(h, id, 'install.json', stepJson({ ok: false }))).statusCode, 200, 'the same name again replaces it');
    assert.strictEqual(JSON.parse(fs.readFileSync(path.join(h.jobFolder(id), 'install.json'), 'utf8')).ok, false);
    assert.strictEqual((await uploadJson(h, id, 'quit-loading.json', stepJson([1, 2, 3]), { type: 'application/json; charset=utf-8' })).statusCode, 200, 'the type may carry parameters; the result may be a list');
    const png400 = await h.upload(id, '1920x1080_s1-5_bag.png', png(1920, 1080, 500));
    assert.deepStrictEqual([png400.statusCode, png400.body.data.width, png400.body.data.height], [200, 1920, 1080], 'a release job takes pictures too');
    h.advance(MIN);
    await uploadJson(h, id, 'stutter.json', stepJson());
    assert.strictEqual(h.jobs[0].heartbeat_at, h.now(), 'an upload renews the heartbeat');
    assert.deepStrictEqual(fs.readdirSync(h.jobFolder(id)).sort(), ['1920x1080_s1-5_bag.png', 'install.json', 'quit-loading.json', 'stutter.json']);
    assert.strictEqual((await uploadJson(h, id, `a${'b'.repeat(59)}.json`, stepJson())).statusCode, 200, '60 characters before the extension is allowed');
  });
});

test('a step result with a bad name, type or size, or that is not JSON, is refused and writes nothing', async () => {
  await withHarness(async (h) => {
    const id = await h.runningJob({ over: newRelease() });
    const bad = ['Install.json', 'install.JSON', 'install.txt', 'install', '.json', '_install.json', '-x.json', 'a b.json', 'a/b.json', '../x.json', '..%2fx.json', 'a\\b.json', 'install.json.exe', 'a..json', `${'a'.repeat(61)}.json`, 'ü.json', '.hidden.json'];
    for (const name of bad) {
      const r = await uploadJson(h, id, name, stepJson());
      assert.deepStrictEqual([r.statusCode, r.body.code], [400, 'bad_request'], JSON.stringify(name));
    }
    for (const type of ['image/png', 'text/plain', 'application/octet-stream', 'video/x-motion-jpeg', '', undefined]) {
      const r = await uploadJson(h, id, 'a.json', stepJson(), { type, headers: type === undefined ? { 'content-type': undefined } : {} });
      assert.deepStrictEqual([r.statusCode, r.body.code], [415, 'bad_type'], String(type));
    }
    assert.strictEqual((await h.upload(id, 'a.png', png(), { type: 'application/json' })).statusCode, 415, 'a picture is still image/png');
    for (const [what, buf] of Object.entries({ 'empty': Buffer.alloc(0), 'text': Buffer.from('not json at all'), 'cut off': Buffer.from('{"a":[1,2'), 'two documents': Buffer.from('{}{}'), 'trailing comma': Buffer.from('{"a":1,}') })) {
      const r = await uploadJson(h, id, 'bad.json', buf);
      assert.deepStrictEqual([r.statusCode, r.body.code], [400, 'bad_request'], what);
      assert.ok(r.body.error.length > 10);
    }
    assert.deepStrictEqual(fs.existsSync(h.jobFolder(id)) ? fs.readdirSync(h.jobFolder(id)) : [], []);
    // declared too large: answered at once and the stream is never read; the limit itself passes
    const declared = await h.call('PUT /api/team/jobs/:id/files/:name', { params: { id, name: 'big.json' }, raw: stepJson(), headers: { 'content-type': 'application/json', 'content-length': String(JSON_LIMIT + 1) } });
    assert.deepStrictEqual([declared.statusCode, declared.body.code, declared.body.error, declared.headers.Connection], [413, 'too_large', 'That result is too large (the limit is 1 MB).', 'close']);
    const atLimit = Buffer.from(`{"pad":"${'x'.repeat(JSON_LIMIT - 10)}"}`);
    assert.strictEqual(atLimit.length, JSON_LIMIT);
    assert.strictEqual((await uploadJson(h, id, 'limit.json', atLimit)).statusCode, 200);
    let pulled = 0;
    const chunk = Buffer.alloc(64 * 1024, 120);
    function* flood() { yield Buffer.from('{"pad":"'); for (let i = 0; i < 400; i++) { pulled++; yield chunk; } }
    const chunked = await h.call('PUT /api/team/jobs/:id/files/:name', { params: { id, name: 'flood.json' }, chunks: flood(), headers: { 'content-type': 'application/json' } });
    assert.deepStrictEqual([chunked.statusCode, chunked.body.code], [413, 'too_large']);
    assert.ok(pulled < 40, `stopped reading early (${pulled} of 400 chunks pulled)`);
    assert.deepStrictEqual(fs.readdirSync(h.jobFolder(id)), ['limit.json']);
  });
});
const JSON_LIMIT = 1024 * 1024;

test('a step result is only for a release job, only from the PC that holds it and only while it runs; clips stay for clip jobs', async () => {
  await withHarness({ mount: { waitUnitMs: 1000 } }, async (h) => {
    for (const [over, who] of [[undefined, 'a shots job'], [newClip(), 'a clip job'], [newBench(), 'a bench job']]) {
      const id = await h.runningJob({ over, accountId: HELIX });
      const r = await uploadJson(h, id, 'install.json', stepJson(), { accountId: HELIX });
      assert.deepStrictEqual([r.statusCode, r.body.code], [400, 'bad_request'], who);
      assert.match(r.body.error, /no step results/);
      assert.ok(!fs.existsSync(path.join(h.jobFolder(id), 'install.json')), who);
    }
    const id = await h.runningJob({ over: newRelease() });
    const clip = await h.uploadClip(id, 'a.mjpeg', fakeClip());
    assert.deepStrictEqual([clip.statusCode, clip.body.code], [400, 'bad_request'], 'a release job takes no clips');
    assert.match(clip.body.error, /pictures, not video clips/);
    const otherPc = await uploadJson(h, id, 'a.json', stepJson(), { pcId: PC_A2 });
    assert.deepStrictEqual([otherPc.statusCode, otherPc.body.code], [403, 'not_your_job']);
    const otherAccount = await uploadJson(h, id, 'a.json', stepJson(), { accountId: HELIX });
    assert.deepStrictEqual([otherAccount.statusCode, otherAccount.body.code], [403, 'not_your_job']);
    assert.strictEqual((await uploadJson(h, id, 'a.json', stepJson(), { headers: { 'x-team-pc': PC_B } })).body.code, 'wrong_pc');
    const queued = await h.makeJob(newRelease());
    assert.deepStrictEqual([(await uploadJson(h, queued, 'a.json', stepJson())).statusCode, (await uploadJson(h, 'c'.repeat(12), 'a.json', stepJson())).statusCode], [409, 404]);
    const cancelled = await h.runningJob({ over: newRelease(), pcId: PC_W, accountId: WAR });
    await h.internal('POST /internal/team/jobs/:id/cancel', { params: { id: cancelled } });
    const c = await uploadJson(h, cancelled, 'a.json', stepJson(), { accountId: WAR });
    assert.deepStrictEqual([c.statusCode, c.body.error], [409, 'This job was cancelled.']);
    assert.ok(!fs.existsSync(path.join(h.jobFolder(queued), 'a.json')) && !fs.existsSync(path.join(h.jobFolder(cancelled), 'a.json')));
  });
});

test('a release job takes 120 files (a shots job still 40), and one may be replaced', async () => {
  await withHarness(async (h) => {
    const id = await h.runningJob({ over: newRelease() });
    fs.mkdirSync(h.jobFolder(id), { recursive: true });
    const RELEASE_CAP = mountTeamJobs.RELEASE_FILES_PER_JOB;
    assert.strictEqual(RELEASE_CAP, 120);
    for (let i = 0; i < RELEASE_CAP - 1; i++) fs.writeFileSync(path.join(h.jobFolder(id), `s${i}.png`), png());
    assert.strictEqual((await uploadJson(h, id, 'last.json', stepJson())).statusCode, 200, 'the 120th file');
    const extra = await h.upload(id, 'one_more.png', png());
    assert.deepStrictEqual([extra.statusCode, extra.body.code, extra.body.error], [409, 'too_many', 'A job takes at most 120 pictures.']);
    assert.strictEqual((await uploadJson(h, id, 'last.json', stepJson({ again: 1 }))).statusCode, 200, 'replacing one is not adding one');
    assert.strictEqual(fs.readdirSync(h.jobFolder(id)).length, RELEASE_CAP);
    const extraJson = await uploadJson(h, id, 'next.json', stepJson());
    assert.deepStrictEqual([extraJson.statusCode, extraJson.body.error], [409, 'A job takes at most 120 results.']);
    const shots = await h.runningJob({ accountId: HELIX });
    fs.mkdirSync(h.jobFolder(shots), { recursive: true });
    for (let i = 0; i < FILES_PER_JOB; i++) fs.writeFileSync(path.join(h.jobFolder(shots), `shot_${i}.png`), png());
    assert.strictEqual((await h.upload(shots, 'one_more.png', png(), { accountId: HELIX })).body.code, 'too_many', 'a shots job is still held to 40');
  });
});

test('done of a release job keeps how each step went, the files it named and the log; a failed step is a result, not a failed job', async () => {
  await withHarness(async (h) => {
    const id = await h.runningJob({ over: newRelease() });
    await uploadJson(h, id, 'install.json', stepJson({ ok: true, bootMs: 812 }));
    await uploadJson(h, id, 'quit-loading.json', stepJson({ ok: false }));
    await h.upload(id, '1920x1080_bag.png', png(1920, 1080, 200));
    h.advance(90_000);
    const steps = [{ step: 'install', ok: true, ms: 812 }, { step: 'quit-loading', ok: false, error: 'It did not quit within 20 seconds.', ms: 20000 }, { step: 'screens', ok: true, ms: 91000.4, junk: 1 }];
    const done = await doneRelease(h, id, steps, { files: ['install.json', 'quit-loading.json', '1920x1080_bag.png', 'install.json'], log: `ok\n${'x'.repeat(100000)}` });
    assert.deepStrictEqual([done.statusCode, done.body], [200, { success: true, data: { id, status: 'done' } }]);
    const job = h.jobs[0];
    assert.deepStrictEqual([job.status, job.error, job.finished_at], ['done', null, h.now()]);
    const result = JSON.parse(job.result);
    assert.deepStrictEqual(result.steps, [{ step: 'install', ok: true, ms: 812 }, { step: 'quit-loading', ok: false, error: 'It did not quit within 20 seconds.', ms: 20000 }, { step: 'screens', ok: true, ms: 91000 }]);
    assert.deepStrictEqual(result.files.map((f) => f.name), ['install.json', 'quit-loading.json', '1920x1080_bag.png']);
    assert.strictEqual(result.runs, undefined);
    assert.ok(Buffer.byteLength(result.log) <= 65536 && result.log.startsWith('ok\n'));
    assert.deepStrictEqual(result.timings, { downloadS: 30, runS: 2300 });
    // the runner reads it back with the files and their paths: step results, pictures
    const got = (await h.internal('GET /internal/team/jobs/:id', { params: { id } })).body.data;
    assert.deepStrictEqual(got.files.map((f) => [f.name, path.isAbsolute(f.path) && fs.existsSync(f.path)]), [['1920x1080_bag.png', true], ['install.json', true], ['quit-loading.json', true]]);
    assert.deepStrictEqual(got.result.steps[1], { step: 'quit-loading', ok: false, error: 'It did not quit within 20 seconds.', ms: 20000 });
    // a resent done is the same success
    assert.deepStrictEqual((await doneRelease(h, id, steps)).body, { success: true, data: { id, status: 'done' } });
    assert.strictEqual((await h.call('POST /api/team/jobs/:id/fail', { params: { id }, body: { error: 'late' } })).statusCode, 409);
  });
  await withHarness(async (h) => {   // every step failed: still done
    const id = await h.runningJob({ over: newRelease() });
    const done = await doneRelease(h, id, STEPS_ALL.map((step) => ({ step, ok: false, error: `${step} broke` })));
    assert.strictEqual(done.statusCode, 200);
    assert.deepStrictEqual([h.jobs[0].status, JSON.parse(h.jobs[0].result).steps.every((s) => !s.ok)], ['done', true]);
  });
});
const STEPS_ALL = ['install', 'quit-loading', 'screens', 'stutter', 'bench', 'soak'];

test('a release done with steps that do not read, a file never uploaded or a bad file name is 400 and leaves the job running', async () => {
  await withHarness(async (h) => {
    const id = await h.runningJob({ over: newRelease() });
    await uploadJson(h, id, 'install.json', stepJson());
    for (const body of [{}, { steps: [] }, { steps: 'install' }, { steps: [{ step: 'install' }] }, { steps: [{ step: 'launch', ok: true }] }, { steps: [{ step: 'install', ok: true }, { step: 'install', ok: true }] },
      { steps: new Array(7).fill({ step: 'install', ok: true }) }]) {
      const r = await h.call('POST /api/team/jobs/:id/done', { params: { id }, body });
      assert.deepStrictEqual([r.statusCode, r.body.code], [400, 'bad_request'], JSON.stringify(body).slice(0, 50));
      assert.ok(r.body.error.length > 10);
    }
    const missing = await doneRelease(h, id, [{ step: 'install', ok: true }], { files: ['install.json', 'never_sent.json'] });
    assert.deepStrictEqual([missing.statusCode, missing.body.code], [400, 'bad_request']);
    assert.match(missing.body.error, /never_sent\.json/);
    for (const files of [['../x.json'], ['A.json'], [7], ['a.mp4'], ['a.mjpeg'], Array.from({ length: 121 }, (_, i) => `s${i}.png`)]) {
      assert.strictEqual((await doneRelease(h, id, [{ step: 'install', ok: true }], { files })).statusCode, 400, JSON.stringify(files).slice(0, 40));
    }
    assert.strictEqual(h.jobs[0].status, 'running');
    assert.strictEqual((await doneRelease(h, id, [{ step: 'install', ok: true }], { files: ['install.json'] })).statusCode, 200, 'a corrected done works');
  });
});

test('the bench step\'s runs are stored in the benchmark history like a bench job\'s; a bad run marks the bench step failed and the rest stands', async () => {
  await withHarness(async (h) => {
    const id = await h.runningJob({ accountId: WAR, pcId: PC_W, over: newRelease() });
    const runs = [benchRun(), benchRun({ clientRunId: '1760000000654321', preset: 'medium' })];
    const done = await doneRelease(h, id, [{ step: 'install', ok: true }, { step: 'bench', ok: true, ms: 600000 }], { runs }, { accountId: WAR });
    assert.strictEqual(done.statusCode, 200, JSON.stringify(done.body));
    assert.deepStrictEqual(h.benchRows.map((r) => [r.account_id, r.source, r.source_pc, r.preset]), [[WAR, 'team', PC_W, 'low'], [WAR, 'team', PC_W, 'medium']]);
    const result = JSON.parse(h.jobs[0].result);
    assert.deepStrictEqual(result.runs, [{ clientRunId: '1760000000123456', id: 1 }, { clientRunId: '1760000000654321', id: 2 }]);
    assert.deepStrictEqual(result.steps[1], { step: 'bench', ok: true, ms: 600000 });
    assert.deepStrictEqual((await doneRelease(h, id, [{ step: 'bench', ok: true }], { runs }, { accountId: WAR })).body, { success: true, data: { id, status: 'done' } }, 'a resent done stores nothing twice');
    assert.strictEqual(h.benchRows.length, 2);
  });
  await withHarness(async (h) => {
    const id = await h.runningJob({ over: newRelease() });
    const done = await doneRelease(h, id, [{ step: 'install', ok: true }, { step: 'bench', ok: true }], { runs: [benchRun(), benchRun({ clientRunId: '1760000000000002', preset: 'max' })] });
    assert.strictEqual(done.statusCode, 200, 'the job is done all the same');
    assert.strictEqual(h.benchRows.length, 0, 'none of the runs is stored');
    const steps = JSON.parse(h.jobs[0].result).steps;
    assert.deepStrictEqual(steps, [{ step: 'install', ok: true }, { step: 'bench', ok: false, error: 'Run 2: This benchmark run has an unknown graphics preset.' }]);
    assert.strictEqual(JSON.parse(h.jobs[0].result).runs, undefined);
  });
  await withHarness(async (h) => {   // the daily cap, and empty or too many runs
    h.benchPadding.set(MUFFINS, 60);
    const id = await h.runningJob({ over: newRelease() });
    await doneRelease(h, id, [{ step: 'bench', ok: true }], { runs: [benchRun()] });
    assert.match(JSON.parse(h.jobs[0].result).steps[0].error, /benchmark/i);
    assert.strictEqual(JSON.parse(h.jobs[0].result).steps[0].ok, false);
    const id2 = await h.runningJob({ over: newRelease(), accountId: HELIX });
    await doneRelease(h, id2, [{ step: 'bench', ok: true }], { runs: [] }, { accountId: HELIX });
    assert.deepStrictEqual(JSON.parse(h.jobs[1].result).steps[0], { step: 'bench', ok: false, error: 'The bench step carried no runs.' });
    const id3 = await h.runningJob({ over: newRelease(), accountId: WAR });
    await doneRelease(h, id3, [{ step: 'bench', ok: true }], { runs: new Array(7).fill(benchRun()) }, { accountId: WAR });
    assert.match(JSON.parse(h.jobs[2].result).steps[0].error, /at most 6 runs/);
    const id4 = await h.runningJob({ over: newRelease(), accountId: WAR, pcId: 'pc-war-other-0009' });
    const noBench = await doneRelease(h, id4, [{ step: 'install', ok: true }], { runs: [benchRun()] }, { accountId: WAR, pcId: 'pc-war-other-0009' });
    assert.deepStrictEqual([noBench.statusCode, noBench.body.error], [400, 'Benchmark runs need a bench step.'], 'runs without a bench step are refused');
    assert.strictEqual(h.jobs[3].status, 'running');
  });
});

test('a release job that stops halfway fails with the steps it finished, and its uploaded results are still there to report', async () => {
  await withHarness(async (h) => {
    const id = await h.runningJob({ over: newRelease() });
    await uploadJson(h, id, 'install.json', stepJson({ ok: true }));
    const r = await h.call('POST /api/team/jobs/:id/fail', { params: { id }, body: { error: 'stopped: the game started', log: 'half way', steps: [{ step: 'install', ok: true, ms: 800 }, { step: 'quit-loading', ok: true }] } });
    assert.deepStrictEqual([r.statusCode, r.body], [200, { success: true, data: { id, status: 'failed' } }]);
    const job = h.jobs[0];
    assert.deepStrictEqual([job.status, job.error], ['failed', 'stopped: the game started']);
    const result = JSON.parse(job.result);
    assert.deepStrictEqual([result.steps, result.log], [[{ step: 'install', ok: true, ms: 800 }, { step: 'quit-loading', ok: true }], 'half way']);
    const got = (await h.internal('GET /internal/team/jobs/:id', { params: { id } })).body.data;
    assert.deepStrictEqual(got.files.map((f) => f.name), ['install.json'], 'the step result it uploaded is kept');
    // steps that do not read are left out, the job fails all the same; other kinds ignore steps
    const bad = await h.runningJob({ over: newRelease(), accountId: HELIX });
    assert.strictEqual((await h.call('POST /api/team/jobs/:id/fail', { accountId: HELIX, params: { id: bad }, body: { error: 'x', steps: [{ step: 'launch' }] } })).statusCode, 200);
    assert.strictEqual(JSON.parse(h.jobs[1].result).steps, undefined);
    const shots = await h.runningJob({ accountId: WAR });
    await h.call('POST /api/team/jobs/:id/fail', { accountId: WAR, params: { id: shots }, body: { error: 'x', steps: [{ step: 'install', ok: true }] } });
    assert.strictEqual(JSON.parse(h.jobs[2].result).steps, undefined);
  });
});

test('the reporter\'s list: finished release jobs not reported yet, each as the single GET returns it, oldest finish first', async () => {
  await withHarness(async (h) => {
    const mk = async (over, who) => { const id = await h.runningJob({ over, accountId: who, pcId: PC_OF[who] }); return id; };
    const a = await mk(newRelease(), MUFFINS);
    const b = await mk(newRelease(), HELIX);
    const c = await mk(newRelease(), WAR);
    const shots = await h.runningJob({ accountId: MUFFINS, pcId: PC_A2 });
    const queued = await h.makeJob(newRelease());
    h.advance(MIN);
    await uploadJson(h, b, 'install.json', stepJson(), { accountId: HELIX });
    await doneRelease(h, b, [{ step: 'install', ok: true }], { files: ['install.json'] }, { accountId: HELIX });
    h.advance(MIN);
    await h.call('POST /api/team/jobs/:id/fail', { params: { id: a }, body: { error: 'the PC went away', steps: [{ step: 'install', ok: false, error: 'no' }] } });
    h.advance(MIN);
    await h.call('POST /api/team/jobs/:id/done', { accountId: MUFFINS, pcId: PC_A2, params: { id: shots }, body: { files: [] } });
    await h.internal('POST /internal/team/jobs/:id/cancel', { params: { id: c } });
    const list = await h.internal('GET /internal/team/jobs', { query: { kind: 'release', status: 'finished', unreported: '1' } });
    assert.strictEqual(list.statusCode, 200, JSON.stringify(list.body));
    assert.deepStrictEqual(Object.keys(list.body), ['success', 'data']);
    assert.deepStrictEqual(Object.keys(list.body.data), ['jobs']);
    assert.deepStrictEqual(list.body.data.jobs.map((j) => [j.id, j.status]), [[b, 'done'], [a, 'failed']], 'done or failed releases, the one that finished first first; not the cancelled, queued, running or shots ones');
    const single = (await h.internal('GET /internal/team/jobs/:id', { params: { id: b } })).body.data;
    assert.deepStrictEqual(list.body.data.jobs[0], single, 'each row is exactly what GET /internal/team/jobs/:id returns');
    assert.deepStrictEqual(Object.keys(single).sort(), ['claimedAccount', 'claimedAt', 'claimedPc', 'createdAt', 'error', 'expiresAt', 'files', 'finishedAt', 'heartbeatAt', 'id', 'kind', 'payload', 'reportedAt', 'result', 'status', 'targetPc', 'title', 'tries', 'weightS']);
    assert.deepStrictEqual([single.kind, single.reportedAt, single.payload.version, single.claimedAccount, single.claimedPc], ['release', null, RELEASE.version, HELIX, PC_B]);
    assert.deepStrictEqual(single.files.map((f) => [f.name, path.isAbsolute(f.path)]), [['install.json', true]]);
    assert.deepStrictEqual(single.result.steps, [{ step: 'install', ok: true }]);
    assert.deepStrictEqual(list.body.data.jobs[1].result.steps, [{ step: 'install', ok: false, error: 'no' }], 'a failed job lists the steps it reported');
    assert.strictEqual(list.body.data.jobs[1].error, 'the PC went away');
    // the other filters
    const ids = async (query) => (await h.internal('GET /internal/team/jobs', { query })).body.data.jobs.map((j) => j.id).sort();
    assert.deepStrictEqual(await ids({ kind: 'release', status: 'open' }), [queued].sort(), 'open: queued or running');
    assert.deepStrictEqual(await ids({ kind: 'release', status: 'cancelled' }), [c]);
    assert.deepStrictEqual(await ids({ kind: 'release', status: 'done' }), [b]);
    assert.deepStrictEqual(await ids({ kind: 'release', status: 'failed' }), [a]);
    assert.deepStrictEqual(await ids({ kind: 'shots', status: 'finished' }), [shots]);
    assert.deepStrictEqual(await ids({ kind: 'release' }), [a, b, c, queued].sort(), 'no status: every status');
    assert.deepStrictEqual((await ids({})).length, 5, 'no filter: every job');
    assert.deepStrictEqual(await ids({ kind: 'stutter' }), []);
    assert.deepStrictEqual(await ids({ kind: 'release', status: 'finished', limit: '1' }), [b], 'limit');
    assert.deepStrictEqual(await ids({ kind: 'release', status: 'finished', unreported: '0' }), [a, b].sort(), 'unreported=0 is no filter');
    // bad parameters are 400 with a reason
    for (const query of [{ kind: 'Release' }, { kind: '1x' }, { kind: ['a'] }, { status: 'all' }, { status: 'done,failed' }, { status: ['done'] }, { unreported: 'yes' }, { unreported: '2' }, { limit: '0' }, { limit: '101' }, { limit: 'x' }, { limit: '-1' }, { limit: '1.5' }]) {
      const r = await h.internal('GET /internal/team/jobs', { query });
      assert.deepStrictEqual([r.statusCode, r.body.code], [400, 'bad_request'], JSON.stringify(query));
      assert.ok(r.body.error.length > 10);
    }
    assert.ok(h.sqlLog.every((sql) => !sql.includes('release') && !sql.includes(b)), 'the kind and ids are parameters, not text in the SQL');
  });
});

test('the reporter\'s routes answer 404 to anyone but the runner, and a list holds at most 100 rows', async () => {
  await withHarness(async (h) => {
    await h.runningJob({ over: newRelease() });
    for (const [route, opts] of [['GET /internal/team/jobs', {}], ['POST /internal/team/jobs/:id/reported', { params: { id: h.jobs[0].id } }]]) {
      for (const bad of [{ addr: '203.0.113.9' }, { secret: null }, { secret: 'wrong-secret-0123456789-abcdefghij' }, { headers: { 'x-forwarded-for': '1.2.3.4' } }]) {
        const r = await h.internal(route, { ...opts, ...bad });
        assert.strictEqual(r.statusCode, 404, `${route} ${JSON.stringify(bad)}`);
      }
    }
    assert.ok(!h.routes['GET /api/internal/team/jobs'] && !h.routes['POST /api/internal/team/jobs/:id/reported'], 'mounted only under /internal');
    assert.strictEqual(h.jobs[0].reported_at, undefined);
  });
  await withHarness(async (h) => {
    for (let i = 0; i < 30; i++) h.jobs.push({ id: `${(1000 + i).toString(16).padStart(12, '0')}`, kind: 'release', title: 't', weight_s: 1, payload: '{}', status: 'done', created_at: T0 + i, expires_at: T0 + 1e9, claimed_account: 1, claimed_pc: 'x', claimed_at: T0, heartbeat_at: T0, finished_at: T0 + i, result: null, error: null, tries: 0, target_pc: null });
    const all = await h.internal('GET /internal/team/jobs', { query: { limit: '100' } });
    assert.strictEqual(all.body.data.jobs.length, 30);
    assert.strictEqual((await h.internal('GET /internal/team/jobs', { query: { limit: '7' } })).body.data.jobs.length, 7);
    assert.strictEqual((await h.internal('GET /internal/team/jobs', {})).body.data.jobs.length, 30, 'the default is 50');
    assert.deepStrictEqual(all.body.data.jobs.map((j) => j.id), [...all.body.data.jobs.map((j) => j.id)].sort(), 'in finishing order (here the same as id order)');
  });
});

test('POST /internal/team/jobs/:id/reported marks a finished job once; a job that has not finished is 409; reported jobs leave the unreported list', async () => {
  await withHarness(async (h) => {
    const done = await h.runningJob({ over: newRelease() });
    const failed = await h.runningJob({ over: newRelease(), accountId: HELIX });
    const running = await h.runningJob({ over: newRelease(), accountId: WAR });
    const queued = await h.makeJob(newRelease());
    const cancelled = await h.makeJob(newRelease());
    await doneRelease(h, done, [{ step: 'install', ok: true }]);
    await h.call('POST /api/team/jobs/:id/fail', { accountId: HELIX, params: { id: failed }, body: { error: 'x' } });
    await h.internal('POST /internal/team/jobs/:id/cancel', { params: { id: cancelled } });
    h.advance(5 * MIN);
    const r = await h.internal('POST /internal/team/jobs/:id/reported', { params: { id: done } });
    assert.deepStrictEqual([r.statusCode, r.body], [200, { success: true, data: { id: done, reportedAt: new Date(Math.floor(h.now() / 1000) * 1000).toISOString() } }]);
    assert.strictEqual(h.jobs.find((j) => j.id === done).reported_at, h.now());
    h.advance(MIN);
    const again = await h.internal('POST /internal/team/jobs/:id/reported', { params: { id: done } });
    assert.deepStrictEqual(again.body.data, r.body.data, 'again is the same answer and the same time');
    assert.strictEqual((await h.internal('GET /internal/team/jobs/:id', { params: { id: done } })).body.data.reportedAt, r.body.data.reportedAt, 'the job row says when');
    for (const id of [failed, cancelled]) assert.strictEqual((await h.internal('POST /internal/team/jobs/:id/reported', { params: { id } })).statusCode, 200);
    for (const id of [running, queued]) {
      const x = await h.internal('POST /internal/team/jobs/:id/reported', { params: { id } });
      assert.deepStrictEqual([x.statusCode, x.body.code, x.body.error], [409, 'not_finished', 'That job has not finished yet.'], id);
    }
    assert.strictEqual(h.jobs.find((j) => j.id === running).reported_at, undefined);
    assert.strictEqual((await h.internal('POST /internal/team/jobs/:id/reported', { params: { id: 'e'.repeat(12) } })).statusCode, 404);
    assert.strictEqual((await h.internal('POST /internal/team/jobs/:id/reported', { params: { id: '../../etc' } })).statusCode, 404);
    const left = (await h.internal('GET /internal/team/jobs', { query: { kind: 'release', status: 'finished', unreported: '1' } })).body.data.jobs;
    assert.deepStrictEqual(left, [], 'nothing finished is left unreported');
    const reported = (await h.internal('GET /internal/team/jobs', { query: { kind: 'release', status: 'finished' } })).body.data.jobs;
    assert.deepStrictEqual(reported.map((j) => j.reportedAt !== null), [true, true]);
  });
});

test('a database without migration 059 answers a readable 503 on the job rows, never a stack', async () => {
  await withHarness(async (h) => {
    const id = await h.makeJob(newRelease());
    const execute = h.pool.execute;
    h.pool.execute = async (sql, p) => { if (/reported_at/.test(sql)) throw Object.assign(new Error("Unknown column 'reported_at'"), { code: 'ER_BAD_FIELD_ERROR' }); return execute(sql, p); };
    for (const [route, opts] of [['GET /internal/team/jobs/:id', { params: { id } }], ['GET /internal/team/jobs', {}], ['POST /internal/team/jobs/:id/reported', { params: { id } }]]) {
      const r = await h.internal(route, opts);
      assert.deepStrictEqual([r.statusCode, r.body.code], [503, 'unavailable'], route);
      assert.ok(!/reported_at|Unknown column/.test(r.body.error));
    }
    h.pool.execute = execute;
  });
});

// ── Held heartbeats (long polling): `wait` ──────────────────────────────────────────────────────────────────────────────────

const sleepMs = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const STILL_HELD = Symbol('still held');
/** The answer of `p` when it comes within `ms`, else STILL_HELD (the promise is left running). */
const within = (p, ms) => Promise.race([p, sleepMs(ms).then(() => STILL_HELD)]);
const held = (h, over = {}, callOpts = {}) => h.call('POST /api/team/heartbeat', { body: beat({ wait: 25, ...over }), ...callOpts });

test('parseWait reads a body\'s wait as 0 to 25 seconds, and anything else as 0', () => {
  const w = (wait) => mountTeamJobs.parseWait({ body: wait === undefined ? {} : { wait } });
  assert.deepStrictEqual([w(25), w(10), w(1), w(0.5), w('12'), w(' 7 ')], [25, 10, 1, 0.5, 12, 7]);
  assert.deepStrictEqual([w(26), w(1000), w('999')], [25, 25, 25], 'more than 25 is 25');
  assert.deepStrictEqual([w(undefined), w(0), w(-5), w('-5'), w('abc'), w(''), w(null), w(NaN), w(true), w([5]), w({}), w('1e3'), w('25 s')], new Array(13).fill(0), 'not a plain number: 0');
  assert.strictEqual(w(Infinity), 0, 'not a finite number: 0');
  assert.strictEqual(mountTeamJobs.parseWait({ body: 'x' }), 0);
  assert.strictEqual(mountTeamJobs.parseWait({}), 0);
  assert.deepStrictEqual([mountTeamJobs.WAIT_MAX_S, mountTeamJobs.HELD_MAX], [25, 10]);
});

test('a heartbeat with no wait, a wait of 0 or nothing to hold for is answered at once, as it always was', async () => {
  await withHarness({ mount: { waitUnitMs: 1000 } }, async (h) => {
    for (const body of [beat(), beat({ wait: 0 }), beat({ wait: -3 }), beat({ wait: 'soon' })]) {
      const r = await within(h.call('POST /api/team/heartbeat', { body }), 1500);
      assert.notStrictEqual(r, STILL_HELD, JSON.stringify(body.wait));
      assert.deepStrictEqual([r.statusCode, r.body.data.offer, r.body.data.cancel], [200, null, []]);
    }
    const id = await h.makeJob();
    const r = await within(held(h), 1500);   // a job is waiting for this PC: there is something to say
    assert.notStrictEqual(r, STILL_HELD, 'an offer is answered at once whatever the wait');
    assert.strictEqual(r.body.data.offer.id, id);
  });
});

test('a held heartbeat answers empty when its wait runs out, and the PC is stored when the request starts', async () => {
  await withHarness({ mount: { waitUnitMs: 40 } }, async (h) => {
    const started = Date.now();
    const p = held(h, { wait: 3 });
    assert.strictEqual(await within(p, 30), STILL_HELD, 'held, not answered');
    assert.deepStrictEqual([h.pcs.size, [...h.pcs.values()][0].name, [...h.pcs.values()][0].last_seen], [1, 'Muffins PC', h.now()], 'the PC row is written at the start, so last_seen stays fresh');
    const r = await p;
    assert.ok(Date.now() - started >= 100, 'it waited about 3 units (120 ms)');
    assert.deepStrictEqual([r.statusCode, r.body.success, r.body.data.offer, r.body.data.cancel], [200, true, null, []]);
    assert.strictEqual(typeof r.body.data.serverTime, 'string');
  });
});

test('an offer made while a heartbeat is held answers it at once', async () => {
  await withHarness(async (h) => {
    const p = held(h);   // 25 real seconds if the wake does not work
    assert.strictEqual(await within(p, 50), STILL_HELD);
    const id = await h.makeJob(newClip());
    const r = await within(p, 3000);
    assert.notStrictEqual(r, STILL_HELD, 'answered by the new job, not by the 25 s');
    assert.deepStrictEqual([r.statusCode, r.body.data.offer.id, r.body.data.offer.kind], [200, id, 'clip']);
  });
});

test('a job this PC may not take does not end its hold: one for another PC, or one it declined', async () => {
  await withHarness({ mount: { waitUnitMs: 60 } }, async (h) => {
    const p = held(h, { wait: 3 });   // 180 ms
    await sleepMs(20);
    await h.makeJob({ kind: 'bench', title: 'for the other PC', payload: BENCH, targetPc: PC_B });
    assert.strictEqual(await within(p, 50), STILL_HELD, 'a job for another PC is nothing to say');
    const r = await p;
    assert.strictEqual(r.body.data.offer, null, 'the wait ran out with nothing for this PC');
  });
  await withHarness({ mount: { waitUnitMs: 60 } }, async (h) => {
    const declined = await h.makeJob();
    await h.call('POST /api/team/jobs/:id/decline', { params: { id: declined }, body: { pcId: PC_A, reason: 'busy' } });
    const p = held(h, { wait: 2 });
    await sleepMs(20);
    await h.makeJob({ title: 'another shots job' });   // a new job: this is news
    const r = await within(p, 1000);
    assert.notStrictEqual(r, STILL_HELD);
    assert.notStrictEqual(r.body.data.offer.id, declined, 'a declined job is still not offered');
    assert.strictEqual(r.body.data.offer.title, 'another shots job');
  });
});

test('a cancel of the job this PC runs answers a held heartbeat at once, and a cancel it was told is not news the next time', async () => {
  await withHarness({ mount: { waitUnitMs: 60 } }, async (h) => {
    const id = await h.runningJob();
    const p = held(h, { wait: 25 });
    assert.strictEqual(await within(p, 50), STILL_HELD, 'a running job and nothing to say: held');
    await h.internal('POST /internal/team/jobs/:id/cancel', { params: { id } });
    const r = await within(p, 3000);
    assert.notStrictEqual(r, STILL_HELD, 'the cancel woke it');
    assert.deepStrictEqual([r.body.data.cancel, r.body.data.offer], [[id], null]);
    // the list keeps a cancel for 10 minutes; the PC has been told, so this heartbeat is held again (not answered in a tight loop)
    const again = held(h, { wait: 2 });
    assert.strictEqual(await within(again, 60), STILL_HELD, 'a known cancel is not news');
    const answer = await again;
    assert.deepStrictEqual(answer.body.data.cancel, [id], 'it still names it when it answers');
    // a heartbeat of another PC that was never told is answered at once with its own cancels (none)
    const other = await within(held(h, { wait: 1, pcId: PC_B }, { accountId: HELIX, pcId: PC_B }), 20);
    assert.strictEqual(other, STILL_HELD, 'nothing for the other PC: held');
  });
  await withHarness(async (h) => {
    const id = await h.runningJob();
    await h.internal('POST /internal/team/jobs/:id/cancel', { params: { id } });
    const r = await within(held(h), 1500);   // cancelled before it asked, and never told: news at once
    assert.notStrictEqual(r, STILL_HELD);
    assert.deepStrictEqual(r.body.data.cancel, [id]);
  });
});

test('a job that goes back to the queue (its PC went quiet) wakes the PC that waits for one', async () => {
  await withHarness(async (h) => {
    const id = await h.runningJob({ accountId: HELIX, pcId: PC_B });
    const p = held(h);   // Muffins' PC waits
    assert.strictEqual(await within(p, 50), STILL_HELD);
    h.advance(4 * MIN);   // Helix's PC is silent for 3 minutes
    await h.internal('GET /internal/team/pcs');   // any call sweeps: the job is queued again
    const r = await within(p, 3000);
    assert.notStrictEqual(r, STILL_HELD, 'the sweep\'s requeue woke it');
    assert.strictEqual(r.body.data.offer.id, id);
    assert.strictEqual(h.jobs[0].tries, 1);
  });
});

test('the runner cancelling a queued job, or making one with supersede, wakes held heartbeats too, and nothing is lost between the first look and the wait', async () => {
  await withHarness({ mount: { waitUnitMs: 60 } }, async (h) => {
    const waiting = await h.makeJob({ kind: 'bench', title: 'bench for this PC', payload: BENCH, targetPc: PC_A });
    await h.call('POST /api/team/jobs/:id/decline', { params: { id: waiting }, body: { pcId: PC_A, reason: 'not_now' } });
    const p = held(h, { wait: 25 });
    assert.strictEqual(await within(p, 40), STILL_HELD);
    const r = await h.internal('POST /internal/team/jobs', { body: newBench({ targetPc: PC_A, supersede: true }) });
    assert.strictEqual(r.body.data.superseded, 1);
    const got = await within(p, 3000);
    assert.notStrictEqual(got, STILL_HELD);
    assert.strictEqual(got.body.data.offer.id, r.body.data.id);
  });
  // a job made just as heartbeats start is never missed: whichever look sees it, no heartbeat waits for the full time
  await withHarness({ mount: { waitUnitMs: 1000 } }, async (h) => {
    await h.tokenOf(MUFFINS, PC_A);   // (a sign-in per PC first: signing in again would end the one the other calls hold)
    await h.tokenOf(HELIX, PC_B);
    const all = [];
    for (let i = 0; i < 12; i++) {
      all.push(held(h, { wait: 25, pcId: i % 2 ? PC_B : PC_A }, { accountId: i % 2 ? HELIX : MUFFINS, pcId: i % 2 ? PC_B : PC_A }));
      if (i % 3 === 0) await h.makeJob({ title: `job ${i}` });
      if (i % 4 === 0) await sleepMs(1);
    }
    await h.makeJob({ title: 'the last one' });
    const answers = await within(Promise.all(all), 4000);
    assert.notStrictEqual(answers, STILL_HELD, 'every heartbeat was answered within 4 s, none waited 25');
    assert.ok(answers.every((a) => a.body.data.offer), 'each of them saw a job');
  });
});

test('at most 10 heartbeats of an account are held; the next is answered at once, another account is not affected, and a slot frees when a hold ends', async () => {
  await withHarness({ mount: { waitUnitMs: 1000 } }, async (h) => {
    await h.tokenOf(MUFFINS, PC_A);
    await h.tokenOf(HELIX, PC_B);
    const holds = [];
    for (let i = 0; i < 10; i++) holds.push(held(h));
    await sleepMs(30);
    assert.ok((await Promise.all(holds.map((p) => within(p, 1)))).every((r) => r === STILL_HELD), 'ten held');
    const eleventh = await within(held(h), 1500);
    assert.notStrictEqual(eleventh, STILL_HELD, 'the eleventh is answered at once');
    assert.deepStrictEqual([eleventh.statusCode, eleventh.body.data.offer], [200, null], 'as a heartbeat with no wait');
    const helix = held(h, { pcId: PC_B }, { accountId: HELIX, pcId: PC_B });
    assert.strictEqual(await within(helix, 40), STILL_HELD, 'another account has its own ten');
    await h.makeJob();   // everything wakes
    const all = await within(Promise.all([...holds, helix]), 3000);
    assert.notStrictEqual(all, STILL_HELD, 'all of them answered by the new job');
    assert.ok(all.every((r) => r.body.data.offer));
  });
  await withHarness({ mount: { waitUnitMs: 1000 } }, async (h) => {   // after the holds ended, a new heartbeat is held again
    await h.tokenOf(MUFFINS, PC_A);
    const first = [];
    for (let i = 0; i < 10; i++) first.push(held(h));
    await sleepMs(20);
    await h.makeJob({ kind: 'bench', title: 'for someone else', payload: BENCH, targetPc: PC_B });
    await sleepMs(20);
    assert.ok((await Promise.all(first.map((p) => within(p, 1)))).every((r) => r === STILL_HELD), 'a job for another PC ends no hold');
    await h.makeJob({ title: 'for muffins' });
    const answers = await within(Promise.all(first), 3000);
    assert.notStrictEqual(answers, STILL_HELD);
    const claimed = answers[0].body.data.offer.id;
    await h.call('POST /api/team/jobs/:id/claim', { params: { id: claimed }, body: { pcId: PC_A } });
    const fresh = held(h, { wait: 1 });
    assert.strictEqual(await within(fresh, 60), STILL_HELD, 'the slots are free again: the next heartbeat is held');
    await h.makeJob({ title: 'one more' });
    assert.notStrictEqual(await within(fresh, 3000), STILL_HELD);
  });
});

test('a PC that hangs up while its heartbeat is held is not answered, and its slot is free', async () => {
  await withHarness({ mount: { waitUnitMs: 1000 } }, async (h) => {
    const res = h.fakeRes();
    const p = h.call('POST /api/team/heartbeat', { body: beat({ wait: 25 }), res });
    assert.strictEqual(await within(p, 50), STILL_HELD);
    res.emit('close');
    const r = await within(p, 1000);
    assert.notStrictEqual(r, STILL_HELD, 'the held call ended at once');
    assert.strictEqual(r.body, null, 'nothing was sent to a PC that is gone');
    assert.deepStrictEqual(res.listeners.close, [], 'the listener is gone');
    // ten PCs that hung up leave no held slot behind
    for (let i = 0; i < 12; i++) {
      const r2 = h.fakeRes();
      const q = h.call('POST /api/team/heartbeat', { body: beat({ wait: 25 }), res: r2 });
      await sleepMs(5);
      r2.emit('close');
      await q;
    }
    const fresh = held(h, { wait: 1 });
    assert.strictEqual(await within(fresh, 40), STILL_HELD, 'a new heartbeat is still held (the slots were given back)');
    await h.makeJob();
    assert.notStrictEqual(await within(fresh, 2000), STILL_HELD);
  });
});

test('a held heartbeat that is refused (a bad PC id, a wrong sign-in) is never held, and the sign-in check comes first', async () => {
  await withHarness({ mount: { waitUnitMs: 1000 } }, async (h) => {
    const bad = await within(h.call('POST /api/team/heartbeat', { body: beat({ wait: 25, pcId: 'bad id!' }) }), 1000);
    assert.notStrictEqual(bad, STILL_HELD);
    assert.strictEqual(bad.statusCode, 400);
    const anon = await within(h.call('POST /api/team/heartbeat', { anon: true, body: beat({ wait: 25 }) }), 1000);
    assert.deepStrictEqual([anon.statusCode, anon.body], [401, SIGNED_OUT]);
    const wrong = await within(h.call('POST /api/team/heartbeat', { body: beat({ wait: 25, pcId: PC_B }) }), 1000);
    assert.strictEqual(wrong.body.code, 'wrong_pc');
  });
});

// ── The clip job: motion-JPEG uploads, turned into mp4s at done ─────────────────────────────────────────────────────────────

const { EventEmitter } = require('node:events');
const { execFileSync } = require('node:child_process');

/** One JPEG picture's start: SOI, a JFIF APP0, a tiny DQT, a frame header of w by h (`sof`: C0 baseline, C2 progressive), a scan header, `pad` bytes of data and EOI. Not a decodable picture: the server reads the frame header. */
const jpegFrame = (w = 960, h = 540, { sof = 0xc0, pad = 200 } = {}) => {
  const head = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0xff, 0xdb, 0x00, 0x03, 0x00]);
  const frame = Buffer.from([0xff, sof, 0x00, 0x11, 0x08, h >> 8, h & 255, w >> 8, w & 255, 0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01]);
  const scan = Buffer.from([0xff, 0xda, 0x00, 0x0c, 0x03, 0x01, 0x00, 0x02, 0x11, 0x03, 0x11, 0x00, 0x3f, 0x00]);
  return Buffer.concat([head, frame, scan, Buffer.alloc(pad, 5), Buffer.from([0xff, 0xd9])]);
};
const fakeClip = (frames = 3, w = 960, h = 540) => Buffer.concat(Array.from({ length: frames }, () => jpegFrame(w, h)));

/** Is a real ffmpeg with an mjpeg and an x264 encoder here (and nice)? The real-transcode tests skip with a printed line when not. */
const REAL_FFMPEG = (() => {
  for (const candidate of [process.env.FFMPEG, '/usr/bin/ffmpeg', '/usr/local/bin/ffmpeg'].filter(Boolean)) {
    try {
      const encoders = execFileSync(candidate, ['-hide_banner', '-encoders'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
      if (/libx264/.test(encoders) && /\bmjpeg\b/.test(encoders) && fs.existsSync('/usr/bin/nice')) return candidate;
    } catch { /* not this one */ }
  }
  return null;
})();
if (!REAL_FFMPEG) console.log('SKIP the real-ffmpeg clip tests: no ffmpeg with libx264 and mjpeg (and /usr/bin/nice) on this machine');
const realTest = (name, fn) => test(name, { skip: REAL_FFMPEG ? false : 'no ffmpeg with libx264 and mjpeg here' }, fn);

/** A tiny real motion-JPEG file made by ffmpeg: `seconds` of a test pattern at 30 fps, `w` by `h`. */
function realMjpeg(dir, { w = 320, h = 180, seconds = 1, name = 'real.mjpeg' } = {}) {
  const file = path.join(dir, name);
  execFileSync(REAL_FFMPEG, ['-nostdin', '-hide_banner', '-loglevel', 'error', '-y', '-f', 'lavfi', '-i', `testsrc2=size=${w}x${h}:rate=30`, '-t', String(seconds), '-c:v', 'mjpeg', '-q:v', '5', '-f', 'mjpeg', file]);
  return fs.readFileSync(file);
}

/** An mp4 of `size` bytes in shape: ftyp, moov and an mdat with the rest (`emptyMdat`: the video of no pictures ffmpeg writes when it decoded nothing). */
function fakeMp4(size, emptyMdat = false) {
  const box = (type, payload) => { const b = Buffer.alloc(8 + payload.length); b.writeUInt32BE(b.length, 0); b.write(type, 4, 'latin1'); payload.copy(b, 8); return b; };
  const ftyp = box('ftyp', Buffer.concat([Buffer.from('isom'), Buffer.alloc(4), Buffer.from('isomiso2')]));
  const moov = box('moov', Buffer.alloc(8, 1));
  const mdat = box('mdat', Buffer.alloc(emptyMdat ? 0 : Math.max(1, size - ftyp.length - moov.length - 8), 9));
  return Buffer.concat([ftyp, moov, mdat]);
}

/**
 * A stand-in for child_process.spawn: `behave(call)` decides what the "ffmpeg" does. call = { cmd, args, opts, crf, output }. It returns { size } (write that many bytes to the output and exit 0),
 * { code } (exit with it), { error } (the process cannot be started), or { hang: true } (runs until killed). Records every call.
 */
function fakeSpawn(behave) {
  const calls = [];
  let active = 0;
  let mostAtOnce = 0;
  const spawn = (cmd, args, opts) => {
    const call = { cmd, args, opts, crf: Number(args[args.indexOf('-crf') + 1]), output: args[args.length - 1], killed: false };
    calls.push(call);
    const child = new EventEmitter();
    child.stderr = new EventEmitter();
    child.kill = (sig) => { call.killed = sig || true; setImmediate(() => child.emit('close', null, sig)); return true; };
    const what = behave(call) || { size: 1000 };
    active++;
    mostAtOnce = Math.max(mostAtOnce, active);
    setTimeout(() => {
      if (what.hang) return;
      active--;
      if (what.error) return child.emit('error', Object.assign(new Error('spawn failed'), { code: what.error }));
      if (what.stderr) child.stderr.emit('data', Buffer.from(what.stderr));
      if (what.size) fs.writeFileSync(call.output, fakeMp4(what.size, what.emptyMdat));
      return child.emit('close', what.code ?? 0, null);
    }, what.delayMs ?? 5);
    return child;
  };
  return { spawn, calls, mostAtOnce: () => mostAtOnce };
}
const clipsWith = (fake, extra = {}) => ({ mount: { ffmpeg: '/opt/test/ffmpeg', spawn: fake.spawn, ffmpegTimeoutMs: 2000, ...extra } });
const doneClips = (h, id, files, extra = {}, callOpts = {}) => h.call('POST /api/team/jobs/:id/done', { params: { id }, body: { files, log: 'the game ran', timings: { downloadS: 3, runS: 20 }, ...extra }, ...callOpts });

test('checkMjpeg reads the first picture\'s size and refuses anything that does not start as a motion-JPEG clip', () => {
  assert.deepStrictEqual(checkMjpeg(jpegFrame(960, 540)), { width: 960, height: 540 });
  assert.deepStrictEqual(checkMjpeg(fakeClip(5, 16, 4096)), { width: 16, height: 4096 });
  assert.deepStrictEqual(checkMjpeg(jpegFrame(640, 360, { sof: 0xc2 })), { width: 640, height: 360 }, 'a progressive picture has its size in an SOF2 header');
  const bad = {
    'empty': Buffer.alloc(0), 'text': Buffer.from('definitely not a video, but long enough to pass a length check'), 'png': png(), 'one byte': Buffer.from([0xff]), 'the marker alone': Buffer.from([0xff, 0xd8]),
    'no jpeg marker': Buffer.concat([Buffer.from([0x00, 0xd8, 0xff, 0xe0]), jpegFrame().subarray(4)]), 'marker backwards': Buffer.concat([Buffer.from([0xd8, 0xff]), jpegFrame().subarray(2)]),
    'too narrow': jpegFrame(15, 540), 'too short': jpegFrame(960, 15), 'too wide': jpegFrame(4097, 540), 'too tall': jpegFrame(960, 4097), 'zero': jpegFrame(0, 0),
    'no frame header': Buffer.concat([jpegFrame().subarray(0, 25), Buffer.alloc(200, 0)]), 'scan before any frame header': Buffer.from([0xff, 0xd8, 0xff, 0xda, 0x00, 0x04, 0x00, 0x00, 0x01, 0x02, 0x03, 0x04]),
    'cut off in the frame header': jpegFrame().subarray(0, 32),
    'a frame header past the first 64 KB': Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xfe, 0xff, 0xff]), Buffer.alloc(0xfffd, 1), Buffer.from([0xff, 0xc0, 0x00, 0x11, 0x08, 0x02, 0x1c, 0x03, 0xc0, 0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01])]),
  };
  for (const [what, buf] of Object.entries(bad)) assert.ok(checkMjpeg(buf).error, what);
  assert.match(checkMjpeg(jpegFrame(5000, 540)).error, /5000 by 540/);
  assert.ok(checkMjpeg('a string').error && checkMjpeg(null).error);
  const marker = Buffer.from([0xff, 0xd8, 0xff, 0xfe, 0x00, 0x02]);   // a comment segment with nothing in it, then the frame header
  assert.deepStrictEqual(checkMjpeg(Buffer.concat([marker, jpegFrame().subarray(2)])), { width: 960, height: 540 }, 'segments before the frame header are skipped by their length');
});

test('ffmpegArgs is the contract\'s command, one argument each', () => {
  assert.deepStrictEqual(ffmpegArgs('/r/j/in.mjpeg', '/r/j/.out.part', 26), [
    '-nostdin', '-hide_banner', '-loglevel', 'error', '-y', '-f', 'mjpeg', '-framerate', '30', '-i', '/r/j/in.mjpeg', '-t', '10', '-vf', "scale='min(960,iw)':-2",
    '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '26', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', '-an', '-f', 'mp4', '/r/j/.out.part']);
  assert.strictEqual(ffmpegArgs('a', 'b', 32)[ffmpegArgs('a', 'b', 32).indexOf('-crf') + 1], '32');
});

test('a clip job is offered after shots and before bench, and before any other kind', async () => {
  await withHarness(async (h) => {
    const bench = await h.makeJob({ kind: 'bench', title: 'a bench', payload: BENCH });
    const odd = await h.makeJob({ kind: 'stutter', title: 'a kind nobody knows yet' });
    const clip = await h.makeJob(newClip());
    const offered = async () => (await h.call('POST /api/team/heartbeat', { body: beat() })).body.data.offer;
    assert.deepStrictEqual([(await offered()).id, (await offered()).kind], [clip, 'clip'], 'a clip job goes ahead of the older bench and the odd kind');
    const shots = await h.makeJob({ title: 'shots, the newest of all' });
    assert.strictEqual((await offered()).id, shots, 'but shots go first');
    await h.call('POST /api/team/jobs/:id/claim', { params: { id: shots }, body: { pcId: PC_A } });
    assert.strictEqual((await offered()).id, clip);
    await h.call('POST /api/team/jobs/:id/claim', { params: { id: clip }, body: { pcId: PC_A } });
    assert.strictEqual((await offered()).id, bench);
    await h.call('POST /api/team/jobs/:id/claim', { params: { id: bench }, body: { pcId: PC_A } });
    assert.strictEqual((await offered()).id, odd);
    const c = await h.call('POST /api/team/jobs/:id/claim', { params: { id: clip }, body: { pcId: PC_A } });
    assert.deepStrictEqual(c.body.data.payload, CLIP, 'the claim hands the clip payload as it was made');
  });
});

test('a clip upload is stored under the job folder as it came, and answers its size and the first picture\'s', async () => {
  await withHarness(async (h) => {
    const id = await h.runningJob({ over: newClip() });
    const clip = fakeClip(4, 960, 540);
    const r = await h.uploadClip(id, 'slow_wraith.mjpeg', clip);
    assert.strictEqual(r.statusCode, 200, JSON.stringify(r.body));
    assert.deepStrictEqual(r.body, { success: true, data: { name: 'slow_wraith.mjpeg', bytes: clip.length, width: 960, height: 540 } });
    assert.ok(fs.readFileSync(path.join(h.jobFolder(id), 'slow_wraith.mjpeg')).equals(clip));
    assert.deepStrictEqual(fs.readdirSync(h.jobFolder(id)), ['slow_wraith.mjpeg'], 'no half-written part is left');
    assert.strictEqual(fs.statSync(h.jobFolder(id)).mode & 0o027, 0, 'the folder is not writable by the group or readable by others');
    assert.strictEqual(fs.statSync(path.join(h.jobFolder(id), 'slow_wraith.mjpeg')).mode & 0o007, 0, 'the file is not readable by others');
    const again = await h.uploadClip(id, 'slow_wraith.mjpeg', fakeClip(2, 640, 360), { headers: { 'x-team-pc': PC_A } });   // the same name again replaces it
    assert.deepStrictEqual([again.statusCode, again.body.data.width], [200, 640]);
    assert.strictEqual(fs.readFileSync(path.join(h.jobFolder(id), 'slow_wraith.mjpeg')).length, fakeClip(2, 640, 360).length);
    h.advance(MIN);
    await h.uploadClip(id, 'fast_wraith.mjpeg', clip, { query: { pcId: PC_A } });
    assert.strictEqual(h.jobs[0].heartbeat_at, h.now(), 'an upload renews the heartbeat');
    assert.strictEqual((await h.uploadClip(id, `a${'b'.repeat(59)}.mjpeg`, clip)).statusCode, 200, '60 characters before the extension is allowed');
    assert.strictEqual((await h.uploadClip(id, '0-9_az.mjpeg', clip)).statusCode, 200);
    assert.deepStrictEqual(fs.readdirSync(h.jobFolder(id)).sort(), ['0-9_az.mjpeg', `a${'b'.repeat(59)}.mjpeg`, 'fast_wraith.mjpeg', 'slow_wraith.mjpeg']);
  });
});

test('a clip upload with a bad name is 400 and writes nothing, whatever the name tries', async () => {
  await withHarness(async (h) => {
    const id = await h.runningJob({ over: newClip() });
    const bad = ['Wraith.mjpeg', 'wraith.MJPEG', 'wraith.mjpg', 'wraith.mp4', 'wraith', '.mjpeg', '_wraith.mjpeg', '-wraith.mjpeg', 'a b.mjpeg', 'a/b.mjpeg', '../x.mjpeg', '..%2fx.mjpeg', 'a\\b.mjpeg', 'wraith.mjpeg.exe',
      'wraith..mjpeg', `${'a'.repeat(61)}.mjpeg`, 'ü.mjpeg', 'a.mjpeg\u0000', '.hidden.mjpeg', 'wraith.mjpeg.png'];
    for (const name of bad) {
      const r = await h.uploadClip(id, name, fakeClip());
      assert.strictEqual(r.statusCode, 400, JSON.stringify(name));
      assert.strictEqual(r.body.code, 'bad_request');
      assert.match(r.body.error, /\.mjpeg/, 'the answer names the clip extension');
    }
    assert.ok(!fs.existsSync(h.jobFolder(id)) || fs.readdirSync(h.jobFolder(id)).length === 0);
  });
});

test('a clip upload must be video/x-motion-jpeg and no more than 48 MB, refused before the body is read when it says so', async () => {
  await withHarness(async (h) => {
    const id = await h.runningJob({ over: newClip() });
    for (const type of ['image/png', 'video/mp4', 'application/octet-stream', 'application/json', '', undefined]) {
      const r = await h.uploadClip(id, 'a.mjpeg', fakeClip(), { type, headers: type === undefined ? { 'content-type': undefined } : {} });
      assert.deepStrictEqual([r.statusCode, r.body.code], [415, 'bad_type'], String(type));
    }
    assert.strictEqual((await h.uploadClip(id, 'a.mjpeg', fakeClip(), { type: 'VIDEO/X-MOTION-JPEG; charset=binary' })).statusCode, 200, 'media type is case-insensitive and may carry parameters');
    assert.strictEqual((await h.upload(id, 'a.png', png(), { type: 'video/x-motion-jpeg' })).statusCode, 415, 'a picture is still image/png');
    // declared too large: answered at once, the stream is never read
    const declared = await h.call('PUT /api/team/jobs/:id/files/:name', { params: { id, name: 'big.mjpeg' }, raw: fakeClip(), headers: { 'content-type': 'video/x-motion-jpeg', 'content-length': String(CLIP_MAX_BYTES + 1) } });
    assert.deepStrictEqual([declared.statusCode, declared.body.code, declared.body.error, declared.headers.Connection], [413, 'too_large', 'That clip is too large (the limit is 48 MB).', 'close']);
    // the limit itself passes the size check
    const head = jpegFrame(960, 540);
    const atLimit = Buffer.concat([head, Buffer.alloc(CLIP_MAX_BYTES - head.length, 1)]);
    assert.strictEqual(atLimit.length, CLIP_MAX_BYTES);
    const ok = await h.uploadClip(id, 'limit.mjpeg', atLimit);
    assert.deepStrictEqual([ok.statusCode, ok.body.data.bytes], [200, CLIP_MAX_BYTES]);
    // no content-length (chunked): counted as it arrives, and reading stops at the cap
    let pulled = 0;
    const megabyte = Buffer.alloc(1024 * 1024, 1);
    function* flood() { yield head; for (let i = 0; i < 300; i++) { pulled++; yield megabyte; } }
    const chunked = await h.call('PUT /api/team/jobs/:id/files/:name', { params: { id, name: 'flood.mjpeg' }, chunks: flood(), headers: { 'content-type': 'video/x-motion-jpeg' } });
    assert.deepStrictEqual([chunked.statusCode, chunked.body.code], [413, 'too_large']);
    assert.ok(pulled < 100, `stopped reading early (${pulled} of 300 megabytes pulled)`);
    assert.deepStrictEqual(fs.readdirSync(h.jobFolder(id)).sort(), ['a.mjpeg', 'limit.mjpeg'], 'nothing of the refused uploads was kept');
  });
});

test('a clip upload that is not a motion-JPEG clip is 400 with a reason', async () => {
  await withHarness(async (h) => {
    const id = await h.runningJob({ over: newClip() });
    const cases = {
      'a png': png(), 'text': Buffer.from('GIF89a this is not a clip at all, only long enough to pass a length check'), 'empty': Buffer.alloc(0), 'a mp4': Buffer.concat([Buffer.from([0, 0, 0, 24]), Buffer.from('ftypisom'), Buffer.alloc(60)]),
      'a picture of 8 pixels': jpegFrame(8, 8), 'a picture of 9000 pixels': jpegFrame(9000, 600), 'cut off in the headers': jpegFrame().subarray(0, 30),
    };
    for (const [what, buf] of Object.entries(cases)) {
      const r = await h.uploadClip(id, 'p.mjpeg', buf);
      assert.strictEqual(r.statusCode, 400, what);
      assert.deepStrictEqual([r.body.success, r.body.code], [false, 'bad_request']);
      assert.ok(r.body.error.length > 10, what);
    }
    assert.ok(!fs.existsSync(path.join(h.jobFolder(id), 'p.mjpeg')));
  });
});

test('a clip is only for a clip job, and a clip job takes no pictures', async () => {
  await withHarness(async (h) => {
    const shots = await h.runningJob();
    const r = await h.uploadClip(shots, 'a.mjpeg', fakeClip());
    assert.deepStrictEqual([r.statusCode, r.body.code], [400, 'bad_request']);
    assert.match(r.body.error, /pictures, not video clips/);
    const bench = await h.runningJob({ over: newBench(), accountId: HELIX });
    assert.strictEqual((await h.uploadClip(bench, 'a.mjpeg', fakeClip(), { accountId: HELIX })).statusCode, 400);
    assert.ok(!fs.existsSync(path.join(h.jobFolder(shots), 'a.mjpeg')) && !fs.existsSync(path.join(h.jobFolder(bench), 'a.mjpeg')));
    assert.strictEqual((await h.upload(shots, 'a.png', png())).statusCode, 200, 'a shots job still takes its pictures');
    const clip = await h.runningJob({ over: newClip(), accountId: WAR });
    const png400 = await h.upload(clip, 'a.png', png(), { accountId: WAR });
    assert.deepStrictEqual([png400.statusCode, png400.body.code], [400, 'bad_request']);
    assert.match(png400.body.error, /video clips/);
    assert.ok(!fs.existsSync(path.join(h.jobFolder(clip), 'a.png')));
  });
});

test('a clip upload is only for the PC that holds the job, and only while it runs', async () => {
  await withHarness(async (h) => {
    const id = await h.runningJob({ over: newClip() });
    const otherPc = await h.uploadClip(id, 'a.mjpeg', fakeClip(), { pcId: PC_A2 });
    assert.deepStrictEqual([otherPc.statusCode, otherPc.body.code], [403, 'not_your_job']);
    const otherAccount = await h.uploadClip(id, 'a.mjpeg', fakeClip(), { accountId: HELIX });
    assert.deepStrictEqual([otherAccount.statusCode, otherAccount.body.code], [403, 'not_your_job']);
    assert.strictEqual((await h.uploadClip(id, 'a.mjpeg', fakeClip(), { headers: { 'x-team-pc': PC_B } })).body.code, 'wrong_pc');
    assert.strictEqual((await h.uploadClip(id, 'a.mjpeg', fakeClip())).statusCode, 200);
    const queued = await h.makeJob(newClip());
    const q = await h.uploadClip(queued, 'a.mjpeg', fakeClip());
    assert.deepStrictEqual([q.statusCode, q.body.code], [409, 'not_running']);
    assert.strictEqual((await h.uploadClip('c'.repeat(12), 'a.mjpeg', fakeClip())).statusCode, 404);
    const cancelled = await h.runningJob({ pcId: PC_B, accountId: HELIX, over: newClip() });
    await h.internal('POST /internal/team/jobs/:id/cancel', { params: { id: cancelled } });
    const c = await h.uploadClip(cancelled, 'a.mjpeg', fakeClip(), { accountId: HELIX });
    assert.deepStrictEqual([c.statusCode, c.body.code, c.body.error], [409, 'not_running', 'This job was cancelled.']);
    assert.ok(!fs.existsSync(path.join(h.jobFolder(queued), 'a.mjpeg')) && !fs.existsSync(path.join(h.jobFolder(cancelled), 'a.mjpeg')));
  });
});

test('a clip job takes at most 40 files in all (clips and videos count), but one may be replaced', async () => {
  await withHarness(async (h) => {
    const id = await h.runningJob({ over: newClip() });
    fs.mkdirSync(h.jobFolder(id), { recursive: true });
    for (let i = 0; i < FILES_PER_JOB - 1; i++) fs.writeFileSync(path.join(h.jobFolder(id), `c_${i}.mjpeg`), fakeClip());
    fs.writeFileSync(path.join(h.jobFolder(id), 'c_0.mp4'), 'a video');
    const extra = await h.uploadClip(id, 'one_more.mjpeg', fakeClip());
    assert.deepStrictEqual([extra.statusCode, extra.body.code, extra.body.error], [409, 'too_many', 'A job takes at most 40 clips.']);
    assert.strictEqual((await h.uploadClip(id, 'c_3.mjpeg', fakeClip(1))).statusCode, 200, 'replacing one is not adding one');
    assert.strictEqual(fs.readdirSync(h.jobFolder(id)).length, FILES_PER_JOB);
  });
});

test('the runner sees a running clip job\'s videos, never its raw clips or half-made parts', async () => {
  await withHarness(async (h) => {
    const id = await h.runningJob({ over: newClip() });
    await h.uploadClip(id, 'a.mjpeg', fakeClip());
    fs.writeFileSync(path.join(h.jobFolder(id), 'b.mp4'), 'a finished video');
    fs.writeFileSync(path.join(h.jobFolder(id), '.c.12345678.part'), 'half');
    fs.writeFileSync(path.join(h.jobFolder(id), 'notes.txt'), 'not ours');
    const got = (await h.internal('GET /internal/team/jobs/:id', { params: { id } })).body.data;
    assert.deepStrictEqual(got.files.map((f) => [f.name, f.bytes, f.path]), [['b.mp4', 16, path.join(h.resultsDir, id, 'b.mp4')]]);
  });
});

// The transcode, with a stand-in for ffmpeg (what it is asked, how it ends); the real one is further down.

test('done turns each clip into an mp4 with the contract\'s command under nice, one at a time, and keeps only the mp4', async () => {
  const fake = fakeSpawn(() => ({ size: 4321 }));
  await withHarness(clipsWith(fake), async (h) => {
    const id = await h.runningJob({ over: newClip() });
    await h.uploadClip(id, 'slow_wraith.mjpeg', fakeClip(3));
    await h.uploadClip(id, 'fast_wraith.mjpeg', fakeClip(2));
    h.advance(90_000);
    const done = await doneClips(h, id, ['slow_wraith.mjpeg', 'fast_wraith.mjpeg', 'slow_wraith.mjpeg']);
    assert.deepStrictEqual([done.statusCode, done.body], [200, { success: true, data: { id, status: 'done' } }]);
    assert.strictEqual(fake.calls.length, 2, 'a clip named twice is made once');
    const dir = path.join(h.resultsDir, id);
    const [first, second] = fake.calls;
    for (const call of fake.calls) {
      assert.strictEqual(call.cmd, '/usr/bin/nice');
      assert.deepStrictEqual(call.args.slice(0, 3), ['-n', '10', '/opt/test/ffmpeg'], 'nice -n 10 and the configured ffmpeg');
      assert.deepStrictEqual(call.args.slice(3, 10), ['-nostdin', '-hide_banner', '-loglevel', 'error', '-y', '-f', 'mjpeg']);
      assert.strictEqual(call.opts.cwd, dir, 'it works in the job\'s own folder');
      assert.strictEqual(call.opts.env.HOME, dir, 'and a HOME that is the job\'s folder: it needs nothing else writable');
      assert.deepStrictEqual(Object.keys(call.opts.env).sort(), ['AV_LOG_FORCE_NOCOLOR', 'HOME', 'LANG', 'PATH'], 'a bare environment: nothing of the service\'s (no secrets) reaches it');
      assert.strictEqual(call.opts.stdio[0], 'ignore', 'no standard input');
      assert.strictEqual(call.opts.shell, undefined, 'never a shell');
      assert.strictEqual(call.crf, 26);
    }
    assert.deepStrictEqual(first.args.slice(3), ffmpegArgs(path.join(dir, 'slow_wraith.mjpeg'), first.output, 26), 'exactly the contract\'s arguments');
    assert.strictEqual(first.args[first.args.indexOf('-i') + 1], path.join(dir, 'slow_wraith.mjpeg'), 'in the order the PC named them');
    assert.strictEqual(second.args[second.args.indexOf('-i') + 1], path.join(dir, 'fast_wraith.mjpeg'));
    assert.ok(path.dirname(first.output) === dir && path.basename(first.output).startsWith('.slow_wraith.') && first.output.endsWith('.part'), 'it writes a part file in the job folder, then renames it');
    assert.deepStrictEqual(fs.readdirSync(dir).sort(), ['fast_wraith.mp4', 'slow_wraith.mp4'], 'the mjpegs and the parts are gone, the videos stay');
    assert.strictEqual(fs.statSync(path.join(dir, 'slow_wraith.mp4')).mode & 0o007, 0, 'not readable by others');
    const job = h.jobs[0];
    assert.deepStrictEqual([job.status, job.error, job.finished_at], ['done', null, h.now()]);
    const result = JSON.parse(job.result);
    assert.deepStrictEqual(result.files, [{ name: 'slow_wraith.mp4', bytes: 4321, crf: 26 }, { name: 'fast_wraith.mp4', bytes: 4321, crf: 26 }]);
    assert.strictEqual(result.log, 'the game ran');
    assert.deepStrictEqual(result.timings, { downloadS: 3, runS: 20 });
    const got = (await h.internal('GET /internal/team/jobs/:id', { params: { id } })).body.data;
    assert.deepStrictEqual(got.files.map((f) => [f.name, f.bytes, f.path]), [['fast_wraith.mp4', 4321, path.join(dir, 'fast_wraith.mp4')], ['slow_wraith.mp4', 4321, path.join(dir, 'slow_wraith.mp4')]], 'the runner is handed the videos with their paths');
    // a resent done (the answer got lost) is the same success and starts nothing
    assert.deepStrictEqual((await doneClips(h, id, ['slow_wraith.mjpeg'])).body, { success: true, data: { id, status: 'done' } });
    assert.strictEqual(fake.calls.length, 2);
  });
});

test('an mp4 that is not under 8 MB is made again at crf 32, and the smaller one is kept', async () => {
  const fake = fakeSpawn((call) => ({ size: call.crf === 26 ? MP4_MAX_BYTES + 1 : MP4_MAX_BYTES - 1 }));
  await withHarness(clipsWith(fake), async (h) => {
    const id = await h.runningJob({ over: newClip() });
    await h.uploadClip(id, 'a.mjpeg', fakeClip());
    const done = await doneClips(h, id, ['a.mjpeg']);
    assert.strictEqual(done.statusCode, 200, JSON.stringify(done.body));
    assert.deepStrictEqual(fake.calls.map((c) => c.crf), [26, 32], 'the second try is the same command at crf 32');
    assert.strictEqual(fake.calls[1].args[fake.calls[1].args.indexOf('-i') + 1], fake.calls[0].args[fake.calls[0].args.indexOf('-i') + 1], 'from the same clip');
    assert.deepStrictEqual(JSON.parse(h.jobs[0].result).files, [{ name: 'a.mp4', bytes: MP4_MAX_BYTES - 1, crf: 32 }]);
    assert.strictEqual(fs.statSync(path.join(h.resultsDir, id, 'a.mp4')).size, MP4_MAX_BYTES - 1);
    assert.deepStrictEqual(fs.readdirSync(path.join(h.resultsDir, id)), ['a.mp4']);
  });
  const exact = fakeSpawn(() => ({ size: MP4_MAX_BYTES }));   // "under 8 MB": the limit itself is over
  await withHarness(clipsWith(exact), async (h) => {
    const id = await h.runningJob({ over: newClip() });
    await h.uploadClip(id, 'a.mjpeg', fakeClip());
    await doneClips(h, id, ['a.mjpeg']);
    assert.strictEqual(exact.calls.length, 2, 'a video of exactly the limit is tried again');
  });
  const under = fakeSpawn(() => ({ size: MP4_MAX_BYTES - 1 }));
  await withHarness(clipsWith(under), async (h) => {
    const id = await h.runningJob({ over: newClip() });
    await h.uploadClip(id, 'a.mjpeg', fakeClip());
    await doneClips(h, id, ['a.mjpeg']);
    assert.strictEqual(under.calls.length, 1, 'a video under the limit is made once');
    assert.strictEqual(MP4_MAX_BYTES, 8_000_000, 'Discord\'s 8 MB, counted the careful way');
  });
});

test('a video that is still over 8 MB at crf 32 fails the job with a readable reason, and nothing is kept', async () => {
  const fake = fakeSpawn(() => ({ size: 9_500_000 }));
  await withHarness(clipsWith(fake), async (h) => {
    const id = await h.runningJob({ over: newClip() });
    await h.uploadClip(id, 'slow_wraith.mjpeg', fakeClip());
    await h.uploadClip(id, 'fast_wraith.mjpeg', fakeClip());
    const done = await doneClips(h, id, ['slow_wraith.mjpeg', 'fast_wraith.mjpeg'], { log: 'the PC log' });
    assert.deepStrictEqual([done.statusCode, done.body.code, done.body.success], [400, 'bad_request', false]);
    assert.match(done.body.error, /^The video of slow_wraith is 9\.5 MB even at the lower quality, and Discord takes at most 8 MB\./);
    assert.deepStrictEqual(fake.calls.map((c) => c.crf), [26, 32], 'it stops at the first clip that cannot be made small enough');
    const job = h.jobs[0];
    assert.deepStrictEqual([job.status, job.error], ['failed', done.body.error]);
    assert.strictEqual(JSON.parse(job.result).log, 'the PC log');
    assert.ok(!fs.existsSync(h.jobFolder(id)) || fs.readdirSync(h.jobFolder(id)).length === 0, 'the clips and the parts are removed with the job');
    const again = await doneClips(h, id, ['slow_wraith.mjpeg']);
    assert.deepStrictEqual([again.statusCode, again.body.code], [409, 'not_running'], 'a resent done reaches a failed job');
  });
});

test('a clip that does not turn into a video fails the job with a readable reason and ffmpeg\'s words in the log, never in the reason', async () => {
  const fake = fakeSpawn(() => ({ code: 1, stderr: '[mjpeg @ 0x55] unable to decode APP fields: Invalid data found when processing input\n/home/ubuntu/death-muffin/secret-path: Invalid data' }));
  await withHarness(clipsWith(fake), async (h) => {
    const id = await h.runningJob({ over: newClip() });
    await h.uploadClip(id, 'a.mjpeg', fakeClip());
    await h.uploadClip(id, 'b.mjpeg', fakeClip());
    const done = await doneClips(h, id, ['a.mjpeg', 'b.mjpeg'], { log: 'the PC log' });
    assert.deepStrictEqual([done.statusCode, done.body.code], [400, 'bad_request']);
    assert.strictEqual(done.body.error, 'The clip a could not be turned into a video (the file may be damaged or cut off).');
    assert.ok(!/ffmpeg|\/home|0x55/.test(done.body.error), 'no program output or path in the reason');
    assert.strictEqual(fake.calls.length, 1, 'no second try for a clip ffmpeg cannot read');
    const job = h.jobs[0];
    assert.deepStrictEqual([job.status, job.error], ['failed', done.body.error]);
    const log = JSON.parse(job.result).log;
    assert.ok(log.startsWith('the PC log') && log.includes('Invalid data found when processing input'), 'what ffmpeg said is in the stored log');
    assert.ok(!fs.existsSync(h.jobFolder(id)) || fs.readdirSync(h.jobFolder(id)).length === 0, 'both clips and the part are removed');
    assert.deepStrictEqual((await h.internal('GET /internal/team/jobs/:id', { params: { id } })).body.data.files, []);
  });
  const empty = fakeSpawn(() => ({ code: 0, size: 0 }));   // ffmpeg exits 0 and writes nothing
  await withHarness(clipsWith(empty), async (h) => {
    const id = await h.runningJob({ over: newClip() });
    await h.uploadClip(id, 'a.mjpeg', fakeClip());
    const done = await doneClips(h, id, ['a.mjpeg']);
    assert.deepStrictEqual([done.statusCode, h.jobs[0].status], [400, 'failed']);
  });
  const noPictures = fakeSpawn(() => ({ code: 0, size: 300, emptyMdat: true }));   // exit 0 and a video of no pictures: ffmpeg decoded nothing and did not mind
  await withHarness(clipsWith(noPictures), async (h) => {
    const id = await h.runningJob({ over: newClip() });
    await h.uploadClip(id, 'a.mjpeg', fakeClip());
    const done = await doneClips(h, id, ['a.mjpeg']);
    assert.deepStrictEqual([done.statusCode, done.body.error, h.jobs[0].status], [400, 'The clip a could not be turned into a video (the file may be damaged or cut off).', 'failed']);
    assert.ok(!fs.existsSync(h.jobFolder(id)) || fs.readdirSync(h.jobFolder(id)).length === 0, 'the empty video is not kept');
  });
});

test('mp4HoldsVideo wants ftyp, moov and an mdat with data, whole', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'team-mp4-'));
  try {
    const write = (name, buf) => { const f = path.join(dir, name); fs.writeFileSync(f, buf); return f; };
    assert.strictEqual(await mp4HoldsVideo(write('ok.mp4', fakeMp4(5000))), true);
    assert.strictEqual(await mp4HoldsVideo(write('empty.mp4', fakeMp4(300, true))), false, 'an mdat of 8 bytes holds nothing');
    assert.strictEqual(await mp4HoldsVideo(write('cut.mp4', fakeMp4(5000).subarray(0, 4000))), false, 'a box that runs past the end of the file');
    assert.strictEqual(await mp4HoldsVideo(write('nomoov.mp4', fakeMp4(5000).subarray(0, 24))), false);
    assert.strictEqual(await mp4HoldsVideo(write('text.mp4', Buffer.from('this is not an mp4 file at all, but it is long enough to read'))), false);
    assert.strictEqual(await mp4HoldsVideo(write('empty-file.mp4', Buffer.alloc(0))), false);
    assert.strictEqual(await mp4HoldsVideo(path.join(dir, 'missing.mp4')), false);
    const big = fakeMp4(5000);   // a 64-bit mdat size (size field 1, then the length) and a last box with size 0 (to the end of the file)
    const ftypMoov = big.subarray(0, 40);
    const mdat64 = Buffer.alloc(16 + 100, 3); mdat64.writeUInt32BE(1, 0); mdat64.write('mdat', 4, 'latin1'); mdat64.writeBigUInt64BE(BigInt(mdat64.length), 8);
    assert.strictEqual(await mp4HoldsVideo(write('wide.mp4', Buffer.concat([ftypMoov, mdat64]))), true);
    const toEnd = Buffer.alloc(8 + 50, 3); toEnd.writeUInt32BE(0, 0); toEnd.write('mdat', 4, 'latin1');
    assert.strictEqual(await mp4HoldsVideo(write('toend.mp4', Buffer.concat([ftypMoov, toEnd]))), true);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('ffmpeg that runs past its limit is killed and the job fails; one that is not installed fails it too, in plain words', async () => {
  const hang = fakeSpawn(() => ({ hang: true }));
  await withHarness(clipsWith(hang, { ffmpegTimeoutMs: 60 }), async (h) => {
    const id = await h.runningJob({ over: newClip() });
    await h.uploadClip(id, 'a.mjpeg', fakeClip());
    const done = await doneClips(h, id, ['a.mjpeg']);
    assert.strictEqual(hang.calls[0].killed, 'SIGKILL', 'the process is killed');
    assert.deepStrictEqual([done.statusCode, h.jobs[0].status], [400, 'failed']);
    assert.strictEqual(done.body.error, 'The clip a took more than 1 second to turn into a video, so it was stopped.', 'the limit is said in seconds (a real one is 120)');
    assert.strictEqual(mountTeamJobs.FFMPEG_TIMEOUT_MS, 120_000, 'the contract\'s 120 s');
    assert.ok(!fs.existsSync(h.jobFolder(id)) || fs.readdirSync(h.jobFolder(id)).length === 0);
  });
  const missing = fakeSpawn(() => ({ error: 'ENOENT' }));
  await withHarness(clipsWith(missing), async (h) => {
    const id = await h.runningJob({ over: newClip() });
    await h.uploadClip(id, 'a.mjpeg', fakeClip());
    const done = await doneClips(h, id, ['a.mjpeg']);
    assert.deepStrictEqual([done.statusCode, h.jobs[0].status, done.body.error], [400, 'failed', 'The server cannot make videos just now (its video tool is not available).']);
  });
  await withHarness({ mount: { ffmpeg: '/opt/test/ffmpeg', spawn: () => { throw Object.assign(new Error('EACCES'), { code: 'EACCES' }); } } }, async (h) => {   // spawn itself throws
    const id = await h.runningJob({ over: newClip() });
    await h.uploadClip(id, 'a.mjpeg', fakeClip());
    const done = await doneClips(h, id, ['a.mjpeg']);
    assert.deepStrictEqual([done.statusCode, h.jobs[0].status, done.body.error], [400, 'failed', 'The server cannot make videos just now (its video tool is not available).']);
  });
  // runFfmpeg on its own: how a process ended, and it never throws
  const real = await runFfmpeg({ ffmpeg: '/bin/sh', args: ['-c', 'echo oops >&2; exit 3'], cwd: os.tmpdir(), timeoutMs: 5000 });
  assert.deepStrictEqual([real.ok, real.why], [false, 'failed']);
  assert.match(real.note, /oops/);
  assert.match(real.note, /code 3/);
  const none = await runFfmpeg({ ffmpeg: '/nonexistent/ffmpeg', args: [], cwd: os.tmpdir(), timeoutMs: 5000 });
  assert.deepStrictEqual([none.ok, none.why], [false, 'failed'], 'nice itself starts and then cannot run the program: a failed run, with nice\'s words');
  assert.deepStrictEqual(await runFfmpeg({ ffmpeg: '/bin/true', args: [], cwd: os.tmpdir(), timeoutMs: 5000 }).then((r) => r.ok), true);
  const slow = await runFfmpeg({ ffmpeg: '/bin/sleep', args: ['30'], cwd: os.tmpdir(), timeoutMs: 100 });
  assert.deepStrictEqual([slow.ok, slow.why], [false, 'timeout'], 'a process that keeps running is killed at the limit');
});

test('a done that names a clip never uploaded, or nothing, or something odd is 400 and leaves the job running and ffmpeg unstarted', async () => {
  const fake = fakeSpawn(() => ({ size: 100 }));
  await withHarness(clipsWith(fake), async (h) => {
    const id = await h.runningJob({ over: newClip() });
    await h.uploadClip(id, 'a.mjpeg', fakeClip());
    const missing = await doneClips(h, id, ['a.mjpeg', 'never_sent.mjpeg']);
    assert.deepStrictEqual([missing.statusCode, missing.body.code], [400, 'bad_request']);
    assert.match(missing.body.error, /never_sent\.mjpeg/);
    for (const files of [[], undefined, 'a.mjpeg', ['a.png'], ['A.mjpeg'], ['../a.mjpeg'], [7], ['a.mp4'], Array.from({ length: 41 }, (_, i) => `c${i}.mjpeg`)]) {
      const r = await doneClips(h, id, files);
      assert.strictEqual(r.statusCode, 400, String(JSON.stringify(files)).slice(0, 40));
    }
    assert.strictEqual(h.jobs[0].status, 'running');
    assert.strictEqual(fake.calls.length, 0);
    assert.deepStrictEqual(fs.readdirSync(h.jobFolder(id)), ['a.mjpeg'], 'the clip is still there for a corrected done');
    assert.strictEqual((await doneClips(h, id, ['a.mjpeg'])).statusCode, 200);
    // and a shots or bench job's done does not take clips
    const shots = await h.runningJob({ accountId: HELIX });
    const odd = await h.call('POST /api/team/jobs/:id/done', { accountId: HELIX, params: { id: shots }, body: { files: ['a.mjpeg'] } });
    assert.strictEqual(odd.statusCode, 400);
  });
});

test('a done that is resent while its clips are still being made joins the first: one transcode, the same answer for both', async () => {
  const fake = fakeSpawn(() => ({ size: 100, delayMs: 60 }));
  await withHarness(clipsWith(fake), async (h) => {
    const id = await h.runningJob({ over: newClip() });
    await h.uploadClip(id, 'a.mjpeg', fakeClip());
    await h.uploadClip(id, 'b.mjpeg', fakeClip());
    const [first, second] = await Promise.all([doneClips(h, id, ['a.mjpeg', 'b.mjpeg']), doneClips(h, id, ['a.mjpeg', 'b.mjpeg'])]);
    assert.deepStrictEqual([first.statusCode, second.statusCode], [200, 200]);
    assert.deepStrictEqual(first.body, second.body);
    assert.strictEqual(fake.calls.length, 2, 'two clips made once, not twice');
    assert.deepStrictEqual(fs.readdirSync(h.jobFolder(id)).sort(), ['a.mp4', 'b.mp4']);
  });
});

test('transcodes run one at a time on this machine, even for different jobs', async () => {
  const fake = fakeSpawn(() => ({ size: 100, delayMs: 40 }));
  await withHarness(clipsWith(fake), async (h) => {
    const one = await h.runningJob({ over: newClip() });
    const two = await h.runningJob({ over: newClip(), accountId: HELIX });
    await h.uploadClip(one, 'a.mjpeg', fakeClip());
    await h.uploadClip(one, 'b.mjpeg', fakeClip());
    await h.uploadClip(two, 'a.mjpeg', fakeClip(), { accountId: HELIX });
    const [r1, r2] = await Promise.all([doneClips(h, one, ['a.mjpeg', 'b.mjpeg']), doneClips(h, two, ['a.mjpeg'], {}, { accountId: HELIX })]);
    assert.deepStrictEqual([r1.statusCode, r2.statusCode], [200, 200], JSON.stringify([r1.body, r2.body]));
    assert.strictEqual(fake.calls.length, 3);
    assert.strictEqual(fake.mostAtOnce(), 1, 'never two ffmpegs at once');
  });
  // a failure in one job does not stop the queue for the next
  let n = 0;
  const flaky = fakeSpawn(() => ({ code: ++n === 1 ? 1 : 0, size: 100, delayMs: 20 }));
  await withHarness(clipsWith(flaky), async (h) => {
    const one = await h.runningJob({ over: newClip() });
    const two = await h.runningJob({ over: newClip(), accountId: HELIX });
    await h.uploadClip(one, 'a.mjpeg', fakeClip());
    await h.uploadClip(two, 'a.mjpeg', fakeClip(), { accountId: HELIX });
    const [r1, r2] = await Promise.all([doneClips(h, one, ['a.mjpeg']), doneClips(h, two, ['a.mjpeg'], {}, { accountId: HELIX })]);
    assert.deepStrictEqual([r1.statusCode, r2.statusCode], [400, 200]);
  });
});

test('a done after a partial try keeps the videos already made and turns the rest into videos', async () => {
  const fake = fakeSpawn(() => ({ size: 777 }));
  await withHarness(clipsWith(fake), async (h) => {
    const id = await h.runningJob({ over: newClip() });
    await h.uploadClip(id, 'b.mjpeg', fakeClip());
    fs.writeFileSync(path.join(h.jobFolder(id), 'a.mp4'), Buffer.alloc(555, 1));   // a.mjpeg was made into a.mp4 before the server restarted
    const done = await doneClips(h, id, ['a.mjpeg', 'b.mjpeg']);
    assert.strictEqual(done.statusCode, 200, JSON.stringify(done.body));
    assert.strictEqual(fake.calls.length, 1, 'only b is made');
    assert.deepStrictEqual(JSON.parse(h.jobs[0].result).files, [{ name: 'a.mp4', bytes: 555 }, { name: 'b.mp4', bytes: 777, crf: 26 }]);
  });
});

test('a clip job that is cancelled or failed by its PC loses its raw clips and parts, and a done after a cancel is refused', async () => {
  const fake = fakeSpawn(() => ({ size: 100 }));
  await withHarness(clipsWith(fake), async (h) => {
    const cancelled = await h.runningJob({ over: newClip() });
    await h.uploadClip(cancelled, 'a.mjpeg', fakeClip());
    fs.writeFileSync(path.join(h.jobFolder(cancelled), '.a.deadbeef.part'), 'half');
    fs.writeFileSync(path.join(h.jobFolder(cancelled), 'keep.mp4'), 'a video');
    assert.strictEqual((await h.internal('POST /internal/team/jobs/:id/cancel', { params: { id: cancelled } })).statusCode, 200);
    assert.deepStrictEqual(fs.readdirSync(h.jobFolder(cancelled)), ['keep.mp4']);
    const late = await doneClips(h, cancelled, ['a.mjpeg']);
    assert.deepStrictEqual([late.statusCode, late.body.error], [409, 'This job was cancelled.']);
    assert.strictEqual(fake.calls.length, 0);
    const failed = await runningJobFor(h, WAR);
    await h.uploadClip(failed, 'a.mjpeg', fakeClip(), { accountId: WAR });
    const f = await h.call('POST /api/team/jobs/:id/fail', { accountId: WAR, params: { id: failed }, body: { error: 'the game crashed', log: 'x' } });
    assert.strictEqual(f.statusCode, 200);
    assert.ok(!fs.existsSync(path.join(h.jobFolder(failed), 'a.mjpeg')), 'a failed clip job keeps no raw clips');
    // a shots job cancelled keeps what it has: the pictures are the result
    const shots = await h.runningJob({ accountId: HELIX });
    await h.upload(shots, 'a.png', png(), { accountId: HELIX });
    await h.internal('POST /internal/team/jobs/:id/cancel', { params: { id: shots } });
    assert.deepStrictEqual(fs.readdirSync(h.jobFolder(shots)), ['a.png']);
  });
  async function runningJobFor(h, accountId) { return h.runningJob({ over: newClip(), accountId }); }
});

test('the heartbeat of a job whose clips are being made is renewed before each clip, so the sweep does not take it back', async () => {
  const fake = fakeSpawn(() => ({ size: 100 }));
  await withHarness(clipsWith(fake), async (h) => {
    const id = await h.runningJob({ over: newClip() });
    await h.uploadClip(id, 'a.mjpeg', fakeClip());
    h.advance(2 * MIN);
    assert.ok(h.jobs[0].heartbeat_at < h.now());
    await doneClips(h, id, ['a.mjpeg']);
    assert.strictEqual(h.jobs[0].status, 'done');
    assert.strictEqual(h.jobs[0].heartbeat_at, h.now(), 'the PC was alive when the transcode began');
  });
});

test('FFMPEG in the environment names the transcoder, /usr/bin/ffmpeg is the default', async () => {
  const keep = process.env.FFMPEG;
  try {
    for (const [env, want] of [['/opt/video/ffmpeg', '/opt/video/ffmpeg'], [undefined, '/usr/bin/ffmpeg']]) {
      if (env === undefined) delete process.env.FFMPEG; else process.env.FFMPEG = env;
      const fake = fakeSpawn(() => ({ size: 100 }));
      await withHarness({ mount: { spawn: fake.spawn } }, async (h) => {   // no `ffmpeg` option: the mount reads the environment
        const id = await h.runningJob({ over: newClip() });
        await h.uploadClip(id, 'a.mjpeg', fakeClip());
        await doneClips(h, id, ['a.mjpeg']);
        assert.strictEqual(fake.calls[0].args[2], want);
      });
    }
  } finally {
    if (keep === undefined) delete process.env.FFMPEG; else process.env.FFMPEG = keep;
  }
});

// The real ffmpeg: a tiny motion-JPEG made by ffmpeg itself, turned into an mp4 by the route (skipped with a printed line when this machine has none).

/** The boxes at the top of an MP4 file, in order ('ftyp', 'moov', 'mdat'). */
const mp4Boxes = (buf) => {
  const out = [];
  for (let at = 0; at + 8 <= buf.length;) {
    const size = buf.readUInt32BE(at);
    out.push(buf.toString('latin1', at + 4, at + 8));
    if (size < 8) break;
    at += size;
  }
  return out;
};
const probe = (file) => {
  try {
    return JSON.parse(execFileSync('ffprobe', ['-v', 'error', '-select_streams', 'v:0', '-count_frames', '-show_entries', 'stream=codec_name,pix_fmt,width,height,nb_read_frames:format=duration', '-of', 'json', file], { encoding: 'utf8' }));
  } catch { return null; }   // no ffprobe here: the checks that need it are skipped
};

realTest('a real tiny motion-JPEG becomes a real h264 mp4: even size, at most 960 wide, fast-start, no audio, and only the mp4 is left', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'team-clip-real-'));
  try {
    await withHarness({ mount: { ffmpeg: REAL_FFMPEG } }, async (h) => {
      const id = await h.runningJob({ over: newClip() });
      const small = realMjpeg(dir, { w: 320, h: 180, seconds: 1, name: 'small.mjpeg' });
      const big = realMjpeg(dir, { w: 1280, h: 720, seconds: 1, name: 'big.mjpeg' });
      assert.strictEqual((await h.uploadClip(id, 'slow_small.mjpeg', small)).body.data.width, 320, 'the first picture of a real clip reads');
      assert.strictEqual((await h.uploadClip(id, 'slow_big.mjpeg', big)).statusCode, 200);
      const done = await doneClips(h, id, ['slow_small.mjpeg', 'slow_big.mjpeg']);
      assert.strictEqual(done.statusCode, 200, JSON.stringify(done.body));
      const folder = h.jobFolder(id);
      assert.deepStrictEqual(fs.readdirSync(folder).sort(), ['slow_big.mp4', 'slow_small.mp4'], 'the mjpegs are deleted, no part is left');
      for (const name of ['slow_big.mp4', 'slow_small.mp4']) {
        const buf = fs.readFileSync(path.join(folder, name));
        const boxes = mp4Boxes(buf);
        assert.strictEqual(boxes[0], 'ftyp', name);
        assert.ok(boxes.indexOf('moov') > 0 && boxes.indexOf('moov') < boxes.indexOf('mdat'), `${name} is fast-start (moov before mdat): ${boxes}`);
        assert.ok(buf.length > 1000 && buf.length < MP4_MAX_BYTES, `${name} is a small real video (${buf.length} bytes)`);
        const info = probe(path.join(folder, name));
        if (!info) continue;
        const v = info.streams[0];
        assert.deepStrictEqual([v.codec_name, v.pix_fmt], ['h264', 'yuv420p'], name);
        assert.ok(v.width <= 960 && v.width % 2 === 0 && v.height % 2 === 0, `${name} ${v.width}x${v.height}`);
        assert.strictEqual(v.nb_read_frames, '30', `${name} keeps its 30 frames at 30 fps`);
        assert.ok(Math.abs(Number(info.format.duration) - 1) < 0.1, `${name} lasts a second`);
      }
      const big264 = probe(path.join(folder, 'slow_big.mp4'));
      if (big264) assert.deepStrictEqual([big264.streams[0].width, big264.streams[0].height], [960, 540], 'a 1280x720 clip is scaled to 960x540');
      const small264 = probe(path.join(folder, 'slow_small.mp4'));
      if (small264) assert.deepStrictEqual([small264.streams[0].width, small264.streams[0].height], [320, 180], 'a smaller one is not scaled up');
      const result = JSON.parse(h.jobs[0].result);
      assert.deepStrictEqual(result.files.map((f) => [f.name, f.crf]), [['slow_small.mp4', 26], ['slow_big.mp4', 26]]);
      assert.deepStrictEqual(result.files.map((f) => f.bytes), result.files.map((f) => fs.statSync(path.join(folder, f.name)).size));
    });
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

realTest('a real clip longer than 10 seconds is cut at 10, and a real file that is not a video fails the job', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'team-clip-real-'));
  try {
    await withHarness({ mount: { ffmpeg: REAL_FFMPEG } }, async (h) => {
      const id = await h.runningJob({ over: newClip() });
      assert.strictEqual((await h.uploadClip(id, 'long.mjpeg', realMjpeg(dir, { w: 160, h: 90, seconds: 12, name: 'long.mjpeg' }))).statusCode, 200);
      const done = await doneClips(h, id, ['long.mjpeg']);
      assert.strictEqual(done.statusCode, 200, JSON.stringify(done.body));
      const info = probe(path.join(h.jobFolder(id), 'long.mp4'));
      if (info) assert.ok(Math.abs(Number(info.format.duration) - 10) < 0.2, `cut at 10 seconds (${info.format.duration})`);
    });
    await withHarness({ mount: { ffmpeg: REAL_FFMPEG } }, async (h) => {
      const id = await h.runningJob({ over: newClip() });
      // a JPEG start that passes the upload checks and is not a video: ffmpeg refuses it at done
      const junk = Buffer.concat([jpegFrame(960, 540).subarray(0, 44), Buffer.alloc(3000, 0xab)]);   // the headers and a frame header, then bytes that are no scan
      assert.strictEqual((await h.uploadClip(id, 'junk.mjpeg', junk)).statusCode, 200);
      const done = await doneClips(h, id, ['junk.mjpeg']);
      assert.deepStrictEqual([done.statusCode, done.body.error], [400, 'The clip junk could not be turned into a video (the file may be damaged or cut off).']);
      assert.strictEqual(h.jobs[0].status, 'failed');
      assert.ok(!fs.existsSync(h.jobFolder(id)) || fs.readdirSync(h.jobFolder(id)).length === 0, 'no mp4, no part, no clip left');
      assert.ok(JSON.parse(h.jobs[0].result).log.length > 0);
    });
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

realTest('the real transcode needs nothing the service\'s unit does not give it: it runs with an unreadable HOME and writes only inside the job folder', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'team-clip-real-'));
  try {
    const real = realMjpeg(dir, { w: 320, h: 180, seconds: 1 });
    const seen = [];
    const spy = (cmd, args, opts) => { seen.push({ cmd, args, opts }); return require('node:child_process').spawn(cmd, args, { ...opts, env: { ...opts.env, HOME: '/nonexistent-home' } }); };
    await withHarness({ mount: { ffmpeg: REAL_FFMPEG, spawn: spy } }, async (h) => {
      const before = fs.readdirSync(path.dirname(h.resultsDir)).sort();
      const id = await h.runningJob({ over: newClip() });
      await h.uploadClip(id, 'a.mjpeg', real);
      const done = await doneClips(h, id, ['a.mjpeg']);
      assert.strictEqual(done.statusCode, 200, JSON.stringify(done.body));
      assert.strictEqual(seen[0].opts.cwd, path.join(h.resultsDir, id));
      assert.deepStrictEqual(fs.readdirSync(h.jobFolder(id)), ['a.mp4']);
      assert.deepStrictEqual(fs.readdirSync(path.dirname(h.resultsDir)).sort(), before.concat(before.includes(path.basename(h.resultsDir)) ? [] : [path.basename(h.resultsDir)]).sort(), 'nothing was written beside the results folder');
    });
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
