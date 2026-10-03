// Headless co-op network bench (no browser): a real WorldSim fight -> makeSnapshot/JSON -> a real relay process -> real socket.io guests -> WorldMirror.
// Deterministic and cheap, so the numbers are not drowned by software GL. Run (relay on 5403 by default):
//   npx vite-node tools/qa/coop-net-bench.ts
// Env: DM_BENCH_RT_PORT (5403)  DM_BENCH_SECONDS (20 of sim time per scenario)  DM_BENCH_GUESTS (2)  DM_BENCH_JSON (path to write results)
import { spawn } from 'node:child_process';
import net from 'node:net';
import fs from 'node:fs';
import path from 'node:path';
import { io, type Socket } from 'socket.io-client';
import { AREAS, type AreaId } from '../../src/content/areas';
import { Nav } from '../../src/gameplay/nav';
import { mulberry32 } from '../../src/gameplay/rng';
import { WorldMirror, makeSnapshot } from '../../src/gameplay/sim/snapshot';
import { WorldSim } from '../../src/gameplay/sim/WorldSim';
import type { WorldSnapshot } from '../../src/net/contracts';

const PORT = process.env.DM_BENCH_RT_PORT || '5403';
const PROXY = String(+PORT + 1); // a byte-counting TCP proxy in front of the relay: real on-the-wire bytes (deflate included)
const SECONDS = +(process.env.DM_BENCH_SECONDS || 20);
const GUESTS = +(process.env.DM_BENCH_GUESTS || 2);
const ALL: AreaId[] = ['chapterhouse', 'graves', 'ossuary', 'nave', 'sanctum'] as AreaId[];
const wait = (ms: number) => new Promise((r) => setTimeout(r, ms));
const cpuMs = (pid: number) => { const f = fs.readFileSync(`/proc/${pid}/stat`, 'utf8').split(') ')[1].split(' '); return (+f[11] + +f[12]) * 10; };
const pct = (a: number[], p: number) => { const s = [...a].sort((x, y) => x - y); return s.length ? s[Math.min(s.length - 1, Math.floor(s.length * p))] : 0; };
const avg = (a: number[]) => (a.length ? a.reduce((s, x) => s + x, 0) / a.length : 0);

interface Scenario { name: string; rings: number; players: AreaId[]; thralls: number; corpses: number }
const SCENARIOS: Scenario[] = [
  { name: 'one-area-fight', rings: 3, players: ['nave', 'nave'], thralls: 5, corpses: 40 },
  { name: 'two-areas-fight', rings: 3, players: ['nave', 'graves'], thralls: 5, corpses: 40 },
  { name: 'far-apart', rings: 3, players: ['graves', 'sanctum'], thralls: 5, corpses: 40 },
  { name: 'big-two-areas', rings: 8, players: ['nave', 'graves'], thralls: 10, corpses: 120 },
];

function buildSim(sc: Scenario) {
  const nav = new Nav();
  nav.setUnlocked(ALL);
  const sim = new WorldSim(nav, mulberry32(7));
  sc.players.forEach((area, i) => {
    const r = AREAS[area].rect;
    sim.setPlayer({ id: `p${i}`, x: (r.x0 + r.x1) / 2 + i, z: (r.z0 + r.z1) / 2, alive: true, area, level: 20 });
  });
  const seen = new Set<AreaId>();
  sc.players.forEach((area, pi) => {
    if (seen.has(area)) return;
    seen.add(area);
    const p = sim.players.get(`p${pi}`)!;
    AREAS[area].enemies.forEach((e, i) => { for (let k = 0; k < sc.rings * 4; k++) { const a = (k / (sc.rings * 4)) * Math.PI * 2; sim.spawnEnemy(e.id, area, p.x + Math.cos(a) * (6 + i * 1.2 + (k % 3) * 0.5), p.z + Math.sin(a) * (6 + i * 1.2 + (k % 3) * 0.5), i === 0, false); } });
    for (let i = 0; i < sc.corpses; i++) sim.addCorpse(p.x + 4 + (i % 8) * 1.2, p.z - 3 - Math.floor(i / 8) * 1.5, 'normal', 'robber', false, 0, 1, area);
    for (let i = 0; i < sc.thralls; i++) {
      const x = p.x - 3 + (i % 5) * 1.5, z = p.z + 2 + Math.floor(i / 5) * 1.5;
      sim.addCorpse(x, z, 'normal', 'robber', false, 0, 1, area);
      sim.applyExhume({ t: 'exhume', by: `p${pi}`, x, z, r: 2, cap: sc.thralls, kind: 'warrior', hp: 1e6, damage: 0, attackSpeedMult: 1 } as never);
    }
  });
  return sim;
}

async function startRelay() {
  const child = spawn(process.execPath, [path.join(__dirname, '../../server/realtime/server.js')], {
    env: { ...process.env, REALTIME_PORT: PORT, REALTIME_HOST: '127.0.0.1', DEV_TRUST_TOKENS: '1', CORS_ORIGIN: 'http://localhost', NODE_ENV: 'development' },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const logs: string[] = [];
  child.stderr!.on('data', (d) => logs.push(String(d)));
  await new Promise<void>((resolve, reject) => {
    child.stdout!.on('data', (d) => { logs.push(String(d)); if (String(d).includes('listening')) resolve(); });
    child.once('exit', (c) => reject(new Error(`relay exited ${c}`)));
    setTimeout(() => reject(new Error('relay start timeout')), 10000);
  });
  return { child, logs };
}

let conns = 0;
const wire = { up: new Map<string, number>(), down: new Map<string, number>() };
function startProxy() {
  const srv = net.createServer((c) => {
    const u = net.connect(+PORT, '127.0.0.1');
    const tag = String(conns++);
    c.on('data', (d) => { u.write(d); if (tag) wire.up.set(tag, (wire.up.get(tag) ?? 0) + d.length); });
    u.on('data', (d) => { c.write(d); if (tag) wire.down.set(tag, (wire.down.get(tag) ?? 0) + d.length); });
    c.on('close', () => u.destroy()); u.on('close', () => c.destroy()); c.on('error', () => u.destroy()); u.on('error', () => c.destroy());
  });
  return new Promise<net.Server>((r) => srv.listen(+PROXY, '127.0.0.1', () => r(srv)));
}
const connect = (name: string) => new Promise<{ s: Socket; hostId: string }>((resolve, reject) => {
  const s = io(`http://127.0.0.1:${PROXY}`, { auth: { token: `offline:${name}` }, reconnection: false, transports: ['websocket'] });
  s.on('connect_error', reject);
  s.on('connect', () => s.emit('world:join', { instance: 'bench', characterId: 1, name, classIndex: 2, level: 20 }, (res: { success: boolean; data?: { hostId: string }; error?: string }) => (res.success ? resolve({ s, hostId: res.data!.hostId }) : reject(new Error(res.error))))); 
});

async function run(sc: Scenario, relay: { child: ReturnType<typeof spawn> }) {
  // 1. Generate the host's snapshot stream from a real sim (10 Hz, every 20th full), measure host-side cost + bytes.
  const sim = buildSim(sc);
  const ticks = Math.round(SECONDS * 10);
  const payloads: { json: string; snap: WorldSnapshot }[] = [];
  const makeMs: number[] = [], strMs: number[] = [], bytes: number[] = [], fullBytes: number[] = [];
  const perArea: Record<string, number> = {};
  for (let i = 0; i < ticks; i++) {
    sc.players.forEach((area, pi) => { const p = sim.players.get(`p${pi}`)!; sim.setPlayer({ id: `p${pi}`, x: p.x, z: p.z, alive: true, area, level: 20 }); });
    sim.step(0.05); sim.step(0.05);
    const full = i % 20 === 0;
    const t0 = performance.now(); const snap = makeSnapshot(sim, full); const t1 = performance.now(); const json = JSON.stringify(snap); const t2 = performance.now();
    makeMs.push(t1 - t0); strMs.push(t2 - t1);
    const b = Buffer.byteLength(json); bytes.push(b); if (full) fullBytes.push(b);
    payloads.push({ json, snap });
    if (i === ticks - 1) for (const e of snap.enemies) perArea[e[12] as string] = (perArea[e[12] as string] ?? 0) + 1;
  }
  const last = payloads[payloads.length - 1].snap;
  // 2. Guest apply cost on a real mirror (JSON.parse + applySnapshot + update at 60 Hz equivalent).
  const mirror = new WorldMirror(); const parseMs: number[] = [], applyMs: number[] = [], updMs: number[] = [];
  for (const p of payloads) { const a = performance.now(); const o = JSON.parse(p.json) as WorldSnapshot; const b = performance.now(); mirror.applySnapshot(o); const c = performance.now(); mirror.update(1 / 60); const d = performance.now(); parseMs.push(b - a); applyMs.push(c - b); updMs.push(d - c); }

  // 3. Push through the real relay with a real host + guests at 10 Hz, count what arrives.
  const base = conns;
  const host = await connect(`host_${sc.name}`);
  const guests: Awaited<ReturnType<typeof connect>>[] = [];
  for (let i = 0; i < GUESTS; i++) guests.push(await connect(`g${i}_${sc.name}`));
  // Guests report where they stand (the relay's interest filter uses it), like the real client's player:move.
  const spot = (area: AreaId, i: number) => { const r = AREAS[area].rect; return { x: (r.x0 + r.x1) / 2 + i, z: (r.z0 + r.z1) / 2, facing: 0, moving: false, hpFrac: 1, level: 20 }; };
  host.s.emit('player:move', spot(sc.players[0], 0));
  guests.forEach((g, i) => g.s.emit('player:move', spot(sc.players[(i + 1) % sc.players.length], i + 1)));
  await wait(200);
  const recv: { n: number; gaps: number[]; lastAt: number; bytes: number; lat: number[] }[] = guests.map(() => ({ n: 0, gaps: [], lastAt: 0, bytes: 0, lat: [] }));
  const sentAt = new Map<number, number>();
  guests.forEach((g, gi) => g.s.on('world:snapshot', (s: WorldSnapshot) => { const now = performance.now(); const r = recv[gi]; r.n++; if (r.lastAt) r.gaps.push(now - r.lastAt); r.lastAt = now; const t = sentAt.get(s.t); if (t) r.lat.push(now - t); }));
  const up0 = new Map(wire.up), down0 = new Map(wire.down);
  const cpu0 = cpuMs(relay.child.pid!); const w0 = Date.now();
  for (const p of payloads) {
    sentAt.set(p.snap.t, performance.now());
    host.s.volatile.emit('world:snapshot', p.snap);
    await wait(100);
  }
  await wait(300);
  const cpu1 = cpuMs(relay.child.pid!); const wallMs = Date.now() - w0;
  [host.s, ...guests.map((g) => g.s)].forEach((s) => s.disconnect());
  await wait(200);
  const sent = payloads.length;
  const kbps = (m: Map<string, number>, m0: Map<string, number>, tag: string) => +(((m.get(tag) ?? 0) - (m0.get(tag) ?? 0)) / 1024 / (wallMs / 1000)).toFixed(1);
  return {
    scenario: sc.name,
    sim: { enemies: last.enemies.length, thralls: last.thralls.length, corpses: sim.corpses.size, zones: sim.zones.size, enemiesByArea: perArea },
    snapshotBytes: { avg: Math.round(avg(bytes)), p95: Math.round(pct(bytes, 0.95)), max: Math.max(...bytes), fullAvg: Math.round(avg(fullBytes)), fullMax: Math.max(...fullBytes), over96k: bytes.filter((b) => b > 96 * 1024).length, kbPerSecPerGuest: +((avg(bytes) * 10) / 1024).toFixed(1) },
    hostCpuMsPerTick: { makeSnapshot: +avg(makeMs).toFixed(3), stringify: +avg(strMs).toFixed(3), makeMax: +Math.max(...makeMs).toFixed(2) },
    guestCpuMsPerSnapshot: { jsonParse: +avg(parseMs).toFixed(3), applySnapshot: +avg(applyMs).toFixed(3), mirrorUpdate: +avg(updMs).toFixed(3) },
    wireKBperSec: { hostUp: kbps(wire.up, up0, String(base)), guestDown: guests.map((_, i) => kbps(wire.down, down0, String(base + 1 + i))) },
    relay: { cpuPctOfOneCore: +((100 * (cpu1 - cpu0)) / wallMs).toFixed(1), sent, perGuestReceived: recv.map((r) => r.n), receivedPct: recv.map((r) => Math.round((100 * r.n) / sent)), gapMsP95: recv.map((r) => Math.round(pct(r.gaps, 0.95))), gapMsMax: recv.map((r) => Math.round(Math.max(0, ...r.gaps))), latencyMsAvg: recv.map((r) => Math.round(avg(r.lat))) },
  };
}

(async () => {
  const relay = await startRelay();
  await startProxy();
  const results: unknown[] = [];
  try {
    for (const sc of SCENARIOS) { const r = await run(sc, relay); results.push(r); console.log(JSON.stringify(r, null, 1)); }
    const tail = relay.logs.join('').split('\n').filter((l) => l && !l.includes('listening') && !l.includes('DEV_TRUST')).slice(-8);
    console.log('relay log tail:', tail);
    if (process.env.DM_BENCH_JSON) fs.writeFileSync(process.env.DM_BENCH_JSON, JSON.stringify(results, null, 1));
  } finally { relay.child.kill('SIGKILL'); }
  process.exit(0);
})().catch((e) => { console.error('FAIL', e); process.exit(1); });
