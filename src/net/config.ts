// Death Muffin API calls stay same-origin. In dev, Vite proxies them to the
// separate Death Muffin auth service on 127.0.0.1:5190; production Nginx routes
// /death-muffin/api to that service. Override with VITE_API_BASE.
export const API_BASE = (import.meta as any).env?.VITE_API_BASE ?? '';

// Death Muffin realtime co-op layer (Socket.io). Local development defaults to
// port 5000; the separate production service listens on 5191. The URL is set at
// deploy time via VITE_WS_BASE. Empty = realtime disabled, hub still works solo.
//
// Production: the site is served over HTTPS, so the socket MUST be wss:// via
// the existing Nginx (a plain ws://…:5000 would be blocked as mixed content).
// Nginx reverse-proxies a dedicated path to 127.0.0.1:5191. Set at build time:
//   VITE_WS_BASE=https://muffindevelopment.com  VITE_WS_PATH=/death-muffin/rt/socket.io
export const WS_BASE =
  (import.meta as any).env?.VITE_WS_BASE ??
  ((import.meta as any).env?.DEV ? 'http://127.0.0.1:5000' : '');

// Socket.io path. Empty → library default (/socket.io) for local dev; set in
// production so Nginx can route it on the shared 443 vhost without collisions.
export const WS_PATH = (import.meta as any).env?.VITE_WS_PATH ?? '';

export const MAX_PARTY_SIZE = 10;
