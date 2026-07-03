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
CWEOF_SERVER

cat > "$DIR/package.json" <<'CWEOF_PKG'
{
  "name": "crossworlds-realtime",
  "version": "0.1.0",
  "private": true,
  "description": "Crossworlds realtime co-op layer (Socket.io). Deploy target: /opt/rod-realtime/ on playcrossworlds.com, port 5000.",
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
