'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const WebSocket = require('ws');
const jwt = require('jsonwebtoken');
const { createLobby } = require('../src/server');
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
    assert.deepEqual(Object.keys(l.sessions[0]).sort(), ['area', 'host', 'id', 'max', 'name', 'open', 'players', 'private']);
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
