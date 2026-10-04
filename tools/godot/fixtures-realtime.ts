/**
 * Golden fixtures for godot/net/realtime: snapshot encoding (makeSnapshot), WorldMirror.applySnapshot/applyEvents/update, the
 * reconnect schedule + error classification, and the event coalescer, all produced by the real TS.
 * Run:  npx vite-node tools/godot/fixtures-realtime.ts   ->  godot/tests/realtime/fixtures/realtime.json
 */
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { makeSnapshot, WorldMirror } from '../../src/gameplay/sim/snapshot';
import { firstConnectDelayMs, isRetryableError, rejoinDelayMs } from '../../src/net/reconnect';
import { EventCoalescer } from '../../src/net/eventCoalescer';
import { VOW_ORDER } from '../../src/content/ascension';
import { saveRejoin, loadRejoin, REJOIN_WINDOW_MS } from '../../src/net/rejoinStore';

let seed = 12345;
const rnd = () => ((seed = (seed * 1664525 + 1013904223) >>> 0) / 4294967296);
const pick = <T,>(a: T[]) => a[Math.floor(rnd() * a.length)];
const num = (lo: number, hi: number) => lo + rnd() * (hi - lo);
const chance = (p: number) => rnd() < p;

const E_STATES = ['rising', 'move', 'windup', 'recover', 'channel', 'dead', 'burrow'];
const T_STATES = ['rising', 'idle', 'move', 'attack', 'dead'];
const KINDS = ['warrior', 'shieldbearer', 'hound', 'wraith', 'archer', 'bonemage', 'plaguebearer', 'colossus'];
const DEFS = ['robber', 'hound', 'penitent'];
const AFFIXES = [undefined, 'bellTolled', 'hungering', 'shrouded', 'vengeful'];

const timer = () => (chance(0.3) ? num(0, 2) : 0);
function enemy(id: number) {
  return {
    id, def: pick(DEFS), area: pick(['graveyard', 'marsh']), level: Math.floor(num(1, 60)), elite: chance(0.3), moving: chance(0.5),
    x: num(-60, 60), z: num(-60, 60), facing: num(-3.2, 3.2), hp: num(1, 900), maxHp: num(900, 1200), speed: num(1, 6), scale: num(0.7, 2),
    state: pick(E_STATES), stateT: num(0, 3), slowT: timer(), wardSlowT: timer(), chillT: timer(), bleedT: timer(), sanctT: timer(), hexT: timer(),
    silenceT: timer(), incenseT: timer(), stunT: timer(), rootT: timer(), diving: chance(0.1), fracture: Math.floor(num(0, 4)), withered: Math.floor(num(0, 13)),
    affix: pick(AFFIXES),
  };
}
function thrall(id: number) {
  return {
    id, owner: pick(['a', 'b']), kind: pick(KINDS), x: num(-60, 60), z: num(-60, 60), facing: num(-3.2, 3.2), hp: num(1, 300), maxHp: num(300, 400),
    state: pick(T_STATES), moving: chance(0.5), stateT: num(0, 3), empowered: chance(0.3), rallyT: timer(), cursedT: timer(), champion: chance(0.2),
    speed: num(1, 6), damage: num(1, 99), attackInterval: num(0.3, 2),
  };
}

function simCase() {
  const enemies = Array.from({ length: Math.floor(num(0, 12)) }, (_, i) => enemy(i + 1));
  const thralls = Array.from({ length: Math.floor(num(0, 8)) }, (_, i) => thrall(100 + i));
  const zones = [
    { id: 300, kind: 'miasma', owner: 'a', x: 1.5, z: 2.5, r: 3, until: 20, bornAt: 10, tick: 0.5, dps: 5, slow: 0, witheredCap: 4, bloom: false, hostile: false, creep: 0.8 },
    { id: 301, kind: 'miasma', owner: 'a', x: -3, z: 4, r: 3, until: 20, bornAt: 10, tick: 0.5, dps: 5, slow: 0, witheredCap: 4, bloom: false, hostile: false },
  ];
  const corpses = [{ id: 400, x: 1, z: 2, kind: 'normal', enemy: 'robber', elite: false, facing: 0.5, scale: 1, area: 'graveyard', bornAt: 5, expiresAt: 25, ruptureAt: 1e9 }];
  const ascended = chance(0.5);
  const vows = ascended ? { [VOW_ORDER[0]]: 1, [VOW_ORDER[1]]: 2 } : {};
  const sim: any = {
    time: num(0, 600), waveTier: Math.floor(num(0, 20)), difficulty: pick(['easy', 'medium', 'hard']), ascension: ascended ? 5 : 0, vows,
    enemies: new Map(enemies.map((e) => [e.id, e])), thralls: new Map(thralls.map((t) => [t.id, t])),
    zones: new Map(zones.map((z) => [z.id, z])), corpses: new Map(corpses.map((c) => [c.id, c])),
    bossState: { active: chance(0.5), x: 1, z: 2, facing: 0, hp: 100, maxHp: 1000, phase: 1, state: 'idle', stateT: 0 },
    depletedNodes: () => (chance(0.5) ? [['tree_1', 12.5], ['rock_4', 3]] : []),
  };
  return {
    input: { time: sim.time, waveTier: sim.waveTier, difficulty: sim.difficulty, ascension: sim.ascension, vows, enemies, thralls, zones, corpses, bossState: sim.bossState, depleted: sim.depletedNodes() },
    simObj: sim,
  };
}

// Make depletedNodes deterministic: capture its value once.
const encodeCases: unknown[] = [];
const mirrorCases: unknown[] = [];
for (let i = 0; i < 60; i++) {
  const c = simCase();
  const dep = c.input.depleted;
  c.simObj.depletedNodes = () => dep;
  const full = i % 2 === 0;
  encodeCases.push({ input: c.input, full, expected: makeSnapshot(c.simObj, full) });
}
// Mirror: 6-step sequences (snapshots that add/remove entities, events, then update(dt)).
for (let i = 0; i < 40; i++) {
  const m = new WorldMirror();
  const steps: unknown[] = [];
  for (let s = 0; s < 6; s++) {
    const c = simCase();
    const dep = c.input.depleted;
    c.simObj.depletedNodes = () => dep;
    // Keep ids overlapping across steps so entities persist/disappear.
    const snap = makeSnapshot(c.simObj, chance(0.5));
    const events = chance(0.6)
      ? [
          { t: 'corpse', corpse: { id: 500 + s, x: 1, z: 1, kind: 'normal', enemy: 'robber', elite: false, facing: 0, scale: 1, area: 'graveyard', bornAt: 0, expiresAt: 20, ruptureAt: 1e9 } },
          { t: 'death', id: 1 + (s % 4) },
          { t: 'thrallGone', id: 100 + (s % 3) },
          { t: 'zone', zone: { id: 700 + s, kind: 'miasma', owner: 'a', x: 0, z: 0, r: 2, until: 9, bornAt: 0, tick: 1, dps: 1, slow: 0, witheredCap: 1, bloom: false, hostile: false } },
          { t: 'nodeGone', id: 'tree_9', respawnS: 30 },
          { t: 'nodeBack', id: 'tree_1' },
          { t: 'seeded', corpseId: 400, by: 'a', armMs: 1500 },
        ]
      : [];
    const dt = num(0.01, 0.2);
    m.applySnapshot(JSON.parse(JSON.stringify(snap)));
    m.applyEvents(JSON.parse(JSON.stringify(events)));
    m.update(dt);
    steps.push({
      snapshot: snap, events, dt,
      state: JSON.parse(JSON.stringify({
        time: m.time, waveTier: m.waveTier, difficulty: m.difficulty, vows: m.vows, ascension: m.ascension,
        enemies: [...m.enemies.values()], thralls: [...m.thralls.values()], corpses: [...m.corpses.values()], zones: [...m.zones.values()],
        depleted: [...m.depleted.entries()], boss: m.bossState,
      })),
    });
  }
  mirrorCases.push({ steps });
}

const delays = {
  rejoin: Array.from({ length: 12 }, (_, i) => rejoinDelayMs(i)),
  first: Array.from({ length: 12 }, (_, i) => firstConnectDelayMs(i)),
};
const msgs = ['Co-op service unreachable — playing solo', 'Realtime service not configured', 'Not authenticated', 'Not authenticated: this account was opened somewhere else',
  'That world is full (10 players)', 'You are already in this world', 'Already in a world', 'xhr poll error', 'websocket error', 'timeout', 'transport close',
  'ECONNREFUSED', 'Failed to fetch', 'network down', 'Could not join the world', ''];
const retry = msgs.flatMap((m) => (['first', 'rejoin'] as const).map((mode) => ({ msg: m, mode, expected: isRetryableError(new Error(m), mode) })));

// Coalescer: replay (events, now) pushes; record each send.
const coalescer = [40, 10].map((perSec) => {
  const sends: unknown[] = [];
  const co = new EventCoalescer((b) => sends.push(b), perSec, 5);
  const pushes: [number[], number][] = [];
  let now = 0;
  for (let i = 0; i < 60; i++) {
    now += num(2, 40);
    const evs = chance(0.6) ? Array.from({ length: Math.floor(num(0, 9)) }, () => Math.floor(num(0, 1000))) : [];
    pushes.push([evs, now]);
    co.push(evs.map((n) => ({ t: 'x', n })) as any, now);
  }
  return { perSec, maxBatch: 5, pushes, sends, waiting: co.waiting };
});

const store: Record<string, string> = {};
const s2 = { getItem: (k: string) => store[k] ?? null, setItem: (k: string, v: string) => void (store[k] = v), removeItem: (k: string) => void delete store[k] };
saveRejoin('abc', 1000, s2);
const rejoin = { window: REJOIN_WINDOW_MS, at: [1000, 1000 + REJOIN_WINDOW_MS, 1001 + REJOIN_WINDOW_MS, 999].map((t) => ({ now: t, expected: loadRejoin(t, s2) })) };

const out = resolve(__dirname, '../../godot/tests/realtime/fixtures/realtime.json');
mkdirSync(dirname(out), { recursive: true });
writeFileSync(out, JSON.stringify({ encodeCases, mirrorCases, delays, retry, coalescer, rejoin }));
console.log('wrote', out, `${encodeCases.length} encode, ${mirrorCases.length} mirror`);
