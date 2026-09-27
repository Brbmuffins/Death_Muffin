/**
 * Crossworlds realtime co-op service — Socket.io over WebSocket.
 *
 * Additive to the existing stack: does NOT touch /opt/rod-auth, the REST
 * endpoints, or the database. Port 5000 (3000/4000/7777/3001 are frozen).
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
 *   JWT_SECRET        — required in production. On the VPS, run with
 *                       ENV_FILE=/opt/rod-auth/.env so the secret is read
 *                       in place from the auth server's env — never copied.
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
  // per-socket per-second budgets
  movesPerSec: 30,
  intentsPerSec: 40,
  snapshotsPerSec: 15,
  eventsPerSec: 60,
  chatPerSec: 3,
};

const INTENT_TYPES = new Set(['hit', 'miasma', 'exhume', 'litany', 'summonBoss', 'recallThralls', 'detonate', 'signature', 'gather']);
/** Host-shaped rites (discipline signatures + Bone Mantle); the host owns their shapes and clamps the aim around the caster. */
const SIGNATURES = new Set(['wall', 'rend', 'dirge', 'bloom', 'mantle', 'offering', 'rally', 'seed']);
const WORLD_BOUND = 400; // |x|,|z| sanity bound in world units

if (DEV_TRUST_TOKENS && process.env.NODE_ENV === 'production') {
  console.error('[realtime] DEV_TRUST_TOKENS is not allowed in production');
  process.exit(1);
}
if (!JWT_SECRET && !DEV_TRUST_TOKENS) {
  console.error('[realtime] JWT_SECRET missing (set ENV_FILE=/opt/rod-auth/.env on the VPS)');
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
const num = (v, fallback = 0) => (Number.isFinite(Number(v)) ? Number(v) : fallback);
const inWorld = (v) => Math.abs(num(v, 1e9)) <= WORLD_BOUND;

/** Token bucket per socket + channel. */
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
      break;
    case 'miasma':
      out.r = Math.min(8, Math.max(0.5, num(out.r, 3)));
      out.dps = Math.min(20000, Math.max(0, num(out.dps)));
      out.durationMs = Math.min(10000, Math.max(500, num(out.durationMs, 6000)));
      out.witheredCap = Math.min(10, Math.max(1, num(out.witheredCap, 5)));
      break;
    case 'exhume':
      out.r = Math.min(4, Math.max(0.2, num(out.r, 1)));
      out.cap = Math.min(8, Math.max(1, num(out.cap, 3)));
      out.hp = Math.min(1e6, Math.max(1, num(out.hp, 50)));
      out.damage = Math.min(1e5, Math.max(0, num(out.damage, 5)));
      out.attackSpeedMult = Math.min(3, Math.max(0.2, num(out.attackSpeedMult, 1)));
      break;
    case 'litany':
      // 7m base; a Soul Harvest-empowered litany is 50% larger (10.5m).
      out.r = Math.min(11, Math.max(1, num(out.r, 7)));
      out.spellPower = Math.min(1e5, Math.max(0, num(out.spellPower)));
      out.leaveCorpses = !!out.leaveCorpses;
      break;
    case 'signature':
      if (!SIGNATURES.has(out.sig) || !inWorld(out.x) || !inWorld(out.z)) return null;
      out.dx = Math.min(1e3, Math.max(-1e3, num(out.dx)));
      out.dz = Math.min(1e3, Math.max(-1e3, num(out.dz)));
      out.sp = Math.min(1e5, Math.max(0, num(out.sp)));
      // Carrion Seed's Withered cap and Rally's duration (the host clamps both again).
      if ('cap' in out) out.cap = Math.min(12, Math.max(1, Math.floor(num(out.cap, 6))));
      if ('dur' in out) out.dur = Math.min(10, Math.max(0, num(out.dur, 6)));
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

const httpServer = http.createServer((req, res) => {
  if (req.url === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'ok', uptime: process.uptime(), worlds: summary() }));
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
      classIndex: Math.min(4, Math.max(0, Math.trunc(num(info && info.classIndex)))),
      x: inWorld(info && info.x) ? num(info.x) : 0,
      z: inWorld(info && info.z) ? num(info.z) : 0,
      facing: num(info && info.facing),
      moving: false,
      hpFrac: 1,
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

  socket.on('player:move', (pos) => {
    const world = myWorld();
    if (!world || !allow(socket, 'move', LIMITS.movesPerSec) || bytes(pos) > LIMITS.moveBytes) return;
    const player = world.players.get(socket.id);
    if (!player || !inWorld(pos && pos.x) || !inWorld(pos && pos.z)) return;
    player.x = num(pos.x);
    player.z = num(pos.z);
    player.facing = num(pos.facing);
    player.moving = !!pos.moving;
    player.hpFrac = Math.min(1, Math.max(0, num(pos.hpFrac, 1)));
    socket.volatile.to(socket.data.worldId).emit('player:move', {
      id: socket.id,
      x: player.x,
      z: player.z,
      facing: player.facing,
      moving: player.moving,
      hpFrac: player.hpFrac,
    });
  });

  // Host-only authoritative channels.
  socket.on('world:snapshot', (snap) => {
    const world = myWorld();
    if (!world || !isHost() || !allow(socket, 'snap', LIMITS.snapshotsPerSec)) return;
    if (!snap || typeof snap !== 'object' || bytes(snap) > LIMITS.snapshotBytes) return;
    // Keep the freshest full-list snapshot for host migration / late joiners.
    if (snap.corpses || !world.snapshot) world.snapshot = snap;
    else world.snapshot = { ...world.snapshot, ...snap, corpses: world.snapshot.corpses, zones: world.snapshot.zones };
    socket.volatile.to(socket.data.worldId).emit('world:snapshot', snap);
  });

  socket.on('world:events', (batch) => {
    const world = myWorld();
    if (!world || !isHost() || !allow(socket, 'events', LIMITS.eventsPerSec)) return;
    if (!Array.isArray(batch) || batch.length > 400 || bytes(batch) > LIMITS.eventsBytes) return;
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

module.exports = { validIntent, pickWorld, worlds, LIMITS, httpServer };
