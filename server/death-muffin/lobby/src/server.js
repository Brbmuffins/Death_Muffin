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
  badCodesMax: 10,          // wrong private codes one connection may try per window before it is told to slow down
  badCodesWindowMs: 10 * 60 * 1000,
  quiet: false,
  accessGate: null,         // optional async (token, claims) => {ok, msg}; see gate.js (staff-only online)
  friendsOf: null,          // optional async (token, accountId) => [accountId] (accepted friends) or null; see friends.js. Unset = no presence
  inviteMs: 5 * 60 * 1000,  // an invite (or an accepted ask) lets that account join for this long
  askMs: 5 * 60 * 1000,     // an unanswered ask to join expires
  askGapMs: 30 * 1000,      // one ask per friend per this long
  rejoinMs: 5 * 60 * 1000,  // a member whose connection dropped (not one who left or was removed) may come back to its session for this long, also when it is Closed
  friendsFetchPerMin: 20,   // friend-list reloads one connection may cause per minute
  relayUdp: null,           // optional { addr, port }: the UDP relay (server/death-muffin/relay); members get a signed ticket for it (relayTicket)
  relayTicketMs: 10 * 60 * 1000, // a ticket must be used this soon (it only opens the UDP lane; the lobby stays the source of truth for membership)
};

const AREA_RE = /^[\w .'\-]{1,32}$/;
/** Close codes of a socket its player closed on purpose (the game closes with 1000; 1001 and 1005 are the other graceful ones). Anything else that ends a
 *  member's socket (1006 no close frame at all: a lost network, a crash, a killed game; our own 1009 / 1013 / 4429) is a drop: the member may rejoin. */
const CLEAN_CLOSE = new Set([1000, 1001, 1005]);
function cleanText(v, max) {
  if (typeof v !== 'string') return null;
  const s = v.replace(/[\u0000-\u001f\u007f]/g, '').trim();
  return s.length >= 1 && s.length <= max ? s : null;
}
const PRESENCE_CLASS_MAX = 99;
const PRESENCE_LEVEL_MAX = 10000;
/** The host's world, shown everywhere a session is (DECISIONS B26): the heat of its world vows and its difficulty id. Display only. */
const HEAT_MAX = 99;
const DIFFICULTY_RE = /^[a-z_]{1,16}$/;
const worldOf = (msg, base = { heat: 0, difficulty: 'medium' }) => ({
  heat: Number.isInteger(msg.heat) && msg.heat >= 0 && msg.heat <= HEAT_MAX ? msg.heat : base.heat,
  difficulty: typeof msg.difficulty === 'string' && DIFFICULTY_RE.test(msg.difficulty) ? msg.difficulty : base.difficulty,
});
/** A UDP relay ticket: "<session>.<peer>.<expires ms>.<hmac>", HMAC-SHA256 over "dm-relay|session|peer|expires" with the shared secret.
 *  The relay (godot/net/relay/dm_udp_relay.gd) checks it the same way. */
function relayTicket(secret, sid, peerId, expiresMs) {
  const mac = crypto.createHmac('sha256', secret).update(`dm-relay|${sid}|${peerId}|${expiresMs}`).digest('hex');
  return `${sid}.${peerId}.${expiresMs}.${mac}`;
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
  const drops = new Map(); // accountId -> {sid, until}: a member whose connection dropped, who may come back to that session (offerRejoin)
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

  /** The UDP lane for a member (undefined when no relay is configured: clients then stay on this WebSocket). */
  function relayFor(s, peerId) {
    if (!o.relayUdp) return undefined;
    return { addr: o.relayUdp.addr, port: o.relayUdp.port, ticket: relayTicket(o.jwtSecret, s.id, peerId, Date.now() + o.relayTicketMs) };
  }
  function sessionInfo(s) {
    return { id: s.id, name: s.name, host: s.host.username, area: s.area, players: 1 + s.clients.size, max: o.maxPlayers, private: s.isPrivate, open: s.open,
      heat: s.world.heat, difficulty: s.world.difficulty };
  }

  function closeSession(s, reason) {
    if (!sessions.delete(s.id)) return;
    for (const [id, d] of drops) if (d.sid === s.id) drops.delete(id);   // a host who ends the session ends every way back in (D6)
    const members = [...s.clients.values()];
    for (const c of members) { c.session = null; c.peerId = 0; sendJson(c, { t: 'session_closed', reason }); }
    s.clients.clear();
    if (s.host.session === s) { s.host.session = null; s.host.peerId = 0; sendJson(s.host, { t: 'session_closed', reason }); }
    log('session closed', s.id, reason);
    pushPresence(s.host);
    for (const c of members) pushPresence(c);
  }

  /** `dropped`: the member's connection was lost (not a leave, a kick or a clean close). It keeps a way back for rejoinMs: an invite into this session (so a
   *  Closed one lets it in) and a rejoin offer for its next connection (offerRejoin). A host who drops still ends the session (D6). */
  function leaveSession(conn, reason, dropped = false) {
    const s = conn.session;
    if (!s) return;
    if (s.host === conn) { closeSession(s, 'host_left'); return; }
    s.clients.delete(conn.peerId);
    const id = conn.peerId;
    conn.session = null; conn.peerId = 0;
    s.lastActivity = Date.now();
    if (dropped && conn.authed && o.rejoinMs > 0) {
      const until = Date.now() + o.rejoinMs;
      drops.set(conn.accountId, { sid: s.id, until });
      s.invites.set(conn.accountId, { until });
    }
    sendJson(s.host, { t: 'peer_left', id, reason });
    pushPresence(conn);
    pushSession(s);
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

  async function authenticate(conn, msg) {
    if (typeof msg.token !== 'string' || msg.token.length > 4096) return sendErr(conn, 'auth', 'missing token', 'auth'), dropConn(conn, 4401, 'auth');
    let p;
    try { p = jwt.verify(msg.token, o.jwtSecret, { algorithms: ['HS256'] }); } catch { return sendErr(conn, 'auth', 'invalid or expired token', 'auth'), dropConn(conn, 4401, 'auth'); }
    if (!p || !Number.isSafeInteger(p.accountId)) return sendErr(conn, 'auth', 'invalid token', 'auth'), dropConn(conn, 4401, 'auth');
    // D10 access gate (src/gate.js): only while the client manifest says staff-only online. Asked once per auth, before this connection can replace another.
    if (o.accessGate) {
      if (conn.authing) return;
      conn.authing = true;
      let v;
      try { v = await o.accessGate(msg.token, p); } catch { v = { ok: false }; }
      conn.authing = false;
      if (conn.cleaned || conn.ws.readyState !== 1) return;
      if (!v || !v.ok) return sendErr(conn, 'locked', (v && v.msg) || 'Online opens soon', 'auth'), dropConn(conn, 4403, 'locked');
    }
    const stamp = typeof p.sid === 'string' ? sidStamp(p.sid) : 0;
    const other = byAccount.get(p.accountId);
    let handover = null;
    if (other && other !== conn) {
      // one live connection per account; with auth-server session ids the newer login wins (same rule as server/realtime)
      if (stamp && other.sidStamp > stamp) return sendErr(conn, 'auth', 'this account was opened somewhere else', 'auth'), dropConn(conn, 4402, 'replaced');
      sendJson(other, { t: 'replaced' });
      dropConn(other, 4402, 'replaced');
      // The new connection takes the old one's place for the account's friends: they are not told it went offline and came back (the game's own link
      // replaces the character select's, README "Friends"), and the presence it had carries over until the new connection sends its own.
      handover = { friends: other.authed ? friendConns(other) : [], presence: other.presence };
      cleanupConn(other, { replaced: true });
    }
    conn.authed = true; conn.accountId = p.accountId; conn.sidStamp = stamp; conn.token = msg.token;
    conn.username = typeof p.username === 'string' && p.username ? p.username.slice(0, 24) : `player${p.accountId}`;
    byAccount.set(conn.accountId, conn);
    clearTimeout(conn.authTimer);
    sendJson(conn, { t: 'ready', accountId: conn.accountId, username: conn.username, maxPlayers: o.maxPlayers, presence: !!o.friendsOf });
    if (handover) {
      conn.presence = handover.presence;
      const now = presenceOf(conn);
      for (const f of handover.friends) if (!f.cleaned) sendJson(f, { t: 'presence', accountId: conn.accountId, p: now });
    }
    offerRejoin(conn);
    loadFriends(conn);
  }

  /** A member whose connection dropped (leaveSession `dropped`) is told, on its next connection and for rejoinMs, which session it may come back to;
   *  joining it needs no code and passes a Closed door (the invite leaveSession left). The offer is repeated on each connection until the window ends,
   *  the session ends, or the account joins or hosts a session. */
  function offerRejoin(conn) {
    const d = fresh(drops, conn.accountId);
    const s = d && sessions.get(d.sid);
    if (!s) { drops.delete(conn.accountId); return; }
    sendJson(conn, { t: 'rejoin', session: sessionInfo(s), from: s.host.username, fromId: s.host.accountId, ms: Math.max(0, d.until - Date.now()) });
  }

  /** `opts.code`: the close code of its socket (clean ones are CLEAN_CLOSE); `opts.replaced`: a newer connection of the account took its place. */
  function cleanupConn(conn, opts = {}) {
    if (conn.cleaned) return;
    conn.cleaned = true;
    clearTimeout(conn.authTimer);
    leaveSession(conn, 'disconnected', opts.code === undefined || !CLEAN_CLOSE.has(opts.code));
    if (conn.authed && !opts.replaced) for (const f of friendConns(conn)) sendJson(f, { t: 'presence', accountId: conn.accountId, p: null });
    if (byAccount.get(conn.accountId) === conn) byAccount.delete(conn.accountId);
    conns.delete(conn);
  }

  const safeEqual = (a, b) => {
    const x = Buffer.from(a); const y = Buffer.from(b);
    return x.length === y.length && crypto.timingSafeEqual(x, y);
  };
  // Wrong-code attempts per connection in a sliding window (a 6-digit code is only 1M tries): checked BEFORE a guess, recorded when it misses.
  function allowCodeTry(conn) {
    const now = Date.now();
    conn.badCodes = (conn.badCodes || []).filter((t) => now - t < o.badCodesWindowMs);
    return conn.badCodes.length < o.badCodesMax;
  }
  function badCode(conn) {
    (conn.badCodes = conn.badCodes || []).push(Date.now());
    return sendErr(conn, 'bad_code', 'wrong or missing code', 'join');
  }

  // ---- friends: presence, invites, asks to join (README "Friends") ----------------------------------------------------------------
  // A friend is mutual: both accounts' lists (each read from the backend with that account's own token) name the other. Presence goes only to
  // connected mutual friends.
  const mutual = (a, b) => a !== b && a.authed && b.authed && a.friends.has(b.accountId) && b.friends.has(a.accountId);
  function friendConns(conn) {
    const out = [];
    for (const id of conn.friends) { const c = byAccount.get(id); if (c && mutual(conn, c)) out.push(c); }
    return out;
  }
  function presenceOf(conn) {
    const s = conn.session;
    return { accountId: conn.accountId, username: conn.username, class: conn.presence.class, level: conn.presence.level, area: conn.presence.area,
      session: s ? { id: s.id, private: s.isPrivate, open: s.open, players: 1 + s.clients.size, max: o.maxPlayers, host: s.host.username, isHost: s.host === conn,
        heat: s.world.heat, difficulty: s.world.difficulty } : null };
  }
  function pushPresence(conn) {
    if (!conn.authed || conn.cleaned) return;
    const p = presenceOf(conn);
    for (const f of friendConns(conn)) sendJson(f, { t: 'presence', accountId: conn.accountId, p });
  }
  function pushSession(s) {
    if (!sessions.has(s.id)) return;
    pushPresence(s.host);
    for (const c of s.clients.values()) pushPresence(c);
  }
  function allowFetch(conn) {
    const now = Date.now();
    conn.fetches = conn.fetches.filter((t) => now - t < 60000);
    if (conn.fetches.length >= o.friendsFetchPerMin) return false;
    conn.fetches.push(now);
    return true;
  }
  async function loadFriends(conn) {
    if (!o.friendsOf || !conn.token || !allowFetch(conn)) return;
    let ids = null;
    try { ids = await o.friendsOf(conn.token, conn.accountId); } catch { ids = null; }
    if (conn.cleaned || !Array.isArray(ids)) return;
    const before = conn.friends;
    conn.friends = new Set(ids.filter(Number.isSafeInteger));
    for (const id of before) {                     // no longer friends: they see us go
      const c = byAccount.get(id);
      if (c && !conn.friends.has(id) && c.friends.has(conn.accountId)) sendJson(c, { t: 'presence', accountId: conn.accountId, p: null });
    }
    sendJson(conn, { t: 'friends', list: friendConns(conn).map(presenceOf) });
    pushPresence(conn);
  }
  const fresh = (map, id) => { const v = map.get(id); if (v && v.until > Date.now()) return v; map.delete(id); return null; };
  function inviteInto(s, from, target, auto) {
    s.invites.set(target.accountId, { until: Date.now() + o.inviteMs });
    sendJson(target, { t: 'invited', from: from.username, fromId: from.accountId, session: sessionInfo(s), auto });
    sendJson(from, { t: 'invite_sent', accountId: target.accountId, username: target.username });
  }
  function newCode() {
    let code = '';
    while (!code || [...sessions.values()].some((x) => x.isPrivate && x.code === code)) code = String(crypto.randomInt(0, 1000000)).padStart(6, '0');
    return code;
  }

  function handleSocial(conn, msg) {
    const s = conn.session;
    const now = Date.now();
    switch (msg.t) {
      case 'presence': {   // what friends see: class (discipline index), level, area id
        const cls = Number.isInteger(msg.class) && msg.class >= 0 && msg.class <= PRESENCE_CLASS_MAX ? msg.class : null;
        const level = Number.isInteger(msg.level) && msg.level >= 1 && msg.level <= PRESENCE_LEVEL_MAX ? msg.level : null;
        const area = typeof msg.area === 'string' && AREA_RE.test(msg.area) ? msg.area : null;
        const p = conn.presence;
        if (p.class === cls && p.level === level && p.area === area) return true;
        conn.presence = { class: cls, level, area };
        pushPresence(conn);
        return true;
      }
      case 'friends_changed': {   // a friend request was answered or a friend removed: both sides reload their lists
        loadFriends(conn);
        const other = Number.isSafeInteger(msg.accountId) ? byAccount.get(msg.accountId) : null;
        if (other && other !== conn) { sendJson(other, { t: 'friends_changed' }); loadFriends(other); }
        return true;
      }
      case 'invite': {   // host: a friend may join this session (Closed or not) for inviteMs
        if (!s || s.host !== conn) return sendErr(conn, 'not_host', 'only the host can invite', 'invite'), true;
        const target = byAccount.get(msg.accountId);
        if (!target || !mutual(conn, target)) return sendErr(conn, 'not_friend', 'you can invite friends who are online', 'invite'), true;
        if (target.session === s) return sendErr(conn, 'already_in', 'they are already in your party', 'invite'), true;
        inviteInto(s, conn, target, false);
        return true;
      }
      case 'ask': {   // ask a friend to join them: to their session's host, or to the friend playing solo
        const target = byAccount.get(msg.accountId);
        if (!target || !mutual(conn, target)) return sendErr(conn, 'not_friend', 'you can ask friends who are online', 'ask'), true;
        if (s) return sendErr(conn, 'in_session', 'leave your current session first', 'ask'), true;
        const last = conn.askedAt.get(target.accountId) || 0;
        if (now - last < o.askGapMs) return sendErr(conn, 'rate_limit', 'you just asked them', 'ask'), true;
        conn.askedAt.set(target.accountId, now);
        const to = target.session ? target.session.host : target;
        to.asks.set(conn.accountId, { username: conn.username, until: now + o.askMs });
        sendJson(to, { t: 'join_request', accountId: conn.accountId, username: conn.username, via: to === target ? undefined : target.username });
        sendJson(conn, { t: 'ask_sent', accountId: target.accountId, username: target.username });
        return true;
      }
      case 'answer': {   // the asked player (a host, or solo after hosting) answers an ask
        const req = Number.isSafeInteger(msg.accountId) ? fresh(conn.asks, msg.accountId) : null;
        const asker = req ? byAccount.get(msg.accountId) : null;
        if (!req || !asker) return sendErr(conn, 'not_found', 'that request is gone', 'answer'), true;
        if (msg.accept !== true) {
          conn.asks.delete(msg.accountId);
          sendJson(asker, { t: 'ask_declined', username: conn.username });
          return true;
        }
        if (!s || s.host !== conn) return sendErr(conn, 'not_host', 'host a session first', 'answer'), true;
        conn.asks.delete(msg.accountId);
        if (asker.session === s) return true;
        inviteInto(s, conn, asker, true);
        return true;
      }
      case 'world': {   // host: its world's heat (world vows) and difficulty changed; members, friends and the list follow
        if (!s || s.host !== conn) return sendErr(conn, 'not_host', 'only the host can do that', 'world'), true;
        const next = worldOf(msg, s.world);
        if (next.heat === s.world.heat && next.difficulty === s.world.difficulty) return true;
        s.world = next;
        for (const c of s.clients.values()) sendJson(c, { t: 'world', heat: next.heat, difficulty: next.difficulty });
        sendJson(conn, { t: 'session_updated', session: sessionInfo(s) });
        pushSession(s);
        return true;
      }
      case 'set_private': {   // host: Closed (invite only, not listed) or Open (listed, anyone joins)
        if (!s || s.host !== conn) return sendErr(conn, 'not_host', 'only the host can do that', 'set_private'), true;
        s.isPrivate = msg.private === true;
        if (s.isPrivate && !s.code) s.code = newCode();
        sendJson(conn, { t: 'session_updated', session: sessionInfo(s) });
        pushSession(s);
        return true;
      }
      default: return false;
    }
  }

  function handleControl(conn, msg) {
    if (handleSocial(conn, msg)) return;
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
          const taken = (c) => [...sessions.values()].some((x) => x.isPrivate && x.code === c);
          code = typeof msg.code === 'string' && /^[\w-]{4,16}$/.test(msg.code) ? msg.code : '';
          if (code && taken(code)) return sendErr(conn, 'bad_request', 'that code is already in use', 'create');
          if (!code) code = newCode();  // unique among live private sessions: join-by-code needs it
        }
        let id;
        do { id = crypto.randomBytes(4).toString('hex'); } while (sessions.has(id));
        const sess = { id, name, area, host: conn, isPrivate, code, clients: new Map(), nextPeerId: HOST_PEER_ID + 1, open: true, lastActivity: Date.now(), invites: new Map(),
          world: worldOf(msg) };
        sessions.set(id, sess);
        drops.delete(conn.accountId);   // hosting its own party: the way back into the old one is not wanted
        conn.session = sess; conn.peerId = HOST_PEER_ID;
        log('session created', id, name);
        sendJson(conn, { t: 'created', session: sessionInfo(sess), code: isPrivate ? code : undefined, peerId: HOST_PEER_ID, relay: relayFor(sess, HOST_PEER_ID) });
        return pushPresence(conn);
      }
      case 'join': {
        if (s) return sendErr(conn, 'in_session', 'leave your current session first', 'join');
        const givenCode = typeof msg.code === 'string' ? msg.code : '';
        let sess = null;
        if (typeof msg.id === 'string') sess = sessions.get(msg.id);
        else if (givenCode) {                        // join by code alone: private sessions are not listed, the code is the whole address
          if (!allowCodeTry(conn)) return sendErr(conn, 'rate_limit', 'too many wrong codes, wait a few minutes', 'join');
          sess = [...sessions.values()].find((x) => x.isPrivate && safeEqual(givenCode, x.code)) || null;
          if (!sess) return badCode(conn);
        }
        if (!sess) return sendErr(conn, 'not_found', 'no such session', 'join');
        const invited = !!fresh(sess.invites, conn.accountId);   // an invite (or an accepted ask) needs no code and passes a closed door
        if (sess.isPrivate && typeof msg.id === 'string' && !invited) {
          if (!allowCodeTry(conn)) return sendErr(conn, 'rate_limit', 'too many wrong codes, wait a few minutes', 'join');
          if (!safeEqual(givenCode, sess.code)) return badCode(conn);
        }
        if (!sess.open && !invited) return sendErr(conn, 'closed', 'the host is not accepting players', 'join');
        if (1 + sess.clients.size >= o.maxPlayers) return sendErr(conn, 'full', `session is full (${o.maxPlayers}/${o.maxPlayers})`, 'join');
        const pid = sess.nextPeerId++;
        sess.clients.set(pid, conn);
        sess.invites.delete(conn.accountId);
        drops.delete(conn.accountId);
        conn.session = sess; conn.peerId = pid;
        sess.lastActivity = Date.now();
        sendJson(conn, { t: 'joined', session: sessionInfo(sess), peerId: pid, relay: relayFor(sess, pid) });
        sendJson(sess.host, { t: 'peer_joined', id: pid, name: conn.username, accountId: conn.accountId });
        return pushSession(sess);
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
        sendJson(conn, { t: 'session_updated', session: sessionInfo(s) });
        return pushSession(s);
      }
      case 'kick': { // host only
        if (!s || s.host !== conn) return sendErr(conn, 'not_host', 'only the host can do that', 'kick');
        const victim = s.clients.get(msg.id);
        if (!victim) return sendErr(conn, 'not_found', 'no such peer', 'kick');
        s.clients.delete(msg.id);
        victim.session = null; victim.peerId = 0;
        sendJson(victim, { t: 'session_closed', reason: 'kicked' });
        sendJson(conn, { t: 'peer_left', id: msg.id, reason: 'kicked' });
        pushPresence(victim);
        return pushSession(s);
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
    const conn = { ws, authed: false, accountId: 0, username: '', session: null, peerId: 0, alive: true, sidStamp: 0, cleaned: false, token: '',
      friends: new Set(), presence: { class: null, level: null, area: null }, asks: new Map(), askedAt: new Map(), fetches: [],
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
      if (!conn.authed) { if (msg.t === 'auth') authenticate(conn, msg).catch(() => dropConn(conn, 4401, 'auth')); else dropConn(conn, 4401, 'auth required'); return; }
      if (conn.session) conn.session.lastActivity = Date.now();
      handleControl(conn, msg);
    });
    ws.on('close', (code) => cleanupConn(conn, { code }));
    ws.on('error', () => { /* close follows */ });
  });

  const timers = [];
  /** Idle sessions end; rejoin windows that ran out are forgotten. */
  function sweep() {
    const now = Date.now();
    for (const s of [...sessions.values()]) if (now - s.lastActivity > o.idleMs) closeSession(s, 'idle');
    for (const [id, d] of drops) if (d.until <= now) drops.delete(id);
  }
  function start() {
    timers.push(setInterval(sweep, o.sweepMs));
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
  return { start, stop, sessions, stats, options: o, _sweepIdle: sweep };
}

module.exports = { createLobby, DEFAULTS, KIND_DATA, relayTicket };
