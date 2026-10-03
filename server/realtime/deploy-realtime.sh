#!/usr/bin/env bash
# =============================================================================
# Crossworlds realtime co-op service — self-contained VPS deploy
# Generated 2026-07-02T20:46:25.782Z from the local repo. Review before running.
#
# Run on playcrossworlds.com:   sudo bash deploy-realtime.sh
# Roll everything back:         sudo bash deploy-realtime.sh --rollback
#
# What it does (and does NOT do):
#   - Creates /opt/rod-realtime/ (new) + a systemd service on loopback :5000
#   - Adds ONE location block to the existing 443 vhost (backed up first;
#     auto-restored if 'nginx -t' fails — the live site cannot be left broken)
#   - Does NOT touch rod-auth, the dashboard, the database, or ports
#     3000/4000/7777/3001. The auth server is never restarted.
# =============================================================================
set -euo pipefail

SVC=rod-realtime
DIR=/opt/rod-realtime
UNIT=/etc/systemd/system/rod-realtime.service
PORT=5000

if [[ "${1:-}" == "--rollback" ]]; then
  echo "[rollback] stopping and removing $SVC ..."
  systemctl disable --now "$SVC" 2>/dev/null || true
  rm -f "$UNIT"; systemctl daemon-reload
  rm -rf "$DIR"
  echo "[rollback] service removed."
  echo "[rollback] NOTE: restore the nginx vhost from its .bak.* file manually if you added the proxy block:"
  echo "           ls -t /etc/nginx/**/*.bak.* 2>/dev/null | head"
  echo "           then: nginx -t && systemctl reload nginx"
  exit 0
fi

if [[ "$(id -u)" != "0" ]]; then echo "Run with sudo."; exit 1; fi

echo "== 1/5  Writing service files to $DIR =="
mkdir -p "$DIR"

cat > "$DIR/server.js" <<'CWEOF_SERVER'
/**
 * Death Muffin realtime co-op service — Socket.io over WebSocket.
 *
 * This is Death Muffin's separate realtime service. It does not alter the
 * original shared Crossworlds REST server. Local default is port 5000;
 * production sets REALTIME_PORT=5191.
 *
 * World model (audit Phase 0): players join instanced worlds of ≤10. Without an
 * invite code you are matched into any public world with space (or a new one);
 * with a code you join/create that world. The oldest member is the host: it
 * simulates enemies and is the ONLY socket allowed to publish snapshots and
 * events. Everyone else sends bounded intents, which are validated, stamped
 * with the real sender id, and delivered to the host only. The latest
 * snapshot is kept so a newly promoted host can continue the world.
 *
 * Config (env, or ENV_FILE pointing at an env file):
 *   REALTIME_PORT     — default 5000
 *   JWT_SECRET        — required in production; use Death Muffin's own
 *                       auth service secret, never the shared server's.
 *   CORS_ORIGIN       — comma-separated allowed origins
 *                       (default http://localhost:5188 for local dev)
 *   DEV_TRUST_TOKENS  — '1' = decode JWTs without signature verification and
 *                       accept the client's offline dev tokens. LOCAL DEV ONLY;
 *                       refuses to combine with production.
 */
require('dotenv').config({ path: process.env.ENV_FILE || `${__dirname}/.env` });

const http = require('http');
const { Server } = require('socket.io');
const jwt = require('jsonwebtoken');

const PORT = Number(process.env.REALTIME_PORT || 5000);
const HOST = process.env.REALTIME_HOST || '0.0.0.0';
const MAX_PARTY_SIZE = 10;
const JWT_SECRET = process.env.JWT_SECRET;
const DEV_TRUST_TOKENS = process.env.DEV_TRUST_TOKENS === '1';
const CORS_ORIGINS = (process.env.CORS_ORIGIN || 'http://localhost:5188').split(',');

const LIMITS = {
  snapshotBytes: 96 * 1024,
  eventsBytes: 64 * 1024,
  intentBytes: 2 * 1024,
  moveBytes: 256,
  gearBytes: 512,
  perfBytes: 2 * 1024,
  perfIntervalMs: 5000,
  // per-socket per-second budgets
  movesPerSec: 30,
  intentsPerSec: 40,
  snapshotsPerSec: 15,
  eventsPerSec: 60,
  chatPerSec: 3,
  gearPerSec: 2,
};

/** A guest only needs the world around it: enemies/thralls farther than this from the recipient are left out of ITS copy of a snapshot (metres; the minimap reaches ~45, the screen less). */
const SNAPSHOT_INTEREST_RADIUS = 64;

const BOSS_IDS = new Set(['prelate', 'gravedigger', 'abbess', 'congregation', 'saint', 'regent', 'mire']);
const INTENT_TYPES = new Set(['hit', 'miasma', 'exhume', 'litany', 'summonBoss', 'recallThralls', 'detonate', 'signature', 'gather', 'legend']);
/** Host-shaped rites (discipline signatures + Bone Mantle); the host owns their shapes and clamps the aim around the caster. */
const SIGNATURES = new Set(['wall', 'rend', 'dirge', 'bloom', 'mantle', 'offering', 'rally', 'seed', 'bash', 'vigil', 'brand',
  'lantern_cone', 'chain_pull', 'burn_the_dead', 'watchmans_ward', 'cremate', 'last_light',
  'toll', 'resonant_step', 'knell', 'sound_the_corpse', 'great_toll',
  'hook_throw', 'harvest', 'crow_swarm', 'hook_pull', 'hex_charm', 'butcher', 'murder_of_crows',
  'echo', 'veil_tear', 'crossing', 'lay_to_rest']);
const WORLD_BOUND = 400; // |x|,|z| sanity bound in world units

if (DEV_TRUST_TOKENS && process.env.NODE_ENV === 'production') {
  console.error('[realtime] DEV_TRUST_TOKENS is not allowed in production');
  process.exit(1);
}
if (!JWT_SECRET && !DEV_TRUST_TOKENS) {
  console.error('[realtime] JWT_SECRET missing (set ENV_FILE to Death Muffin auth .env)');
  process.exit(1);
}
if (DEV_TRUST_TOKENS) console.warn('[realtime] DEV_TRUST_TOKENS=1 — signatures NOT verified. Local dev only.');

/** worldId -> { players: Map<socketId, player>, public: boolean, snapshot: object|null } */
const worlds = new Map();
let worldCounter = 1;

const summary = () =>
  Object.fromEntries(
    [...worlds.entries()].map(([id, w]) => [
      id,
      // Socket ids only in local dev (never expose them in production health output).
      DEV_TRUST_TOKENS ? { host: hostOf(w), players: [...w.players.keys()] } : w.players.size,
    ]),
  );
const hostOf = (w) => (w && w.players.size ? w.players.keys().next().value : null);
const bytes = (v) => {
  try {
    return Buffer.byteLength(JSON.stringify(v));
  } catch {
    return Infinity;
  }
};
/**
 * Size of a snapshot without serialising it twice: cheap row-count estimate when it is clearly small, the exact JSON size
 * once it gets near the cap. (The transport's maxHttpBufferSize still bounds any single frame.)
 */
function snapshotBytes(snap) {
  const n = (a) => (Array.isArray(a) ? a.length : 0);
  const est = 2048 + n(snap.enemies) * 110 + n(snap.thralls) * 110 + n(snap.corpses) * 350 + n(snap.zones) * 450 + n(snap.zpos) * 40 + n(snap.depleted) * 40;
  return est <= LIMITS.snapshotBytes / 2 ? est : bytes(snap);
}

/** Dropped-message counters, with a rate-limited console line per kind so journalctl shows it without flooding. */
const drops = { snapshotOversize: 0, snapshotRate: 0, snapshotInvalid: 0, eventsOversize: 0, eventsRate: 0 };
const lastDropLog = {};
function noteDrop(kind, who, detail = '') {
  drops[kind]++;
  const now = Date.now();
  if (now - (lastDropLog[kind] || 0) < 10000) return;
  lastDropLog[kind] = now;
  console.warn(`[realtime] DROP ${kind} (total ${drops[kind]}) from ${who}${detail ? ` ${detail}` : ''}`);
}

/**
 * Per-recipient interest filter: the snapshot as one guest should see it. Returns the SAME object when nothing is
 * out of range, so the common case stays a single shared broadcast. Rows keep the legacy shape (older guests just see
 * fewer entities, exactly as if the rest had despawned).
 */
function snapshotFor(snap, x, z, recipientId) {
  if (!Array.isArray(snap.enemies) || !Array.isArray(snap.thralls)) return snap;
  const r2 = SNAPSHOT_INTEREST_RADIUS * SNAPSHOT_INTEREST_RADIUS;
  const near = (rx, rz) => !((rx - x) * (rx - x) + (rz - z) * (rz - z) > r2);
  const enemies = snap.enemies.filter((e) => near(e[2], e[3]));
  const thralls = snap.thralls.filter((t) => t[1] === recipientId || near(t[3], t[4]));
  if (enemies.length === snap.enemies.length && thralls.length === snap.thralls.length) return snap;
  return { ...snap, enemies, thralls };
}

/** Relay a host snapshot to everyone else in its world: one shared encode for guests that need all of it, one per guest that gets a trimmed copy. */
function relaySnapshot(socket, world, snap) {
  const shared = [];
  for (const [id, p] of world.players) {
    if (id === socket.id) continue;
    const mine = p.located ? snapshotFor(snap, p.x, p.z, id) : snap;
    if (mine === snap) shared.push(id);
    else io.sockets.sockets.get(id)?.volatile.emit('world:snapshot', mine);
  }
  if (shared.length === world.players.size - 1) socket.volatile.to(socket.data.worldId).emit('world:snapshot', snap);
  else if (shared.length) io.volatile.to(shared).emit('world:snapshot', snap);
}

const num = (v, fallback = 0) => (Number.isFinite(Number(v)) ? Number(v) : fallback);
const inWorld = (v) => Math.abs(num(v, 1e9)) <= WORLD_BOUND;

/** Token bucket per socket + channel. */
// Visible equipment: item ids per slot, shown on the hero for everyone in the world (client-side cosmetics only).
const GEAR_SLOTS = ['head', 'chest', 'legs', 'feet', 'hands', 'main_hand', 'off_hand', 'cape', 'pet'];
function cleanGear(g) {
  const out = {};
  if (!g || typeof g !== 'object') return out;
  for (const slot of GEAR_SLOTS) {
    const id = g[slot];
    if (typeof id === 'string' && /^[a-z0-9_]{1,48}$/.test(id)) out[slot] = id;
  }
  return out;
}

function allow(socket, channel, perSec) {
  const now = Date.now();
  const buckets = (socket.data.buckets ??= {});
  const b = (buckets[channel] ??= { tokens: perSec, at: now });
  b.tokens = Math.min(perSec, b.tokens + ((now - b.at) / 1000) * perSec);
  b.at = now;
  if (b.tokens < 1) return false;
  b.tokens -= 1;
  return true;
}

/** Shape + bounds check for client intents. Returns a sanitised copy or null. */
function validIntent(intent) {
  if (!intent || typeof intent !== 'object' || !INTENT_TYPES.has(intent.t)) return null;
  if (bytes(intent) > LIMITS.intentBytes) return null;
  const out = { ...intent };
  for (const k of ['x', 'z']) if (k in out && !inWorld(out[k])) return null;
  switch (out.t) {
    case 'hit':
      if (!Array.isArray(out.ids) || out.ids.length > 64 || !out.ids.every(Number.isInteger)) return null;
      out.dmg = Math.min(Math.max(0, num(out.dmg)), 100000);
      out.fracture = Math.min(3, Math.max(0, num(out.fracture)));
      out.boss = !!out.boss;
      // Hemorrhage (Marrow Spear): a bleed per second, never more than a quarter of the hit.
      if ('bleed' in out) out.bleed = Math.min(Math.max(0, num(out.bleed)), out.dmg * 0.25);
      // Grave Frost: a flag only; the host sim owns the Chill duration.
      if ('chill' in out) out.chill = !!out.chill;
      // Rot Lance: at most one Withered stack per hit, capped 1..12 (the host clamps again).
      if ('withered' in out) out.withered = Math.min(1, Math.max(0, Math.floor(num(out.withered))));
      if ('witheredCap' in out) out.witheredCap = Math.min(12, Math.max(1, Math.floor(num(out.witheredCap, 5))));
      // Bone Prison / Grave Hands: flags only; the host sim owns the root and slow durations.
      if ('root' in out) out.root = !!out.root;
      if ('slow' in out) out.slow = !!out.slow;
      // Impale rune: a root length in seconds, never more than the rune's 1.5 s (the host clamps again).
      if ('rootS' in out) out.rootS = Math.min(1.5, Math.max(0, num(out.rootS)));
      // Marrow Spear (legendary rally): a flag only; the host checks the caster's own clamped mods.
      if ('spear' in out) out.spear = !!out.spear;
      break;
    case 'legend': {
      // Legendary set mods the sim reads for this owner. Same bounds the sim clamps to (src/gameplay/legendary.ts).
      const m = out.mods && typeof out.mods === 'object' ? out.mods : {};
      out.mods = {
        thrallDeathBurst: Math.min(2, Math.max(0, num(m.thrallDeathBurst))),
        championEvery: Math.min(20, Math.max(0, Math.floor(num(m.championEvery)))),
        spearRally: Math.min(3, Math.max(0, num(m.spearRally))),
        miasmaSpreadsWithered: num(m.miasmaSpreadsWithered) > 0 ? 1 : 0,
        witheredBurstAt: Math.min(12, Math.max(0, Math.floor(num(m.witheredBurstAt)))),
      };
      break;
    }
    case 'miasma':
      out.r = Math.min(8, Math.max(0.5, num(out.r, 3)));
      out.dps = Math.min(20000, Math.max(0, num(out.dps)));
      out.durationMs = Math.min(10000, Math.max(500, num(out.durationMs, 6000)));
      out.witheredCap = Math.min(10, Math.max(1, num(out.witheredCap, 5)));
      // Relic runes: Creeping Rot drifts at most 1.5 m/s; Contagion is a flag (the host owns both effects).
      if ('creep' in out) out.creep = Math.min(1.5, Math.max(0, num(out.creep)));
      if ('contagion' in out) out.contagion = !!out.contagion;
      break;
    case 'exhume':
      // Bone Colossus looks for corpses within 6 m of the point, Mass Grave within 4 m, a plain exhume within 4 m of a corpse it already named.
      out.colossus = !!out.colossus;
      out.r = Math.min(out.colossus ? 6 : 4, Math.max(0.2, num(out.r, 1)));
      // Mass Grave rune: up to three corpses at once (the host applies the weaker stats itself).
      if ('count' in out) out.count = Math.min(3, Math.max(1, Math.floor(num(out.count, 1))));
      out.cap = Math.min(8, Math.max(1, num(out.cap, 3)));
      out.hp = Math.min(1e6, Math.max(1, num(out.hp, 50)));
      out.damage = Math.min(1e5, Math.max(0, num(out.damage, 5)));
      out.attackSpeedMult = Math.min(3, Math.max(0.2, num(out.attackSpeedMult, 1)));
      break;
    case 'litany':
      // 7m base; a Soul Harvest-empowered litany is 50% larger (10.5m).
      // Requiem rune: the burst lands up to 2 s later over twice the radius (21 m with Soul Harvest), so r may reach 22 only with a delay.
      if ('delayMs' in out) out.delayMs = Math.min(2000, Math.max(0, Math.floor(num(out.delayMs))));
      out.r = Math.min(out.delayMs > 0 ? 22 : 11, Math.max(1, num(out.r, 7)));
      out.spellPower = Math.min(1e5, Math.max(0, num(out.spellPower)));
      out.leaveCorpses = !!out.leaveCorpses;
      // Hollow Choir rune: thralls are spared instead of sacrificed.
      if ('spare' in out) out.spare = !!out.spare;
      break;
    case 'summonBoss':
      // Area bosses: which boss to wake; older clients send none and mean the Prelate. The host keeps one awake.
      out.boss = BOSS_IDS.has(out.boss) ? out.boss : 'prelate';
      break;
    case 'signature':
      if (!SIGNATURES.has(out.sig) || !inWorld(out.x) || !inWorld(out.z)) return null;
      out.dx = Math.min(1e3, Math.max(-1e3, num(out.dx)));
      out.dz = Math.min(1e3, Math.max(-1e3, num(out.dz)));
      out.sp = Math.min(1e5, Math.max(0, num(out.sp)));
      // Carrion Seed's Withered cap and Rally's duration (the host clamps both again).
      if ('cap' in out) out.cap = Math.min(12, Math.max(1, Math.floor(num(out.cap, 6))));
      if ('dur' in out) out.dur = Math.min(10, Math.max(0, num(out.dur, 6)));
      // Hollow Knight: 'bash' carries only the charge direction (already clamped
      // above), 'vigil' and 'brand' only the aim point. The host re-derives the
      // body struck, the corpse spent and every duration, so there is nothing
      // else here to trust.
      break;
    case 'gather':
      // Depletes a gathering node on the host (rewards come from the REST API, never from here).
      if (typeof out.nodeId !== 'string' || !/^[a-z]{1,16}_\d{1,4}$/.test(out.nodeId)) return null;
      out.successes = Math.min(3, Math.max(1, Math.floor(num(out.successes, 1))));
      break;
    case 'detonate':
      // Corpse Explosion: the host owns radius and corpse modifiers; the client
      // only names the corpse and claims its damage (clamped again by the sim).
      if (!Number.isInteger(out.corpseId) || out.corpseId < 0) return null;
      out.dmg = Math.min(Math.max(0, num(out.dmg)), 100000);
      break;
  }
  return out;
}

/** Client performance beacon (src/net/perfBeacon.ts): last PERF_KEEP reports per username, newest last. */
const PERF_KEEP = 40;
const perfReports = new Map();
const pnum = (v, max = 1e9) => (typeof v === 'number' && Number.isFinite(v) ? Math.min(max, Math.max(-max, Math.round(v * 10) / 10)) : 0);
const pstr = (v, n) => (typeof v === 'string' ? v.replace(/[^\x20-\x7e]/g, '?').slice(0, n) : '');
/** Validate + rate-limit one report. `state` is per socket ({ at }). Returns the cleaned report or null. Never trusts shape or size. */
function acceptPerf(state, raw, now = Date.now()) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
  if (now - (state.at || 0) < LIMITS.perfIntervalMs) return null;
  if (bytes(raw) > LIMITS.perfBytes) return null;
  state.at = now;
  const lt = Array.isArray(raw.lt) ? raw.lt : [];
  const r = {
    at: now,
    win: pnum(raw.win), fps: pnum(raw.fps, 1000), p50: pnum(raw.p50), p95: pnum(raw.p95), max: pnum(raw.max), maxAt: pnum(raw.maxAt),
    lt: [pnum(lt[0]), pnum(lt[1]), pnum(lt[2])], hid: pnum(raw.hid),
    q: pstr(raw.q, 12), cap: pnum(raw.cap), sc: pnum(raw.sc), dpr: pnum(raw.dpr), cv: pstr(raw.cv, 12),
    calls: pnum(raw.calls), tris: pnum(raw.tris), prog: pnum(raw.prog), geo: pnum(raw.geo), tex: pnum(raw.tex), heap: pnum(raw.heap),
    area: pstr(raw.area, 16), en: pnum(raw.en), th: pnum(raw.th), co: pnum(raw.co), fx: pnum(raw.fx),
    host: raw.host ? 1 : 0, pl: pnum(raw.pl),
    ev: (Array.isArray(raw.ev) ? raw.ev : []).slice(0, 8).map((e) => pstr(e, 40)),
  };
  if (typeof raw.gpu === 'string') {
    r.gpu = pstr(raw.gpu, 80);
    r.hc = pnum(raw.hc);
    r.dmem = pnum(raw.dmem);
    r.plat = pstr(raw.plat, 20);
  }
  return r;
}
function storePerf(username, r) {
  let list = perfReports.get(username);
  if (!list) perfReports.set(username, (list = []));
  list.push(r);
  if (list.length > PERF_KEEP) list.shift();
  // Bound the number of tracked usernames too (dev servers see throwaway names).
  if (perfReports.size > 500) perfReports.delete(perfReports.keys().next().value);
}
function perfLine(username, r) {
  const gpu = r.gpu ? ` gpu=${r.gpu.slice(0, 40)}` : '';
  return `[perf] ${username} ${r.area} fps=${r.fps} frame=${r.p50}/${r.p95}/${r.max}ms longtasks=${r.lt.join('/')} hidden=${r.hid}ms calls=${r.calls} tris=${r.tris} programs=${r.prog} heap=${r.heap}MB q=${r.q} scale=${r.sc}${gpu} ev=[${r.ev.join('; ')}]`;
}

const httpServer = http.createServer((req, res) => {
  if (req.url === '/perf') {
    // Local-only (the service binds 127.0.0.1 in production and Nginx never routes this path); refuse anything proxied or remote anyway.
    const ra = req.socket.remoteAddress || '';
    if (!(ra === '127.0.0.1' || ra === '::1' || ra === '::ffff:127.0.0.1') || req.headers['x-forwarded-for']) {
      res.writeHead(404);
      return res.end();
    }
    res.writeHead(200, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify(Object.fromEntries(perfReports)));
  }
  if (req.url === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'ok', uptime: process.uptime(), worlds: summary(), drops }));
  } else {
    res.writeHead(404);
    res.end();
  }
});

// REALTIME_PATH lets the shared-443 Nginx vhost route this service on a
// dedicated path (e.g. /rt/socket.io). Unset → library default for local dev.
const io = new Server(httpServer, {
  cors: { origin: CORS_ORIGINS },
  maxHttpBufferSize: 256 * 1024,
  // Snapshots are repetitive JSON (about a quarter of their size once deflated); the browser negotiates this natively. Small frames skip it.
  perMessageDeflate: { threshold: 1024, zlibDeflateOptions: { level: 1 }, serverNoContextTakeover: true, clientNoContextTakeover: true },
  ...(process.env.REALTIME_PATH ? { path: process.env.REALTIME_PATH } : {}),
});

// JWT handshake — same tokens the auth server issues on /login.
io.use((socket, next) => {
  const token = socket.handshake.auth && socket.handshake.auth.token;
  if (!token) return next(new Error('Not authenticated'));
  try {
    if (DEV_TRUST_TOKENS && typeof token === 'string' && token.startsWith('offline:')) {
      const name = token.slice(8).slice(0, 24) || 'offline';
      socket.data.accountId = `offline:${name}`;
      socket.data.username = name;
      return next();
    }
    const payload = DEV_TRUST_TOKENS ? jwt.decode(token) : jwt.verify(token, JWT_SECRET);
    if (!payload || !payload.accountId) return next(new Error('Not authenticated'));
    socket.data.accountId = payload.accountId;
    socket.data.username = payload.username || `player${payload.accountId}`;
    next();
  } catch {
    next(new Error('Not authenticated'));
  }
});

function pickWorld(code) {
  if (code) {
    const id = `w:${String(code).replace(/[^a-z0-9-]/gi, '').slice(0, 12).toLowerCase()}`;
    if (!worlds.has(id)) worlds.set(id, { players: new Map(), public: false, snapshot: null });
    return id;
  }
  for (const [id, w] of worlds) if (w.public && w.players.size < MAX_PARTY_SIZE) return id;
  const id = `w:${(worldCounter++).toString(36)}${Math.random().toString(36).slice(2, 5)}`;
  worlds.set(id, { players: new Map(), public: true, snapshot: null });
  return id;
}

io.on('connection', (socket) => {
  socket.on('world:join', (info, ack) => {
    if (typeof ack !== 'function') return;
    if (socket.data.worldId) return ack({ success: false, error: 'Already in a world' });
    const worldId = pickWorld(info && info.instance);
    const world = worlds.get(worldId);
    if (world.players.size >= MAX_PARTY_SIZE) {
      console.log(`[realtime] ${socket.data.username} rejected from ${worldId} (full)`);
      return ack({ success: false, error: 'That world is full (10 players)' });
    }
    // One socket per account per world (no duplicate-login ghosts).
    for (const p of world.players.values()) {
      if (p.accountId === socket.data.accountId) return ack({ success: false, error: 'You are already in this world' });
    }
    const player = {
      id: socket.id,
      accountId: socket.data.accountId,
      characterId: Math.trunc(num(info && info.characterId)),
      name: socket.data.username,
      // Disciplines 0–9 (the Release 0.3 classes are 5–9; a 0–4 clamp showed them to partners as Rotweavers).
      classIndex: Math.min(9, Math.max(0, Math.trunc(num(info && info.classIndex)))),
      // Character level: level-scaled areas (the Plague Cloister) match the party's highest.
      level: Math.min(999, Math.max(1, Math.trunc(num(info && info.level)) || 1)),
      x: inWorld(info && info.x) ? num(info.x) : 0,
      z: inWorld(info && info.z) ? num(info.z) : 0,
      facing: num(info && info.facing),
      moving: false,
      hpFrac: 1,
      gear: cleanGear(info && info.gear),
    };
    world.players.set(socket.id, player);
    socket.data.worldId = worldId;
    socket.join(worldId);
    const { accountId, ...publicPlayer } = player;
    socket.to(worldId).emit('player:join', publicPlayer);
    console.log(`[realtime] ${player.name} joined ${worldId} (${world.players.size}/${MAX_PARTY_SIZE})`);
    ack({
      success: true,
      data: {
        self: publicPlayer,
        players: [...world.players.values()].map(({ accountId: _a, ...p }) => p),
        hostId: hostOf(world),
        instance: worldId.slice(2),
        snapshot: world.snapshot,
      },
    });
  });

  const myWorld = () => (socket.data.worldId ? worlds.get(socket.data.worldId) : null);
  const isHost = () => hostOf(myWorld()) === socket.id;

  socket.on('player:gear', (gear) => {
    const world = myWorld();
    if (!world || !allow(socket, 'gear', LIMITS.gearPerSec) || bytes(gear) > LIMITS.gearBytes) return;
    const player = world.players.get(socket.id);
    if (!player) return;
    player.gear = cleanGear(gear);
    socket.to(socket.data.worldId).emit('player:gear', { id: socket.id, gear: player.gear });
  });

  socket.on('perf:report', (raw) => {
    const r = acceptPerf((socket.data.perf ??= { at: 0 }), raw);
    if (!r) return;
    storePerf(socket.data.username, r);
    console.log(perfLine(socket.data.username, r));
  });

  socket.on('player:move', (pos) => {
    const world = myWorld();
    if (!world || !allow(socket, 'move', LIMITS.movesPerSec) || bytes(pos) > LIMITS.moveBytes) return;
    const player = world.players.get(socket.id);
    if (!player || !inWorld(pos && pos.x) || !inWorld(pos && pos.z)) return;
    player.x = num(pos.x);
    player.z = num(pos.z);
    player.located = true; // from here on the snapshot interest filter can use this position
    player.facing = num(pos.facing);
    player.moving = !!pos.moving;
    player.hpFrac = Math.min(1, Math.max(0, num(pos.hpFrac, 1)));
    // Level rides along (optional) so partners see level-ups without a rejoin.
    const level = Math.trunc(num(pos.level));
    if (level >= 1 && level <= 999) player.level = level;
    socket.volatile.to(socket.data.worldId).emit('player:move', {
      id: socket.id,
      x: player.x,
      z: player.z,
      facing: player.facing,
      moving: player.moving,
      hpFrac: player.hpFrac,
      level: player.level,
    });
  });

  // Host-only authoritative channels.
  socket.on('world:snapshot', (snap) => {
    const world = myWorld();
    if (!world || !isHost()) return;
    if (!allow(socket, 'snap', LIMITS.snapshotsPerSec)) return noteDrop('snapshotRate', socket.data.username);
    if (!snap || typeof snap !== 'object') return noteDrop('snapshotInvalid', socket.data.username);
    const size = snapshotBytes(snap);
    if (size > LIMITS.snapshotBytes) return noteDrop('snapshotOversize', socket.data.username, `${size} B > ${LIMITS.snapshotBytes} B, ${Array.isArray(snap.enemies) ? snap.enemies.length : '?'} enemies`);
    // Keep the freshest full-list snapshot for host migration / late joiners.
    if (snap.corpses || !world.snapshot) world.snapshot = snap;
    else world.snapshot = { ...world.snapshot, ...snap, corpses: world.snapshot.corpses, zones: world.snapshot.zones };
    relaySnapshot(socket, world, snap);
  });

  socket.on('world:events', (batch) => {
    const world = myWorld();
    if (!world || !isHost()) return;
    if (!allow(socket, 'events', LIMITS.eventsPerSec)) return noteDrop('eventsRate', socket.data.username);
    if (!Array.isArray(batch) || batch.length > 400 || bytes(batch) > LIMITS.eventsBytes) return noteDrop('eventsOversize', socket.data.username, Array.isArray(batch) ? `${batch.length} events` : 'not an array');
    socket.to(socket.data.worldId).emit('world:events', batch);
  });

  // Non-host requests: validated, stamped, delivered to the host only.
  socket.on('world:intent', (intent) => {
    const world = myWorld();
    if (!world || !allow(socket, 'intent', LIMITS.intentsPerSec)) return;
    const clean = validIntent(intent);
    if (!clean) return;
    clean.by = socket.id;
    const host = hostOf(world);
    if (host && host !== socket.id) io.to(host).emit('world:intent', { from: socket.id, intent: clean });
  });

  socket.on('chat:send', (text) => {
    const worldId = socket.data.worldId;
    if (!worldId || !allow(socket, 'chat', LIMITS.chatPerSec)) return;
    const clean = String(text || '').trim().slice(0, 240);
    if (!clean) return;
    console.log(`[CHAT] [${worldId}] ${socket.data.username}: ${clean}`);
    io.to(worldId).emit('chat:message', { id: socket.id, name: socket.data.username, text: clean });
  });

  socket.on('disconnect', () => {
    const worldId = socket.data.worldId;
    const world = worldId && worlds.get(worldId);
    if (!world) return;
    const wasHost = hostOf(world) === socket.id;
    if (!world.players.delete(socket.id)) return;
    socket.to(worldId).emit('player:leave', { id: socket.id });
    console.log(`[realtime] ${socket.data.username} left ${worldId} (${world.players.size}/${MAX_PARTY_SIZE})`);
    if (world.players.size === 0) worlds.delete(worldId);
    else if (wasHost) {
      // Promote the next-oldest member and hand them the canonical snapshot.
      io.to(worldId).emit('room:host', { hostId: hostOf(world), snapshot: world.snapshot });
    }
  });
});

if (require.main === module) {
  httpServer.listen(PORT, HOST, () => {
    console.log(`[realtime] listening on ${HOST}:${PORT} (cors: ${CORS_ORIGINS.join(', ')})`);
  });
}

module.exports = { validIntent, pickWorld, worlds, LIMITS, httpServer, cleanGear, acceptPerf, perfReports, storePerf, perfLine, snapshotBytes, snapshotFor, drops, SNAPSHOT_INTEREST_RADIUS };
CWEOF_SERVER

cat > "$DIR/package.json" <<'CWEOF_PKG'
{
  "name": "death-muffin-realtime",
  "version": "0.1.0",
  "private": true,
  "description": "Death Muffin realtime co-op service (Socket.io). Production listens on 127.0.0.1:5191.",
  "main": "server.js",
  "scripts": {
    "start": "node server.js"
  },
  "dependencies": {
    "dotenv": "^16.4.5",
    "jsonwebtoken": "^9.0.2",
    "socket.io": "^4.8.1"
  }
}
CWEOF_PKG

echo "== 2/5  Installing dependencies (npm --omit=dev) =="
( cd "$DIR" && npm install --omit=dev --no-audit --no-fund )

echo "== 3/5  Installing systemd unit =="
cat > "$UNIT" <<'CWEOF_UNIT'
# systemd unit for the Crossworlds realtime co-op service.
# Deploy target: /etc/systemd/system/rod-realtime.service
# NOT INSTALLED YET — part of the Phase 3 VPS deploy, pending user approval.
[Unit]
Description=Crossworlds realtime co-op service (Socket.io, port 5000)
After=network.target

[Service]
Type=simple
User=ubuntu
WorkingDirectory=/opt/rod-realtime
ExecStart=/usr/bin/node /opt/rod-realtime/server.js
Restart=on-failure
RestartSec=5
# JWT secret is read in place from the auth server's env — never copied.
Environment=ENV_FILE=/opt/rod-auth/.env
Environment=REALTIME_PORT=5000
Environment=REALTIME_HOST=127.0.0.1
Environment=REALTIME_PATH=/rt/socket.io
Environment=CORS_ORIGIN=https://playcrossworlds.com
Environment=NODE_ENV=production
# Binds 127.0.0.1 only (loopback) — reached via the Nginx wss reverse proxy,
# never exposed directly. No new public firewall port required.

[Install]
WantedBy=multi-user.target
CWEOF_UNIT
systemctl daemon-reload
systemctl enable --now "$SVC"
sleep 1
systemctl --no-pager --lines=0 status "$SVC" || true

echo "== 4/5  Health check on loopback =="
if curl -fsS "http://127.0.0.1:$PORT/health"; then
  echo; echo "  [ok] service healthy on 127.0.0.1:$PORT"
else
  echo "  [FAIL] service not answering — check: journalctl -u $SVC -n 40 --no-pager"; exit 1
fi

echo "== 5/5  Nginx wss reverse proxy =="
VHOST="$(grep -rlE 'server_name[^;]*playcrossworlds' /etc/nginx/sites-enabled /etc/nginx/sites-available /etc/nginx/conf.d 2>/dev/null \
  | xargs -r grep -lE 'listen[[:space:]].*443' 2>/dev/null | sort -u | head -1 || true)"

if [[ -z "$VHOST" ]]; then
  echo "  [skip] Could not confidently find the 443 vhost for playcrossworlds.com."
  echo "         Add this block by hand inside its 'server { listen 443 ... }' block, then: nginx -t && systemctl reload nginx"
  echo "---------------------------------------------"
  cat <<'CWEOF_NGINX'
location block inside the EXISTING `server { listen 443 ssl; ... }`
# block for playcrossworlds.com (do not create a new server block).
#
# It routes wss://playcrossworlds.com/rt/socket.io/  ->  127.0.0.1:5000
# reusing the existing Certbot SSL, so no new public port and no mixed content.

location /rt/socket.io/ {
    proxy_pass http://127.0.0.1:5000;

    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";

    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;

    # WebSockets are long-lived; don't let Nginx time them out at 60s.
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
}
CWEOF_NGINX
  echo "---------------------------------------------"
  exit 0
fi

echo "  vhost: $VHOST"
if grep -q '/rt/socket.io/' "$VHOST"; then
  echo "  [ok] proxy block already present — nothing to change."
else
  BAK="$VHOST.bak.$(date +%s)"
  cp "$VHOST" "$BAK"
  echo "  backed up -> $BAK"
  BLOCK=$(cat <<'CWEOF_NGINX'
location block inside the EXISTING `server { listen 443 ssl; ... }`
# block for playcrossworlds.com (do not create a new server block).
#
# It routes wss://playcrossworlds.com/rt/socket.io/  ->  127.0.0.1:5000
# reusing the existing Certbot SSL, so no new public port and no mixed content.

location /rt/socket.io/ {
    proxy_pass http://127.0.0.1:5000;

    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";

    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;

    # WebSockets are long-lived; don't let Nginx time them out at 60s.
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
}
CWEOF_NGINX
)
  # Insert the location block right after the first 'listen ... 443' line.
  awk -v ins="$BLOCK" '{print} /listen[[:space:]].*443/ && !done {print ""; print ins; done=1}' "$VHOST" > "$VHOST.tmp"
  mv "$VHOST.tmp" "$VHOST"
  if nginx -t; then
    systemctl reload nginx
    echo "  [ok] nginx reloaded with wss proxy at /rt/socket.io/"
  else
    cp "$BAK" "$VHOST"
    echo "  [FAIL] nginx -t rejected the edit — restored $VHOST from backup. Site untouched."
    echo "         Add the block by hand and re-run 'nginx -t'. Service itself is fine on :$PORT."
    exit 1
  fi
fi

echo
echo "== DONE =="
echo "Verify externally:"
echo "  curl -s 'https://playcrossworlds.com/rt/socket.io/?EIO=4&transport=polling'   # socket.io handshake, not 404"
echo "  curl -s http://playcrossworlds.com:3000/api/health                            # auth server untouched"
echo
echo "Then rebuild the web client with:"
echo "  VITE_WS_BASE=https://playcrossworlds.com VITE_WS_PATH=/rt/socket.io npm run build"
