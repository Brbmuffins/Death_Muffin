'use strict';
/**
 * Team jobs (ROADMAP Phase 1, "New: the team app"; DECISIONS B54, B55): jobs that need a real graphics card run on the three team PCs (War,
 * Muffins, Helix) in a small Windows app. This server queues a job, one PC claims it, uploads its result files and finishes it; the Discord
 * agent's runner (same machine) creates jobs and reads the results. Tables team_members, team_pcs, team_jobs, migration 057.
 *
 * The app signs in with its own team token, never the game's login session: POST /api/team/login checks the account's password like /login does
 * (the same bcrypt compare and rate limiter) but does not claim the account's game session (session.cjs), then the account must be in team_members
 * (403 `not_team` otherwise). The token is 32 random bytes as base64url, kept only as its SHA-256 in team_tokens, good for 90 days, one live token
 * per PC and at most 5 per account. Every other app route needs `Authorization: Team <token>`: not revoked, not expired, the account still in
 * team_members and active, else 401 `signed_out`. The token names its PC: that is the PC every call acts as (a body, header or query that names
 * another PC is 403 `wrong_pc`). Each route is also mounted without the /api prefix, like benchmarks.cjs (nginx strips /death-muffin/api):
 *   POST /api/team/login                       { username, password, pcId, pcName } -> { success, data: { token, expiresAt, accountId, username } }
 *   POST /api/team/logout                      revokes the token it came with -> { success }
 *   GET  /api/team/me                          -> { success, data: { accountId, username } }
 *   POST /api/team/heartbeat                   the PC's state, every 30 s -> { success, data: { serverTime, offer } }   offer: null or the oldest queued job
 *                                              this PC has not declined
 *   POST /api/team/jobs/:id/claim              { pcId } -> { success, data: { id, kind, title, payload } }   409 `taken` when another PC got it first
 *   POST /api/team/jobs/:id/decline            { pcId, reason } -> { success }   the job stays queued for the other PCs and is not offered to this one again
 *   PUT  /api/team/jobs/:id/files/:name        one PNG as the raw body (at most 8 MB, 40 a job) -> { success, data: { name, bytes, width, height } }
 *   POST /api/team/jobs/:id/done               { files, log, timings } -> { success, data: { id, status } }
 *   POST /api/team/jobs/:id/fail               { error, log } -> { success, data: { id, status } }
 * The runner (loopback only, and X-Team-Secret equal to the contents of TEAM_SECRET_FILE; anything else answers 404):
 *   POST /internal/team/jobs                   { kind, title, weightS, payload, ttlS } -> { success, data: { id } }
 *   GET  /internal/team/jobs/:id               the row with its files (absolute paths)
 *   POST /internal/team/jobs/:id/cancel        -> { success, data: { id, status } }
 *   GET  /internal/team/pcs                    PCs seen in the last 2 minutes with mode and state
 *
 * Errors are { success: false, code, error } and `error` is player-readable (the app shows it as it is): 400 bad_request, 401 bad_login / signed_out,
 * 403 not_team / wrong_pc / not_your_job, 404 not_found, 409 taken / not_running / too_many, 413 too_large, 415 bad_type, 429 rate_limited / too_many_jobs,
 * 503 unavailable (a table is missing or the results folder is not writable), 500 server_error.
 * A running job whose PC sends no heartbeat for 3 minutes goes back to queued once (tries + 1); the second time it fails. A queued job past its
 * expires_at becomes expired. Both are swept on every heartbeat and every internal call, so no timer is needed.
 * Everything a PC sends is untrusted: strings are trimmed, stripped of control characters and capped; a result file must be a real PNG of a sane
 * size, with a name from a closed alphabet, written only under <resultsDir>/<job id>/.
 */
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const DEFAULT_RESULTS_DIR = '/home/ubuntu/death-muffin/team-results';
const DEFAULT_SECRET_FILE = '/home/ubuntu/death-muffin/discord-agent/secret';
const FILE_MAX_BYTES = 8 * 1024 * 1024;
const FILES_PER_JOB = 40;
const PNG_SIDE_MIN = 16;
const PNG_SIDE_MAX = 4096;
const LOG_MAX = 64 * 1024;
const ERROR_MAX = 400;
const QUIET_MINUTES = 3;
const SEEN_MINUTES = 2;
const DECLINES_MAX = 20;
const OPEN_JOBS_MAX = 50;                 // queued + running jobs the runner may have at once
const TTL_DEFAULT_S = 3600;
const TTL_MIN_S = 60;
const TTL_MAX_S = 7 * 86400;
const WEIGHT_MAX_S = 86400;
const PAYLOAD_MAX = 200000;               // characters of the payload's JSON
const SECRET_MIN = 16;
const TOKEN_DAYS = 90;
const TOKENS_MAX = 5;                     // live sign-ins per account; a new one beyond that revokes the oldest
const TOKEN_RE = /^[A-Za-z0-9_-]{16,128}$/;
const SIGNED_OUT = 'Signed out: sign in to the team app again.';

const MODES = ['ask', 'auto', 'yes'];
const DECLINE_REASONS = ['not_now', 'paused', 'busy'];
const PC_ID_RE = /^[A-Za-z0-9_-]{8,64}$/;
const JOB_ID_RE = /^[0-9a-f]{12}$/;
const FILE_NAME_RE = /^[a-z0-9_-]{1,60}\.png$/;
const KIND_RE = /^[a-z][a-z0-9_]{0,23}$/;
const HIDDEN = /[\u0000-\u001f\u007f-\u009f\u200b-\u200f\u2028-\u202e\u2066-\u2069\ufeff]/g;
const LOG_HIDDEN = /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f-\u009f\u200b-\u200f\u2028-\u202e\u2066-\u2069\ufeff]/g;   // keeps tab, line feed, carriage return
const LOOPBACK = new Set(['127.0.0.1', '::1', '::ffff:127.0.0.1']);
const PROXY_HEADERS = ['x-forwarded-for', 'x-real-ip', 'forwarded', 'x-forwarded-host', 'x-forwarded-proto'];   // nginx sets these on everything it forwards
const QUIET_ERROR = 'The team PC went quiet while it was running this job.';
const PNG_SIGNATURE = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
const PNG_IEND = Buffer.from([0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82]);

const isObject = (v) => !!v && typeof v === 'object' && !Array.isArray(v);
const finite = (v) => typeof v === 'number' && Number.isFinite(v);
/** A trimmed, control-free, length-capped string ('' for anything that is not a string). Tabs and line breaks become a space first. */
const text = (v, max) => (typeof v === 'string' ? v.replace(/[\t\n\r]+/g, ' ').replace(HIDDEN, '').trim().slice(0, max).trim() : '');
const clampInt = (v, lo, hi) => (finite(v) ? Math.min(hi, Math.max(lo, Math.round(v))) : null);
const asJson = (v) => {
  if (v == null) return null;
  if (typeof v !== 'string') return v;
  try { return JSON.parse(v); } catch { return null; }
};
const isoOf = (seconds) => (seconds == null || !Number.isFinite(Number(seconds)) ? null : new Date(Number(seconds) * 1000).toISOString());
const sha256 = (s) => crypto.createHash('sha256').update(String(s)).digest();
const sha256Hex = (s) => crypto.createHash('sha256').update(String(s)).digest('hex');

/** A log: control characters (except tab and line breaks) dropped, at most 64 KB of UTF-8. */
function cleanLog(v) {
  if (typeof v !== 'string') return '';
  let s = v.replace(LOG_HIDDEN, '').slice(0, LOG_MAX);
  if (Buffer.byteLength(s) > LOG_MAX) s = Buffer.from(s).subarray(0, LOG_MAX).toString('utf8').replace(/\ufffd+$/, '');
  return s;
}

const cleanTimings = (raw) => {
  const t = isObject(raw) ? raw : {};
  const s = (v) => (finite(v) ? Math.min(86400, Math.max(0, Math.round(v * 10) / 10)) : null);
  return { downloadS: s(t.downloadS), runS: s(t.runS) };
};

// ── Parsing what a PC or the runner sends ────────────────────────────────────────────────────────────────────────────────

/** The PC id a request names, in a body, a header or a query: '' when it names none, null when what it names is not a valid id. */
function namedPc(req) {
  const raw = (req.headers && req.headers['x-team-pc']) || (req.query && req.query.pcId) || (isObject(req.body) && req.body.pcId) || '';
  if (raw === '' || raw === undefined) return '';
  const id = typeof raw === 'string' ? raw.trim() : '';
  return PC_ID_RE.test(id) ? id : null;
}

/** Validate a heartbeat body. Returns { error } or { pc } (`pcId` is what the body names, '' for none: the route holds it to the token's). */
function parseHeartbeat(body) {
  const b = isObject(body) ? body : {};
  const pcId = typeof b.pcId === 'string' ? b.pcId.trim() : '';
  if (b.pcId !== undefined && !PC_ID_RE.test(pcId)) return { error: 'This PC has no valid id.' };
  const s = isObject(b.state) ? b.state : {};
  return {
    pc: {
      pcId, name: text(b.name, 64), version: text(b.version, 32), gpu: text(b.gpu, 120),
      mode: MODES.includes(b.mode) ? b.mode : 'ask',
      state: { gameRunning: s.gameRunning === true, fullscreen: s.fullscreen === true, onBattery: s.onBattery === true, busy: s.busy === true, paused: s.paused === true },
    },
  };
}

/** Validate the runner's new job. Returns { error } or { job }. */
function parseNewJob(body) {
  const b = isObject(body) ? body : {};
  const kind = typeof b.kind === 'string' ? b.kind.trim() : '';
  if (!KIND_RE.test(kind)) return { error: 'The job needs a kind (lowercase letters, digits and underscores).' };
  const title = text(b.title, 160);
  if (!title) return { error: 'The job needs a title.' };
  if (!isObject(b.payload)) return { error: 'The job needs a payload object.' };
  const payload = JSON.stringify(b.payload);
  if (payload.length > PAYLOAD_MAX) return { error: 'The job payload is too large.' };
  return { job: { kind, title, weightS: clampInt(b.weightS, 0, WEIGHT_MAX_S) ?? 60, payload, ttlS: clampInt(b.ttlS, TTL_MIN_S, TTL_MAX_S) ?? TTL_DEFAULT_S } };
}

/**
 * Check a PNG file: signature, an IHDR chunk first with each side 16 to 4096 pixels, and the closing IEND chunk (a cut-off upload has none).
 * Returns { error } or { width, height }.
 */
function checkPng(buf) {
  if (!Buffer.isBuffer(buf) || buf.length < 45 || !buf.subarray(0, 8).equals(PNG_SIGNATURE)) return { error: 'That file is not a PNG picture.' };
  if (buf.readUInt32BE(8) !== 13 || buf.toString('latin1', 12, 16) !== 'IHDR') return { error: 'That file is not a PNG picture.' };
  const width = buf.readUInt32BE(16);
  const height = buf.readUInt32BE(20);
  if (width < PNG_SIDE_MIN || height < PNG_SIDE_MIN || width > PNG_SIDE_MAX || height > PNG_SIDE_MAX) {
    return { error: `That picture is ${width} by ${height} pixels; each side must be ${PNG_SIDE_MIN} to ${PNG_SIDE_MAX}.` };
  }
  if (!buf.subarray(buf.length - 12).equals(PNG_IEND)) return { error: 'That PNG picture is cut off.' };
  return { width, height };
}

/** The request body as one buffer, read at most `max` bytes: { tooLarge: true } as soon as it passes the cap (nothing more is kept). */
function readBody(req, max) {
  return new Promise((resolve, reject) => {
    const parts = [];
    let total = 0;
    let settled = false;
    const settle = (fn, value) => {
      if (settled) return;
      settled = true;
      req.off('data', onData);
      req.off('end', onEnd);
      req.off('error', onError);
      req.off('close', onClose);
      fn(value);
    };
    const onData = (chunk) => {
      total += chunk.length;
      if (total > max) { req.pause(); return settle(resolve, { tooLarge: true }); }
      parts.push(chunk);
    };
    const onEnd = () => settle(resolve, Buffer.concat(parts, total));
    const onError = (err) => settle(reject, err);
    const onClose = () => settle(reject, Object.assign(new Error('the upload was cut off'), { code: 'UPLOAD_ABORTED' }));
    req.on('data', onData);
    req.on('end', onEnd);
    req.on('error', onError);
    req.on('close', onClose);
  });
}

// ── Result files ─────────────────────────────────────────────────────────────────────────────────────────────────────────

/** The files of a job's result folder: [{ name, bytes }] in name order (only names the upload accepts; half-written parts are skipped). */
async function listFiles(resultsDir, id) {
  let entries;
  try {
    entries = await fs.promises.readdir(path.join(resultsDir, id), { withFileTypes: true });
  } catch (err) {
    if (err && err.code === 'ENOENT') return [];
    throw err;
  }
  const out = [];
  for (const e of entries) {
    if (!e.isFile() || !FILE_NAME_RE.test(e.name)) continue;
    const st = await fs.promises.stat(path.join(resultsDir, id, e.name));
    out.push({ name: e.name, bytes: st.size });
  }
  return out.sort((a, b) => (a.name < b.name ? -1 : 1));
}

/** Write one file under <resultsDir>/<id>/ (folders 0750, the file 0640, put in place with a rename). Throws when the path would leave that folder. */
async function storeFile(resultsDir, id, name, buf) {
  if (!JOB_ID_RE.test(id) || !FILE_NAME_RE.test(name)) throw new Error('unsafe result path');
  const root = path.resolve(resultsDir);
  const dir = path.join(root, id);
  const target = path.join(dir, name);
  if (path.dirname(target) !== dir || path.dirname(dir) !== root) throw new Error('unsafe result path');
  await fs.promises.mkdir(root, { recursive: true, mode: 0o750 });
  await fs.promises.mkdir(dir, { recursive: true, mode: 0o750 });
  const part = path.join(dir, `.${name}.${crypto.randomBytes(4).toString('hex')}.part`);
  try {
    await fs.promises.writeFile(part, buf, { mode: 0o640, flag: 'wx' });
    await fs.promises.rename(part, target);
  } catch (err) {
    await fs.promises.rm(part, { force: true }).catch(() => {});
    throw err;
  }
}

// ── Routes ───────────────────────────────────────────────────────────────────────────────────────────────────────────────

/** Did this PC decline the job? `result` is the job's result column (JSON or text): { declines: [{ pcId, reason, at }] }. */
function declinedBy(result, pcId) {
  const r = asJson(result);
  return isObject(r) && Array.isArray(r.declines) && r.declines.some((d) => isObject(d) && d.pcId === pcId);
}

const STATUS_WORDS = {
  queued: 'This job is not running.', expired: 'This job ran out of time before a PC took it.', cancelled: 'This job was cancelled.',
  done: 'This job has already finished.', failed: 'This job has already finished.',
};

module.exports = function mountTeamJobs(app, pool, {
  limiter, loginLimiter, comparePassword, tokenDays = TOKEN_DAYS,
  resultsDir = process.env.TEAM_RESULTS_DIR || DEFAULT_RESULTS_DIR, secretFile = process.env.TEAM_SECRET_FILE || DEFAULT_SECRET_FILE,
} = {}) {
  const paths = (p) => [`/api${p}`, p];   // the app's routes on both paths (see the header)
  const fail = (res, status, code, error) => res.status(status).json({ success: false, code, error });
  const noTable = (res) => fail(res, 503, 'unavailable', 'Team jobs are not available just yet. Please try again later.');
  const jobNotFound = (res) => fail(res, 404, 'not_found', 'That job does not exist.');
  const notFound = (res) => res.status(404).json({ success: false, error: 'Not found' });

  /** Answer a thrown error: a missing table or an unwritable results folder is a readable 503, anything else a logged 500 (`serverError`: its player-readable text). */
  const answerError = (res, err, what, serverError = 'The server could not finish that. Please try again.') => {
    if (err && err.code === 'ER_NO_SUCH_TABLE') return noTable(res);
    if (err && ['EROFS', 'EACCES', 'EPERM', 'ENOSPC'].includes(err.code)) {
      console.error(`team ${what} storage error:`, err.code);
      return fail(res, 503, 'unavailable', 'The server cannot store team files just now. Please try again later.');
    }
    console.error(`team ${what} error:`, (err && (err.code || err.message)) || err);
    return fail(res, 500, 'server_error', serverError);
  };
  const route = (what, fn, serverError) => async (req, res) => {
    try { await fn(req, res); } catch (err) { if (!res.headersSent) answerError(res, err, what, serverError); else console.error(`team ${what} error after the reply:`, (err && (err.code || err.message)) || err); }
  };

  // ── Sign-in: the team token ──
  const signedOut = (res) => fail(res, 401, 'signed_out', SIGNED_OUT);
  /**
   * `Authorization: Team <token>`: the token's hash must be in team_tokens, not revoked, not expired, its account still in team_members and active.
   * Sets req.user { accountId, username, pcId, tokenHash }; last_used is refreshed at most once a minute. No JWT and no game session check.
   */
  const teamAuth = async (req, res, next) => {
    const m = /^Team\s+(\S+)$/i.exec(String((req.headers || {}).authorization || ''));
    if (!m || !TOKEN_RE.test(m[1])) return signedOut(res);
    const tokenHash = sha256Hex(m[1]);
    let row;
    try {
      const [rows] = await pool.execute(
        `SELECT t.account_id, t.pc_id, a.username, (t.last_used IS NULL OR t.last_used < NOW() - INTERVAL 1 MINUTE) AS stale
           FROM team_tokens t JOIN team_members m ON m.account_id = t.account_id JOIN accounts a ON a.id = t.account_id
          WHERE t.token_hash = ? AND t.revoked = 0 AND t.expires_at > NOW() AND a.active = 1 LIMIT 1`, [tokenHash]);
      row = rows[0];
      if (row && Number(row.stale)) await pool.execute('UPDATE team_tokens SET last_used = NOW() WHERE token_hash = ?', [tokenHash]);
    } catch (err) {
      return answerError(res, err, 'auth');
    }
    if (!row) return signedOut(res);
    req.user = { accountId: Number(row.account_id), username: String(row.username), pcId: String(row.pc_id), tokenHash };
    return next();
  };
  const guards = limiter ? [teamAuth, limiter] : [teamAuth];

  /** The PC a call acts as: the one its token was made for. A body, header or query that names another is 403 `wrong_pc`; null after answering. */
  const actingPc = (req, res) => {
    const named = namedPc(req);
    if (named === null) { fail(res, 400, 'bad_request', 'This PC has no valid id.'); return null; }
    if (named && named !== req.user.pcId) { fail(res, 403, 'wrong_pc', 'This sign-in belongs to another PC. Sign in to the team app again on this PC.'); return null; }
    return req.user.pcId;
  };

  app.post(paths('/team/login'), ...(loginLimiter ? [loginLimiter] : []), route('login', async (req, res) => {
    const b = isObject(req.body) ? req.body : {};
    if (typeof b.username !== 'string' || typeof b.password !== 'string' || !b.username || !b.password) return fail(res, 400, 'bad_request', 'Username and password are required.');
    const pcId = typeof b.pcId === 'string' ? b.pcId.trim() : '';
    if (!PC_ID_RE.test(pcId)) return fail(res, 400, 'bad_request', 'This PC has no valid id.');
    const name = b.username.trim();
    const [rows] = await pool.execute('SELECT id, username, password_hash, active FROM accounts WHERE username = ? OR email = ? LIMIT 1', [name, name]);
    const account = rows[0];
    if (!account || !account.active || !(await comparePassword(b.password, account.password_hash))) return fail(res, 401, 'bad_login', 'Invalid username or password.');
    const [members] = await pool.execute('SELECT account_id FROM team_members WHERE account_id = ? LIMIT 1', [account.id]);
    if (!members.length) return fail(res, 403, 'not_team', 'This account is not on the team.');   // (after the password: a stranger learns nothing about who is on the team)
    const token = crypto.randomBytes(32).toString('base64url');
    const tokenHash = sha256Hex(token);
    await pool.execute('UPDATE team_tokens SET revoked = 1 WHERE account_id = ? AND pc_id = ? AND revoked = 0', [account.id, pcId]);   // a PC has one live sign-in
    await pool.execute(
      'INSERT INTO team_tokens (token_hash, account_id, pc_id, pc_name, created_at, last_used, expires_at) VALUES (?, ?, ?, ?, NOW(3), NOW(), NOW() + INTERVAL ? DAY)',
      [tokenHash, account.id, pcId, text(b.pcName, 64), tokenDays]);
    const [live] = await pool.execute('SELECT token_hash FROM team_tokens WHERE account_id = ? AND revoked = 0 AND expires_at > NOW() ORDER BY created_at ASC, token_hash ASC', [account.id]);
    for (const old of live.slice(0, Math.max(0, live.length - TOKENS_MAX))) {
      await pool.execute('UPDATE team_tokens SET revoked = 1 WHERE token_hash = ?', [old.token_hash]);
    }
    const [[made]] = await pool.execute('SELECT UNIX_TIMESTAMP(expires_at) AS expires_ts FROM team_tokens WHERE token_hash = ?', [tokenHash]);
    res.json({ success: true, data: { token, expiresAt: isoOf(made.expires_ts), accountId: Number(account.id), username: String(account.username) } });
  }, 'Account service is unavailable.'));

  app.post(paths('/team/logout'), ...guards, route('logout', async (req, res) => {
    await pool.execute('UPDATE team_tokens SET revoked = 1 WHERE token_hash = ?', [req.user.tokenHash]);
    res.json({ success: true });
  }));

  // ── The quiet-PC sweep ──
  /**
   * Running jobs whose PC sent no heartbeat for QUIET_MINUTES go back to queued once (tries + 1) and fail the second time; queued jobs past
   * their expires_at become expired. The order matters: a job requeued just now has no heartbeat, so it is not failed in the same call.
   */
  async function sweep() {
    await pool.execute(
      "UPDATE team_jobs SET status = 'failed', error = ?, finished_at = NOW() WHERE status = 'running' AND tries >= 1 AND COALESCE(heartbeat_at, claimed_at) < NOW() - INTERVAL ? MINUTE",
      [QUIET_ERROR, QUIET_MINUTES]);
    await pool.execute(
      "UPDATE team_jobs SET status = 'queued', tries = tries + 1, claimed_account = NULL, claimed_pc = NULL, claimed_at = NULL, heartbeat_at = NULL WHERE status = 'running' AND tries < 1 AND COALESCE(heartbeat_at, claimed_at) < NOW() - INTERVAL ? MINUTE",
      [QUIET_MINUTES]);
    await pool.execute("UPDATE team_jobs SET status = 'expired', finished_at = NOW() WHERE status = 'queued' AND expires_at <= NOW()");
  }

  const loadJob = async (id) => {
    const [rows] = await pool.execute('SELECT id, status, claimed_account, claimed_pc, result FROM team_jobs WHERE id = ? LIMIT 1', [id]);
    return rows[0] || null;
  };
  const validJobId = (req, res) => {
    const id = typeof req.params.id === 'string' ? req.params.id : '';
    if (JOB_ID_RE.test(id)) return id;
    jobNotFound(res);
    return null;
  };

  /**
   * The job a PC works on, or null after answering: it must exist, run, and be claimed by this account on this PC (the token's).
   * `again` is the status a finish call may repeat (a resent done answers success).
   */
  async function ownRunning(req, res, id, again) {
    const pcId = actingPc(req, res);
    if (pcId === null) return null;
    const job = await loadJob(id);
    if (!job) { jobNotFound(res); return null; }
    const mine = Number(job.claimed_account) === req.user.accountId && job.claimed_pc === pcId;
    if (job.status === 'running' && !mine) { fail(res, 403, 'not_your_job', 'This job is running on another PC.'); return null; }
    if (job.status !== 'running') {
      if (again && job.status === again && mine) { res.json({ success: true, data: { id, status: job.status } }); return null; }
      fail(res, 409, 'not_running', STATUS_WORDS[job.status] || 'This job is not running.');
      return null;
    }
    return job;
  }

  app.get(paths('/team/me'), ...guards, route('me', async (req, res) => {
    res.json({ success: true, data: { accountId: req.user.accountId, username: req.user.username } });
  }));

  app.post(paths('/team/heartbeat'), ...guards, route('heartbeat', async (req, res) => {
    const pcId = actingPc(req, res);
    if (pcId === null) return;
    const parsed = parseHeartbeat(req.body);
    if (parsed.error) return fail(res, 400, 'bad_request', parsed.error);
    const pc = parsed.pc;
    const account = req.user.accountId;
    const state = JSON.stringify(pc.state);
    await pool.execute(
      `INSERT INTO team_pcs (account_id, pc_id, name, version, gpu, mode, state, last_seen) VALUES (?, ?, ?, ?, ?, ?, ?, NOW())
       ON DUPLICATE KEY UPDATE name = ?, version = ?, gpu = ?, mode = ?, state = ?, last_seen = NOW()`,
      [account, pcId, pc.name, pc.version, pc.gpu, pc.mode, state, pc.name, pc.version, pc.gpu, pc.mode, state]);
    // This PC's own running job is alive (renewed before the sweep, so a PC that woke up late keeps it).
    await pool.execute("UPDATE team_jobs SET heartbeat_at = NOW() WHERE status = 'running' AND claimed_account = ? AND claimed_pc = ?", [account, pcId]);
    await sweep();
    // The oldest queued job this PC has not declined. At most OPEN_JOBS_MAX jobs are queued, so the list is every one of them.
    const [rows] = await pool.execute(
      `SELECT id, kind, title, weight_s, result, UNIX_TIMESTAMP(expires_at) AS expires_ts FROM team_jobs
        WHERE status = 'queued' AND expires_at > NOW() ORDER BY created_at ASC, id ASC LIMIT ${OPEN_JOBS_MAX}`);
    const j = rows.find((r) => !declinedBy(r.result, pcId));
    const offer = j ? { id: String(j.id), kind: String(j.kind), title: String(j.title), weightS: Number(j.weight_s), expiresAt: isoOf(j.expires_ts) } : null;
    res.json({ success: true, data: { serverTime: new Date().toISOString(), offer } });
  }));

  app.post(paths('/team/jobs/:id/claim'), ...guards, route('claim', async (req, res) => {
    const id = validJobId(req, res);
    if (!id) return;
    const pcId = actingPc(req, res);
    if (pcId === null) return;
    const account = req.user.accountId;
    const [claimed] = await pool.execute(
      "UPDATE team_jobs SET status = 'running', claimed_account = ?, claimed_pc = ?, claimed_at = NOW(), heartbeat_at = NOW() WHERE id = ? AND status = 'queued' AND expires_at > NOW()",
      [account, pcId, id]);
    if (!claimed.affectedRows) {
      const job = await loadJob(id);
      if (!job) return jobNotFound(res);
      const again = job.status === 'running' && Number(job.claimed_account) === account && job.claimed_pc === pcId;   // a resent claim from the PC that has it
      if (!again) return fail(res, 409, 'taken', job.status === 'running' ? 'Another team PC already took this job.' : STATUS_WORDS[job.status] || 'This job is not available any more.');
      await pool.execute("UPDATE team_jobs SET heartbeat_at = NOW() WHERE id = ? AND status = 'running'", [id]);
    }
    const [rows] = await pool.execute('SELECT id, kind, title, payload FROM team_jobs WHERE id = ? LIMIT 1', [id]);
    const j = rows[0];
    res.json({ success: true, data: { id: String(j.id), kind: String(j.kind), title: String(j.title), payload: asJson(j.payload) || {} } });
  }));

  app.post(paths('/team/jobs/:id/decline'), ...guards, route('decline', async (req, res) => {
    const id = validJobId(req, res);
    if (!id) return;
    const b = isObject(req.body) ? req.body : {};
    const pcId = actingPc(req, res);
    if (pcId === null) return;
    if (!DECLINE_REASONS.includes(b.reason)) return fail(res, 400, 'bad_request', 'Say why the job was declined: not_now, paused or busy.');
    const job = await loadJob(id);
    if (!job) return jobNotFound(res);
    if (job.status === 'queued') {   // one entry per PC, its latest answer last; the PC is not offered this job again
      const result = isObject(asJson(job.result)) ? asJson(job.result) : {};
      const declines = (Array.isArray(result.declines) ? result.declines : []).filter((d) => !d || d.pcId !== pcId);
      declines.push({ pcId, reason: b.reason, at: new Date().toISOString() });
      result.declines = declines.slice(-DECLINES_MAX);
      await pool.execute("UPDATE team_jobs SET result = ? WHERE id = ? AND status = 'queued'", [JSON.stringify(result), id]);
    }
    res.json({ success: true });
  }));

  app.put(paths('/team/jobs/:id/files/:name'), ...guards, route('upload', async (req, res) => {
    const id = validJobId(req, res);
    if (!id) return;
    const name = typeof req.params.name === 'string' ? req.params.name : '';
    if (!FILE_NAME_RE.test(name)) return fail(res, 400, 'bad_request', 'A picture name uses lowercase letters, digits, - and _, and ends in .png (at most 60 characters before it).');
    if (String((req.headers || {})['content-type'] || '').split(';')[0].trim().toLowerCase() !== 'image/png') return fail(res, 415, 'bad_type', 'Send the picture as image/png.');
    const tooLarge = () => {
      res.set('Connection', 'close');   // the rest of the upload is not read; the connection ends with the answer
      return fail(res, 413, 'too_large', 'That picture is too large (the limit is 8 MB).');
    };
    const declared = Number((req.headers || {})['content-length']);
    if (Number.isFinite(declared) && declared > FILE_MAX_BYTES) return tooLarge();
    const job = await ownRunning(req, res, id, null);
    if (!job) return;
    const files = await listFiles(resultsDir, id);
    if (files.length >= FILES_PER_JOB && !files.some((f) => f.name === name)) return fail(res, 409, 'too_many', `A job takes at most ${FILES_PER_JOB} pictures.`);
    let body;
    try {
      body = await readBody(req, FILE_MAX_BYTES);
    } catch (err) {
      if (err && err.code === 'UPLOAD_ABORTED') return;   // the PC went away mid-upload: nobody to answer
      throw err;
    }
    if (body.tooLarge) return tooLarge();
    const png = checkPng(body);
    if (png.error) return fail(res, 400, 'bad_request', png.error);
    await storeFile(resultsDir, id, name, body);
    await pool.execute("UPDATE team_jobs SET heartbeat_at = NOW() WHERE id = ? AND status = 'running'", [id]);   // an upload shows the PC is alive
    res.json({ success: true, data: { name, bytes: body.length, width: png.width, height: png.height } });
  }));

  app.post(paths('/team/jobs/:id/done'), ...guards, route('done', async (req, res) => {
    const id = validJobId(req, res);
    if (!id) return;
    const b = isObject(req.body) ? req.body : {};
    const named = Array.isArray(b.files) ? b.files : [];
    if (named.length > FILES_PER_JOB || !named.every((n) => typeof n === 'string' && FILE_NAME_RE.test(n))) {
      return fail(res, 400, 'bad_request', `The finished job must name its pictures (up to ${FILES_PER_JOB}, like shot_1.png).`);
    }
    const job = await ownRunning(req, res, id, 'done');
    if (!job) return;
    const onDisk = new Map((await listFiles(resultsDir, id)).map((f) => [f.name, f.bytes]));
    const missing = named.find((n) => !onDisk.has(n));
    if (missing) return fail(res, 400, 'bad_request', `The picture ${missing} was never uploaded.`);
    const old = isObject(asJson(job.result)) ? asJson(job.result) : {};
    const result = { ...old, files: [...new Set(named)].map((n) => ({ name: n, bytes: onDisk.get(n) })), log: cleanLog(b.log), timings: cleanTimings(b.timings) };
    const [done] = await pool.execute(
      "UPDATE team_jobs SET status = 'done', finished_at = NOW(), result = ?, error = NULL WHERE id = ? AND status = 'running' AND claimed_account = ?",
      [JSON.stringify(result), id, req.user.accountId]);
    if (!done.affectedRows) return fail(res, 409, 'not_running', 'This job is not running any more.');
    res.json({ success: true, data: { id, status: 'done' } });
  }));

  app.post(paths('/team/jobs/:id/fail'), ...guards, route('fail', async (req, res) => {
    const id = validJobId(req, res);
    if (!id) return;
    const b = isObject(req.body) ? req.body : {};
    const job = await ownRunning(req, res, id, 'failed');
    if (!job) return;
    const old = isObject(asJson(job.result)) ? asJson(job.result) : {};
    const result = { ...old, log: cleanLog(b.log) };
    const [failed] = await pool.execute(
      "UPDATE team_jobs SET status = 'failed', finished_at = NOW(), result = ?, error = ? WHERE id = ? AND status = 'running' AND claimed_account = ?",
      [JSON.stringify(result), text(b.error, ERROR_MAX) || 'The team PC could not finish this job.', id, req.user.accountId]);
    if (!failed.affectedRows) return fail(res, 409, 'not_running', 'This job is not running any more.');
    res.json({ success: true, data: { id, status: 'failed' } });
  }));

  // ── The runner's routes (/internal/team/..., this machine only) ──
  let secretWarned = false;
  const readSecret = () => {
    try {
      return fs.readFileSync(secretFile, 'utf8').trim();
    } catch (err) {
      if (!secretWarned) { secretWarned = true; console.error('team secret file unreadable:', (err && err.code) || err); }
      return '';
    }
  };
  /**
   * Only the runner: the connection comes from this machine itself and carries none of nginx's forwarding headers (a request that came through
   * nginx also arrives from 127.0.0.1, and /death-muffin/api/ would reach these paths), and X-Team-Secret equals the secret file's contents.
   * Anything else answers 404 as if the route did not exist.
   */
  const internal = (req, res, next) => {
    const headers = req.headers || {};
    const from = req.socket && req.socket.remoteAddress;
    if (!LOOPBACK.has(from) || PROXY_HEADERS.some((h) => headers[h] !== undefined)) return notFound(res);
    const given = headers['x-team-secret'];
    const secret = readSecret();
    if (secret.length < SECRET_MIN || typeof given !== 'string' || !crypto.timingSafeEqual(sha256(given), sha256(secret))) return notFound(res);
    return next();
  };
  const internalRoute = (what, fn) => route(what, async (req, res) => { await sweep(); await fn(req, res); });

  const JOB_COLS = `id, kind, title, weight_s, payload, status, UNIX_TIMESTAMP(created_at) AS created_ts, UNIX_TIMESTAMP(expires_at) AS expires_ts, claimed_account, claimed_pc,
    UNIX_TIMESTAMP(claimed_at) AS claimed_ts, UNIX_TIMESTAMP(heartbeat_at) AS heartbeat_ts, UNIX_TIMESTAMP(finished_at) AS finished_ts, result, error, tries`;

  app.post('/internal/team/jobs', internal, internalRoute('create', async (req, res) => {
    const parsed = parseNewJob(req.body);
    if (parsed.error) return fail(res, 400, 'bad_request', parsed.error);
    const j = parsed.job;
    const [[{ n }]] = await pool.execute("SELECT COUNT(*) AS n FROM team_jobs WHERE status IN ('queued', 'running')");
    if (Number(n) >= OPEN_JOBS_MAX) return fail(res, 429, 'too_many_jobs', `There are already ${OPEN_JOBS_MAX} jobs waiting or running.`);
    for (let attempt = 0; attempt < 3; attempt++) {
      const id = crypto.randomBytes(6).toString('hex');
      try {
        await pool.execute(
          "INSERT INTO team_jobs (id, kind, title, weight_s, payload, status, created_at, expires_at) VALUES (?, ?, ?, ?, ?, 'queued', NOW(3), NOW() + INTERVAL ? SECOND)",
          [id, j.kind, j.title, j.weightS, j.payload, j.ttlS]);
        return res.json({ success: true, data: { id } });
      } catch (err) {
        if (!(err && err.code === 'ER_DUP_ENTRY')) throw err;   // a random id that already exists: draw another
      }
    }
    return fail(res, 500, 'server_error', 'The server could not make a job id. Please try again.');
  }));

  app.get('/internal/team/jobs/:id', internal, internalRoute('get', async (req, res) => {
    const id = validJobId(req, res);
    if (!id) return;
    const [rows] = await pool.execute(`SELECT ${JOB_COLS} FROM team_jobs WHERE id = ? LIMIT 1`, [id]);
    const j = rows[0];
    if (!j) return jobNotFound(res);
    const files = (await listFiles(resultsDir, id)).map((f) => ({ ...f, path: path.join(path.resolve(resultsDir), id, f.name) }));
    res.json({
      success: true,
      data: {
        id, kind: String(j.kind), title: String(j.title), weightS: Number(j.weight_s), payload: asJson(j.payload) || {}, status: String(j.status), tries: Number(j.tries),
        createdAt: isoOf(j.created_ts), expiresAt: isoOf(j.expires_ts), claimedAccount: j.claimed_account == null ? null : Number(j.claimed_account), claimedPc: j.claimed_pc == null ? null : String(j.claimed_pc),
        claimedAt: isoOf(j.claimed_ts), heartbeatAt: isoOf(j.heartbeat_ts), finishedAt: isoOf(j.finished_ts),
        result: asJson(j.result), error: j.error == null ? null : String(j.error), files,
      },
    });
  }));

  app.post('/internal/team/jobs/:id/cancel', internal, internalRoute('cancel', async (req, res) => {
    const id = validJobId(req, res);
    if (!id) return;
    const [cancelled] = await pool.execute("UPDATE team_jobs SET status = 'cancelled', finished_at = NOW() WHERE id = ? AND status IN ('queued', 'running')", [id]);
    if (!cancelled.affectedRows) {
      const job = await loadJob(id);
      if (!job) return jobNotFound(res);
      if (job.status !== 'cancelled') return fail(res, 409, 'not_running', 'That job has already finished.');
    }
    res.json({ success: true, data: { id, status: 'cancelled' } });
  }));

  app.get('/internal/team/pcs', internal, internalRoute('pcs', async (req, res) => {
    const [rows] = await pool.execute(
      `SELECT p.account_id, a.username, p.pc_id, p.name, p.version, p.gpu, p.mode, p.state, UNIX_TIMESTAMP(p.last_seen) AS seen_ts
         FROM team_pcs p LEFT JOIN accounts a ON a.id = p.account_id WHERE p.last_seen > NOW() - INTERVAL ? MINUTE ORDER BY p.last_seen DESC`,
      [SEEN_MINUTES]);
    res.json({
      success: true,
      data: {
        pcs: rows.map((p) => ({
          accountId: Number(p.account_id), username: p.username == null ? '' : String(p.username), pcId: String(p.pc_id), name: String(p.name), version: String(p.version), gpu: String(p.gpu),
          mode: String(p.mode), state: asJson(p.state) || {}, lastSeen: isoOf(p.seen_ts),
        })),
      },
    });
  }));
};

module.exports.parseHeartbeat = parseHeartbeat;
module.exports.parseNewJob = parseNewJob;
module.exports.checkPng = checkPng;
module.exports.cleanLog = cleanLog;
module.exports.FILE_MAX_BYTES = FILE_MAX_BYTES;
module.exports.FILES_PER_JOB = FILES_PER_JOB;
module.exports.OPEN_JOBS_MAX = OPEN_JOBS_MAX;
module.exports.DEFAULT_RESULTS_DIR = DEFAULT_RESULTS_DIR;
module.exports.DEFAULT_SECRET_FILE = DEFAULT_SECRET_FILE;
