'use strict';
const http = require('http');
const crypto = require('crypto');
const jwt = require('jsonwebtoken');
const { WebSocketServer } = require('ws');
const { HEADER_BYTES, KIND_DATA, HOST_PEER_ID, BROADCAST, readHeader } = require('./protocol');

const DEFAULTS = {
  host: '127.0.0.1',
  port: 5192,
  jwtSecret: '',
  maxPlayers: 4,            // D2: DmSession.MAX_PLAYERS (host included)
  maxSessions: 200,
  authTimeoutMs: 5000,
  idleMs: 15 * 60 * 1000,   // a session with no traffic from its members for this long is closed
  sweepMs: 30 * 1000,
  pingMs: 20 * 1000,
  maxPacketBytes: 65536,    // payload, header excluded
  maxTextBytes: 2048,
  ratePerSec: 600,          // packets/s refilled per connection
  rateBurst: 1200,
  bytesPerSec: 1024 * 1024, // bytes/s refilled per connection
  bytesBurst: 2 * 1024 * 1024,
  maxBuffered: 4 * 1024 * 1024, // a recipient with more than this queued is dropped as a slow consumer
  quiet: false,
};

const AREA_RE = /^[\w .'\-]{1,32}$/;
function cleanText(v, max) {
  if (typeof v !== 'string') return null;
  const s = v.replace(/[\u0000-\u001f\u007f]/g, '').trim();
  return s.length >= 1 && s.length <= max ? s : null;
}
function sidStamp(sid) {
  const n = Number(String(sid).split('-')[0]);
  return Number.isFinite(n) && n > 0 ? n : 0;
}

function createLobby(userOpts = {}) {
  const o = { ...DEFAULTS, ...userOpts };
  if (!o.jwtSecret) throw new Error('jwtSecret is required');
  const log = (...a) => { if (!o.quiet) console.log('[lobby]', ...a); };

  const sessions = new Map(); // id -> session
  const byAccount = new Map(); // accountId -> conn
  const conns = new Set();
  const stats = { connections: 0, packets: 0, bytes: 0, dropped: 0, rateKicks: 0 };

  const httpServer = http.createServer((req, res) => {
    if (req.url === '/health') {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ ok: true, sessions: sessions.size, connections: conns.size }));
      return;
    }
    res.writeHead(404); res.end();
  });
  const wss = new WebSocketServer({ server: httpServer, maxPayload: o.maxPacketBytes + HEADER_BYTES });

  const sendJson = (conn, obj) => {
    if (conn.ws.readyState === 1) conn.ws.send(JSON.stringify(obj));
  };
  const sendErr = (conn, code, msg, req) => sendJson(conn, { t: 'error', code, msg, req });

  function sessionInfo(s) {
    return { id: s.id, name: s.name, host: s.host.username, area: s.area, players: 1 + s.clients.size, max: o.maxPlayers, private: s.isPrivate, open: s.open };
  }

  function closeSession(s, reason) {
    if (!sessions.delete(s.id)) return;
    const members = [...s.clients.values()];
    for (const c of members) { c.session = null; c.peerId = 0; sendJson(c, { t: 'session_closed', reason }); }
    s.clients.clear();
    if (s.host.session === s) { s.host.session = null; s.host.peerId = 0; sendJson(s.host, { t: 'session_closed', reason }); }
    log('session closed', s.id, reason);
  }

  function leaveSession(conn, reason) {
    const s = conn.session;
    if (!s) return;
    if (s.host === conn) { closeSession(s, 'host_left'); return; }
    s.clients.delete(conn.peerId);
    const id = conn.peerId;
    conn.session = null; conn.peerId = 0;
    s.lastActivity = Date.now();
    sendJson(s.host, { t: 'peer_left', id, reason });
  }

  function dropConn(conn, code, reason) {
    try { conn.ws.close(code, reason); } catch { /* already closing */ }
  }

  function takeTokens(conn, bytes) {
    const now = Date.now();
    const dt = (now - conn.bucket.t) / 1000;
    conn.bucket.t = now;
    conn.bucket.msgs = Math.min(o.rateBurst, conn.bucket.msgs + dt * o.ratePerSec);
    conn.bucket.bytes = Math.min(o.bytesBurst, conn.bucket.bytes + dt * o.bytesPerSec);
    conn.bucket.msgs -= 1; conn.bucket.bytes -= bytes;
    return conn.bucket.msgs >= 0 && conn.bucket.bytes >= 0;
  }

  function authenticate(conn, msg) {
    if (typeof msg.token !== 'string' || msg.token.length > 4096) return sendErr(conn, 'auth', 'missing token', 'auth'), dropConn(conn, 4401, 'auth');
    let p;
    try { p = jwt.verify(msg.token, o.jwtSecret, { algorithms: ['HS256'] }); } catch { return sendErr(conn, 'auth', 'invalid or expired token', 'auth'), dropConn(conn, 4401, 'auth'); }
    if (!p || !Number.isSafeInteger(p.accountId)) return sendErr(conn, 'auth', 'invalid token', 'auth'), dropConn(conn, 4401, 'auth');
    const stamp = typeof p.sid === 'string' ? sidStamp(p.sid) : 0;
    const other = byAccount.get(p.accountId);
    if (other && other !== conn) {
      // one live connection per account; with auth-server session ids the newer login wins (same rule as server/realtime)
      if (stamp && other.sidStamp > stamp) return sendErr(conn, 'auth', 'this account was opened somewhere else', 'auth'), dropConn(conn, 4402, 'replaced');
      sendJson(other, { t: 'replaced' });
      dropConn(other, 4402, 'replaced');
      cleanupConn(other);
    }
    conn.authed = true; conn.accountId = p.accountId; conn.sidStamp = stamp;
    conn.username = typeof p.username === 'string' && p.username ? p.username.slice(0, 24) : `player${p.accountId}`;
    byAccount.set(conn.accountId, conn);
    clearTimeout(conn.authTimer);
    sendJson(conn, { t: 'ready', accountId: conn.accountId, username: conn.username, maxPlayers: o.maxPlayers });
  }

  function cleanupConn(conn) {
    if (conn.cleaned) return;
    conn.cleaned = true;
    clearTimeout(conn.authTimer);
    leaveSession(conn, 'disconnected');
    if (byAccount.get(conn.accountId) === conn) byAccount.delete(conn.accountId);
    conns.delete(conn);
  }

  function handleControl(conn, msg) {
    const s = conn.session;
    switch (msg.t) {
      case 'list': {
        const list = [...sessions.values()].filter((x) => !x.isPrivate && x.open).map(sessionInfo);
        return sendJson(conn, { t: 'sessions', sessions: list });
      }
      case 'create': {
        if (s) return sendErr(conn, 'in_session', 'leave your current session first', 'create');
        if (sessions.size >= o.maxSessions) return sendErr(conn, 'busy', 'the lobby is full, try again later', 'create');
        const name = cleanText(msg.name, 32);
        const area = typeof msg.area === 'string' && AREA_RE.test(msg.area) ? msg.area : null;
        if (!name || !area) return sendErr(conn, 'bad_request', 'name (1-32) and area are required', 'create');
        const isPrivate = msg.private === true;
        let code = '';
        if (isPrivate) {
          code = typeof msg.code === 'string' && /^[\w-]{4,16}$/.test(msg.code) ? msg.code : String(crypto.randomInt(0, 1000000)).padStart(6, '0');
        }
        let id;
        do { id = crypto.randomBytes(4).toString('hex'); } while (sessions.has(id));
        const sess = { id, name, area, host: conn, isPrivate, code, clients: new Map(), nextPeerId: HOST_PEER_ID + 1, open: true, lastActivity: Date.now() };
        sessions.set(id, sess);
        conn.session = sess; conn.peerId = HOST_PEER_ID;
        log('session created', id, name);
        return sendJson(conn, { t: 'created', session: sessionInfo(sess), code: isPrivate ? code : undefined, peerId: HOST_PEER_ID });
      }
      case 'join': {
        if (s) return sendErr(conn, 'in_session', 'leave your current session first', 'join');
        const sess = typeof msg.id === 'string' ? sessions.get(msg.id) : null;
        if (!sess) return sendErr(conn, 'not_found', 'no such session', 'join');
        if (sess.isPrivate) {
          const given = typeof msg.code === 'string' ? Buffer.from(msg.code) : Buffer.alloc(0);
          const want = Buffer.from(sess.code);
          if (given.length !== want.length || !crypto.timingSafeEqual(given, want)) return sendErr(conn, 'bad_code', 'wrong or missing code', 'join');
        }
        if (!sess.open) return sendErr(conn, 'closed', 'the host is not accepting players', 'join');
        if (1 + sess.clients.size >= o.maxPlayers) return sendErr(conn, 'full', `session is full (${o.maxPlayers}/${o.maxPlayers})`, 'join');
        const pid = sess.nextPeerId++;
        sess.clients.set(pid, conn);
        conn.session = sess; conn.peerId = pid;
        sess.lastActivity = Date.now();
        sendJson(conn, { t: 'joined', session: sessionInfo(sess), peerId: pid });
        return sendJson(sess.host, { t: 'peer_joined', id: pid, name: conn.username, accountId: conn.accountId });
      }
      case 'leave': {
        if (!s) return sendErr(conn, 'not_in_session', 'not in a session', 'leave');
        const wasHost = s.host === conn;
        leaveSession(conn, 'left');
        return wasHost ? undefined : sendJson(conn, { t: 'left' });
      }
      case 'set_open': { // host only: stop/allow new joins (used by a started or locked session)
        if (!s || s.host !== conn) return sendErr(conn, 'not_host', 'only the host can do that', 'set_open');
        s.open = msg.open !== false;
        return sendJson(conn, { t: 'session_updated', session: sessionInfo(s) });
      }
      case 'kick': { // host only
        if (!s || s.host !== conn) return sendErr(conn, 'not_host', 'only the host can do that', 'kick');
        const victim = s.clients.get(msg.id);
        if (!victim) return sendErr(conn, 'not_found', 'no such peer', 'kick');
        s.clients.delete(msg.id);
        victim.session = null; victim.peerId = 0;
        sendJson(victim, { t: 'session_closed', reason: 'kicked' });
        return sendJson(conn, { t: 'peer_left', id: msg.id, reason: 'kicked' });
      }
      case 'auth': return sendErr(conn, 'bad_request', 'already authenticated', 'auth');
      default: return sendErr(conn, 'bad_request', 'unknown message', msg.t);
    }
  }

  function relay(conn, data) {
    const s = conn.session;
    if (!s) { stats.dropped++; return; }
    const h = readHeader(data);
    if (!h) { stats.dropped++; return; }
    s.lastActivity = Date.now();
    stats.packets++; stats.bytes += data.length;
    data.writeUInt32LE(conn.peerId, 3); // the relay stamps the true source: peers cannot spoof each other
    const send = (c) => {
      if (c.ws.readyState !== 1) return;
      if (c.ws.bufferedAmount > o.maxBuffered) { dropConn(c, 1013, 'slow consumer'); return; }
      c.ws.send(data, { binary: true });
    };
    if (conn === s.host) {
      if (h.dst === BROADCAST) { for (const c of s.clients.values()) send(c); return; }
      const c = s.clients.get(h.dst);
      if (c) send(c); else stats.dropped++;
    } else if (h.dst === HOST_PEER_ID || h.dst === BROADCAST) {
      send(s.host); // clients only ever talk to the host; client<->client traffic is the host's (Godot server relay) job
    } else stats.dropped++;
  }

  wss.on('connection', (ws) => {
    const conn = { ws, authed: false, accountId: 0, username: '', session: null, peerId: 0, alive: true, sidStamp: 0, cleaned: false,
      bucket: { t: Date.now(), msgs: o.rateBurst, bytes: o.bytesBurst } };
    conns.add(conn); stats.connections++;
    conn.authTimer = setTimeout(() => { if (!conn.authed) dropConn(conn, 4401, 'auth timeout'); }, o.authTimeoutMs);
    ws.on('pong', () => { conn.alive = true; });
    ws.on('message', (data, isBinary) => {
      const buf = Buffer.isBuffer(data) ? data : Buffer.concat(data);
      if (!takeTokens(conn, buf.length)) { stats.rateKicks++; sendErr(conn, 'rate_limit', 'too many packets'); dropConn(conn, 4429, 'rate limit'); return; }
      if (isBinary) {
        if (!conn.authed) return dropConn(conn, 4401, 'auth required');
        if (buf.length > o.maxPacketBytes + HEADER_BYTES) { stats.dropped++; return; }
        return relay(conn, buf);
      }
      if (buf.length > o.maxTextBytes) return dropConn(conn, 1009, 'too large');
      let msg;
      try { msg = JSON.parse(buf.toString('utf8')); } catch { return sendErr(conn, 'bad_request', 'invalid json'); }
      if (!msg || typeof msg !== 'object' || typeof msg.t !== 'string') return sendErr(conn, 'bad_request', 'invalid message');
      if (!conn.authed) { if (msg.t === 'auth') authenticate(conn, msg); else dropConn(conn, 4401, 'auth required'); return; }
      if (conn.session) conn.session.lastActivity = Date.now();
      handleControl(conn, msg);
    });
    ws.on('close', () => cleanupConn(conn));
    ws.on('error', () => { /* close follows */ });
  });

  const timers = [];
  function start() {
    timers.push(setInterval(() => {
      const now = Date.now();
      for (const s of [...sessions.values()]) if (now - s.lastActivity > o.idleMs) closeSession(s, 'idle');
    }, o.sweepMs));
    timers.push(setInterval(() => {
      for (const c of conns) {
        if (!c.alive) { c.ws.terminate(); continue; }
        c.alive = false;
        try { c.ws.ping(); } catch { /* closing */ }
      }
    }, o.pingMs));
    for (const t of timers) t.unref();
    return new Promise((resolve, reject) => {
      httpServer.once('error', reject);
      httpServer.listen(o.port, o.host, () => resolve(httpServer.address().port));
    });
  }
  async function stop() {
    for (const t of timers) clearInterval(t);
    for (const s of [...sessions.values()]) closeSession(s, 'shutdown');
    for (const c of conns) c.ws.terminate();
    await new Promise((r) => wss.close(r));
    await new Promise((r) => httpServer.close(r));
  }
  return { start, stop, sessions, stats, options: o, _sweepIdle: () => { const now = Date.now(); for (const s of [...sessions.values()]) if (now - s.lastActivity > o.idleMs) closeSession(s, 'idle'); } };
}

module.exports = { createLobby, DEFAULTS, KIND_DATA };
