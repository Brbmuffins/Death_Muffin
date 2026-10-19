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
const { parseHeartbeat, parseNewJob, checkPng, cleanLog, FILE_MAX_BYTES, FILES_PER_JOB, OPEN_JOBS_MAX } = mountTeamJobs;

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
const beat = (over = {}) => ({ pcId: PC_A, name: 'Muffins PC', version: '0.1.0', gpu: 'NVIDIA GeForce RTX 4070', mode: 'ask', state: { gameRunning: false, fullscreen: false, onBattery: false, busy: false, paused: false }, ...over });

/**
 * The team tables in memory, keyed on the SQL team-jobs.cjs issues (each statement checks its own parameter count), plus a tiny Express stand-in.
 * `call` runs an app route as an account (no token with anon), `internal` runs the runner's routes from an address with a secret.
 */
function harness({ missingTable = false, members = [MUFFINS, HELIX, WAR], resultsDir } = {}) {
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
      if (sql.startsWith("SELECT id, kind, title, weight_s, result, UNIX_TIMESTAMP(expires_at) AS expires_ts FROM team_jobs WHERE status = 'queued' AND expires_at > NOW() ORDER BY created_at ASC, id ASC LIMIT 50")) {
        const open = jobs.filter((j) => j.status === 'queued' && j.expires_at > clock).sort((a, b) => a.created_at - b.created_at || (a.id < b.id ? -1 : 1));
        return [open.slice(0, 50).map((j) => ({ id: j.id, kind: j.kind, title: j.title, weight_s: j.weight_s, result: json(j.result), expires_ts: secs(j.expires_at) }))];
      }
      if (sql === 'SELECT id, status, claimed_account, claimed_pc, result FROM team_jobs WHERE id = ? LIMIT 1') {
        const j = byId(p[0]);
        return [j ? [{ id: j.id, status: j.status, claimed_account: j.claimed_account, claimed_pc: j.claimed_pc, result: json(j.result) }] : []];
      }
      if (sql.startsWith("UPDATE team_jobs SET status = 'running', claimed_account = ?, claimed_pc = ?")) {
        need(p, 3, sql);
        const j = byId(p[2]);
        if (j && j.status === 'queued' && j.expires_at > clock) { Object.assign(j, { status: 'running', claimed_account: p[0], claimed_pc: p[1], claimed_at: clock, heartbeat_at: clock }); return affected(1); }
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
        need(p, 6, sql);
        assert.ok(sql.includes("'queued', NOW(3), NOW() + INTERVAL ? SECOND"));
        if (byId(p[0])) throw Object.assign(new Error('dup'), { code: 'ER_DUP_ENTRY' });
        jobs.push({
          id: p[0], kind: p[1], title: p[2], weight_s: p[3], payload: p[4], status: 'queued', created_at: clock + jobs.length, expires_at: clock + p[5] * 1000,
          claimed_account: null, claimed_pc: null, claimed_at: null, heartbeat_at: null, finished_at: null, result: null, error: null, tries: 0,
        });
        return affected(1);
      }
      if (sql.startsWith('SELECT id, kind, title, weight_s, payload, status, UNIX_TIMESTAMP(created_at) AS created_ts')) {
        const j = byId(p[0]);
        return [j ? [{ ...j, payload: json(j.payload), result: json(j.result), created_ts: secs(j.created_at), expires_ts: secs(j.expires_at), claimed_ts: secs(j.claimed_at), heartbeat_ts: secs(j.heartbeat_at), finished_ts: secs(j.finished_at) }] : []];
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
      throw new Error(`unexpected SQL ${sql}`);
    },
  };

  const routes = {};
  const reg = (m) => (path_, ...fns) => { for (const p of [].concat(path_)) routes[`${m} ${p}`] = fns; };
  const app = { post: reg('POST'), get: reg('GET'), put: reg('PUT') };
  const limits = { login: 0, calls: 0 };   // how often the login limiter and the per-account limiter ran
  const loginLimiter = (req, res, next) => { limits.login++; return next(); };
  const limiter = (req, res, next) => { limits.calls++; assert.ok(req.user && req.user.accountId, 'the per-account limiter runs after the sign-in check'); return next(); };
  const comparePassword = async (password, hash) => hash === `hash:${password}`;
  const secretFile = path.join(resultsDir, '..', `secret-${path.basename(resultsDir)}`);
  fs.writeFileSync(secretFile, `${SECRET}\n`);
  mountTeamJobs(app, pool, { limiter, loginLimiter, comparePassword, resultsDir, secretFile });

  const fakeRes = () => ({
    statusCode: 200, body: null, headers: {}, headersSent: false,
    set(k, v) { this.headers[k] = v; }, status(c) { this.statusCode = c; return this; }, json(b) { this.body = b; this.headersSent = true; return this; },
  });
  const run = async (route, req) => {
    const res = fakeRes();
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
  const call = async (route, { body, accountId = MUFFINS, pcId = PC_OF[accountId], params = {}, query = {}, headers = {}, anon = false, token, authorization, raw, chunks } = {}) => {
    const auth = anon ? undefined : authorization ?? `Team ${token ?? await tokenOf(accountId, pcId)}`;
    const base = { body, params, query, headers: auth === undefined ? headers : { authorization: auth, ...headers }, socket: { remoteAddress: '203.0.113.9' } };
    if (raw === undefined && chunks === undefined) return run(route, base);
    const stream = Readable.from(chunks || [raw]);
    return run(route, Object.assign(stream, base, { body: undefined }));
  };
  const internal = (route, { body, params = {}, addr = '127.0.0.1', secret = SECRET, headers = {} } = {}) => run(route, {
    body, params, query: {}, socket: { remoteAddress: addr }, headers: { ...(secret === null ? {} : { 'x-team-secret': secret }), ...headers },
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
  const jobFolder = (id) => path.join(resultsDir, id);

  return {
    pool, jobs, pcs, accounts, tokenRows, memberSet, limits, sqlLog, routes, call, login, loginRaw, tokenOf, internal, makeJob, runningJob, upload, jobFolder, resultsDir,
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
      createdAt: new Date(T0).toISOString(), expiresAt: new Date(T0 + 600_000).toISOString(), claimedAccount: null, claimedPc: null, claimedAt: null, heartbeatAt: null, finishedAt: null,
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
