// Node socket.io-client peer for the Godot realtime integration test (tests/realtime/run.gd). LOCAL server only.
// usage: node peer.mjs <url> <instance> <name> <logfile> [snapshotTag]
// Joins <instance>, appends every event it sees as one JSON line to <logfile>. Whoever the relay makes host publishes a snapshot
// at 10 Hz. Rejoins (every 300 ms) after a drop, so it also survives a server restart.
import { io } from 'socket.io-client';
import { appendFileSync } from 'node:fs';

const [url, instance, name, logfile, tag = name] = process.argv.slice(2);
if (!/^https?:\/\/(127\.0\.0\.1|localhost)(:\d+)?$/.test(url)) { console.error('peer: local urls only'); process.exit(2); }
const log = (o) => appendFileSync(logfile, JSON.stringify({ at: Date.now(), ...o }) + '\n');
let socket = null;
let hostTimer = null;
let tick = 0;

function startHosting() {
  if (hostTimer) return;
  hostTimer = setInterval(() => {
    tick++;
    socket?.volatile.emit('world:snapshot', {
      t: tick / 10, waveTier: 3, difficulty: 'hard', ascension: 0,
      enemies: [[7, 'robber', 1.5, 2.5, 0.5, 80, 100, 1, 2 | 1, 0.5, 3, 1, 'graveyard', 2, 12]],
      thralls: [[200, socket.id, 'warrior', 0.5, 0.5, 0, 50, 60, 1, 0, 1, 3, 9, 0.8]],
      boss: { active: false, x: 0, z: 0, facing: 0, hp: 0, maxHp: 0, phase: 1, state: 'idle', stateT: 0 },
      depleted: [['tree_1', 4]], tag,
    });
  }, 100);
}
function stopHosting() { clearInterval(hostTimer); hostTimer = null; }

function connect() {
  socket = io(url, { auth: { token: `offline:${name}` }, reconnection: false, timeout: 3000 });
  socket.on('connect_error', (e) => { log({ ev: 'connect_error', msg: e.message }); setTimeout(connect, 300); });
  socket.on('connect', () => {
    socket.emit('world:join', { instance, characterId: 90 + name.length, classIndex: 2, level: 7, x: 3, z: 4, facing: 1, gear: { main_hand: 'bone_staff' } }, (res) => {
      if (!res?.success) { log({ ev: 'join_failed', error: res?.error }); socket.disconnect(); setTimeout(connect, 300); return; }
      log({ ev: 'joined', self: res.data.self, players: res.data.players, hostId: res.data.hostId, snapshotTag: res.data.snapshot?.tag ?? null, snapshotT: res.data.snapshot?.t ?? null });
      if (res.data.hostId === socket.id) startHosting();
      for (const ev of ['player:join', 'player:leave', 'player:move', 'player:gear', 'chat:message', 'world:intent', 'world:snapshot', 'world:events', 'room:host', 'session:replaced']) {
        socket.on(ev, (p) => {
          if (ev === 'world:snapshot') { log({ ev, t: p.t, tag: p.tag, enemies: p.enemies?.length }); return; }
          log({ ev, p });
          if (ev === 'room:host' && p.hostId === socket.id) startHosting();
        });
      }
    });
  });
  socket.on('disconnect', (r) => { log({ ev: 'disconnect', reason: r }); stopHosting(); setTimeout(connect, 300); });
}
// a moving peer so the other side sees player:move
setInterval(() => socket?.connected && socket.volatile.emit('player:move', { x: 3 + Math.random(), z: 4, facing: 1, moving: true, hpFrac: 0.5, level: 7 }), 100).unref();
connect();
process.on('SIGTERM', () => { socket?.disconnect(); process.exit(0); });
