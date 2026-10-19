'use strict';
/**
 * Team jobs (ROADMAP Phase 1, "New: the team app"; DECISIONS B54, B55): jobs that need a real graphics card run on the three team PCs (War,
 * Muffins, Helix) in a small Windows app. This server queues a job, one PC claims it, uploads its result files and finishes it; the Discord
 * agent's runner (same machine) creates jobs and reads the results. Tables team_members, team_pcs, team_jobs, migration 057 (team_jobs.target_pc, migration 058; team_jobs.reported_at, migration 059).
 * Job kinds: `shots` (pictures of a proposal, uploaded as PNG files), `release` (the release checks of a new client on a team PC: one job, steps run in order, each step's
 * result uploaded as a `<step>.json` file beside the screens' PNGs as it finishes, then `done` with how each step went; the reporter reads them with the internal list route),
 * `clip` (short videos of a change: the PC uploads motion-JPEG files, and `done` turns each into an
 * mp4 with ffmpeg here, because the game's debug build has no video encoder) and `bench` (the release's benchmark runs on a team PC, handed over in `done` and stored
 * in the benchmark history, benchmarks.cjs, marked as team-PC runs; the `release` job, which server/death-muffin/team-release.sh queues per team PC after each client release, carries the same runs).
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
 *   POST /api/team/heartbeat                   the PC's state (+ optional `wait`, 0..25 seconds, default 0) -> { success, data: { serverTime, offer, cancel, queue } }   offer: null or the oldest queued job
 *                                              of the first kind in KIND_ORDER that has one (shots, then clip, then bench, then any other kind) that this PC has not declined; cancel: the ids of jobs this PC claimed that were cancelled in the last 10 minutes (the
 *                                              app stops the one it runs and ignores the rest); queue: the jobs this PC would be offered, in that order and the offer first, at most 20, each
 *                                              { id, kind, title, weightS } (the app's AFK notice lists them). With `wait` > 0 the request is held (long poll) while there is nothing to say:
 *                                              no offer for this PC and no cancel it has not been told, until a job this PC may take is queued (the runner creates one, or a
 *                                              running job goes back to the queue), one it runs is cancelled, or `wait` runs out; then it answers as it always does. The PC is
 *                                              stored at the start of the request. At most 10 requests of an account are held at once (more are answered at once, as with 0)
 *   POST /api/team/jobs/:id/claim              { pcId } -> { success, data: { id, kind, title, payload } }   409 `taken` when another PC got it first; a job made
 *                                              with a target PC is offered to and claimed by that PC only (403 `not_your_job` for another)
 *   POST /api/team/jobs/:id/decline            { pcId, reason } -> { success }   the job stays queued for the other PCs and is not offered to this one again
 *   PUT  /api/team/jobs/:id/files/:name        one file as the raw body, 40 a job (120 for a release job): a PNG (`image/png`, at most 20 MB; not for a clip job), for a clip job only a
 *                                              motion-JPEG clip (`<name>.mjpeg`, `video/x-motion-jpeg`, at most 48 MB, starting with a JPEG picture), for a release job only a step's
 *                                              result (`<name>.json`, `application/json`, at most 1 MB, valid JSON) -> { success, data: { name, bytes, width, height } } (no size for a JSON file)
 *   POST /api/team/jobs/:id/done               shots: { files, log, timings }; clip: { files: [the uploaded .mjpeg names], log, timings }, which turns each clip into
 *                                              <name>.mp4 (ffmpeg, below) and keeps the mp4 only; release: { steps: [{ step, ok, error?, ms? }], files: [uploaded .png/.json names],
 *                                              runs?: [the bench step's benchmark payloads, as for bench], log, timings }; bench: { runs: [the benchmark payloads DmApi.post_benchmark sends, at most 6, each at
 *                                              most 64 KB of JSON], log, timings } -> { success, data: { id, status } }. A bench run that does not validate (the words
 *                                              of POST /api/benchmarks) fails the job with those words and answers 400 with them. The body may be up to 1 MB (this
 *                                              route reads its own: server.js leaves it to it, DONE_BODY_MAX); a bigger one is 413 `too_large`
 *   POST /api/team/jobs/:id/fail               { error, log, steps? } -> { success, data: { id, status } }   (`steps` as in a release job's done: what the PC finished before it stopped)
 * The runner (loopback only, and X-Team-Secret equal to the contents of TEAM_SECRET_FILE; anything else answers 404):
 *   POST /internal/team/jobs                   { kind, title, weightS, payload, ttlS, targetPc?, supersede? } -> { success, data: { id, superseded? } }   (also removes the
 *                                              result folders of jobs that finished more than 14 days ago); supersede: true (needs targetPc) cancels this kind's
 *                                              other QUEUED jobs for that PC once the new one is stored (a running job is never touched)
 *   GET  /internal/team/jobs?kind=&status=&unreported=1&limit=   the rows as the one below returns each (files with absolute paths included), `{ jobs: [...] }`, oldest finish first:
 *                                              kind a job kind; status `finished` (done or failed), `open` (queued or running) or one status; unreported=1 only jobs not yet marked reported
 *   POST /internal/team/jobs/:id/reported      marks a finished job (done, failed, cancelled, expired) as reported (once; again is the same answer) -> { success, data: { id, reportedAt } }
 *   GET  /internal/team/jobs/:id               the row with its files (absolute paths): the pictures, step results and mp4s
 *   POST /internal/team/jobs/:id/cancel        -> { success, data: { id, status } }
 *   GET  /internal/team/pcs[?days=N]           PCs seen in the last 2 minutes (or the last N days, 1 to 365) with mode and state
 *
 * Errors are { success: false, code, error } and `error` is player-readable (the app shows it as it is): 400 bad_request, 401 bad_login / signed_out,
 * 403 not_team / wrong_pc / not_your_job, 404 not_found, 409 taken / not_running / too_many / not_finished, 413 too_large, 415 bad_type, 429 rate_limited / too_many_jobs
 * (rate_limited also when a bench run is past the account's daily benchmark cap),
 * 503 unavailable (a table is missing or the results folder is not writable), 500 server_error.
 * A running job whose PC sends no heartbeat for 3 minutes goes back to queued once (tries + 1); the second time it fails. A queued job past its
 * expires_at becomes expired. Both are swept on every heartbeat and every internal call, so no timer is needed.
 * Everything a PC sends is untrusted: strings are trimmed, stripped of control characters and capped; a result file must be a real PNG (or a motion-JPEG clip
 * that starts with a JPEG picture) of a sane size, with a name from a closed alphabet, written only under <resultsDir>/<job id>/.
 * A clip's mp4 is made by `/usr/bin/nice -n 10 $FFMPEG` (default /usr/bin/ffmpeg) started with an argument array, never a shell, with its working folder and HOME in
 * the job's folder (the service's unit lets it write nothing else), a 120 s limit (killed after it), crf 26 and, when the mp4 is not under 8 MB (Discord's limit for the
 * bot), crf 32; one transcode at a time on this machine. A clip that does not turn into a video fails the job with a readable reason.
 */
const crypto = require('crypto');
const { EventEmitter } = require('events');
const childProcess = require('child_process');
const fs = require('fs');
const path = require('path');
const { parseRun, saveRun, DAILY_CAP_ERROR } = require('./benchmarks.cjs');

const DEFAULT_RESULTS_DIR = '/home/ubuntu/death-muffin/team-results';
const DEFAULT_SECRET_FILE = '/home/ubuntu/death-muffin/discord-agent/secret';
const FILE_MAX_BYTES = 20 * 1024 * 1024;   // a picture: a busy 3840x2160 PNG passes 8 MB (Helix's release check, 2026-10-19)
const CLIP_MAX_BYTES = 48 * 1024 * 1024;  // one motion-JPEG clip (the game writes at most 4 clips of 8 s a variant, about 25 MB each at the most)
const MP4_MAX_BYTES = 8 * 1000 * 1000;    // the mp4 must be under this (Discord's 8 MB for the bot, counted the careful way: 8,000,000 bytes is under 8 MiB too)
const CLIP_CRF = 26;
const CLIP_CRF_SMALL = 32;                // the second try, when the first mp4 is not under MP4_MAX_BYTES
const FFMPEG_TIMEOUT_MS = 120 * 1000;     // one transcode; the process is killed after it
const DEFAULT_FFMPEG = '/usr/bin/ffmpeg';
const NICE = '/usr/bin/nice';
const FFMPEG_NOTE_MAX = 1500;             // characters of ffmpeg's own words kept in the job's log when a transcode fails
const FILES_PER_JOB = 40;
const RELEASE_FILES_PER_JOB = 120;        // a release job's screens alone are up to 4 resolutions x 2 UI scales x 6 shots, and every step has its result file
const JSON_MAX_BYTES = 1024 * 1024;       // one step's result file
const LIST_LIMIT_DEFAULT = 50;
const LIST_LIMIT_MAX = 100;
const RUNS_PER_JOB = 6;                   // benchmark runs a `bench` job hands over
const RUN_MAX_BYTES = 64 * 1024;          // JSON bytes of one benchmark run
const SEEN_DAYS_MAX = 365;
const DONE_BODY_MAX = 1024 * 1024;        // bytes of a `done` body: 6 bench runs of 64 KB and a 64 KB log, JSON-escaped, fit with room to spare
const DONE_ROUTE_RE = /^\/(?:api\/)?team\/jobs\/[0-9a-f]{12}\/done\/?$/;   // the route that reads its own body (server.js's JSON parser leaves it alone)
// The uploads read their own body too: a .json step result is sent as application/json, and server.js's JSON parser would read it first and leave
// the route waiting for a body already gone (2026-10-19: Helix's release checks timed out three times on install.json).
const FILES_ROUTE_RE = /^\/(?:api\/)?team\/jobs\/[0-9a-f]{12}\/files\/[^/]+$/;
const KIND_ORDER = ['shots', 'clip', 'release', 'bench'];   // what a heartbeat offers first: a release or bench job waits on its PC until it is quiet, so it must never hide a newer shots or clip job; other kinds come last
const KIND_RANK_SQL = `CASE kind ${KIND_ORDER.map((k, i) => `WHEN '${k}' THEN ${i}`).join(' ')} ELSE ${KIND_ORDER.length} END`;
const CANCEL_MINUTES = 10;                // a heartbeat names the PC's jobs cancelled this recently
const CANCELS_MAX = 20;
const WAIT_MAX_S = 25;                    // the longest a heartbeat may be held (`wait`, seconds); nginx's 60 s read timeout and Cloudflare's 100 s are above it
const HELD_MAX = 10;                      // held heartbeats of one account at a time; the next is answered at once
const RESULTS_KEEP_DAYS = 14;             // a finished job's result folder is removed when it has been finished this long
const PRUNE_BATCH = 500;                  // result folders looked at in one clean-up
const PNG_SIDE_MIN = 16;
const PNG_SIDE_MAX = 4096;
const LOG_MAX = 64 * 1024;
const ERROR_MAX = 400;
const QUIET_MINUTES = 3;
const SEEN_MINUTES = 2;
const DECLINES_MAX = 20;
const OPEN_JOBS_MAX = 50;                 // queued + running jobs the runner may have at once
const QUEUE_SHOWN = 20;                   // the heartbeat's `queue`: at most this many of the jobs this PC would be offered
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
const CLIP_NAME_RE = /^[a-z0-9][a-z0-9_-]{0,59}\.mjpeg$/;
const MP4_NAME_RE = /^[a-z0-9][a-z0-9_-]{0,59}\.mp4$/;
const JSON_NAME_RE = /^[a-z0-9][a-z0-9_-]{0,59}\.json$/;
const RESULT_NAME_RE = { result: [FILE_NAME_RE, MP4_NAME_RE, JSON_NAME_RE], stored: [FILE_NAME_RE, CLIP_NAME_RE, MP4_NAME_RE, JSON_NAME_RE] };   // what a job's listing shows (pictures and videos), and what its folder may hold
const CLIP_TYPE = 'video/x-motion-jpeg';
const KIND_CLIP = 'clip';
const KIND_RELEASE = 'release';
const STEP_NAMES = ['install', 'quit-loading', 'screens', 'stutter', 'bench', 'soak'];   // a release job's steps, in the order they run
const STATUS_FILTERS = { finished: ['done', 'failed'], open: ['queued', 'running'], queued: ['queued'], running: ['running'], done: ['done'], failed: ['failed'], cancelled: ['cancelled'], expired: ['expired'] };
const TERMINAL = ['done', 'failed', 'cancelled', 'expired'];
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

/** How long this heartbeat may be held, in seconds: the body's `wait` (a number, or text of one), 0 to 25; anything else, negative or missing is 0 (answer at once, as ever). */
function parseWait(req) {
  const raw = isObject(req.body) ? req.body.wait : undefined;
  const n = typeof raw === 'number' ? raw : typeof raw === 'string' && /^\d{1,3}(\.\d{1,3})?$/.test(raw.trim()) ? Number(raw) : 0;
  return Number.isFinite(n) && n > 0 ? Math.min(WAIT_MAX_S, n) : 0;
}

/** Validate the runner's new job (`targetPc`: the one PC that may take it, optional; `supersede`: also cancel the PC's other queued jobs of its kind). Returns { error } or { job }. */
function parseNewJob(body) {
  const b = isObject(body) ? body : {};
  const kind = typeof b.kind === 'string' ? b.kind.trim() : '';
  if (!KIND_RE.test(kind)) return { error: 'The job needs a kind (lowercase letters, digits and underscores).' };
  const title = text(b.title, 160);
  if (!title) return { error: 'The job needs a title.' };
  if (!isObject(b.payload)) return { error: 'The job needs a payload object.' };
  const payload = JSON.stringify(b.payload);
  if (payload.length > PAYLOAD_MAX) return { error: 'The job payload is too large.' };
  let targetPc = null;   // the one PC that may take the job; none = any team PC
  if (b.targetPc !== undefined && b.targetPc !== null) {
    targetPc = typeof b.targetPc === 'string' ? b.targetPc.trim() : '';
    if (!PC_ID_RE.test(targetPc)) return { error: 'The job\'s target PC is not a valid PC id.' };
  }
  const supersede = b.supersede === true;   // replace this kind's queued jobs for the same PC (a newer release's benchmark makes the older one pointless)
  if (b.supersede !== undefined && typeof b.supersede !== 'boolean') return { error: 'supersede must be true or false.' };
  if (supersede && targetPc === null) return { error: 'A job that supersedes others needs a target PC (the PC whose queued jobs of this kind it replaces).' };
  return { job: { kind, title, weightS: clampInt(b.weightS, 0, WEIGHT_MAX_S) ?? 60, payload, ttlS: clampInt(b.ttlS, TTL_MIN_S, TTL_MAX_S) ?? TTL_DEFAULT_S, targetPc, supersede } };
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

/**
 * Check a motion-JPEG clip: it must start with the JPEG marker FFD8, and its first picture's start-of-frame marker (found within the first 64 KB) gives a width and height
 * of 16 to 4096 pixels each (the same sanity as a PNG; a picture claiming more must not reach the decoder). The rest of the file is ffmpeg's to judge when `done` turns it
 * into a video. Returns { error } or { width, height }.
 */
function checkMjpeg(buf) {
  const notClip = { error: 'That file is not a motion-JPEG clip (it must start with a JPEG picture).' };
  if (!Buffer.isBuffer(buf) || buf.length < 4 || buf[0] !== 0xff || buf[1] !== 0xd8) return notClip;
  const end = Math.min(buf.length, 64 * 1024);
  let i = 2;
  while (i + 4 <= end) {
    if (buf[i] !== 0xff) return notClip;               // not on a marker: the picture's structure is lost
    const m = buf[i + 1];
    if (m === 0xff) { i++; continue; }                 // fill byte before a marker
    if (m === 0x01 || (m >= 0xd0 && m <= 0xd8)) { i += 2; continue; }   // markers that carry no length: TEM, RSTn, SOI
    if (m === 0xd9 || m === 0xda) return notClip;      // the picture's end or its data came before any frame header
    if (m >= 0xc0 && m <= 0xcf && m !== 0xc4 && m !== 0xc8 && m !== 0xcc) {   // SOF0..SOF15 (DHT, JPG and DAC are not frame headers)
      if (i + 9 > buf.length) return notClip;
      const height = buf.readUInt16BE(i + 5);
      const width = buf.readUInt16BE(i + 7);
      if (width < PNG_SIDE_MIN || height < PNG_SIDE_MIN || width > PNG_SIDE_MAX || height > PNG_SIDE_MAX) {
        return { error: `That clip is ${width} by ${height} pixels; each side must be ${PNG_SIDE_MIN} to ${PNG_SIDE_MAX}.` };
      }
      return { width, height };
    }
    i += 2 + buf.readUInt16BE(i + 2);                  // any other segment: skip its length
  }
  return notClip;
}

/** Check a step's result file: UTF-8 JSON (any value). Returns { error } or {}. */
function checkJson(buf) {
  if (!Buffer.isBuffer(buf) || !buf.length) return { error: 'That file is not JSON (it is empty).' };
  try {
    JSON.parse(buf.toString('utf8'));
  } catch {
    return { error: 'That file is not valid JSON.' };
  }
  return {};
}

/**
 * Validate a release job's steps: a list of 1 to 6, each `{ step, ok, error?, ms? }` with a step from STEP_NAMES (once) and `ok` true or false. `error` is kept as text (at most 400
 * characters, only when there is one), `ms` as a whole number of milliseconds 0 to a day. Returns { error } or { steps }.
 */
function cleanSteps(raw) {
  if (!Array.isArray(raw) || !raw.length || raw.length > STEP_NAMES.length) return { error: `The finished job must say how each step went (1 to ${STEP_NAMES.length} steps: ${STEP_NAMES.join(', ')}).` };
  const steps = [];
  for (const s of raw) {
    if (!isObject(s) || typeof s.step !== 'string' || !STEP_NAMES.includes(s.step) || typeof s.ok !== 'boolean') {
      return { error: `A step must name one of ${STEP_NAMES.join(', ')} and say whether it worked (ok true or false).` };
    }
    if (steps.some((x) => x.step === s.step)) return { error: `The step ${s.step} is listed twice.` };
    const out = { step: s.step, ok: s.ok };
    const error = text(s.error, ERROR_MAX);
    if (error) out.error = error;
    if (finite(s.ms)) out.ms = Math.min(86_400_000, Math.max(0, Math.round(s.ms)));
    steps.push(out);
  }
  return { steps };
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

/**
 * The files of a job's result folder: [{ name, bytes }] in name order. `which` is 'result' (the pictures and the mp4s: what the runner is shown) or 'stored' (also the
 * motion-JPEG clips waiting to be turned into videos: what counts against a job's 40 files). Only names the upload accepts; half-written parts are skipped.
 */
async function listFiles(resultsDir, id, which = 'result') {
  let entries;
  try {
    entries = await fs.promises.readdir(path.join(resultsDir, id), { withFileTypes: true });
  } catch (err) {
    if (err && err.code === 'ENOENT') return [];
    throw err;
  }
  const accepted = RESULT_NAME_RE[which];
  const out = [];
  for (const e of entries) {
    if (!e.isFile() || !accepted.some((re) => re.test(e.name))) continue;
    const st = await fs.promises.stat(path.join(resultsDir, id, e.name));
    out.push({ name: e.name, bytes: st.size });
  }
  return out.sort((a, b) => (a.name < b.name ? -1 : 1));
}

/** Write one file under <resultsDir>/<id>/ (folders 0750, the file 0640, put in place with a rename). Throws when the path would leave that folder. */
async function storeFile(resultsDir, id, name, buf) {
  if (!JOB_ID_RE.test(id) || !RESULT_NAME_RE.stored.some((re) => re.test(name))) throw new Error('unsafe result path');
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

/**
 * Does this mp4 hold video? Its top-level boxes must include ftyp, moov and an mdat that carries data: ffmpeg writes a video of no pictures (a moov and an empty mdat) and exits 0
 * when it decoded nothing, and that must not go out as a clip. Reads only the box headers. A file whose boxes do not fit its size (cut off) is not a video either.
 */
async function mp4HoldsVideo(file) {
  let fh = null;
  try {
    fh = await fs.promises.open(file, 'r');
    const { size } = await fh.stat();
    const seen = {};
    const head = Buffer.alloc(16);
    for (let at = 0, boxes = 0; at + 8 <= size && boxes < 64; boxes++) {
      const { bytesRead } = await fh.read(head, 0, 16, at);
      if (bytesRead < 8) return false;
      let len = head.readUInt32BE(0);
      let header = 8;
      if (len === 1 && bytesRead >= 16) { len = Number(head.readBigUInt64BE(8)); header = 16; }
      else if (len === 0) len = size - at;   // the last box runs to the end of the file
      if (len < header || at + len > size) return false;
      seen[head.toString('latin1', 4, 8)] = Math.max(seen[head.toString('latin1', 4, 8)] || 0, len - header);
      at += len;
    }
    return 'ftyp' in seen && 'moov' in seen && (seen.mdat || 0) > 0;
  } catch {
    return false;
  } finally {
    if (fh) await fh.close().catch(() => {});
  }
}

// ── Turning a clip into a video ──────────────────────────────────────────────────────────────────────────────────────────

/** ffmpeg's arguments for one clip (the contract's, one argument each: no shell reads them). `-f mjpeg` names the input's format, so ffmpeg never guesses it from the bytes. */
function ffmpegArgs(input, output, crf) {
  return ['-nostdin', '-hide_banner', '-loglevel', 'error', '-y',
    '-f', 'mjpeg', '-framerate', '30', '-i', input, '-t', '10', '-vf', "scale='min(960,iw)':-2",
    '-c:v', 'libx264', '-preset', 'veryfast', '-crf', String(crf), '-pix_fmt', 'yuv420p', '-movflags', '+faststart', '-an', '-f', 'mp4', output];
}

/**
 * Run `nice -n 10 <ffmpeg> <args>` and say how it ended: { ok: true } or { ok: false, why: 'missing' | 'timeout' | 'failed', note }. `why` is 'missing' when the program cannot be
 * started at all, 'timeout' when it ran past `timeoutMs` (it is killed), 'failed' for any other end but a clean exit 0 (`note`: the end of what ffmpeg said). It only starts a process
 * from an argument array, with the job's folder as its working folder and HOME, and a bare environment; it never throws.
 */
function runFfmpeg({ ffmpeg, args, cwd, timeoutMs, spawn = childProcess.spawn, nice = NICE }) {
  return new Promise((resolve) => {
    let child;
    let settled = false;
    let note = '';
    let timer = null;
    const settle = (result) => {
      if (settled) return;
      settled = true;
      if (timer) clearTimeout(timer);
      resolve({ note: note.trim().slice(-FFMPEG_NOTE_MAX), ...result });
    };
    try {
      child = spawn(nice, ['-n', '10', ffmpeg, ...args], {
        cwd, stdio: ['ignore', 'ignore', 'pipe'], windowsHide: true,
        env: { PATH: '/usr/local/bin:/usr/bin:/bin', HOME: cwd, LANG: 'C', AV_LOG_FORCE_NOCOLOR: '1' },
      });
    } catch (err) {
      return settle({ ok: false, why: 'missing', note: String((err && err.code) || err) });
    }
    if (child.stderr) child.stderr.on('data', (d) => { note = (note + d.toString('utf8')).slice(-4 * FFMPEG_NOTE_MAX); });
    child.on('error', (err) => settle({ ok: false, why: err && err.code === 'ENOENT' ? 'missing' : 'failed', note: String((err && err.code) || err) }));
    child.on('close', (code, signal) => {
      if (code === 0) return settle({ ok: true });
      return settle({ ok: false, why: 'failed', note: `${note}\n(ffmpeg ended with ${signal ? `signal ${signal}` : `code ${code}`})` });
    });
    timer = setTimeout(() => {
      try { child.kill('SIGKILL'); } catch { /* already gone */ }
      settle({ ok: false, why: 'timeout' });
    }, timeoutMs);
  });
}

// ── Routes ───────────────────────────────────────────────────────────────────────────────────────────────────────────────

/** Did this PC say "Not now" to the job? `result` is the job's result column (JSON or text): { declines: [{ pcId, reason, at }] }. Only `not_now`
 *  keeps a job from that PC for good; `busy` (another job was running) and `paused` only meant "not at that moment" (2026-10-19: a job offered while
 *  Helix's PC ran its release checks was declined as busy and, with one team PC, never offered again). */
function declinedBy(result, pcId) {
  const r = asJson(result);
  return isObject(r) && Array.isArray(r.declines) && r.declines.some((d) => isObject(d) && d.pcId === pcId && d.reason === 'not_now');
}

const STATUS_WORDS = {
  queued: 'This job is not running.', expired: 'This job ran out of time before a PC took it.', cancelled: 'This job was cancelled.',
  done: 'This job has already finished.', failed: 'This job has already finished.',
};

module.exports = function mountTeamJobs(app, pool, {
  limiter, loginLimiter, comparePassword, tokenDays = TOKEN_DAYS,
  resultsDir = process.env.TEAM_RESULTS_DIR || DEFAULT_RESULTS_DIR, secretFile = process.env.TEAM_SECRET_FILE || DEFAULT_SECRET_FILE,
  ffmpeg = process.env.FFMPEG || DEFAULT_FFMPEG,   // the clips' transcoder (the options below are for tests: a fake process, a short limit, a small size cap)
  spawn = childProcess.spawn, ffmpegTimeoutMs = FFMPEG_TIMEOUT_MS, mp4MaxBytes = MP4_MAX_BYTES,
  waitUnitMs = 1000,   // milliseconds in one second of a heartbeat's `wait` (a test makes it short)
} = {}) {
  const paths = (p) => [`/api${p}`, p];   // the app's routes on both paths (see the header)
  const fail = (res, status, code, error) => res.status(status).json({ success: false, code, error });
  const noTable = (res) => fail(res, 503, 'unavailable', 'Team jobs are not available just yet. Please try again later.');
  const jobNotFound = (res) => fail(res, 404, 'not_found', 'That job does not exist.');
  const notFound = (res) => res.status(404).json({ success: false, error: 'Not found' });

  /** Answer a thrown error: a missing table or an unwritable results folder is a readable 503, anything else a logged 500 (`serverError`: its player-readable text). */
  const answerError = (res, err, what, serverError = 'The server could not finish that. Please try again.') => {
    if (err && (err.code === 'ER_NO_SUCH_TABLE' || err.code === 'ER_BAD_FIELD_ERROR')) return noTable(res);   // (a column of a migration that is not applied yet is the same as a missing table)
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

  // ── Held heartbeats (long polling) ──
  const wakeups = new EventEmitter();   // fired whenever a queued job may have appeared or a job was cancelled: the held heartbeats look again
  wakeups.setMaxListeners(0);
  const wake = () => wakeups.emit('wake');
  const heldBy = new Map();             // account id -> its held heartbeats right now
  const told = new Map();               // "account/pc" -> the cancel ids the PC was last answered with (a cancel it has been told is not news when it asks again)

  /**
   * A heartbeat that may be held: opened before the first look (a wake between the look and the wait is not lost), closed when it answers. null when the account already has HELD_MAX held
   * (the heartbeat is then answered at once, as with no `wait`).
   */
  function openWaiter(account, res) {
    if ((heldBy.get(account) || 0) >= HELD_MAX) return null;
    heldBy.set(account, (heldBy.get(account) || 0) + 1);
    const w = { woken: false, gone: false, poke: null };
    const onWake = () => { w.woken = true; if (w.poke) w.poke(); };
    const onClose = () => { w.gone = true; if (w.poke) w.poke(); };   // the PC hung up
    wakeups.on('wake', onWake);
    if (res && typeof res.on === 'function') res.on('close', onClose);
    w.close = () => {
      wakeups.off('wake', onWake);
      if (res && typeof res.off === 'function') res.off('close', onClose);
      const left = (heldBy.get(account) || 1) - 1;
      if (left > 0) heldBy.set(account, left); else heldBy.delete(account);
    };
    // Sleeps until a wake, the PC hanging up or `ms` pass (a wake that came since the last sleep ends this one at once).
    w.sleep = (ms) => new Promise((resolve) => {
      if (w.woken || w.gone || ms <= 0) { w.woken = false; return resolve(); }
      const timer = setTimeout(() => { w.poke = null; resolve(); }, ms);
      w.poke = () => { clearTimeout(timer); w.poke = null; w.woken = false; resolve(); };
    });
    return w;
  }

  /** What a heartbeat answers: the offer for this PC and the ids of the jobs it claimed that were cancelled lately (after the sweep). */
  async function heartbeatAnswer(account, pcId) {
    await sweep();
    // The oldest queued job of the first kind that has one (KIND_ORDER) that this PC has not declined and that is not meant for another PC. At most OPEN_JOBS_MAX jobs are queued, so the list is every one of them.
    const [rows] = await pool.execute(
      `SELECT id, kind, title, weight_s, result, UNIX_TIMESTAMP(expires_at) AS expires_ts FROM team_jobs
        WHERE status = 'queued' AND expires_at > NOW() AND (target_pc IS NULL OR target_pc = ?) ORDER BY ${KIND_RANK_SQL} ASC, created_at ASC, id ASC LIMIT ${OPEN_JOBS_MAX}`, [pcId]);
    const j = rows.find((r) => !declinedBy(r.result, pcId));
    const offer = j ? { id: String(j.id), kind: String(j.kind), title: String(j.title), weightS: Number(j.weight_s), expiresAt: isoOf(j.expires_ts) } : null;
    // The jobs this PC claimed that were cancelled lately: a cancel reaches the PC within a heartbeat (it cannot know until it asks). A job cancelled while queued was never claimed.
    const [cancelled] = await pool.execute(
      `SELECT id FROM team_jobs WHERE status = 'cancelled' AND claimed_account = ? AND claimed_pc = ? AND finished_at > NOW() - INTERVAL ? MINUTE
        ORDER BY finished_at DESC, id ASC LIMIT ${CANCELS_MAX}`, [account, pcId, CANCEL_MINUTES]);
    // The queue this PC would be offered, in order (the app's AFK notice lists it, Helix 2026-10-19): the offer first, at most QUEUE_SHOWN.
    const queue = rows.filter((r) => !declinedBy(r.result, pcId)).slice(0, QUEUE_SHOWN)
      .map((r) => ({ id: String(r.id), kind: String(r.kind), title: String(r.title), weightS: Number(r.weight_s) }));
    return { offer, cancel: cancelled.map((c) => String(c.id)), queue };
  }
  /** Something to say right now: an offer, or a cancel this PC has not been told yet (a held heartbeat does not end for a cancel it already knows: the list keeps it for 10 minutes). */
  const hasNews = (answer, key) => !!answer.offer || answer.cancel.some((id) => !(told.get(key) || new Set()).has(id));

  // ── The quiet-PC sweep ──
  /**
   * Running jobs whose PC sent no heartbeat for QUIET_MINUTES go back to queued once (tries + 1) and fail the second time; queued jobs past
   * their expires_at become expired. The order matters: a job requeued just now has no heartbeat, so it is not failed in the same call.
   */
  async function sweep() {
    await pool.execute(
      "UPDATE team_jobs SET status = 'failed', error = ?, finished_at = NOW() WHERE status = 'running' AND tries >= 1 AND COALESCE(heartbeat_at, claimed_at) < NOW() - INTERVAL ? MINUTE",
      [QUIET_ERROR, QUIET_MINUTES]);
    const [requeued] = await pool.execute(
      "UPDATE team_jobs SET status = 'queued', tries = tries + 1, claimed_account = NULL, claimed_pc = NULL, claimed_at = NULL, heartbeat_at = NULL WHERE status = 'running' AND tries < 1 AND COALESCE(heartbeat_at, claimed_at) < NOW() - INTERVAL ? MINUTE",
      [QUIET_MINUTES]);
    await pool.execute("UPDATE team_jobs SET status = 'expired', finished_at = NOW() WHERE status = 'queued' AND expires_at <= NOW()");
    if (requeued && requeued.affectedRows > 0) wake();   // a job is queued again: a PC that waits for one may take it
  }

  const loadJob = async (id) => {
    const [rows] = await pool.execute('SELECT id, kind, status, claimed_account, claimed_pc, target_pc, result FROM team_jobs WHERE id = ? LIMIT 1', [id]);
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
    const waitS = parseWait(req);
    const state = JSON.stringify(pc.state);
    const waiter = waitS > 0 ? openWaiter(account, res) : null;   // opened first: a job queued while this heartbeat looks is not missed
    try {
      await pool.execute(
        `INSERT INTO team_pcs (account_id, pc_id, name, version, gpu, mode, state, last_seen) VALUES (?, ?, ?, ?, ?, ?, ?, NOW())
         ON DUPLICATE KEY UPDATE name = ?, version = ?, gpu = ?, mode = ?, state = ?, last_seen = NOW()`,
        [account, pcId, pc.name, pc.version, pc.gpu, pc.mode, state, pc.name, pc.version, pc.gpu, pc.mode, state]);
      // This PC's own running job is alive (renewed before the sweep, so a PC that woke up late keeps it).
      await pool.execute("UPDATE team_jobs SET heartbeat_at = NOW() WHERE status = 'running' AND claimed_account = ? AND claimed_pc = ?", [account, pcId]);
      const key = `${account}/${pcId}`;
      let answer = await heartbeatAnswer(account, pcId);
      if (waiter && !hasNews(answer, key)) {
        // Nothing to say: hold the request until there is, or `wait` runs out (then it answers as it always does).
        const deadline = Date.now() + waitS * waitUnitMs;
        for (;;) {
          await waiter.sleep(deadline - Date.now());
          if (waiter.gone) return;   // the PC hung up: nobody to answer
          answer = await heartbeatAnswer(account, pcId);
          if (hasNews(answer, key) || Date.now() >= deadline) break;
        }
      }
      told.set(key, new Set(answer.cancel));
      res.json({ success: true, data: { serverTime: new Date().toISOString(), offer: answer.offer, cancel: answer.cancel, queue: answer.queue } });
    } finally {
      if (waiter) waiter.close();
    }
  }));

  app.post(paths('/team/jobs/:id/claim'), ...guards, route('claim', async (req, res) => {
    const id = validJobId(req, res);
    if (!id) return;
    const pcId = actingPc(req, res);
    if (pcId === null) return;
    const account = req.user.accountId;
    const [claimed] = await pool.execute(
      "UPDATE team_jobs SET status = 'running', claimed_account = ?, claimed_pc = ?, claimed_at = NOW(), heartbeat_at = NOW() WHERE id = ? AND status = 'queued' AND expires_at > NOW() AND (target_pc IS NULL OR target_pc = ?)",
      [account, pcId, id, pcId]);
    if (!claimed.affectedRows) {
      const job = await loadJob(id);
      if (!job) return jobNotFound(res);
      if (job.status === 'queued' && job.target_pc != null && job.target_pc !== pcId) return fail(res, 403, 'not_your_job', 'This job is meant for another team PC.');
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
    // what the file is: a motion-JPEG video clip (a clip job), a step's JSON result (a release job) or a PNG picture (any job but a clip job)
    const sort = CLIP_NAME_RE.test(name) ? 'clip' : JSON_NAME_RE.test(name) ? 'result' : FILE_NAME_RE.test(name) ? 'picture' : null;
    if (!sort) return fail(res, 400, 'bad_request', 'A file name uses lowercase letters, digits, - and _, and ends in .png (a picture), .mjpeg (a video clip) or .json (a step\'s result), at most 60 characters before it.');
    const limit = sort === 'clip' ? CLIP_MAX_BYTES : sort === 'result' ? JSON_MAX_BYTES : FILE_MAX_BYTES;
    const type = sort === 'clip' ? CLIP_TYPE : sort === 'result' ? 'application/json' : 'image/png';
    if (String((req.headers || {})['content-type'] || '').split(';')[0].trim().toLowerCase() !== type) return fail(res, 415, 'bad_type', `Send the ${sort} as ${type}.`);
    const tooLarge = () => {
      res.set('Connection', 'close');   // the rest of the upload is not read; the connection ends with the answer
      return fail(res, 413, 'too_large', `That ${sort} is too large (the limit is ${limit / 1048576} MB).`);
    };
    const declared = Number((req.headers || {})['content-length']);
    if (Number.isFinite(declared) && declared > limit) return tooLarge();
    const job = await ownRunning(req, res, id, null);
    if (!job) return;
    if (sort === 'clip' && job.kind !== KIND_CLIP) return fail(res, 400, 'bad_request', 'This job takes pictures, not video clips.');
    if (sort === 'result' && job.kind !== KIND_RELEASE) return fail(res, 400, 'bad_request', 'This job takes no step results (.json files).');
    if (sort === 'picture' && job.kind === KIND_CLIP) return fail(res, 400, 'bad_request', 'This job takes video clips (.mjpeg), not pictures.');
    const cap = job.kind === KIND_RELEASE ? RELEASE_FILES_PER_JOB : FILES_PER_JOB;
    const files = await listFiles(resultsDir, id, 'stored');
    if (files.length >= cap && !files.some((f) => f.name === name)) return fail(res, 409, 'too_many', `A job takes at most ${cap} ${sort}s.`);
    let body;
    try {
      body = await readBody(req, limit);
    } catch (err) {
      if (err && err.code === 'UPLOAD_ABORTED') return;   // the PC went away mid-upload: nobody to answer
      throw err;
    }
    if (body.tooLarge) return tooLarge();
    const checked = sort === 'clip' ? checkMjpeg(body) : sort === 'result' ? checkJson(body) : checkPng(body);
    if (checked.error) return fail(res, 400, 'bad_request', checked.error);
    await storeFile(resultsDir, id, name, body);
    await pool.execute("UPDATE team_jobs SET heartbeat_at = NOW() WHERE id = ? AND status = 'running'", [id]);   // an upload shows the PC is alive
    res.json({ success: true, data: { name, bytes: body.length, width: checked.width, height: checked.height } });
  }));

  /** Remove what a clip job's PC uploaded and its half-made videos (the .mjpeg files and the parts of the mp4s): nothing reads them once the job has finished one way or the other. Best effort. */
  async function dropClipSources(id) {
    if (!JOB_ID_RE.test(id)) return;
    const dir = path.join(path.resolve(resultsDir), id);
    let entries;
    try { entries = await fs.promises.readdir(dir, { withFileTypes: true }); } catch { return; }
    for (const e of entries) {
      if (e.isFile() && (CLIP_NAME_RE.test(e.name) || /^\..+\.part$/.test(e.name))) await fs.promises.rm(path.join(dir, e.name), { force: true }).catch(() => {});
    }
  }

  /** Fail the running job `job` of this account with `error` and the log: false when it is not running any more (it is not changed then). */
  async function markFailed(accountId, id, job, error, log, extra = {}) {
    const old = isObject(asJson(job.result)) ? asJson(job.result) : {};
    const result = { ...old, ...extra, log: cleanLog(log) };
    const [failed] = await pool.execute(
      "UPDATE team_jobs SET status = 'failed', finished_at = NOW(), result = ?, error = ? WHERE id = ? AND status = 'running' AND claimed_account = ?",
      [JSON.stringify(result), error, id, accountId]);
    if (!failed.affectedRows) return false;
    if (job.kind === KIND_CLIP) await dropClipSources(id);
    return true;
  }

  /** Fail the running job `job` of this account with `error` and the PC's log; false when it is not running any more (the answer is sent). */
  async function failRunning(req, res, id, job, error, log, extra = {}) {
    if (await markFailed(req.user.accountId, id, job, error, log, extra)) return true;
    fail(res, 409, 'not_running', 'This job is not running any more.');
    return false;
  }

  /**
   * A `bench` job's done: its runs (the benchmark payloads the game queued, `DmApi.post_benchmark`'s body) are validated as POST /api/benchmarks validates them
   * and stored for the claiming account with source 'team' and this PC's id. Anything wrong with the runs fails the job with the readable reason and answers
   * 400 with it (a retry would send the same runs); a database error leaves the job running, for the PC to send again (a stored run answers its first id).
   */
  async function finishBench(req, res, id, job, b) {
    const refuse = async (status, code, reason) => {
      if (await failRunning(req, res, id, job, text(reason, ERROR_MAX), b.log)) fail(res, status, code, reason);
    };
    const runs = Array.isArray(b.runs) ? b.runs : [];
    if (!runs.length) return refuse(400, 'bad_request', 'A finished benchmark job must carry its runs.');
    if (runs.length > RUNS_PER_JOB) return refuse(400, 'bad_request', `A benchmark job takes at most ${RUNS_PER_JOB} runs.`);
    const parsed = [];
    for (let i = 0; i < runs.length; i++) {
      const label = runs.length > 1 ? `Run ${i + 1}: ` : '';
      if (!isObject(runs[i]) || Buffer.byteLength(JSON.stringify(runs[i])) > RUN_MAX_BYTES) return refuse(400, 'bad_request', `${label}This benchmark run is not readable or is too large.`);
      const p = parseRun(runs[i]);
      if (p.error) return refuse(400, 'bad_request', label + p.error);
      parsed.push(p.run);
    }
    const stored = [];
    for (const r of parsed) {
      const saved = await saveRun(pool, req.user.accountId, r, { source: 'team', sourcePc: req.user.pcId });
      if (saved.capped) return refuse(429, 'rate_limited', DAILY_CAP_ERROR);
      stored.push({ clientRunId: r.clientRunId, id: saved.id });
    }
    const old = isObject(asJson(job.result)) ? asJson(job.result) : {};
    const result = { ...old, files: [], runs: stored, log: cleanLog(b.log), timings: cleanTimings(b.timings) };
    const [done] = await pool.execute(
      "UPDATE team_jobs SET status = 'done', finished_at = NOW(), result = ?, error = NULL WHERE id = ? AND status = 'running' AND claimed_account = ?",
      [JSON.stringify(result), id, req.user.accountId]);
    if (!done.affectedRows) return fail(res, 409, 'not_running', 'This job is not running any more.');
    return res.json({ success: true, data: { id, status: 'done' } });
  }

  // ── A release job's done: how each step went, and the bench step's runs ──
  /**
   * `done` of a release job: `steps` (cleanSteps: what the report shows for each step), `files` (the pictures and step results it uploaded, all of which must be on disk) and
   * optionally `runs`, the bench step's benchmark payloads, which are stored in the benchmark history for the claiming account like a bench job's (source 'team'): a run that does not
   * validate, or one past the daily cap, does not fail the job; it marks the bench step as failed with the reason, and none of the runs is stored. The job is `done` whatever its steps say
   * (a failed step is a result, not a failed job). A bad body is 400 and leaves the job running.
   */
  async function finishRelease(req, res, id, job, b) {
    const cleaned = cleanSteps(b.steps);
    if (cleaned.error) return fail(res, 400, 'bad_request', cleaned.error);
    const steps = cleaned.steps;
    const named = Array.isArray(b.files) ? b.files : [];
    const cap = RELEASE_FILES_PER_JOB;
    if (named.length > cap || !named.every((n) => typeof n === 'string' && (FILE_NAME_RE.test(n) || JSON_NAME_RE.test(n)))) {
      return fail(res, 400, 'bad_request', `The finished job must name its pictures and step results (up to ${cap}, like bench.json or 1920x1080_bag.png).`);
    }
    const onDisk = new Map((await listFiles(resultsDir, id)).map((f) => [f.name, f.bytes]));
    const missing = named.find((n) => !onDisk.has(n));
    if (missing) return fail(res, 400, 'bad_request', `The file ${missing} was never uploaded.`);
    let stored;
    if (b.runs !== undefined) {
      const bench = steps.find((x) => x.step === 'bench');
      if (!bench) return fail(res, 400, 'bad_request', 'Benchmark runs need a bench step.');
      const runs = Array.isArray(b.runs) ? b.runs : [];
      const parsed = [];
      let why = '';
      if (!runs.length) why = 'The bench step carried no runs.';
      else if (runs.length > RUNS_PER_JOB) why = `A benchmark takes at most ${RUNS_PER_JOB} runs.`;
      for (let i = 0; !why && i < runs.length; i++) {
        const label = runs.length > 1 ? `Run ${i + 1}: ` : '';
        if (!isObject(runs[i]) || Buffer.byteLength(JSON.stringify(runs[i])) > RUN_MAX_BYTES) { why = `${label}This benchmark run is not readable or is too large.`; break; }
        const p = parseRun(runs[i]);
        if (p.error) { why = label + p.error; break; }
        parsed.push(p.run);
      }
      if (!why) {
        stored = [];
        for (const r of parsed) {
          const saved = await saveRun(pool, req.user.accountId, r, { source: 'team', sourcePc: req.user.pcId });
          if (saved.capped) { why = DAILY_CAP_ERROR; break; }
          stored.push({ clientRunId: r.clientRunId, id: saved.id });
        }
      }
      if (why) {   // the benchmark could not be kept: the report says so, the other steps stand
        bench.ok = false;
        bench.error = text(why, ERROR_MAX);
      }
    }
    const old = isObject(asJson(job.result)) ? asJson(job.result) : {};
    const result = { ...old, steps, files: [...new Set(named)].map((n) => ({ name: n, bytes: onDisk.get(n) })), log: cleanLog(b.log), timings: cleanTimings(b.timings) };
    if (stored) result.runs = stored;
    const [done] = await pool.execute(
      "UPDATE team_jobs SET status = 'done', finished_at = NOW(), result = ?, error = NULL WHERE id = ? AND status = 'running' AND claimed_account = ?",
      [JSON.stringify(result), id, req.user.accountId]);
    if (!done.affectedRows) return fail(res, 409, 'not_running', 'This job is not running any more.');
    return res.json({ success: true, data: { id, status: 'done' } });
  }

  // ── A clip job's done: every uploaded clip becomes an mp4 ──
  const clipsFinishing = new Map();   // job id -> the promise of its finish: a resent done (the app gives up on an answer after a while) joins it instead of starting a second transcode
  let clipQueue = Promise.resolve();  // one transcode at a time on this machine (each is niced, but a burst of them would still crowd the live game servers)

  /**
   * One clip: `<name>.mjpeg` becomes `<name>.mp4` (crf 26; crf 32 when that is not under mp4MaxBytes), the mjpeg is deleted. Returns { bytes, crf } or { error, note }:
   * `error` is the player-readable reason, `note` what ffmpeg said (for the log). Nothing but the finished mp4 is left behind (the part file is removed whatever happens).
   */
  async function transcodeOne(id, mjpeg) {
    const dir = path.join(path.resolve(resultsDir), id);
    const base = mjpeg.replace(/\.mjpeg$/, '');
    const input = path.join(dir, mjpeg);
    const target = path.join(dir, `${base}.mp4`);
    const part = path.join(dir, `.${base}.${crypto.randomBytes(4).toString('hex')}.part`);
    const damaged = `The clip ${base} could not be turned into a video (the file may be damaged or cut off).`;
    const limitSeconds = Math.max(1, Math.round(ffmpegTimeoutMs / 1000));
    const limitWords = `${limitSeconds} second${limitSeconds === 1 ? '' : 's'}`;
    let bytes = 0;
    try {
      for (const crf of [CLIP_CRF, CLIP_CRF_SMALL]) {
        const r = await runFfmpeg({ ffmpeg, args: ffmpegArgs(input, part, crf), cwd: dir, timeoutMs: ffmpegTimeoutMs, spawn });
        if (!r.ok) {
          const error = r.why === 'missing' ? 'The server cannot make videos just now (its video tool is not available).'
            : r.why === 'timeout' ? `The clip ${base} took more than ${limitWords} to turn into a video, so it was stopped.` : damaged;
          return { error, note: r.note };
        }
        const st = await fs.promises.stat(part).catch(() => null);
        if (!st || !st.isFile() || st.size < 1 || !(await mp4HoldsVideo(part))) return { error: damaged, note: 'ffmpeg made no video with pictures in it' };
        bytes = st.size;
        if (bytes < mp4MaxBytes) {
          await fs.promises.chmod(part, 0o640);
          await fs.promises.rename(part, target);
          await fs.promises.rm(input, { force: true });
          return { bytes, crf };
        }
      }
      return { error: `The video of ${base} is ${(bytes / 1000000).toFixed(1)} MB even at the lower quality, and Discord takes at most ${Math.round(mp4MaxBytes / 1000000)} MB. Record a shorter clip.`, note: '' };
    } finally {
      await fs.promises.rm(part, { force: true }).catch(() => {});
    }
  }

  /**
   * The finish of a clip job (the PC's done): each named clip is turned into a video (one that an earlier try of this done already made is kept), then the job is done with
   * the videos in its result. A clip that does not turn into a video fails the job with the reason (a second try would send the same clip). Returns { status, body }.
   */
  async function finishClipNow(accountId, id, job, named, log, timings) {
    const refuse = (status, code, error) => ({ status, body: { success: false, code, error } });
    const names = [...new Set(named)];
    const stored = new Map((await listFiles(resultsDir, id, 'stored')).map((f) => [f.name, f.bytes]));
    const missing = names.find((n) => !stored.has(n) && !stored.has(n.replace(/\.mjpeg$/, '.mp4')));
    if (missing) return refuse(400, 'bad_request', `The clip ${missing} was never uploaded.`);
    const made = [];
    for (const n of names) {
      await pool.execute("UPDATE team_jobs SET heartbeat_at = NOW() WHERE id = ? AND status = 'running'", [id]);   // a long transcode keeps the job alive
      const mp4 = n.replace(/\.mjpeg$/, '.mp4');
      if (!stored.has(n)) { made.push({ name: mp4, bytes: stored.get(mp4) }); continue; }   // turned into a video by an earlier try of this done
      const r = await transcodeOne(id, n);
      if (r.error) {
        console.error(`team clip ${id}/${n}:`, r.error, String(r.note || '').replace(/\s+/g, ' ').slice(0, 300));
        const detail = r.note ? `${cleanLog(log)}\n\nThe server's video tool said:\n${r.note}` : log;
        if (!(await markFailed(accountId, id, job, text(r.error, ERROR_MAX), detail))) return refuse(409, 'not_running', 'This job is not running any more.');
        return refuse(400, 'bad_request', r.error);
      }
      made.push({ name: mp4, bytes: r.bytes, crf: r.crf });
    }
    const old = isObject(asJson(job.result)) ? asJson(job.result) : {};
    const result = { ...old, files: made, log: cleanLog(log), timings: cleanTimings(timings) };
    const [done] = await pool.execute(
      "UPDATE team_jobs SET status = 'done', finished_at = NOW(), result = ?, error = NULL WHERE id = ? AND status = 'running' AND claimed_account = ?",
      [JSON.stringify(result), id, accountId]);
    if (!done.affectedRows) return refuse(409, 'not_running', 'This job is not running any more.');
    return { status: 200, body: { success: true, data: { id, status: 'done' } } };
  }

  async function finishClip(req, res, id, job, b) {
    const named = Array.isArray(b.files) ? b.files : [];
    if (!named.length || named.length > FILES_PER_JOB || !named.every((n) => typeof n === 'string' && CLIP_NAME_RE.test(n))) {
      return fail(res, 400, 'bad_request', `The finished job must name its clips (1 to ${FILES_PER_JOB}, like low_wraith.mjpeg).`);
    }
    let finishing = clipsFinishing.get(id);
    if (!finishing) {
      const run = () => finishClipNow(req.user.accountId, id, job, named, b.log, b.timings);
      const turn = clipQueue.then(run, run);
      clipQueue = turn.then(() => {}, () => {});
      finishing = turn.finally(() => clipsFinishing.delete(id));
      clipsFinishing.set(id, finishing);
    }
    const out = await finishing;
    return res.status(out.status).json(out.body);
  }

  /**
   * The JSON body of a route whose body may be bigger than server.js's global parser takes (it skips DONE_ROUTE): read here, after the sign-in check, up to `max` bytes.
   * A body that says it is bigger (Content-Length) is refused before anything is read; one that turns out bigger stops at the cap. Both are 413 `too_large` in plain words,
   * a body that is not JSON is 400. A body that is already parsed (req.body) is left as it is.
   */
  const jsonBody = (max, what) => async (req, res, next) => {
    if (req.body !== undefined || typeof req.on !== 'function') return next();
    try {
      const tooLarge = () => {
        res.set('Connection', 'close');   // the rest of the body is not read; the connection ends with the answer
        return fail(res, 413, 'too_large', `That ${what} is too large (the limit is ${Math.round(max / 1048576)} MB).`);
      };
      const declared = Number((req.headers || {})['content-length']);
      if (Number.isFinite(declared) && declared > max) return tooLarge();
      let buf;
      try {
        buf = await readBody(req, max);
      } catch (err) {
        if (err && err.code === 'UPLOAD_ABORTED') return undefined;   // the PC went away mid-body: nobody to answer
        throw err;
      }
      if (buf.tooLarge) return tooLarge();
      try {
        req.body = buf.length ? JSON.parse(buf.toString('utf8')) : {};
      } catch {
        return fail(res, 400, 'bad_request', `That ${what} could not be read.`);
      }
    } catch (err) {
      return answerError(res, err, 'done');
    }
    return next();
  };

  app.post(paths('/team/jobs/:id/done'), ...guards, jsonBody(DONE_BODY_MAX, 'result'), route('done', async (req, res) => {
    const id = validJobId(req, res);
    if (!id) return;
    const b = isObject(req.body) ? req.body : {};
    const job = await ownRunning(req, res, id, 'done');
    if (!job) return;
    if (job.kind === 'bench') return finishBench(req, res, id, job, b);
    if (job.kind === KIND_CLIP) return finishClip(req, res, id, job, b);
    if (job.kind === KIND_RELEASE) return finishRelease(req, res, id, job, b);
    const named = Array.isArray(b.files) ? b.files : [];
    if (named.length > FILES_PER_JOB || !named.every((n) => typeof n === 'string' && FILE_NAME_RE.test(n))) {
      return fail(res, 400, 'bad_request', `The finished job must name its pictures (up to ${FILES_PER_JOB}, like shot_1.png).`);
    }
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
    // a release job that stops halfway still reports the steps it finished (a list that does not read is left out: the job fails all the same)
    const steps = job.kind === KIND_RELEASE && Array.isArray(b.steps) ? cleanSteps(b.steps) : {};
    if (!(await failRunning(req, res, id, job, text(b.error, ERROR_MAX) || 'The team PC could not finish this job.', b.log, steps.steps ? { steps: steps.steps } : {}))) return;
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

  const JOB_COLS = `id, kind, title, weight_s, payload, status, target_pc, UNIX_TIMESTAMP(created_at) AS created_ts, UNIX_TIMESTAMP(expires_at) AS expires_ts, claimed_account, claimed_pc,
    UNIX_TIMESTAMP(claimed_at) AS claimed_ts, UNIX_TIMESTAMP(heartbeat_at) AS heartbeat_ts, UNIX_TIMESTAMP(finished_at) AS finished_ts, UNIX_TIMESTAMP(reported_at) AS reported_ts, result, error, tries`;

  /**
   * Remove the result folders of jobs that finished more than RESULTS_KEEP_DAYS ago: only direct children of the results folder named like a job id (12 lowercase hex),
   * only real directories (a symlink or a file with such a name is left alone, and nothing is ever followed through one), only when the job's row says it finished that
   * long ago (a running or queued job, a recent one and a folder with no row stay). Best effort: a failure is logged and never stops what called it.
   */
  async function pruneResults() {
    try {
      const root = path.resolve(resultsDir);
      let entries;
      try {
        entries = await fs.promises.readdir(root, { withFileTypes: true });
      } catch (err) {
        if (err && err.code === 'ENOENT') return;
        throw err;
      }
      const ids = entries.filter((e) => e.isDirectory() && !e.isSymbolicLink() && JOB_ID_RE.test(e.name)).map((e) => e.name).slice(0, PRUNE_BATCH);
      if (!ids.length) return;
      const [old] = await pool.execute(
        `SELECT id FROM team_jobs WHERE finished_at IS NOT NULL AND finished_at < NOW() - INTERVAL ? DAY AND id IN (${ids.map(() => '?').join(', ')})`, [RESULTS_KEEP_DAYS, ...ids]);
      for (const row of old) {
        const id = String(row.id);
        const dir = path.join(root, id);
        if (!JOB_ID_RE.test(id) || path.dirname(dir) !== root) continue;
        const st = await fs.promises.lstat(dir).catch(() => null);
        if (st && st.isDirectory() && !st.isSymbolicLink()) await fs.promises.rm(dir, { recursive: true, force: true });
      }
    } catch (err) {
      console.error('team results clean-up error:', (err && (err.code || err.message)) || err);
    }
  }

  app.post('/internal/team/jobs', internal, internalRoute('create', async (req, res) => {
    const parsed = parseNewJob(req.body);
    if (parsed.error) return fail(res, 400, 'bad_request', parsed.error);
    const j = parsed.job;
    await pruneResults();
    const [[{ n }]] = await pool.execute("SELECT COUNT(*) AS n FROM team_jobs WHERE status IN ('queued', 'running')");
    if (Number(n) >= OPEN_JOBS_MAX) return fail(res, 429, 'too_many_jobs', `There are already ${OPEN_JOBS_MAX} jobs waiting or running.`);
    for (let attempt = 0; attempt < 3; attempt++) {
      const id = crypto.randomBytes(6).toString('hex');
      try {
        await pool.execute(
          "INSERT INTO team_jobs (id, kind, title, weight_s, payload, status, created_at, expires_at, target_pc) VALUES (?, ?, ?, ?, ?, 'queued', NOW(3), NOW() + INTERVAL ? SECOND, ?)",
          [id, j.kind, j.title, j.weightS, j.payload, j.ttlS, j.targetPc]);
        if (!j.supersede) { wake(); return res.json({ success: true, data: { id } }); }
        // The new job is stored: now the PC's older queued jobs of this kind are pointless (never a running one).
        const [replaced] = await pool.execute(
          "UPDATE team_jobs SET status = 'cancelled', finished_at = NOW() WHERE kind = ? AND target_pc = ? AND status = 'queued' AND id <> ?", [j.kind, j.targetPc, id]);
        wake();
        return res.json({ success: true, data: { id, superseded: Number(replaced.affectedRows) } });
      } catch (err) {
        if (!(err && err.code === 'ER_DUP_ENTRY')) throw err;   // a random id that already exists: draw another
      }
    }
    return fail(res, 500, 'server_error', 'The server could not make a job id. Please try again.');
  }));

  /** One job row as the runner reads it (status, times as ISO strings, payload, result, error, and its files with absolute paths). */
  const jobData = async (j) => {
    const id = String(j.id);
    const files = (await listFiles(resultsDir, id)).map((f) => ({ ...f, path: path.join(path.resolve(resultsDir), id, f.name) }));
    return {
      id, kind: String(j.kind), title: String(j.title), weightS: Number(j.weight_s), payload: asJson(j.payload) || {}, status: String(j.status), tries: Number(j.tries),
      targetPc: j.target_pc == null ? null : String(j.target_pc), createdAt: isoOf(j.created_ts), expiresAt: isoOf(j.expires_ts), claimedAccount: j.claimed_account == null ? null : Number(j.claimed_account), claimedPc: j.claimed_pc == null ? null : String(j.claimed_pc),
      claimedAt: isoOf(j.claimed_ts), heartbeatAt: isoOf(j.heartbeat_ts), finishedAt: isoOf(j.finished_ts), reportedAt: isoOf(j.reported_ts),
      result: asJson(j.result), error: j.error == null ? null : String(j.error), files,
    };
  };

  /**
   * The reporter's list: `kind` (a job kind), `status` (`finished` = done or failed, `open` = queued or running, or one status), `unreported=1` (no reported_at yet), `limit` (1 to 100, default 50).
   * Oldest finish first (a job that has not finished, by its creation), then id. Each row is what GET /internal/team/jobs/:id returns.
   */
  app.get('/internal/team/jobs', internal, internalRoute('list', async (req, res) => {
    const q = req.query || {};
    const where = [];
    const params = [];
    if (q.kind !== undefined) {
      if (typeof q.kind !== 'string' || !KIND_RE.test(q.kind)) return fail(res, 400, 'bad_request', 'kind is a job kind (lowercase letters, digits and underscores).');
      where.push('kind = ?');
      params.push(q.kind);
    }
    if (q.status !== undefined) {
      const wanted = typeof q.status === 'string' ? STATUS_FILTERS[q.status] : undefined;
      if (!wanted) return fail(res, 400, 'bad_request', `status is one of ${Object.keys(STATUS_FILTERS).join(', ')}.`);
      where.push(`status IN (${wanted.map((w) => `'${w}'`).join(', ')})`);   // (the words come from the closed list above)
    }
    if (q.unreported !== undefined) {
      if (q.unreported !== '1' && q.unreported !== '0') return fail(res, 400, 'bad_request', 'unreported is 1 (only jobs not reported yet) or 0.');
      if (q.unreported === '1') where.push('reported_at IS NULL');
    }
    let limit = LIST_LIMIT_DEFAULT;
    if (q.limit !== undefined) {
      limit = typeof q.limit === 'string' && /^\d{1,3}$/.test(q.limit) ? Number(q.limit) : 0;
      if (limit < 1 || limit > LIST_LIMIT_MAX) return fail(res, 400, 'bad_request', `limit is a whole number from 1 to ${LIST_LIMIT_MAX}.`);
    }
    const [rows] = await pool.execute(
      `SELECT ${JOB_COLS} FROM team_jobs${where.length ? ` WHERE ${where.join(' AND ')}` : ''} ORDER BY COALESCE(finished_at, created_at) ASC, id ASC LIMIT ${limit}`, params);
    res.json({ success: true, data: { jobs: await Promise.all(rows.map(jobData)) } });
  }));

  app.get('/internal/team/jobs/:id', internal, internalRoute('get', async (req, res) => {
    const id = validJobId(req, res);
    if (!id) return;
    const [rows] = await pool.execute(`SELECT ${JOB_COLS} FROM team_jobs WHERE id = ? LIMIT 1`, [id]);
    const j = rows[0];
    if (!j) return jobNotFound(res);
    res.json({ success: true, data: await jobData(j) });
  }));

  /** The report that holds a finished job's result was posted: reported_at is set once (a second call answers the same time). Only a job that has finished, was cancelled or expired. */
  app.post('/internal/team/jobs/:id/reported', internal, internalRoute('reported', async (req, res) => {
    const id = validJobId(req, res);
    if (!id) return;
    const [marked] = await pool.execute(
      `UPDATE team_jobs SET reported_at = NOW() WHERE id = ? AND reported_at IS NULL AND status IN (${TERMINAL.map((t) => `'${t}'`).join(', ')})`, [id]);
    if (!marked.affectedRows) {
      const job = await loadJob(id);
      if (!job) return jobNotFound(res);
      if (!TERMINAL.includes(job.status)) return fail(res, 409, 'not_finished', 'That job has not finished yet.');
    }
    const [[row]] = await pool.execute('SELECT UNIX_TIMESTAMP(reported_at) AS reported_ts FROM team_jobs WHERE id = ? LIMIT 1', [id]);
    res.json({ success: true, data: { id, reportedAt: isoOf(row && row.reported_ts) } });
  }));

  app.post('/internal/team/jobs/:id/cancel', internal, internalRoute('cancel', async (req, res) => {
    const id = validJobId(req, res);
    if (!id) return;
    const [cancelled] = await pool.execute("UPDATE team_jobs SET status = 'cancelled', finished_at = NOW() WHERE id = ? AND status IN ('queued', 'running')", [id]);
    if (!cancelled.affectedRows) {
      const job = await loadJob(id);
      if (!job) return jobNotFound(res);
      if (job.status !== 'cancelled') return fail(res, 409, 'not_running', 'That job has already finished.');
    } else {
      const job = await loadJob(id);   // a cancelled clip job's uploaded clips are of no use to anyone
      if (job && job.kind === KIND_CLIP) await dropClipSources(id);
      wake();   // a PC that runs it, and one that waits to be offered what a cancel puts out of the queue, look again
    }
    res.json({ success: true, data: { id, status: 'cancelled' } });
  }));

  app.get('/internal/team/pcs', internal, internalRoute('pcs', async (req, res) => {
    let minutes = SEEN_MINUTES;   // ?days=N: every PC seen in the last N days (the benchmark after a release goes to each of them)
    const days = (req.query || {}).days;
    if (days !== undefined) {
      const n = typeof days === 'string' && /^\d{1,3}$/.test(days) ? Number(days) : 0;
      if (n < 1 || n > SEEN_DAYS_MAX) return fail(res, 400, 'bad_request', `days is a whole number from 1 to ${SEEN_DAYS_MAX}.`);
      minutes = n * 1440;
    }
    const [rows] = await pool.execute(
      `SELECT p.account_id, a.username, p.pc_id, p.name, p.version, p.gpu, p.mode, p.state, UNIX_TIMESTAMP(p.last_seen) AS seen_ts
         FROM team_pcs p LEFT JOIN accounts a ON a.id = p.account_id WHERE p.last_seen > NOW() - INTERVAL ? MINUTE ORDER BY p.last_seen DESC`,
      [minutes]);
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
module.exports.parseWait = parseWait;
module.exports.WAIT_MAX_S = WAIT_MAX_S;
module.exports.HELD_MAX = HELD_MAX;
module.exports.checkPng = checkPng;
module.exports.checkMjpeg = checkMjpeg;
module.exports.checkJson = checkJson;
module.exports.cleanSteps = cleanSteps;
module.exports.STEP_NAMES = STEP_NAMES;
module.exports.RELEASE_FILES_PER_JOB = RELEASE_FILES_PER_JOB;
module.exports.JSON_MAX_BYTES = JSON_MAX_BYTES;
module.exports.ffmpegArgs = ffmpegArgs;
module.exports.runFfmpeg = runFfmpeg;
module.exports.mp4HoldsVideo = mp4HoldsVideo;
module.exports.cleanLog = cleanLog;
module.exports.FILE_MAX_BYTES = FILE_MAX_BYTES;
module.exports.CLIP_MAX_BYTES = CLIP_MAX_BYTES;
module.exports.MP4_MAX_BYTES = MP4_MAX_BYTES;
module.exports.FFMPEG_TIMEOUT_MS = FFMPEG_TIMEOUT_MS;
module.exports.FILES_PER_JOB = FILES_PER_JOB;
module.exports.OPEN_JOBS_MAX = OPEN_JOBS_MAX;
module.exports.RUNS_PER_JOB = RUNS_PER_JOB;
module.exports.DONE_BODY_MAX = DONE_BODY_MAX;
module.exports.KIND_ORDER = KIND_ORDER;
/** Whether `req` is the route that reads its own, bigger JSON body (server.js's global parser skips it). */
module.exports.readsOwnBody = (req) => {
  if (!req) return false;
  const p = String(req.path || req.url || '').split('?')[0];
  return (req.method === 'POST' && DONE_ROUTE_RE.test(p)) || (req.method === 'PUT' && FILES_ROUTE_RE.test(p));
};
module.exports.RESULTS_KEEP_DAYS = RESULTS_KEEP_DAYS;
module.exports.RUN_MAX_BYTES = RUN_MAX_BYTES;
module.exports.DEFAULT_RESULTS_DIR = DEFAULT_RESULTS_DIR;
module.exports.DEFAULT_SECRET_FILE = DEFAULT_SECRET_FILE;
