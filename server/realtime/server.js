/**
 * Crossworlds realtime co-op service — Socket.io over WebSocket.
 *
 * Additive to the existing stack: does NOT touch /opt/rod-auth, the REST
 * endpoints, or the database. Port 5000 (3000/4000/7777/3001 are frozen).
 *
 * Config (env, or ENV_FILE pointing at an env file):
 *   REALTIME_PORT     — default 5000
 *   JWT_SECRET        — required in production. On the VPS, run with
 *                       ENV_FILE=/opt/rod-auth/.env so the secret is read
 *                       in place from the auth server's env — never copied.
 *   CORS_ORIGIN       — comma-separated allowed origins
 *                       (default http://localhost:5188 for local dev)
 *   DEV_TRUST_TOKENS  — '1' = decode JWTs without signature verification.
 *                       LOCAL DEV ONLY; refuses to combine with production.
 */
require('dotenv').config({ path: process.env.ENV_FILE || `${__dirname}/.env` });

const http = require('http');
const { Server } = require('socket.io');
const jwt = require('jsonwebtoken');

const PORT = Number(process.env.REALTIME_PORT || 5000);
// Production binds loopback (reached only via the Nginx reverse proxy); local
// dev defaults to all interfaces.
const HOST = process.env.REALTIME_HOST || '0.0.0.0';
const MAX_PARTY_SIZE = 4;
const JWT_SECRET = process.env.JWT_SECRET;
const DEV_TRUST_TOKENS = process.env.DEV_TRUST_TOKENS === '1';
const CORS_ORIGINS = (process.env.CORS_ORIGIN || 'http://localhost:5188').split(',');

if (DEV_TRUST_TOKENS && process.env.NODE_ENV === 'production') {
  console.error('[realtime] DEV_TRUST_TOKENS is not allowed in production');
  process.exit(1);
}
if (!JWT_SECRET && !DEV_TRUST_TOKENS) {
  console.error('[realtime] JWT_SECRET missing (set ENV_FILE=/opt/rod-auth/.env on the VPS)');
  process.exit(1);
}
if (DEV_TRUST_TOKENS) {
  console.warn('[realtime] DEV_TRUST_TOKENS=1 — JWT signatures NOT verified. Local dev only.');
}

// roomId -> Map<socketId, player> (insertion order = join order; first is host)
const rooms = new Map();

function roomSummary() {
  return Object.fromEntries([...rooms.entries()].map(([id, m]) => [id, m.size]));
}

// Host = oldest member. The host client simulates shared entities (arena
// enemies) and broadcasts their state; the server only relays.
function hostOf(roomId) {
  const room = rooms.get(roomId);
  if (!room || room.size === 0) return null;
  return room.keys().next().value;
}

const httpServer = http.createServer((req, res) => {
  if (req.url === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'ok', uptime: process.uptime(), rooms: roomSummary() }));
  } else {
    res.writeHead(404);
    res.end();
  }
});

// REALTIME_PATH lets the shared-443 Nginx vhost route this service on a
// dedicated path (e.g. /rt/socket.io) without colliding with the dashboard's
// own Socket.io. Unset → library default (/socket.io) for local dev.
const io = new Server(httpServer, {
  cors: { origin: CORS_ORIGINS },
  ...(process.env.REALTIME_PATH ? { path: process.env.REALTIME_PATH } : {}),
});

// JWT handshake — same tokens the auth server issues on /login.
io.use((socket, next) => {
  const token = socket.handshake.auth && socket.handshake.auth.token;
  if (!token) return next(new Error('Not authenticated'));
  try {
    const payload = DEV_TRUST_TOKENS ? jwt.decode(token) : jwt.verify(token, JWT_SECRET);
    if (!payload || !payload.accountId) return next(new Error('Not authenticated'));
    socket.data.accountId = payload.accountId;
    socket.data.username = payload.username || `player${payload.accountId}`;
    next();
  } catch (err) {
    next(new Error('Not authenticated'));
  }
});

io.on('connection', (socket) => {
  socket.on('room:join', (info, ack) => {
    const roomId = String((info && info.room) || 'hub').slice(0, 32);
    if (socket.data.roomId) return ack && ack({ success: false, error: 'Already in a room' });

    let room = rooms.get(roomId);
    if (!room) {
      room = new Map();
      rooms.set(roomId, room);
    }
    if (room.size >= MAX_PARTY_SIZE) {
      console.log(`[realtime] ${socket.data.username} rejected from ${roomId} (full)`);
      return ack && ack({ success: false, error: 'Party full' });
    }

    const player = {
      id: socket.id,
      characterId: Number(info && info.characterId) || 0,
      name: socket.data.username,
      classIndex: Number(info && info.classIndex) || 0,
      x: Number(info && info.x) || 0,
      y: Number(info && info.y) || 0,
      z: Number(info && info.z) || 0,
      orientation: Number(info && info.orientation) || 0,
    };
    room.set(socket.id, player);
    socket.data.roomId = roomId;
    socket.join(roomId);
    socket.to(roomId).emit('player:join', player);
    console.log(`[realtime] ${player.name} joined ${roomId} (${room.size}/${MAX_PARTY_SIZE})`);
    ack && ack({
      success: true,
      data: { self: player, players: [...room.values()], hostId: hostOf(roomId) },
    });
  });

  // Generic arena relay — enemy state from the host, hit requests to the host.
  // Payloads are opaque to the server; clients own the simulation (documented
  // simplification: client-authoritative combat, PvE co-op only).
  socket.on('arena:event', (payload) => {
    const roomId = socket.data.roomId;
    if (!roomId || typeof payload !== 'object' || payload === null) return;
    socket.volatile.to(roomId).emit('arena:event', { ...payload, from: socket.id });
  });

  // Position relay. Client throttles to ~10Hz; volatile = drop stale frames
  // under backpressure rather than queueing them.
  socket.on('player:move', (pos) => {
    const roomId = socket.data.roomId;
    if (!roomId) return;
    const player = rooms.get(roomId) && rooms.get(roomId).get(socket.id);
    if (!player) return;
    player.x = Number(pos && pos.x) || 0;
    player.y = Number(pos && pos.y) || 0;
    player.z = Number(pos && pos.z) || 0;
    player.orientation = Number(pos && pos.orientation) || 0;
    socket.volatile.to(roomId).emit('player:move', {
      id: socket.id,
      x: player.x,
      y: player.y,
      z: player.z,
      orientation: player.orientation,
    });
  });

  socket.on('chat:send', (text) => {
    const roomId = socket.data.roomId;
    if (!roomId) return;
    const clean = String(text || '').trim().slice(0, 240);
    if (!clean) return;
    console.log(`[CHAT] [${roomId}] ${socket.data.username}: ${clean}`);
    io.to(roomId).emit('chat:message', { id: socket.id, name: socket.data.username, text: clean });
  });

  socket.on('disconnect', () => {
    const roomId = socket.data.roomId;
    if (!roomId) return;
    const room = rooms.get(roomId);
    if (room && room.delete(socket.id)) {
      socket.to(roomId).emit('player:leave', { id: socket.id });
      console.log(`[realtime] ${socket.data.username} left ${roomId} (${room.size}/${MAX_PARTY_SIZE})`);
      if (room.size === 0) {
        rooms.delete(roomId);
      } else {
        // Promote the next-oldest member so enemy simulation continues.
        io.to(roomId).emit('room:host', { hostId: hostOf(roomId) });
      }
    }
  });
});

httpServer.listen(PORT, HOST, () => {
  console.log(`[realtime] listening on ${HOST}:${PORT} (cors: ${CORS_ORIGINS.join(', ')})`);
});
