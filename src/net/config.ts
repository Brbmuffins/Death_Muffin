// The live auth server (port 3000) speaks plain HTTP and sends no CORS headers,
// so the browser can't call it cross-origin. All API calls go same-origin:
// in dev the Vite proxy (vite.config.ts) forwards them to playcrossworlds.com:3000;
// in production Nginx on the same domain does the same. Override with VITE_API_BASE.
export const API_BASE = (import.meta as any).env?.VITE_API_BASE ?? '';

// Phase 3 realtime co-op layer (Socket.io, port 5000 — 3000/4000/7777/3001 are
// frozen). Local dev talks to the local service; production URL is set at
// deploy time via VITE_WS_BASE. Empty = realtime disabled, hub still works solo.
//
// Production: the site is served over HTTPS, so the socket MUST be wss:// via
// the existing Nginx (a plain ws://…:5000 would be blocked as mixed content).
// Nginx reverse-proxies a dedicated path to 127.0.0.1:5000. Set at build time:
//   VITE_WS_BASE=https://playcrossworlds.com  VITE_WS_PATH=/rt/socket.io
export const WS_BASE =
  (import.meta as any).env?.VITE_WS_BASE ??
  ((import.meta as any).env?.DEV ? 'http://localhost:5000' : '');

// Socket.io path. Empty → library default (/socket.io) for local dev; set in
// production so Nginx can route it on the shared 443 vhost without collisions.
export const WS_PATH = (import.meta as any).env?.VITE_WS_PATH ?? '';

export const MAX_PARTY_SIZE = 4;
