'use strict';
// Friends over the lobby: presence to mutual friends only, invites, asks to join, Open / Closed (README "Friends").
const test = require('node:test');
const assert = require('node:assert/strict');
const WebSocket = require('ws');
const jwt = require('jsonwebtoken');
const { createLobby } = require('../src/server');
const { createFriendsSource } = require('../src/friends');

const SECRET = 'test-secret-not-real';
const tok = (id) => jwt.sign({ accountId: id, username: `u${id}` }, SECRET, { expiresIn: '1h' });

/** graph: accountId -> [friend ids] as each account's backend list says (edit it, then send friends_changed). */
async function boot(graph, opts = {}) {
  const friendsOf = async (token) => {
    const id = jwt.decode(token).accountId;
    return graph.has(id) ? [...graph.get(id)] : [];
  };
  const lobby = createLobby({ jwtSecret: SECRET, port: 0, quiet: true, friendsOf, ...opts });
  const port = await lobby.start();
  const all = [];
  const connect = async (id) => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}`);
    const c = { id, ws, texts: [], waiters: [] };
    ws.on('message', (d, bin) => { if (!bin) c.texts.push(JSON.parse(d.toString())); c.waiters.splice(0).forEach((w) => w()); });
    ws.on('error', () => {});
    await new Promise((r) => ws.once('open', r));
    c.send = (o) => ws.send(JSON.stringify(o));
    c.until = async (pred, ms = 2000) => {
      const t0 = Date.now();
      for (;;) {
        const hit = pred(c);
        if (hit) return hit;
        if (Date.now() - t0 > ms) throw new Error(`u${id} timeout; texts=` + JSON.stringify(c.texts));
        await new Promise((r) => { c.waiters.push(r); setTimeout(r, 50); });
      }
    };
    c.next = (t, f = () => true) => c.until(() => { const i = c.texts.findIndex((m) => m.t === t && f(m)); return i >= 0 ? c.texts.splice(i, 1)[0] : null; });
    c.none = async (t, ms = 150) => { await new Promise((r) => setTimeout(r, ms)); return !c.texts.some((m) => m.t === t); };
    all.push(c);
    c.send({ t: 'auth', token: tok(id) });
    await c.next('ready');
    c.snapshot = await c.next('friends');
    return c;
  };
  return { lobby, connect, close: async () => { all.forEach((c) => c.ws.terminate()); await lobby.stop(); } };
}
const g = (pairs) => {
  const m = new Map();
  for (const [a, b] of pairs) { m.set(a, [...(m.get(a) || []), b]); m.set(b, [...(m.get(b) || []), a]); }
  return m;
};

test('presence: mutual friends see each other come online, change, play together and leave; others see nothing', async () => {
  const graph = g([[1, 2]]);
  graph.set(3, [1]);   // 3 lists 1, but 1 does not list 3: not mutual
  const s = await boot(graph);
  try {
    const a = await s.connect(1);
    const b = await s.connect(2);
    const c = await s.connect(3);
    const on = await a.next('presence', (m) => m.accountId === 2);
    assert.equal(on.p.username, 'u2');
    assert.equal(on.p.session, null);
    b.send({ t: 'presence', class: 11, level: 631, area: 'sextons-acre' });
    const ch = await a.next('presence', (m) => m.accountId === 2 && m.p.level === 631);
    assert.deepEqual([ch.p.class, ch.p.area], [11, 'sextons-acre']);
    b.send({ t: 'presence', class: 11, level: 631, area: 'sextons-acre' });   // unchanged: nothing sent
    assert.ok(await a.none('presence'));
    b.send({ t: 'presence', class: 'x', level: -1, area: '<script>' });       // junk is dropped to null
    const junk = await a.next('presence', (m) => m.accountId === 2);
    assert.deepEqual([junk.p.class, junk.p.level, junk.p.area], [null, null, null]);
    b.send({ t: 'create', name: 'Crypt', area: 'graves', private: false });
    const hosting = await a.next('presence', (m) => m.accountId === 2 && m.p.session);
    assert.deepEqual({ ...hosting.p.session, id: 'x' }, { id: 'x', private: false, open: true, players: 1, max: 4, host: 'u2', isHost: true, heat: 0, difficulty: 'medium' });
    a.send({ t: 'join', id: hosting.p.session.id });   // a friend's Open party: Join from the list
    await a.next('joined');
    const two = await a.next('presence', (m) => m.accountId === 2 && m.p.session && m.p.session.players === 2);
    assert.ok(two);
    b.ws.close();
    const off = await a.next('presence', (m) => m.accountId === 2 && m.p === null);
    assert.ok(off);
    assert.ok(!c.texts.some((m) => m.t === 'presence'), 'a one-sided friend never sees presence');
    const snap = (await s.connect(4)).texts;
    assert.ok(!snap.some((m) => m.t === 'presence'));
  } finally { await s.close(); }
});

test('presence: the snapshot on connect lists online mutual friends with their presence', async () => {
  const s = await boot(g([[1, 2], [1, 3]]));
  try {
    const b = await s.connect(2);
    b.send({ t: 'presence', class: 2, level: 40, area: 'graves' });
    await new Promise((r) => setTimeout(r, 50));
    const a = await s.connect(1);
    assert.deepEqual(a.snapshot.list, [{ accountId: 2, username: 'u2', class: 2, level: 40, area: 'graves', session: null }]);
    assert.equal((await b.next('presence', (m) => m.accountId === 1)).p.username, 'u1');
  } finally { await s.close(); }
});

test('friends_changed: an accepted request reaches both sides at once, a removal hides presence', async () => {
  const graph = new Map();
  const s = await boot(graph);
  try {
    const a = await s.connect(1);
    const b = await s.connect(2);
    graph.set(1, [2]); graph.set(2, [1]);       // B accepted A's request on the backend
    b.send({ t: 'friends_changed', accountId: 1 });
    await a.next('friends_changed');            // A's client reloads its list (the toast / list update)
    // both lists reload at once: whichever lands second carries the other (a snapshot, or a presence push)
    await b.until(() => b.texts.some((m) => (m.t === 'friends' && m.list.length === 1) || (m.t === 'presence' && m.accountId === 1 && m.p)));
    await a.until(() => a.texts.some((m) => (m.t === 'friends' && m.list.length === 1) || (m.t === 'presence' && m.accountId === 2 && m.p)));
    graph.set(1, []); graph.set(2, []);         // A removed B
    a.send({ t: 'friends_changed', accountId: 2 });
    await b.next('presence', (m) => m.accountId === 1 && m.p === null);
    await b.next('friends_changed');
  } finally { await s.close(); }
});

test('invite: only the host invites, only online mutual friends; an invite opens a Closed party and is used once', async () => {
  const s = await boot(g([[1, 2], [1, 3]]));
  try {
    const host = await s.connect(1);
    const f = await s.connect(2);
    const stranger = await s.connect(4);
    host.send({ t: 'invite', accountId: 2 });
    assert.equal((await host.next('error')).code, 'not_host');
    host.send({ t: 'create', name: 'Closed crypt', area: 'graves', private: true });
    const created = await host.next('created');
    assert.equal(created.session.private, true);
    host.send({ t: 'invite', accountId: 4 });
    assert.equal((await host.next('error')).code, 'not_friend');
    stranger.send({ t: 'join', id: created.session.id });
    assert.equal((await stranger.next('error')).code, 'bad_code');
    host.send({ t: 'invite', accountId: 2 });
    await host.next('invite_sent', (m) => m.accountId === 2);
    const inv = await f.next('invited');
    assert.deepEqual([inv.from, inv.fromId, inv.auto, inv.session.id], ['u1', 1, false, created.session.id]);
    f.send({ t: 'join', id: inv.session.id });
    await f.next('joined');
    host.send({ t: 'invite', accountId: 2 });
    assert.equal((await host.next('error')).code, 'already_in');
    f.send({ t: 'leave' });
    await f.next('left');
    f.send({ t: 'join', id: inv.session.id });   // the invite was used
    assert.equal((await f.next('error')).code, 'bad_code');
  } finally { await s.close(); }
});

test('invites expire', async () => {
  const s = await boot(g([[1, 2]]), { inviteMs: 60 });
  try {
    const host = await s.connect(1);
    const f = await s.connect(2);
    host.send({ t: 'create', name: 'C', area: 'graves', private: true });
    const { session } = await host.next('created');
    host.send({ t: 'invite', accountId: 2 });
    await f.next('invited');
    await new Promise((r) => setTimeout(r, 100));
    f.send({ t: 'join', id: session.id });
    assert.equal((await f.next('error')).code, 'bad_code');
  } finally { await s.close(); }
});

test('ask: to a solo friend (who hosts, then accepts: the asker is invited with auto), declined, rate limited; routed to the host of a friend\'s party', async () => {
  const s = await boot(g([[1, 2], [2, 3]]), { askGapMs: 200 });
  try {
    const a = await s.connect(1);
    const b = await s.connect(2);
    const c = await s.connect(3);
    a.send({ t: 'ask', accountId: 3 });
    assert.equal((await a.next('error')).code, 'not_friend');
    a.send({ t: 'ask', accountId: 2 });
    await a.next('ask_sent', (m) => m.accountId === 2);
    const req = await b.next('join_request');
    assert.deepEqual([req.accountId, req.username, req.via], [1, 'u1', undefined]);
    a.send({ t: 'ask', accountId: 2 });
    assert.equal((await a.next('error')).code, 'rate_limit');
    b.send({ t: 'answer', accountId: 1, accept: true });          // solo: must host first
    assert.equal((await b.next('error')).code, 'not_host');
    b.send({ t: 'create', name: 'B party', area: 'graves', private: true });
    await b.next('created');
    b.send({ t: 'answer', accountId: 1, accept: true });
    const inv = await a.next('invited');
    assert.equal(inv.auto, true);
    a.send({ t: 'join', id: inv.session.id });
    await a.next('joined');
    b.send({ t: 'answer', accountId: 1, accept: true });          // answered already
    assert.equal((await b.next('error')).code, 'not_found');
    // C is friends with B only; A is in B's party. C asks B... and is declined
    c.send({ t: 'ask', accountId: 2 });
    await b.next('join_request', (m) => m.accountId === 3);
    b.send({ t: 'answer', accountId: 3, accept: false });
    assert.equal((await c.next('ask_declined')).username, 'u2');
  } finally { await s.close(); }
});

test('ask: a friend who is a guest in someone else\'s party routes the ask to that host', async () => {
  const s = await boot(g([[1, 2], [3, 2]]));
  try {
    const host = await s.connect(3);
    const friend = await s.connect(2);
    const asker = await s.connect(1);
    host.send({ t: 'create', name: 'H', area: 'graves', private: false });
    const { session } = await host.next('created');
    friend.send({ t: 'join', id: session.id });
    await friend.next('joined');
    asker.send({ t: 'ask', accountId: 2 });
    const req = await host.next('join_request');
    assert.deepEqual([req.accountId, req.via], [1, 'u2']);
    assert.ok(await friend.none('join_request'));
  } finally { await s.close(); }
});

test('set_private: Closed leaves the list (and gets a code), Open comes back; friends see it', async () => {
  const s = await boot(g([[1, 2]]));
  try {
    const host = await s.connect(1);
    const f = await s.connect(2);
    host.send({ t: 'create', name: 'Mine', area: 'graves', private: false });
    const { session } = await host.next('created');
    host.send({ t: 'set_private', private: true });
    const up = await host.next('session_updated');
    assert.equal(up.session.private, true);
    assert.equal((await f.next('presence', (m) => m.p && m.p.session && m.p.session.private)).p.session.id, session.id);
    f.send({ t: 'list' });
    assert.deepEqual((await f.next('sessions')).sessions, []);
    assert.ok([...s.lobby.sessions.values()][0].code.length === 6);
    host.send({ t: 'set_private', private: false });
    await f.next('presence', (m) => m.p && m.p.session && !m.p.session.private);
    f.send({ t: 'list' });
    assert.equal((await f.next('sessions')).sessions.length, 1);
    f.send({ t: 'set_private', private: true });
    assert.equal((await f.next('error')).code, 'not_host');
  } finally { await s.close(); }
});

test('the host\'s world (heat, difficulty) rides the session everywhere: list, join, invite, presence; members hear changes', async () => {
  const s = await boot(g([[1, 2], [1, 3]]));
  try {
    const host = await s.connect(1);
    const guest = await s.connect(2);
    const friend = await s.connect(3);
    host.send({ t: 'create', name: 'H', area: 'graves', private: false, heat: 7, difficulty: 'hard' });
    const { session } = await host.next('created');
    assert.deepEqual([session.heat, session.difficulty], [7, 'hard']);
    guest.send({ t: 'list' });
    assert.deepEqual((await guest.next('sessions')).sessions.map((x) => [x.heat, x.difficulty]), [[7, 'hard']]);
    guest.send({ t: 'join', id: session.id });
    assert.equal((await guest.next('joined')).session.heat, 7);
    host.send({ t: 'world', heat: 0, difficulty: 'medium' });
    assert.deepEqual(await guest.next('world'), { t: 'world', heat: 0, difficulty: 'medium' });
    assert.equal((await host.next('session_updated')).session.heat, 0);
    const p = await friend.next('presence', (m) => m.p && m.p.session && m.p.session.heat === 0 && m.p.session.difficulty === 'medium');
    assert.equal(p.p.session.id, session.id);
    host.send({ t: 'invite', accountId: 3 });
    const inv = await friend.next('invited');
    assert.deepEqual([inv.session.heat, inv.session.difficulty], [0, 'medium']);
    guest.send({ t: 'world', heat: 30 });
    assert.equal((await guest.next('error')).code, 'not_host');
  } finally { await s.close(); }
});

test('without friendsOf the lobby works as before: no friends snapshot, presence ignored', async () => {
  const lobby = createLobby({ jwtSecret: SECRET, port: 0, quiet: true });
  const port = await lobby.start();
  try {
    const ws = new WebSocket(`ws://127.0.0.1:${port}`);
    const got = [];
    ws.on('message', (d) => got.push(JSON.parse(d.toString())));
    await new Promise((r) => ws.once('open', r));
    ws.send(JSON.stringify({ t: 'auth', token: tok(1) }));
    ws.send(JSON.stringify({ t: 'presence', class: 1, level: 2, area: 'graves' }));
    await new Promise((r) => setTimeout(r, 150));
    assert.deepEqual(got.map((m) => m.t), ['ready']);
    assert.equal(got[0].presence, false);
    ws.terminate();
  } finally { await lobby.stop(); }
});

test('friends source: reads accepted friend ids with the player\'s own token; failures are null', async () => {
  const calls = [];
  const ok = createFriendsSource({ backendUrl: 'http://b', fetchImpl: async (url, init) => { calls.push([url, init.headers.authorization]); return { ok: true, json: async () => ({ success: true, data: { friends: [{ accountId: 2 }, { accountId: 'x' }, { accountId: 7 }] } }) }; } });
  assert.deepEqual(await ok('T'), [2, 7]);
  assert.deepEqual(calls, [['http://b/api/friends', 'Bearer T']]);
  assert.equal(await createFriendsSource({ backendUrl: 'http://b', fetchImpl: async () => ({ ok: false }) })('T'), null);
  assert.equal(await createFriendsSource({ backendUrl: 'http://b', fetchImpl: async () => { throw new Error('down'); } })('T'), null);
});

test('file friends source (tests): {accountId: [ids]} read on every lookup; unreadable is null', async () => {
  const fs = require('fs');
  const os = require('os');
  const path = require('path');
  const { createFileFriendsSource } = require('../src/friends');
  const f = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'dmfr-')), 'f.json');
  const src = createFileFriendsSource(f);
  assert.equal(await src('T', 1), null);
  fs.writeFileSync(f, JSON.stringify({ 1: [2, 'x', 3] }));
  assert.deepEqual(await src('T', 1), [2, 3]);
  assert.deepEqual(await src('T', 9), []);
  fs.rmSync(path.dirname(f), { recursive: true });
});
