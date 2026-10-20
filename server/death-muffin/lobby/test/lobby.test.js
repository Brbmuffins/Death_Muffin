'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const WebSocket = require('ws');
const jwt = require('jsonwebtoken');
const { createLobby, relayTicket } = require('../src/server');
const crypto = require('crypto');
const { HEADER_BYTES } = require('../src/protocol');

const SECRET = 'test-secret-not-real';
const tok = (id, extra = {}, secret = SECRET, opts = { expiresIn: '1h' }) => jwt.sign({ accountId: id, username: `u${id}`, ...extra }, secret, opts);

async function boot(opts = {}) {
  const lobby = createLobby({ jwtSecret: SECRET, port: 0, quiet: true, ...opts });
  const port = await lobby.start();
  const clients = [];
  const connect = async (id, { token, auth = true } = {}) => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}`);
    const c = { ws, texts: [], bins: [], closed: null, waiters: [] };
    ws.on('message', (d, bin) => {
      if (bin) c.bins.push(Buffer.from(d)); else c.texts.push(JSON.parse(d.toString()));
      c.waiters.splice(0).forEach((w) => w());
    });
    ws.on('close', (code, reason) => { c.closed = { code, reason: reason.toString() }; c.waiters.splice(0).forEach((w) => w()); });
    ws.on('error', () => {});
    await new Promise((r) => ws.once('open', r));
    c.send = (o) => ws.send(JSON.stringify(o));
    c.until = async (pred, ms = 2000) => {
      const t0 = Date.now();
      for (;;) {
        const hit = pred(c);
        if (hit) return hit;
        if (Date.now() - t0 > ms) throw new Error('timeout waiting; texts=' + JSON.stringify(c.texts));
        await new Promise((r) => { c.waiters.push(r); setTimeout(r, 50); });
      }
    };
    c.next = (t) => c.until(() => { const i = c.texts.findIndex((m) => m.t === t); return i >= 0 ? c.texts.splice(i, 1)[0] : null; });
    clients.push(c);
    if (token) c.send({ t: 'auth', token });
    else if (auth) { c.send({ t: 'auth', token: tok(id) }); await c.next('ready'); }
    return c;
  };
  const close = async () => { clients.forEach((c) => c.ws.terminate()); await lobby.stop(); };
  return { lobby, port, connect, close };
}
const pkt = (src, dst, payload, mode = 2, ch = 0) => {
  const b = Buffer.alloc(HEADER_BYTES + payload.length);
  b[0] = 1; b[1] = mode; b[2] = ch; b.writeUInt32LE(src, 3); b.writeUInt32LE(dst, 7); Buffer.from(payload).copy(b, HEADER_BYTES);
  return b;
};
const bin = (c, n = 1) => c.until((x) => (x.bins.length >= n ? x.bins : null));

test('auth: valid token ready, bad/expired/wrong-secret/missing rejected', async () => {
  const s = await boot();
  try {
    const ok = await s.connect(1);
    assert.ok(ok.ws.readyState === 1);
    for (const token of ['garbage', tok(2, {}, 'other-secret'), tok(3, {}, SECRET, { expiresIn: -10 }), jwt.sign({ username: 'x' }, SECRET)]) {
      const c = await s.connect(9, { token });
      await c.until((x) => x.closed);
      assert.equal(c.closed.code, 4401);
    }
    const none = await s.connect(9, { auth: false });
    none.send({ t: 'list' });
    await none.until((x) => x.closed);
    assert.equal(none.closed.code, 4401);
  } finally { await s.close(); }
});

test('auth: alg none token refused', async () => {
  const s = await boot();
  try {
    const t = jwt.sign({ accountId: 5, username: 'x' }, '', { algorithm: 'none' });
    const c = await s.connect(5, { token: t });
    await c.until((x) => x.closed);
    assert.equal(c.closed.code, 4401);
  } finally { await s.close(); }
});

test('auth timeout closes silent connections', async () => {
  const s = await boot({ authTimeoutMs: 100 });
  try {
    const c = await s.connect(1, { auth: false });
    await c.until((x) => x.closed);
    assert.equal(c.closed.code, 4401);
  } finally { await s.close(); }
});

test('lobby: create, list, join, leave', async () => {
  const s = await boot();
  try {
    const h = await s.connect(1), a = await s.connect(2);
    h.send({ t: 'create', name: 'Crypt run', area: 'hollow-graves' });
    const created = await h.next('created');
    assert.equal(created.peerId, 1);
    assert.equal(created.session.players, 1);
    a.send({ t: 'list' });
    const l = await a.next('sessions');
    assert.equal(l.sessions.length, 1);
    assert.deepEqual(Object.keys(l.sessions[0]).sort(), ['area', 'difficulty', 'heat', 'host', 'id', 'max', 'name', 'open', 'players', 'private']);
    assert.equal(l.sessions[0].host, 'u1');
    assert.equal(l.sessions[0].max, 4);
    a.send({ t: 'join', id: created.session.id });
    const j = await a.next('joined');
    assert.equal(j.peerId, 2);
    assert.equal(j.session.players, 2);
    const pj = await h.next('peer_joined');
    assert.equal(pj.id, 2); assert.equal(pj.name, 'u2');
    a.send({ t: 'leave' });
    await a.next('left');
    const pl = await h.next('peer_left');
    assert.deepEqual([pl.id, pl.reason], [2, 'left']);
    a.send({ t: 'join', id: 'nope' });
    assert.equal((await a.next('error')).code, 'not_found');
    h.send({ t: 'create', name: 'again', area: 'x' });
    assert.equal((await h.next('error')).code, 'in_session');
  } finally { await s.close(); }
});

test('relay: with a UDP relay configured, created and joined carry a signed ticket for that member; without one, nothing', async () => {
  const s = await boot({ relayUdp: { addr: '203.0.113.7', port: 5193 }, relayTicketMs: 60000 });
  try {
    const h = await s.connect(1), a = await s.connect(2);
    h.send({ t: 'create', name: 'Udp run', area: 'hollow-graves' });
    const c = await h.next('created');
    a.send({ t: 'join', id: c.session.id });
    const j = await a.next('joined');
    for (const [m, pid] of [[c, 1], [j, 2]]) {
      assert.equal(m.relay.addr, '203.0.113.7'); assert.equal(m.relay.port, 5193);
      const [sid, peer, exp, mac] = m.relay.ticket.split('.');
      assert.deepEqual([sid, Number(peer)], [c.session.id, pid]);
      assert.ok(Number(exp) > Date.now() && Number(exp) <= Date.now() + 60000, 'expires within relayTicketMs');
      assert.equal(mac, crypto.createHmac('sha256', SECRET).update(`dm-relay|${sid}|${peer}|${exp}`).digest('hex'), 'HMAC with the shared secret');
      assert.equal(m.relay.ticket, relayTicket(SECRET, sid, pid, Number(exp)));
    }
  } finally { await s.close(); }
  const plain = await boot();
  try {
    const h = await plain.connect(1);
    h.send({ t: 'create', name: 'Ws run', area: 'hollow-graves' });
    assert.equal((await h.next('created')).relay, undefined);
  } finally { await plain.close(); }
});

test('lobby: validation and private sessions', async () => {
  const s = await boot();
  try {
    const h = await s.connect(1), a = await s.connect(2);
    h.send({ t: 'create', name: '', area: 'x' });
    assert.equal((await h.next('error')).code, 'bad_request');
    h.send({ t: 'create', name: 'p', area: 'x', private: true });
    const created = await h.next('created');
    assert.match(created.code, /^\d{6}$/);
    a.send({ t: 'list' });
    assert.equal((await a.next('sessions')).sessions.length, 0);
    a.send({ t: 'join', id: created.session.id });
    assert.equal((await a.next('error')).code, 'bad_code');
    a.send({ t: 'join', id: created.session.id, code: '000000x' });
    assert.equal((await a.next('error')).code, 'bad_code');
    a.send({ t: 'join', id: created.session.id, code: created.code });
    assert.equal((await a.next('joined')).peerId, 2);
  } finally { await s.close(); }
});

test('5th player refused with a reason; peer ids are never reused', async () => {
  const s = await boot();
  try {
    const h = await s.connect(1);
    h.send({ t: 'create', name: 'full', area: 'x' });
    const id = (await h.next('created')).session.id;
    const cs = [];
    for (let i = 2; i <= 4; i++) {
      const c = await s.connect(i); c.send({ t: 'join', id });
      assert.equal((await c.next('joined')).peerId, i); cs.push(c);
    }
    const e = await s.connect(5); e.send({ t: 'join', id });
    const err = await e.next('error');
    assert.equal(err.code, 'full'); assert.match(err.msg, /full/);
    cs[0].send({ t: 'leave' });
    await h.until((x) => x.texts.filter((m) => m.t === 'peer_left').length === 1);
    e.send({ t: 'join', id });
    assert.equal((await e.next('joined')).peerId, 5);
  } finally { await s.close(); }
});

test('relay: host<->client round trip, broadcast, source stamped by relay, no client<->client', async () => {
  const s = await boot();
  try {
    const h = await s.connect(1), a = await s.connect(2), b = await s.connect(3);
    h.send({ t: 'create', name: 'r', area: 'x' });
    const id = (await h.next('created')).session.id;
    a.send({ t: 'join', id }); await a.next('joined');
    b.send({ t: 'join', id }); await b.next('joined');
    await h.until((x) => x.texts.filter((m) => m.t === 'peer_joined').length === 2);
    a.ws.send(pkt(99, 1, [1, 2, 3, 4]));          // spoofed src 99
    const got = (await bin(h))[0];
    assert.equal(got.readUInt32LE(3), 2, 'src stamped');
    assert.deepEqual([...got.subarray(HEADER_BYTES)], [1, 2, 3, 4]);
    assert.equal(got[1], 2);
    h.ws.send(pkt(0, 3, [9, 9]));
    assert.deepEqual([...(await bin(b))[0].subarray(HEADER_BYTES)], [9, 9]);
    assert.equal((await bin(b))[0].readUInt32LE(3), 1);
    h.ws.send(pkt(0, 0, [7]));
    await bin(a); await bin(b, 2);
    assert.deepEqual([...a.bins[a.bins.length - 1].subarray(HEADER_BYTES)], [7]);
    a.ws.send(pkt(0, 3, [5]));                    // client -> other client: dropped
    await new Promise((r) => setTimeout(r, 150));
    assert.equal(b.bins.length, 2);
    assert.ok(s.lobby.stats.dropped >= 1);
    a.ws.send(Buffer.from([1, 2]));               // runt frame: dropped, connection survives
    a.ws.send(pkt(0, 1, [0xAA]));
    assert.equal((await bin(h, 2)).length, 2);
  } finally { await s.close(); }
});

test('relay: zero-length and binary-payload round trip is opaque', async () => {
  const s = await boot();
  try {
    const h = await s.connect(1), a = await s.connect(2);
    h.send({ t: 'create', name: 'r', area: 'x' });
    const id = (await h.next('created')).session.id;
    a.send({ t: 'join', id }); await a.next('joined');
    const payload = Buffer.from(Array.from({ length: 1000 }, (_, i) => i % 256));
    a.ws.send(pkt(0, 1, payload));
    assert.deepEqual((await bin(h))[0].subarray(HEADER_BYTES), payload);
    a.ws.send(pkt(0, 1, []));
    assert.equal((await bin(h, 2))[1].length, HEADER_BYTES);
  } finally { await s.close(); }
});

test('disconnect: host drop ends session for everyone; client drop is announced', async () => {
  const s = await boot();
  try {
    const h = await s.connect(1), a = await s.connect(2), b = await s.connect(3);
    h.send({ t: 'create', name: 'd', area: 'x' });
    const id = (await h.next('created')).session.id;
    a.send({ t: 'join', id }); await a.next('joined');
    b.send({ t: 'join', id }); await b.next('joined');
    a.ws.terminate();
    const pl = await h.next('peer_left');
    assert.deepEqual([pl.id, pl.reason], [2, 'disconnected']);
    h.ws.terminate();
    const sc = await b.next('session_closed');
    assert.equal(sc.reason, 'host_left');
    assert.equal(s.lobby.sessions.size, 0);
    b.send({ t: 'list' });
    assert.equal((await b.next('sessions')).sessions.length, 0);
    b.ws.send(pkt(0, 1, [1]));                    // no longer in a session: dropped, still connected
    await new Promise((r) => setTimeout(r, 100));
    assert.equal(b.closed, null);
  } finally { await s.close(); }
});

test('host leave / kick / set_open', async () => {
  const s = await boot();
  try {
    const h = await s.connect(1), a = await s.connect(2), b = await s.connect(3);
    h.send({ t: 'create', name: 'k', area: 'x' });
    const id = (await h.next('created')).session.id;
    a.send({ t: 'join', id }); await a.next('joined');
    a.send({ t: 'kick', id: 1 });
    assert.equal((await a.next('error')).code, 'not_host');
    h.send({ t: 'set_open', open: false });
    await h.next('session_updated');
    b.send({ t: 'list' }); assert.equal((await b.next('sessions')).sessions.length, 0);
    b.send({ t: 'join', id }); assert.equal((await b.next('error')).code, 'closed');
    h.send({ t: 'kick', id: 2 });
    assert.equal((await a.next('session_closed')).reason, 'kicked');
    assert.equal((await h.next('peer_left')).reason, 'kicked');
    h.send({ t: 'leave' });
    await h.next('session_closed');
    assert.equal(s.lobby.sessions.size, 0);
  } finally { await s.close(); }
});

test('same account reconnecting replaces the old connection and frees its session', async () => {
  const s = await boot();
  try {
    const h = await s.connect(1);
    h.send({ t: 'create', name: 'x', area: 'x' }); await h.next('created');
    const h2 = await s.connect(1);
    await h.until((x) => x.closed);
    assert.equal(h.closed.code, 4402);
    assert.equal(s.lobby.sessions.size, 0);
    h2.send({ t: 'create', name: 'x2', area: 'x' }); await h2.next('created');
  } finally { await s.close(); }
});

test('idle sessions expire', async () => {
  const s = await boot({ idleMs: 50, sweepMs: 40 });
  try {
    const h = await s.connect(1), a = await s.connect(2);
    h.send({ t: 'create', name: 'i', area: 'x' });
    const id = (await h.next('created')).session.id;
    a.send({ t: 'join', id }); await a.next('joined');
    assert.equal((await a.next('session_closed')).reason, 'idle');
    assert.equal((await h.next('session_closed')).reason, 'idle');
    assert.equal(s.lobby.sessions.size, 0);
  } finally { await s.close(); }
});

test('limits: oversized packet dropped, oversized text closes, flood is disconnected', async () => {
  const s = await boot({ maxPacketBytes: 300, maxTextBytes: 400, ratePerSec: 1, rateBurst: 40 });
  try {
    const h = await s.connect(1), a = await s.connect(2);
    h.send({ t: 'create', name: 'l', area: 'x' });
    const id = (await h.next('created')).session.id;
    a.send({ t: 'join', id }); await a.next('joined');
    a.ws.send(pkt(0, 1, Buffer.alloc(400)));      // over maxPayload: ws closes the socket
    await a.until((x) => x.closed);
    assert.ok([1009, 1006].includes(a.closed.code));
    await h.next('peer_left');
    const t = await s.connect(3);
    t.ws.send(JSON.stringify({ t: 'list', pad: 'x'.repeat(500) }));
    await t.until((x) => x.closed);
    assert.equal(t.closed.code, 1009);
    const f = await s.connect(4);
    for (let i = 0; i < 100; i++) f.ws.send(JSON.stringify({ t: 'list' }));
    await f.until((x) => x.closed);
    assert.equal(f.closed.code, 4429);
    assert.ok(s.lobby.stats.rateKicks >= 1);
    assert.equal(h.closed, null, 'other connections unaffected');
  } finally { await s.close(); }
});

test('limits: byte budget', async () => {
  const s = await boot({ bytesPerSec: 10, bytesBurst: 5000 });
  try {
    const h = await s.connect(1), a = await s.connect(2);
    h.send({ t: 'create', name: 'b', area: 'x' });
    const id = (await h.next('created')).session.id;
    a.send({ t: 'join', id }); await a.next('joined');
    for (let i = 0; i < 10; i++) a.ws.send(pkt(0, 1, Buffer.alloc(1000)));
    await a.until((x) => x.closed);
    assert.equal(a.closed.code, 4429);
  } finally { await s.close(); }
});

test('health endpoint', async () => {
  const s = await boot();
  try {
    const r = await fetch(`http://127.0.0.1:${s.port}/health`);
    assert.equal((await r.json()).ok, true);
  } finally { await s.close(); }
});

// ---- D10: staff-only online gate -------------------------------------------------------------------------------------------------------
const fs = require('fs');
const os = require('os');
const path = require('path');
const { createStaffGate } = require('../src/gate');

function gateEnv(online) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dm-gate-'));
  const file = path.join(dir, 'manifest.json');
  const write = (o) => fs.writeFileSync(file, JSON.stringify(o === undefined ? {} : { online: o }));
  if (online !== null) write(online);
  const calls = [];
  const staffIds = new Set([7]);
  const fetchImpl = async (url, opts) => {
    calls.push(url);
    const id = JSON.parse(Buffer.from(opts.headers.authorization.slice(7).split('.')[1], 'base64url')).accountId;
    return { ok: true, json: async () => ({ success: true, staff: staffIds.has(id) }) };
  };
  const gate = createStaffGate({ manifestPath: file, backendUrl: 'http://backend.test', fetchImpl, readMs: 0 });
  return { gate, write, calls, file };
}

test('gate: locked manifest refuses everyone, staff mode admits only backend-confirmed staff, open admits all', async () => {
  const g = gateEnv({ enabled: false, message: 'Online opens soon' });
  const s = await boot({ accessGate: g.gate });
  try {
    const refuse = async (id) => {
      const c = await s.connect(id, { token: tok(id) });
      const e = await c.next('error'); await c.until((x) => x.closed);
      return { e, code: c.closed.code, ready: c.texts.some((m) => m.t === 'ready') };
    };
    let r = await refuse(7);
    assert.equal(r.e.code, 'locked'); assert.equal(r.code, 4403); assert.equal(r.e.msg, 'Online opens soon');
    assert.equal(g.calls.length, 0, 'locked without staff mode never asks the backend');
    g.write({ enabled: false, staff: true, message: 'Staff preview' });
    r = await refuse(8);
    assert.equal(r.code, 4403); assert.equal(r.e.msg, 'Staff preview'); assert.equal(g.calls.length, 1);
    const staff = await s.connect(7); // helper waits for `ready`
    const created = (staff.send({ t: 'create', name: 'staff run', area: 'hollow' }), await staff.next('created'));
    assert.ok(created.session.id);
    g.write({ enabled: false, staff: 'true' });  // only a literal true is staff mode
    assert.equal((await refuse(7)).code, 4403);
    g.write({ enabled: true });
    const calls = g.calls.length;
    const anyone = await s.connect(9);
    assert.ok(anyone.ws.readyState === 1);
    assert.equal(g.calls.length, calls, 'open to all never asks the backend');
  } finally { await s.close(); }
});

test('gate: unreadable manifest and backend failure both fail closed; a refused account cannot replace a live one', async () => {
  const g = gateEnv(null);
  const s = await boot({ accessGate: g.gate });
  try {
    const c = await s.connect(7, { token: tok(7) });
    await c.until((x) => x.closed); assert.equal(c.closed.code, 4403);
    g.write({ enabled: false, staff: true });
    const live = await s.connect(7);
    g.write({ enabled: false, staff: false });
    const again = await s.connect(7, { token: tok(7) });
    await again.until((x) => x.closed);
    assert.equal(live.ws.readyState, 1, 'the refused second login did not kick the live connection');
    const down = createStaffGate({ manifestPath: g.file, backendUrl: 'http://x', fetchImpl: async () => { throw new Error('down'); }, readMs: 0 });
    g.write({ enabled: false, staff: true });
    assert.equal((await down('t')).ok, false);
  } finally { await s.close(); }
});

test('gate: off by default (no accessGate option) leaves auth unchanged', async () => {
  const s = await boot();
  try { assert.ok((await s.connect(5)).ws.readyState === 1); } finally { await s.close(); }
});
test('join by code alone: finds the private session, wrong codes are counted and rate limited, codes stay unique', async () => {
  const s = await boot({ badCodesMax: 3 });
  try {
    const h = await s.connect(1), h2 = await s.connect(2), a = await s.connect(3), late = await s.connect(4);
    h.send({ t: 'create', name: 'one', area: 'x', private: true });
    const c1 = await h.next('created');
    h2.send({ t: 'create', name: 'two', area: 'x', private: true });
    const c2 = await h2.next('created');
    assert.notEqual(c1.code, c2.code);
    a.send({ t: 'join', code: c2.code });
    const j = await a.next('joined');
    assert.equal(j.session.id, c2.session.id);
    assert.equal(j.peerId, 2);
    assert.equal((await h2.next('peer_joined')).id, 2);
    // public sessions are not reachable by a code, an unknown code is bad_code, three misses and the fourth try is rate limited
    const h3 = await s.connect(5);
    h3.send({ t: 'create', name: 'pub', area: 'x' });
    const c3 = await h3.next('created');
    assert.equal(c3.code, undefined);
    for (const code of ['999999', '123456', '000000']) {
      late.send({ t: 'join', code });
      assert.equal((await late.next('error')).code, 'bad_code');
    }
    late.send({ t: 'join', code: c1.code });
    assert.equal((await late.next('error')).code, 'rate_limit');
    late.send({ t: 'join', id: c1.session.id, code: c1.code });
    assert.equal((await late.next('error')).code, 'rate_limit');
    // a closed session answers closed even for the right code
    h.send({ t: 'set_open', open: false });
    await h.next('session_updated');
    const ok = await s.connect(6);
    ok.send({ t: 'join', code: c1.code });
    assert.equal((await ok.next('error')).code, 'closed');
    // a host-chosen code that is taken is refused
    const h4 = await s.connect(7);
    h4.send({ t: 'create', name: 'dup', area: 'x', private: true, code: c1.code });
    assert.equal((await h4.next('error')).code, 'bad_request');
  } finally { await s.close(); }
});

// ---- rejoin after a drop (README "Rejoin window"; DECISIONS D13) ---------------------------------------------------------------------------------------

const quiet = async (c, t, ms = 200) => { await new Promise((r) => setTimeout(r, ms)); return !c.texts.some((m) => m.t === t); };

test('rejoin: a member whose connection dropped is offered its Closed session on its next connection and walks back in without a code', async () => {
  const s = await boot();
  try {
    const h = await s.connect(1), a = await s.connect(2), stranger = await s.connect(3);
    h.send({ t: 'create', name: 'Closed crypt', area: 'graves', private: true });
    const created = await h.next('created');
    a.send({ t: 'join', code: created.code });
    await a.next('joined');
    await h.next('peer_joined');
    a.ws.terminate();                                       // the network dropped: no leave, no close frame
    assert.deepEqual((await h.next('peer_left')).reason, 'disconnected');
    const back = await s.connect(2);
    const offer = await back.next('rejoin');
    assert.equal(offer.session.id, created.session.id);
    assert.deepEqual([offer.from, offer.fromId, offer.session.players, offer.session.private], ['u1', 1, 1, true]);
    assert.ok(offer.ms > 0 && offer.ms <= s.lobby.options.rejoinMs, `the window left is told (${offer.ms})`);
    stranger.send({ t: 'join', id: created.session.id });   // the pass is the dropped member's alone
    assert.equal((await stranger.next('error')).code, 'bad_code');
    back.send({ t: 'join', id: created.session.id });       // no code
    const j = await back.next('joined');
    assert.equal(j.session.id, created.session.id);
    const pj = await h.next('peer_joined');
    assert.deepEqual([pj.name, pj.accountId], ['u2', 2]);
    assert.notEqual(pj.id, 2, 'a peer id is never reused within a session');
    back.send({ t: 'leave' }); await back.next('left');
    const again = await s.connect(2);
    assert.ok(await quiet(again, 'rejoin'), 'having joined again, the offer is gone');
  } finally { await s.close(); }
});

test('rejoin: a member who left, was removed, closed its socket on purpose, or whose host dropped is offered nothing', async () => {
  const s = await boot();
  try {
    const h = await s.connect(1), a = await s.connect(2), b = await s.connect(3), c = await s.connect(4);
    h.send({ t: 'create', name: 'Open crypt', area: 'graves' });
    const id = (await h.next('created')).session.id;
    for (const x of [a, b, c]) { x.send({ t: 'join', id }); await x.next('joined'); await h.next('peer_joined'); }
    a.send({ t: 'leave' });                                 // left
    await a.next('left');
    h.send({ t: 'kick', id: 3 });                           // removed
    await b.next('session_closed');
    c.ws.close(1000, 'bye');                                // what the game does when it closes its lobby socket on purpose
    assert.deepEqual([(await h.next('peer_left')).reason, (await h.next('peer_left')).reason, (await h.next('peer_left')).reason], ['left', 'kicked', 'disconnected']);
    for (const acct of [2, 3, 4]) {
      const back = await s.connect(acct);
      assert.ok(await quiet(back, 'rejoin'), `account ${acct} is offered nothing`);
    }
    const d = await s.connect(5);
    d.send({ t: 'join', id }); await d.next('joined'); await h.next('peer_joined');
    h.ws.terminate();                                       // a host who drops ends the session (D6): its last member has nothing to come back to
    await d.next('session_closed');
    d.ws.terminate();
    const dBack = await s.connect(5);
    assert.ok(await quiet(dBack, 'rejoin'));
  } finally { await s.close(); }
});

test('rejoin: the offer ends with its window, with the session, and when the account hosts a party of its own', async () => {
  const s = await boot({ rejoinMs: 300 });
  try {
    const h = await s.connect(1), a = await s.connect(2), b = await s.connect(3), c = await s.connect(4);
    h.send({ t: 'create', name: 'Closed', area: 'graves', private: true });
    const created = await h.next('created');
    for (const x of [a, b, c]) { x.send({ t: 'join', code: created.code }); await x.next('joined'); await h.next('peer_joined'); }
    a.ws.terminate(); b.ws.terminate(); c.ws.terminate();
    await h.next('peer_left'); await h.next('peer_left'); await h.next('peer_left');
    const bBack = await s.connect(3);                      // b is offered it, then hosts its own party instead: the old offer is gone
    await bBack.next('rejoin');
    bBack.send({ t: 'create', name: 'Mine', area: 'graves' });
    await bBack.next('created');
    bBack.send({ t: 'leave' });
    await new Promise((r) => setTimeout(r, 50));
    const bAgain = await s.connect(3);
    assert.ok(await quiet(bAgain, 'rejoin', 100), 'hosting its own party forgot the way back');
    h.send({ t: 'leave' });                                 // the host ends the session: c has nothing to come back to
    await new Promise((r) => setTimeout(r, 50));
    const cBack = await s.connect(4);
    assert.ok(await quiet(cBack, 'rejoin', 100), 'the session ended');
    await new Promise((r) => setTimeout(r, 300));           // a's window runs out (there is no session left either way: test the window on a fresh one)
    const h2 = await s.connect(6), e = await s.connect(7);
    h2.send({ t: 'create', name: 'Closed 2', area: 'graves', private: true });
    const c2 = await h2.next('created');
    e.send({ t: 'join', code: c2.code }); await e.next('joined'); await h2.next('peer_joined');
    e.ws.terminate(); await h2.next('peer_left');
    await new Promise((r) => setTimeout(r, 450));
    const eBack = await s.connect(7);
    assert.ok(await quiet(eBack, 'rejoin', 100), 'the window ran out');
    eBack.send({ t: 'join', id: c2.session.id });
    assert.equal((await eBack.next('error')).code, 'bad_code', 'and so did the way through the Closed door');
  } finally { await s.close(); }
});

test('rejoin: it is told again on each connection of the window, and a newer login of the account counts as the drop of the older one', async () => {
  const s = await boot();
  try {
    const h = await s.connect(1), a = await s.connect(2);
    h.send({ t: 'create', name: 'Closed', area: 'graves', private: true });
    const created = await h.next('created');
    a.send({ t: 'join', code: created.code }); await a.next('joined');
    a.ws.terminate();
    const first = await s.connect(2);
    await first.next('rejoin');
    first.ws.terminate();                                   // dropped again before it decided: the offer stands
    const second = await s.connect(2);
    assert.equal((await second.next('rejoin')).session.id, created.session.id);
    // a newer login on another PC while a member is still in the session (a half-open socket the lobby has not noticed): the older one is replaced and the new one is offered the way back
    const h2 = await s.connect(8), m = await s.connect(9);
    h2.send({ t: 'create', name: 'Closed 2', area: 'graves', private: true });
    const c2 = await h2.next('created');
    m.send({ t: 'join', code: c2.code }); await m.next('joined'); await h2.next('peer_joined');
    const m2 = await s.connect(9);
    await m.next('replaced');
    assert.equal((await m2.next('rejoin')).session.id, c2.session.id);
  } finally { await s.close(); }
});
