'use strict';
// Entry point. Env: DM_LOBBY_JWT_SECRET (required; same value as the auth backend's JWT_SECRET), DM_LOBBY_PORT (5192), DM_LOBBY_HOST (127.0.0.1),
// DM_LOBBY_IDLE_MS, DM_LOBBY_QUIET=1. Staff-only online gate (off unless set): DM_LOBBY_MANIFEST (client manifest.json path), DM_LOBBY_BACKEND (default http://127.0.0.1:5190). ENV_FILE may point at the backend .env to read JWT_SECRET from (never printed).
const fs = require('fs');
const { createLobby } = require('./server');
const { createStaffGate } = require('./gate');

function secretFromEnvFile(file) {
  try {
    for (const line of fs.readFileSync(file, 'utf8').split(/\r?\n/)) {
      const m = /^\s*JWT_SECRET\s*=\s*(.*)\s*$/.exec(line);
      if (m) return m[1].replace(/^['"]|['"]$/g, '');
    }
  } catch { /* handled by caller */ }
  return '';
}

const secret = process.env.DM_LOBBY_JWT_SECRET || (process.env.ENV_FILE ? secretFromEnvFile(process.env.ENV_FILE) : '');
if (!secret) { console.error('[lobby] JWT secret missing: set DM_LOBBY_JWT_SECRET or ENV_FILE'); process.exit(1); }
const num = (v, d) => (v && Number.isFinite(Number(v)) ? Number(v) : d);
const lobby = createLobby({
  jwtSecret: secret,
  host: process.env.DM_LOBBY_HOST || '127.0.0.1',
  port: num(process.env.DM_LOBBY_PORT, 5192),
  idleMs: num(process.env.DM_LOBBY_IDLE_MS, 15 * 60 * 1000),
  quiet: process.env.DM_LOBBY_QUIET === '1',
  accessGate: process.env.DM_LOBBY_MANIFEST ? createStaffGate({ manifestPath: process.env.DM_LOBBY_MANIFEST, backendUrl: process.env.DM_LOBBY_BACKEND || 'http://127.0.0.1:5190' }) : null,
});
lobby.start().then((p) => { if (process.env.DM_LOBBY_QUIET !== '1') console.log(`[lobby] listening on ${lobby.options.host}:${p}`); if (process.send) process.send('ready'); })
  .catch((e) => { console.error('[lobby] failed to start:', e.code || e.message); process.exit(1); });
for (const sig of ['SIGINT', 'SIGTERM']) process.on(sig, () => { lobby.stop().finally(() => process.exit(0)); });
