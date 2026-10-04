/**
 * Whole-sim scenario fixtures for godot/sim (run: npx vite-node tools/godot/fixtures-sim-run.ts; also run by gen-fixtures.sh).
 * A bot drives the REAL WorldSim (fixed seed, scripted players) for N ticks. Everything the bot did (player bodies, direct calls, intents)
 * is recorded as the scenario's script, and canonical snapshots of the whole world are recorded every `every` ticks. The GDScript sim replays
 * the script and must reproduce the snapshots (tests/sim/scenario_runner.gd). Output: tests/sim/fixtures/scn_<name>.json.
 */
import { mkdirSync, writeFileSync } from 'node:fs';
import { mulberry32 } from '../../src/gameplay/rng';
import { Nav } from '../../src/gameplay/nav';
import { WorldSim } from '../../src/gameplay/sim/WorldSim';
import { AREAS, type AreaId } from '../../src/content/areas';
import { ENEMIES, AFFIX_ORDER, type EnemyId } from '../../src/content/enemies';
import { OMENS } from '../../src/content/omens';
import { WORLD, worldNav, ALL_OPEN, OUT } from './sim-fixture-lib';

mkdirSync(OUT, { recursive: true });

type Body = { id: string; x: number; z: number; alive: boolean; area: AreaId | null; family?: string; level?: number };
type Call = { m: string; a: unknown[] };
type Step = { tick: number; players?: Body[]; calls?: Call[]; intents?: any[] };
type Any = any; // eslint-disable-line @typescript-eslint/no-explicit-any

interface Cfg {
  name: string;
  seed: number;
  nav: 'world' | 'empty';
  unlocked?: AreaId[];
  difficulty?: string;
  waveTier?: number;
  omen?: string;
  vows?: Record<string, number>;
  corpseLifeMult?: number;
  crypts?: boolean;
  cover?: boolean;
  nodes?: boolean;
  players: Body[];
  ticks: number;
  every: number;
  profile: Profile;
  initCalls?: Call[];
  /** Extra per-tick scripted behaviour (depths descend, zoo spawns). */
  hook?: (ctx: Ctx) => void;
}
interface Profile { hit: number; exhume: number; miasma: number; litany: number; detonate: number; sig: number; legend?: Record<string, number>; sigs?: string[]; move: boolean; families?: boolean }
interface Ctx { sim: Any; tick: number; step: Step; players: Body[]; bot: () => number; call: (m: string, ...a: unknown[]) => void }

// --- Canonical snapshot (the same field lists live in tests/sim/scenario_runner.gd) -------------------------------------------------------
type K = 'n' | 's' | 'b' | 'id' | 'v' | 'm' | 'e';
const ENEMY_F: [string, K][] = [['id', 'n'], ['def', 's'], ['area', 's'], ['level', 'n'], ['elite', 'b'], ['x', 'n'], ['z', 'n'], ['facing', 'n'], ['hp', 'n'], ['maxHp', 'n'], ['damage', 'n'], ['speed', 'n'], ['radius', 'n'], ['scale', 'n'], ['state', 's'], ['stateT', 'n'], ['attackCd', 'n'], ['targetPlayer', 's'], ['targetThrall', 'id'], ['aimX', 'n'], ['aimZ', 'n'], ['channelCorpse', 'id'], ['flankSide', 'n'], ['fracture', 'n'], ['fractureT', 'n'], ['withered', 'n'], ['witheredT', 'n'], ['witheredDps', 'n'], ['witheredOwner', 's'], ['contagious', 'b'], ['slowT', 'n'], ['wardSlowT', 'n'], ['lastHitBy', 's'], ['flash', 'n'], ['gait', 'n'], ['moving', 'b'], ['bleedT', 'n'], ['bleedDps', 'n'], ['bleedOwner', 's'], ['chillT', 'n'], ['sanctT', 'n'], ['hexT', 'n'], ['silenceT', 'n'], ['stunT', 'n'], ['rootT', 'n'], ['incenseT', 'n'], ['knellBeats', 'n'], ['knellNext', 'n'], ['knellOwner', 's'], ['knellDamage', 'n'], ['hexOwner', 's'], ['diving', 'b'], ['diveX', 'n'], ['diveZ', 'n'], ['groundT', 'n'], ['hooking', 'b'], ['hookCd', 'n'], ['fleeT', 'n'], ['erupting', 'v'], ['dugIn', 'b'], ['digPending', 'b'], ['burrowLeft', 'v'], ['unbindCd', 'n'], ['unboundBy', 'id'], ['blockFxAt', 'n'], ['auraCd', 'n'], ['affix', 's'], ['affixCd', 'v'], ['tollAt', 'v'], ['markT', 'n'], ['markBonus', 'n'], ['markBy', 's'], ['plagueAt', 'n'], ['extra', 'v']];
const THRALL_F: [string, K][] = [['id', 'n'], ['owner', 's'], ['kind', 's'], ['x', 'n'], ['z', 'n'], ['facing', 'n'], ['hp', 'n'], ['maxHp', 'n'], ['damage', 'n'], ['attackInterval', 'n'], ['range', 'n'], ['speed', 'n'], ['state', 's'], ['stateT', 'n'], ['attackCd', 'n'], ['target', 'id'], ['slot', 'n'], ['bornAt', 'n'], ['empowered', 'b'], ['flash', 'n'], ['gait', 'n'], ['moving', 'b'], ['rallyT', 'n'], ['champion', 'b'], ['echoUntil', 'e'], ['allyHeal', 'n'], ['cursedT', 'n'], ['stallT', 'n'], ['nextPathAt', 'n'], ['detourUntil', 'n'], ['seatX', 'v'], ['seatZ', 'v']];
const CORPSE_F: [string, K][] = [['id', 'n'], ['x', 'n'], ['z', 'n'], ['kind', 's'], ['enemy', 's'], ['elite', 'b'], ['facing', 'n'], ['scale', 'n'], ['area', 's'], ['bornAt', 'n'], ['expiresAt', 'n'], ['ruptureAt', 'm'], ['seedOwner', 's'], ['seedDmg', 'n'], ['seedCap', 'n'], ['seedArmedAt', 'm'], ['seedExpires', 'n'], ['echoOwner', 's']];
const ZONE_F: [string, K][] = [['id', 'n'], ['kind', 's'], ['owner', 's'], ['x', 'n'], ['z', 'n'], ['r', 'n'], ['until', 'n'], ['bornAt', 'n'], ['tick', 'n'], ['dps', 'n'], ['slow', 'n'], ['witheredCap', 'n'], ['bloom', 'b'], ['hostile', 'b'], ['creep', 'n'], ['contagion', 'b'], ['gen', 'm'], ['spreadT', 'm']];

function norm(v: Any, k: K): Any {
  switch (k) {
    case 'n': return typeof v === 'number' ? v : 0;
    case 's': return typeof v === 'string' ? v : '';
    case 'b': return !!v;
    case 'id': return typeof v === 'number' ? v : -1;
    case 'e': return typeof v === 'number' ? v : -1;
    case 'm': return typeof v === 'number' && Number.isFinite(v) ? v : -1;
    default: return v === undefined ? null : v;
  }
}
function pickFields(o: Any, fields: [string, K][]) {
  const out: Any = {};
  for (const [f, k] of fields) {
    let v = o[f];
    if (f === 'extra') v = (o.extra ?? []).map((x: Any) => ({ affix: x.affix, affixCd: x.affixCd ?? null, tollAt: x.tollAt ?? null }));
    if (f === 'tollAt') v = o.tollAt ?? null;
    out[f] = norm(v, k);
  }
  return out;
}
const evKey = (ev: Any) => `${ev.t}|${ev.kind ?? ''}|${ev.reason ?? ''}|${ev.from ?? ''}|${ev.id ?? ev.corpse?.id ?? ev.zone?.id ?? ev.corpseId ?? ''}|${ev.player ?? ''}`;

function snapshot(sim: Any, rngCalls: number, evs: string[]) {
  const sorted = <T extends { id: number }>(a: T[]) => [...a].sort((x, y) => x.id - y.id);
  const run = sim.depths;
  return {
    time: sim.time, nextId: sim.nextId, rngCalls, surgeIn: sim.surgeIn,
    enemies: sorted([...sim.enemies.values()] as Any[]).map((e) => pickFields(e, ENEMY_F)),
    thralls: sorted([...sim.thralls.values()] as Any[]).map((t) => ({ ...pickFields(t, THRALL_F), detourN: t.detour?.length ?? 0 })),
    corpses: sorted([...sim.corpses.values()] as Any[]).map((c) => pickFields(c, CORPSE_F)),
    zones: sorted([...sim.zones.values()] as Any[]).map((z) => pickFields(z, ZONE_F)),
    walls: sorted([...sim.walls.values()] as Any[]).map((w) => ({ id: w.id, owner: w.owner, x0: w.x0, z0: w.z0, x1: w.x1, z1: w.z1, until: w.until })),
    brands: [...sim.brands.entries()].map(([id, b]: Any) => ({ id, owner: b.owner, x: b.x, z: b.z, area: b.area, until: b.until })),
    surge: sim.surge ? { area: sim.surge.area, x: sim.surge.x, z: sim.surge.z, wavesSpawned: sim.surge.wavesSpawned, spawned: sim.surge.spawned, killed: sim.surge.killed, ids: sim.surge.ids.size } : null,
    waveTimers: [...sim.waveTimers.entries()].sort(([a]: Any, [b]: Any) => (a < b ? -1 : 1)),
    waveCounts: [...sim.waveCounts.entries()].sort(([a]: Any, [b]: Any) => (a < b ? -1 : 1)),
    vacantS: [...sim.vacantS.entries()].sort(([a]: Any, [b]: Any) => (a < b ? -1 : 1)),
    arrivedAt: [...sim.arrivedAt.entries()].sort(([a]: Any, [b]: Any) => (a < b ? -1 : 1)),
    nodes: [...sim.nodes.values()].map((n: Any) => [n.id, n.remaining, n.respawnAt]),
    depths: run ? { depth: run.depth, need: run.need, kills: run.kills, stairOpen: run.stairOpen, floorT: run.floorT, waveT: run.waveT, waved: run.waved, peak: run.peak, floors: run.floors, totalKills: run.totalKills } : null,
    raised: [...sim.raised.entries()].sort(([a]: Any, [b]: Any) => (a < b ? -1 : 1)),
    players: [...sim.players.values()].map((p: Any) => [p.id, p.x, p.z, p.alive, p.area ?? '']),
    bossActive: sim.boss.state.active,
    events: evs,
  };
}

// --- The bot ---------------------------------------------------------------------------------------------------------------------------
const KINDS = ['warrior', 'shieldbearer', 'hound', 'wraith', 'archer', 'bonemage', 'plaguebearer', 'bogus'];
const ALL_SIGS = ['wall', 'rend', 'dirge', 'bloom', 'mantle', 'offering', 'rally', 'seed', 'bash', 'vigil', 'brand', 'lantern_cone', 'chain_pull', 'burn_the_dead', 'watchmans_ward', 'cremate', 'last_light', 'toll', 'resonant_step', 'knell', 'sound_the_corpse', 'great_toll', 'hook_throw', 'harvest', 'crow_swarm', 'hook_pull', 'hex_charm', 'butcher', 'murder_of_crows', 'echo', 'veil_tear', 'crossing', 'lay_to_rest'];

// Debug: SCN=<name[,name]> only runs those scenarios, EVERY=<n> overrides the checkpoint spacing (finer = pinpoints a divergence).
const FROM = Number(process.env.FROM ?? 0), TO = Number(process.env.TO ?? 1e9);
const ONLY = process.env.SCN ? process.env.SCN.split(',') : null;
function runScenario(cfg: Cfg) {
  if (ONLY && !ONLY.includes(cfg.name)) return;
  if (process.env.EVERY) cfg = { ...cfg, every: Number(process.env.EVERY) };
  const bot = mulberry32(cfg.seed ^ 0x5bd1e995);
  const BR = (n: number) => Math.floor(bot() * n);
  const BP = <T,>(a: readonly T[]): T => a[BR(a.length)];
  const BC = (p: number) => bot() < p;
  const BRange = (lo: number, hi: number) => lo + bot() * (hi - lo);
  const nav = cfg.nav === 'world' ? worldNav(cfg.unlocked) : new Nav();
  if (cfg.nav === 'empty' && cfg.unlocked) nav.setUnlocked(cfg.unlocked);
  const simRand = mulberry32(cfg.seed);
  let rngCalls = 0;
  const sim: Any = new WorldSim(nav, () => { rngCalls++; return simRand(); });
  const dt = 0.05;
  const script: Step[] = [];
  const checkpoints: Any[] = [];
  const setup = { seed: cfg.seed, nav: cfg.nav, unlocked: cfg.unlocked ?? null, difficulty: cfg.difficulty ?? 'medium', waveTier: cfg.waveTier ?? 0, omen: cfg.omen ?? null, vows: cfg.vows ?? {}, corpseLifeMult: cfg.corpseLifeMult ?? 1, crypts: !!cfg.crypts, cover: !!cfg.cover, nodes: !!cfg.nodes, dt, every: cfg.every, ticks: cfg.ticks };
  sim.difficulty = setup.difficulty;
  sim.waveTier = setup.waveTier;
  if (cfg.omen) sim.omen = (OMENS as Any)[cfg.omen];
  if (cfg.vows) sim.vows = cfg.vows;
  sim.corpseLifeMult = setup.corpseLifeMult;
  if (cfg.crypts) sim.setCrypts(WORLD.crypts);
  if (cfg.cover) sim.setCover(WORLD.cover);
  if (cfg.nodes) sim.setNodes(WORLD.nodes);
  const players: Body[] = cfg.players.map((p) => ({ ...p }));
  const last = new Map<string, string>();
  const waypoint = new Map<string, { x: number; z: number; pause: number }>();
  let windowEvents: string[] = [];

  const callSim = (m: string, args: unknown[]) => {
    if (m === 'startDepths') return sim.startDepths(...(args as [string, number, number, boolean]));
    if (m === 'descendDepths') return sim.descendDepths();
    if (m === 'endDepths') return sim.endDepths();
    if (m === 'spawnEnemy') return sim.spawnEnemy(...(args as [EnemyId, AreaId, number, number, boolean, boolean, any]));
    if (m === 'startSurge') return sim.startSurge(...(args as [AreaId]));
    if (m === 'clearArea') return sim.clearArea(...(args as [AreaId]));
    if (m === 'markVisited') return sim.markVisited(...(args as [AreaId]));
    if (m === 'removePlayer') return sim.removePlayer(...(args as [string]));
    if (m === 'retagPlayer') return sim.retagPlayer(...(args as [string, string]));
    if (m === 'setUnlocked') return nav.setUnlocked(args[0] as AreaId[]);
    if (m === 'setWaveTier') { sim.waveTier = args[0] as number; return; }
    throw new Error('unknown call ' + m);
  };
  const emitStep = (tick: number, step: Step) => {
    if (step.players?.length || step.calls?.length || step.intents?.length) script.push(step);
  };
  const initStep: Step = { tick: 0, players: players.map((p) => ({ ...p })), calls: [], intents: [] };
  for (const p of players) { sim.setPlayer({ ...p }); last.set(p.id, JSON.stringify(p)); }
  for (const c of cfg.initCalls ?? []) { callSim(c.m, c.a); initStep.calls!.push(c); }

  const nearest = <T extends { x: number; z: number }>(list: T[], x: number, z: number, maxD = Infinity): T | null => {
    let best: T | null = null, bd = maxD;
    for (const o of list) { const d = Math.hypot(o.x - x, o.z - z); if (d < bd) { bd = d; best = o; } }
    return best;
  };

  for (let tick = 0; tick < cfg.ticks; tick++) {
    const step: Step = tick === 0 ? initStep : { tick, players: [], calls: [], intents: [] };
    const intents: Any[] = step.intents!;
    const ctx: Ctx = { sim, tick, step, players, bot, call: (m, ...a) => { callSim(m, a); step.calls!.push({ m, a }); } };
    cfg.hook?.(ctx);
    for (const [pi, p] of players.entries()) {
      if (!p.alive) { if (tick % 400 === 399 + pi) p.alive = true; continue; }
      const prof = cfg.profile;
      // Movement: patrol waypoints inside the player's area (depths: inside the floor's rooms).
      if (prof.move && p.area) {
        const rect = AREAS[p.area].rect;
        let wp = waypoint.get(p.id);
        if (!wp || Math.hypot(wp.x - p.x, wp.z - p.z) < 0.8) {
          if (wp && wp.pause > 0) wp.pause--;
          else {
            const fl = sim.nav.depthsFloor;
            if (p.area === 'depths' && fl) {
              const rm = fl.rooms.filter((r: Any) => r.active);
              const r = BP(rm) as Any;
              waypoint.set(p.id, { x: r.cx + BRange(-3, 3), z: r.cz + BRange(-3, 3), pause: BR(3) });
            } else waypoint.set(p.id, { x: BRange(rect.x0 + 4, rect.x1 - 4), z: BRange(rect.z0 + 4, rect.z1 - 4), pause: BR(3) });
          }
          wp = waypoint.get(p.id);
        }
        if (wp) {
          const d = Math.hypot(wp.x - p.x, wp.z - p.z);
          if (d > 0.01) {
            const s = Math.min(d, 4.6 * dt);
            let nx = p.x + ((wp.x - p.x) / d) * s, nz = p.z + ((wp.z - p.z) / d) * s;
            // keep walking inside the walkable space like a real client would (nav.resolve)
            [nx, nz] = nav.resolve(nx, nz, 0.45);
            p.x = nx; p.z = nz;
          }
        }
      }
      const foes = [...sim.enemies.values()].filter((e: Any) => e.area === p.area && e.state !== 'dead' && e.state !== 'burrow' && e.state !== 'rising');
      const near = nearest(foes, p.x, p.z, 11) as Any;
      const prime = (k: number) => (tick + pi * 3) % k === 0;
      if (near && prime(prof.hit)) {
        const ids = foes.filter((e: Any) => Math.hypot(e.x - near.x, e.z - near.z) < 2.5).slice(0, 1 + BR(3)).map((e: Any) => e.id);
        const dmg = BRange(15, 140);
        const h: Any = { t: 'hit', by: p.id, ids, dmg };
        if (BC(0.2)) h.fracture = 1;
        if (BC(0.15)) h.bleed = dmg * BRange(0.05, 0.3);
        if (BC(0.1)) h.chill = true;
        if (BC(0.1)) { h.root = true; if (BC(0.5)) h.rootS = BP([1.5, 0.5, 0, -1, 4]); }
        if (BC(0.1)) h.slow = true;
        if (BC(0.15)) { h.withered = 1; if (BC(0.6)) h.witheredCap = BP([1, 3, 6, 12, 20, 0]); }
        if (BC(0.1)) h.spear = true;
        intents.push(h);
      }
      const corpses = [...sim.corpses.values()].filter((c: Any) => c.area === p.area);
      const nc = nearest(corpses, p.x, p.z, 8) as Any;
      if (nc && prime(prof.exhume)) {
        const kind = BP(KINDS);
        const x: Any = { t: 'exhume', by: p.id, x: nc.x + BRange(-0.3, 0.3), z: nc.z + BRange(-0.3, 0.3), r: BP([0.8, 3, 0.2, 1.5]), kind, cap: 2 + BR(5), hp: BRange(30, 600), damage: BRange(5, 120), attackSpeedMult: BRange(1, 1.5) };
        if (BC(0.3)) x.count = BP([1, 2, 3, 9, -2, 2.7]);
        if (kind === 'wraith' && BC(0.5)) x.allyHeal = BRange(0, 0.05);
        if (BC(0.12)) { x.colossus = true; x.r = BP([6, 3, 10]); }
        if (BC(0.05)) x.bond = true;
        intents.push(x);
        if (BC(0.2)) intents.push({ t: 'refreshThralls', by: p.id, hpMult: BP([1, 1.1, 2, 0.5, 1.2]), damageMult: BP([1, 1.2, 3]), speedMult: BP([1, 1.05]) });
      }
      if (near && prime(prof.miasma)) {
        const m: Any = { t: 'miasma', by: p.id, x: near.x, z: near.z, r: BRange(2.5, 5), dps: BRange(5, 40), durationMs: BP([6000, 4000, 8000]), witheredCap: BP([5, 8, 12]), bloom: BC(0.3) };
        if (BC(0.25)) m.creep = BP([1.5, 0.5, 5, 0]);
        if (BC(0.25)) m.contagion = true;
        intents.push(m);
      }
      if (prime(prof.litany)) intents.push({ t: 'litany', by: p.id, x: p.x + BRange(-2, 2), z: p.z + BRange(-2, 2), r: BP([7, 10, 3]), spellPower: BRange(5, 60), leaveCorpses: BC(0.5), ...(BC(0.2) ? { spare: true } : {}), ...(BC(0.25) ? { delayMs: BP([2000, 500, 5000]) } : {}) });
      if (nc && prime(prof.detonate)) intents.push({ t: 'detonate', by: p.id, corpseId: nc.id, dmg: BP([BRange(10, 600), 5e5, -4]) });
      if (prime(prof.sig)) {
        const sig = BP(prof.sigs ?? ALL_SIGS);
        const tx = near ? near.x : p.x + BRange(-6, 6), tz = near ? near.z : p.z + BRange(-6, 6);
        const s: Any = { t: 'signature', by: p.id, sig, x: nc && BC(0.4) ? nc.x : tx, z: nc && BC(0.4) ? nc.z : tz, dx: BRange(-1, 1), dz: BRange(-1, 1), sp: BRange(10, 200) };
        // A wall cast exactly through a body is a degenerate case (which side it is pushed to is decided by a ~1e-18 sign): offset the aim.
        if (sig === 'wall') { s.x += BRange(-3, 3); s.z += BRange(-3, 3); }
        if (sig === 'seed') s.cap = BP([6, 12, 0, 40]);
        if (sig === 'rally') s.dur = BP([6, 8, 20, 1]);
        if (sig === 'toll') s.dur = BP([0, 1]);
        intents.push(s);
      }
      if (prof.legend && tick % 400 === pi * 7) intents.push({ t: 'legend', by: p.id, mods: { ...prof.legend } });
      if (BC(0.002)) intents.push({ t: 'recallThralls', by: p.id, x: p.x, z: p.z });
      if (cfg.nodes && p.area === 'acre' && prime(40)) {
        const n = nearest([...sim.nodes.values()].filter((o: Any) => o.remaining > 0 && o.area === 'acre'), p.x, p.z);
        if (n) { p.x = (n as Any).x + 0.5; p.z = (n as Any).z; intents.push({ t: 'gather', by: p.id, nodeId: (n as Any).id, successes: BP([1, 2, 3, 7, 0]) }); }
      }
      if (prof.families && BC(0.0)) intents.push({});
    }
    // Record changed bodies (positions after the bot moved them).
    for (const p of players) {
      const s = JSON.stringify(p);
      if (last.get(p.id) !== s) { step.players!.push({ ...p }); last.set(p.id, s); }
    }
    for (const b of step.players!) sim.setPlayer({ ...b });
    for (const i of intents) sim.apply(i);
    emitStep(tick, step);
    const evs = sim.step(dt);
    for (const ev of evs) { windowEvents.push(evKey(ev)); if (process.env.PRINTEV && ev.t === process.env.PRINTEV && tick + 1 >= FROM && tick + 1 <= TO) console.log('EV', tick + 1, JSON.stringify(ev)); }
    if ((tick + 1) % cfg.every === 0 && tick + 1 >= FROM && tick + 1 <= TO) {
      checkpoints.push({ tick: tick + 1, snap: snapshot(sim, rngCalls, windowEvents) });
      windowEvents = [];
    }
  }
  const fx = { scenario: cfg.name, setup, script: [initStep, ...script.filter((s) => s !== initStep)], checkpoints };
  writeFileSync(`${OUT}/scn_${cfg.name}.json`, JSON.stringify(fx) + '\n');
  const last_ = checkpoints[checkpoints.length - 1].snap;
  console.log(`scn_${cfg.name}: ${cfg.ticks} ticks, ${checkpoints.length} checkpoints, ${last_.enemies.length} enemies, ${last_.thralls.length} thralls, ${last_.corpses.length} corpses, rngCalls ${rngCalls}`);
}

// --- Scenarios --------------------------------------------------------------------------------------------------------------------------
const P = (id: string, x: number, z: number, area: AreaId, level = 5, family?: string): Body => ({ id, x, z, alive: true, area, level, ...(family ? { family } : {}) });
const FIGHT: Profile = { hit: 6, exhume: 37, miasma: 83, litany: 131, detonate: 61, sig: 29, move: true };
const LEGEND = { thrallDeathBurst: 0.5, championEvery: 3, spearRally: 1, miasmaSpreadsWithered: 1, witheredBurstAt: 4 };

runScenario({ name: 'graves_basic', seed: 101, nav: 'world', players: [P('p1', 0, -10, 'graves')], ticks: 2600, every: 50, profile: { ...FIGHT, sigs: ['wall', 'rend', 'dirge', 'bloom', 'mantle', 'offering', 'rally', 'seed'] }, crypts: true });
runScenario({ name: 'graves_empty_nav', seed: 102, nav: 'empty', players: [P('p1', 0, -10, 'graves'), P('p2', 8, -20, 'graves', 12)], ticks: 1800, every: 50, profile: FIGHT });
runScenario({ name: 'ossuary_party', seed: 103, nav: 'world', unlocked: ALL_OPEN, difficulty: 'hard', waveTier: 5, omen: 'tolling', vows: { elder_dead: 2, iron_dead: 1, swollen_waves: 1, deacon_host: 1, elite_surge: 1, thin_graves: 1 }, corpseLifeMult: 1.3,
  players: [P('p1', 48, -20, 'ossuary', 14), P('p2', 40, -10, 'ossuary', 20), P('p3', -50, -30, 'warren', 9)], ticks: 2200, every: 50, profile: FIGHT, crypts: true });
runScenario({ name: 'legion_legends', seed: 104, nav: 'world', unlocked: ALL_OPEN, waveTier: 8, players: [P('p1', 0, -10, 'graves', 30)], ticks: 2400, every: 50,
  profile: { hit: 5, exhume: 17, miasma: 60, litany: 211, detonate: 91, sig: 23, move: true, legend: LEGEND, sigs: ['rally', 'rend', 'dirge', 'bloom', 'seed', 'mantle', 'vigil', 'brand', 'offering', 'wall', 'bash'] }, crypts: true });
runScenario({ name: 'new_blood', seed: 105, nav: 'world', unlocked: ALL_OPEN, waveTier: 3,
  players: [P('k1', 0, -10, 'graves', 10, 'knight'), P('w1', 6, -14, 'graves', 10, 'warden'), P('m1', -6, -14, 'graves', 10, 'monk'), P('c1', 10, -8, 'graves', 10, 'witch'), P('v1', -10, -8, 'graves', 10, 'veil')],
  ticks: 2000, every: 50, profile: { hit: 7, exhume: 41, miasma: 97, litany: 151, detonate: 71, sig: 9, move: true, sigs: ALL_SIGS.slice(11), families: true } });
for (const area of ['warren', 'ossuary', 'nave', 'coliseum', 'sanctum', 'cloister', 'pyre', 'fen'] as AreaId[]) {
  const r = AREAS[area].rect;
  runScenario({ name: `area_${area}`, seed: 200 + area.length, nav: 'world', unlocked: ALL_OPEN, waveTier: 4, players: [P('p1', (r.x0 + r.x1) / 2, (r.z0 + r.z1) / 2, area, 25), P('p2', (r.x0 + r.x1) / 2 + 5, (r.z0 + r.z1) / 2 + 3, area, 25)],
    ticks: 1800, every: 50, profile: { ...FIGHT, hit: 4, exhume: 23 }, crypts: true, cover: true });
}
// The zoo: one of every enemy (plain and elite with each affix) around two players, thralls to fight them.
{
  const calls: Call[] = [];
  const zooAreas: Record<string, AreaId> = { robber: 'graves', hound: 'graves', penitent: 'graves', sac: 'graves', deacon: 'ossuary', risen: 'graves', censer: 'nave', wraith: 'nave', rat: 'warren', golem: 'ossuary', gargoyle: 'nave', moth: 'graves', bat: 'graves', seraph: 'sanctum', ghoul: 'graves', acolyte: 'nave', templar: 'nave', niche: 'nave', plague_doctor: 'cloister', flagellant: 'cloister', cinder_husk: 'pyre', pyre_priest: 'pyre', cinderhound: 'pyre', slag_brute: 'pyre', bog_hag: 'fen', mire_leech: 'fen', fen_wisp: 'fen', drowned_sexton: 'fen' };
  const centers: Record<string, [number, number]> = { graves: [0, -14], ossuary: [48, -20], nave: [0, -70], sanctum: [0, -116], cloister: [44, -116], pyre: [90, -116], fen: [-41, -80], warren: [-52, -30] };
  for (const [id, area] of Object.entries(zooAreas)) {
    const [cx, cz] = centers[area];
    for (let k = 0; k < 3; k++) calls.push({ m: 'spawnEnemy', a: [id, area, cx + 6 + k * 1.3, cz + (k - 1) * 2, k === 2, false, k === 2 ? AFFIX_ORDER[(Object.keys(zooAreas).indexOf(id)) % AFFIX_ORDER.length] : undefined] });
  }
  const players = Object.entries(centers).filter(([a]) => a !== 'warren').map(([a, c], i) => P(`z${i}`, c[0], c[1], a as AreaId, 30));
  runScenario({ name: 'zoo', seed: 301, nav: 'world', unlocked: ALL_OPEN, players, ticks: 1500, every: 50, profile: { ...FIGHT, exhume: 19, hit: 4, move: false }, initCalls: calls, crypts: true });
}
// Catacomb Depths: a run of two floors, descending when the stair opens.
runScenario({ name: 'depths', seed: 401, nav: 'world', unlocked: ALL_OPEN, waveTier: 2, players: [P('p1', 170, -30, 'depths', 20)], ticks: 2600, every: 50, profile: { ...FIGHT, hit: 4, exhume: 29, sig: 37, sigs: ['wall', 'rend', 'dirge', 'bloom', 'seed', 'mantle', 'rally'] },
  initCalls: [{ m: 'startDepths', a: ['p1', 987654, 4, false] }],
  hook: (ctx) => {
    const run = ctx.sim.depths;
    const p = ctx.players[0];
    if (ctx.tick === 0 || !run) return;
    if (ctx.tick === 1) { const f = ctx.sim.nav.depthsFloor; p.x = f.start.x; p.z = f.start.z; ctx.step.players!.push({ ...p }); }
    if (run.stairOpen && ctx.tick % 80 === 0 && run.floors < 3) {
      ctx.call('descendDepths');
      const f = ctx.sim.nav.depthsFloor; p.x = f.start.x; p.z = f.start.z; ctx.step.players!.push({ ...p });
    }
  } });
// Direct calls: surges forced, area clear, wave tier changes, retag/remove players, gathering nodes in the Acre.
runScenario({ name: 'misc_calls', seed: 501, nav: 'world', unlocked: ALL_OPEN, players: [P('p1', 0, -10, 'graves', 8), P('p2', -40, 22, 'acre', 8), P('p3', 48, -20, 'ossuary', 15)], ticks: 1800, every: 50, nodes: true, crypts: true,
  profile: { ...FIGHT, hit: 5, exhume: 31 },
  hook: (ctx) => {
    if (ctx.tick === 300) ctx.call('startSurge', 'graves');
    if (ctx.tick === 700) ctx.call('setWaveTier', 6);
    if (ctx.tick === 900) ctx.call('clearArea', 'ossuary');
    if (ctx.tick === 1100) { ctx.call('retagPlayer', 'p3', 'p3b'); ctx.players[2].id = 'p3b'; }
    if (ctx.tick === 1400) { ctx.call('removePlayer', 'p1'); ctx.players.splice(0, 1); }
    if (ctx.tick === 1500) ctx.call('startSurge', 'ossuary');
  } });
