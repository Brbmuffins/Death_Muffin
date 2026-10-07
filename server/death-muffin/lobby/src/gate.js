'use strict';
// Staff-only online gate (owner decision D10). The lobby has no DB, so it follows the client manifest the launcher and the Godot client read
// (online: {enabled, staff, message}) and, in staff mode, asks the auth backend once per connection auth who the token belongs to
// (GET /api/me -> {staff}, decided from the account row). Fails closed: unreadable manifest or a backend that cannot confirm staff = refused.
const fs = require('fs');

const LOCKED = 'Online opens soon';

function createStaffGate({ manifestPath, backendUrl, fetchImpl = globalThis.fetch, readMs = 2000, timeoutMs = 3000 }) {
  let cache = { at: 0, online: null };
  function manifestOnline() {
    const now = Date.now();
    if (now - cache.at < readMs) return cache.online;
    let online = null;
    try { const m = JSON.parse(fs.readFileSync(manifestPath, 'utf8')); online = m && typeof m.online === 'object' ? m.online : {}; } catch { online = null; }
    cache = { at: now, online };
    return online;
  }
  return async function gate(token) {
    const online = manifestOnline();
    if (!online) return { ok: false, msg: LOCKED };                 // unreadable: closed
    if (online.enabled === true) return { ok: true };              // open to everyone: no backend call
    const msg = typeof online.message === 'string' && online.message.trim() ? online.message.trim().slice(0, 70) : LOCKED;
    if (online.staff !== true) return { ok: false, msg };
    try {
      const r = await fetchImpl(`${backendUrl}/api/me`, { headers: { authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(timeoutMs) });
      const j = r.ok ? await r.json() : null;
      return j && j.staff === true ? { ok: true } : { ok: false, msg };
    } catch { return { ok: false, msg }; }
  };
}

module.exports = { createStaffGate, LOCKED };
