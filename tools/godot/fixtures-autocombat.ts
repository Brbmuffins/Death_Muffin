/**
 * Golden fixtures for godot/game/dm_auto_combat.gd, dm_auto_dodge.gd, dm_boss_telegraphs.gd
 * (run: npx vite-node tools/godot/fixtures-autocombat.ts; also run by gen-fixtures.sh). Everything comes from the REAL TS modules
 * (src/gameplay/autoCombat.ts, autoDodge.ts). Output: godot/tests/game/fixtures/*.json, { fn, cases: [{ in, out }] }.
 * Infinity (hazard `until`) is JSON null; Godot's test maps it back.
 */
import { mkdirSync, writeFileSync } from 'node:fs';
import { exactStringify } from './exact-json';
import { mulberry32 } from '../../src/gameplay/rng';
import { ABILITIES } from '../../src/content/abilities';
import { AREAS, AREA_ORDER } from '../../src/content/areas';
import { selectAutoCombatAction, selectAutoCombatMovement } from '../../src/gameplay/autoCombat';
import { BossTelegraphs, dodgeStep, inHazard, nearestSafePoint, poolHazard, stepIntoHazard, type Hazard } from '../../src/gameplay/autoDodge';
import { worldNav, ALL_OPEN } from './sim-fixture-lib';

const OUT = 'godot/tests/game/fixtures';
mkdirSync(OUT, { recursive: true });
const counts: Record<string, number> = {};
const w = (fn: string, cases: { in: unknown; out: unknown }[]) => {
  writeFileSync(`${OUT}/${fn}.json`, exactStringify({ fn, cases }) + '\n');
  counts[fn] = cases.length;
};
const J = <T>(x: T): T => JSON.parse(JSON.stringify(x));

const rand = mulberry32(20261104);
const R = (n: number) => Math.floor(rand() * n);
const pick = <T>(a: readonly T[]): T => a[R(a.length)];
const chance = (p: number) => rand() < p;
const between = (lo: number, hi: number) => lo + rand() * (hi - lo);
/** Short decimals (<= 12 significant digits) so the JSON inputs parse exactly in Godot. */
const q = (x: number, d = 2) => Math.round(x * 10 ** d) / 10 ** d;

const AREAS_PLAY = AREA_ORDER.filter((a) => a !== 'depths');
const NAVS = [worldNav(), worldNav(ALL_OPEN), worldNav(['ossuary', 'nave'])];
const ABILITY_IDS = Object.keys(ABILITIES);
const FAMILIES = ['necromancer', 'necromancer', 'necromancer', 'necromancer', 'warden', 'monk', 'witch', 'veil', 'knight'];
const STATES = ['move', 'move', 'move', 'windup', 'channel', 'recover', 'rising', 'burrow', 'dead'];
const PRIMARIES = ['bone_needle', 'bone_needle', 'bone_fan', 'rot_lance', 'flail_swing', 'spirit_bolt', 'palm_strike', 'hollow_cut'].filter((id) => ABILITIES[id as keyof typeof ABILITIES]);
const SIGS = ['command_rend', 'plague_bloom', 'ossuary_wall', 'dirge'];

type Pt = { x: number; z: number };
const inRect = (a: string, margin = 3): Pt => {
  const r = AREAS[a as keyof typeof AREAS].rect;
  return { x: q(between(r.x0 + margin, r.x1 - margin)), z: q(between(r.z0 + margin, r.z1 - margin)) };
};
const around = (c: Pt, lo: number, hi: number): Pt => {
  const a = rand() * Math.PI * 2, d = between(lo, hi);
  return { x: q(c.x + Math.sin(a) * d), z: q(c.z + Math.cos(a) * d) };
};

let nextId = 1;
function mkEnemy(c: Pt, area: string | undefined, spread: [number, number]) {
  const pos = around(c, spread[0], spread[1]);
  const maxHp = pick([20, 40, 100, 300]);
  const e: any = { id: nextId++, x: pos.x, z: pos.z, hp: chance(0.95) ? q(maxHp * between(0.1, 1)) : 0, maxHp, state: pick(STATES), radius: pick([0.4, 0.5, 0.5, 0.7, 1]), elite: chance(0.18) };
  if (area) e.area = chance(0.9) ? area : pick(AREAS_PLAY);
  if (chance(0.08)) e.hexOwner = 'p1';
  return e;
}
function mkCorpse(c: Pt, area: string | undefined, selfId: string) {
  const pos = around(c, 0.3, 11);
  const cp: any = { id: nextId++, x: pos.x, z: pos.z, kind: pick(['normal', 'normal', 'normal', 'resonant', 'swift', 'toxic', 'none']) };
  if (area && chance(0.8)) cp.area = chance(0.9) ? area : pick(AREAS_PLAY);
  if (chance(0.12)) cp.seedOwner = chance(0.5) ? selfId : 'other';
  if (chance(0.12)) cp.echoOwner = pick(['*', selfId, 'other']);
  return cp;
}

// ---------------------------------------------------------------------------------------------------------------------
// A. selectAutoCombatAction
// ---------------------------------------------------------------------------------------------------------------------
{
  const cases: { in: unknown; out: unknown }[] = [];
  const seen: Record<string, number> = {};
  for (let i = 0; i < 900; i++) {
    const necro = i >= 520; // second batch: dense necromancer fights with most of the kit ready, to reach the late branches
    const area = chance(0.8) ? pick(AREAS_PLAY) : undefined;
    const pos = area ? inRect(area) : { x: q(between(-30, 30)), z: q(between(-30, 30)) };
    const maxEssence = necro ? 100 : pick([60, 100, 100, 140]);
    const player: any = { x: pos.x, z: pos.z, essence: q(maxEssence * (necro ? between(0.6, 1) : pick([0.05, 0.2, 0.3, 0.5, 0.7, 0.95, 1, rand()]))), maxEssence };
    if (area) player.area = area;
    if (chance(0.7)) { player.maxHp = pick([80, 120, 200]); player.hp = q(player.maxHp * pick([0.2, 0.3, 0.5, 0.65, 0.8, 1, rand()])); }
    if (chance(0.25)) player.veilForm = true;
    if (chance(0.3)) player.betweenUntil = q(between(0, 5000), 0);
    if (chance(0.3)) player.bulwarkUntil = q(between(0, 5000), 0);
    if (chance(0.3)) player.unbreakableUntil = q(between(0, 5000), 0);
    const family = necro ? 'necromancer' : pick(FAMILIES);
    const selfId = 'p1';
    const nE = necro ? 3 + R(12) : pick([0, 1, 1, 2, 3, 4, 6, 8, 12, 16]);
    const enemies: any[] = [];
    const clusterAt = around(pos, 1, 9);
    for (let k = 0; k < nE; k++) enemies.push(necro ? mkEnemy(chance(0.8) ? clusterAt : pos, area, [0.3, 3.2]) : mkEnemy(chance(0.65) ? clusterAt : pos, area, chance(0.5) ? [0.5, 3] : [1, 15]));
    const nC = necro ? pick([0, 0, 0, 1, 3, 6]) : pick([0, 0, 1, 2, 3, 5, 8]);
    const corpses: any[] = [];
    for (let k = 0; k < nC; k++) corpses.push(mkCorpse(chance(0.5) ? clusterAt : pos, area, selfId));
    const boss: any = chance(0.22)
      ? { active: true, ...around(pos, 2, 16), hp: pick([0, 500, 4000]), state: pick(['idle', 'move', 'slam', 'dead']) }
      : { active: false, x: 0, z: 0, hp: 100, state: 'idle' };
    const pReady = necro ? pick([0.4, 0.6, 0.8]) : pick([0.5, 0.85, 1, 1]);
    const ready = ABILITY_IDS.filter(() => chance(pReady));
    const input: any = { player, enemies, corpses, boss, thrallCount: necro && chance(0.6) ? 6 : R(7), thrallCap: necro ? 6 : pick([4, 6, 8]), ready, selfId, now: q(between(0, 8000), 0) };
    if (family !== 'necromancer' || chance(0.5)) input.family = family;
    if (necro && player.hp !== undefined) player.hp = q(player.maxHp * pick([0.3, 0.8, 1]));
    if (chance(0.5)) input.primary = pick(PRIMARIES);
    if (chance(0.25)) input.primaryRange = pick([2.5, 3, 5, 8, 11, 14]);
    if (chance(0.5)) input.signature = pick(SIGS);
    const ready_ = new Set(ready);
    const res = selectAutoCombatAction({ ...input, ready: (id: string) => ready_.has(id) } as any);
    const k = res ? res.id : 'null';
    seen[k] = (seen[k] ?? 0) + 1;
    cases.push({ in: input, out: J(res) });
  }
  w('auto_action', cases);
  console.log('actions:', JSON.stringify(seen));
}

// ---------------------------------------------------------------------------------------------------------------------
// shared hazard generator
// ---------------------------------------------------------------------------------------------------------------------
function randHazard(c: Pt): Hazard {
  const at = around(c, 0, 5);
  const until = chance(0.5) ? Infinity : q(between(0, 6000), 0);
  switch (R(5)) {
    case 0: return { k: 'circle', x: at.x, z: at.z, r: q(between(1.2, 4.5)), until };
    case 1: return { k: 'cone', x: at.x, z: at.z, dir: q(between(-3.14, 3.14), 3), r: q(between(3, 9)), half: q(between(0.5, 1.2), 3), until, src: 'c', dir0: 1 };
    case 2: return { k: 'seg', x: at.x, z: at.z, dir: q(between(-3.14, 3.14), 3), len: q(between(5, 11)), hw: q(between(0.6, 1)), until };
    case 3: return { k: 'rect', x: at.x, z: at.z, hw: q(between(0.8, 2.5)), hd: q(between(0.8, 2.5)), until };
    default: return { k: 'except', x: at.x, z: at.z, r: q(between(8, 14)), spots: Array.from({ length: R(4) + 1 }, () => { const s = around(at, 0, 9); return [s.x, s.z] as [number, number]; }), safeR: q(between(1.5, 3)), until };
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// B. selectAutoCombatMovement (multi-step with memory)
// ---------------------------------------------------------------------------------------------------------------------
{
  const cases: { in: unknown; out: unknown }[] = [];
  let dirs = 0, nulls = 0, dodged = 0, routed = 0;
  for (let i = 0; i < 170; i++) {
    const area = chance(0.92) ? pick(AREAS_PLAY) : undefined;
    let pos = area ? inRect(area, chance(0.2) ? 1.2 : 4) : { x: q(between(-30, 30)), z: q(between(-30, 30)) };
    const ni = R(NAVS.length);
    const useNav = chance(0.7);
    const useMem = chance(0.85);
    const family = chance(0.2) ? pick(FAMILIES) : undefined;
    const primary = chance(0.4) ? pick(PRIMARIES) : undefined;
    const primaryRange = chance(0.2) ? pick([2.5, 3, 7, 11, 14]) : undefined;
    const maxHp = pick([80, 120]);
    const baseP: any = { essence: 50, maxEssence: 100 };
    if (area) baseP.area = area;
    if (chance(0.6)) { baseP.maxHp = maxHp; baseP.hp = q(maxHp * pick([0.2, 0.3, 0.6, 1])); }
    const nE = pick([1, 1, 2, 3, 4, 6, 8]);
    const enemies: any[] = [];
    for (let k = 0; k < nE; k++) {
      const e = mkEnemy(pos, area, chance(0.6) ? [1.5, 8] : [5, 26]);
      if (chance(0.8)) e.state = pick(['move', 'move', 'windup', 'channel']);
      if (e.hp <= 0) e.hp = 10;
      if (area && chance(0.97)) e.area = area;
      enemies.push(e);
    }
    const hazards0: Hazard[] = chance(0.5) ? Array.from({ length: 1 + R(3) }, () => randHazard(pos)) : [];
    const hasHazardKey = hazards0.length > 0 || chance(0.1);
    const nSteps = 4 + R(14);
    const dtBase = pick([1 / 60, 1 / 30, 0.05, 0.1, 0.016]);
    const mem: any = useMem ? (chance(0.15) ? { targetId: enemies[0].id, closing: chance(0.5) } : {}) : undefined;
    const memInit = mem ? J(mem) : null;
    const steps: any[] = [];
    let now = q(between(0, 3000), 0);
    const nav = useNav ? NAVS[ni] : undefined;
    for (let s = 0; s < nSteps; s++) {
      const player = { ...baseP, x: pos.x, z: pos.z };
      const dt = useMem ? (chance(0.1) ? 0 : dtBase * (chance(0.2) ? 3 : 1)) : 0;
      const hazards = hasHazardKey ? (s > 2 && chance(0.2) ? [...hazards0, randHazard(pos)] : hazards0) : undefined;
      const inp = { player, enemies: J(enemies), primary, primaryRange, family, ...(hazards ? { hazards } : {}) };
      const out = selectAutoCombatMovement({ ...inp, nav } as any, mem, now, dt);
      steps.push({ player, enemies: J(enemies), ...(hazards ? { hazards: J(hazards) } : {}), now, dt, out: J(out), mem: mem ? J(mem) : null });
      if (out) dirs++; else nulls++;
      if (mem?.dodge?.goal) dodged++;
      if (mem?.route?.length) routed++;
      // advance the world
      if (out) pos = { x: q(pos.x + out.x * 5.5 * (dt || 1 / 60)), z: q(pos.z + out.z * 5.5 * (dt || 1 / 60)) };
      for (const e of enemies) {
        const dx = pos.x - e.x, dz = pos.z - e.z, d = Math.hypot(dx, dz) || 1;
        if (e.state === 'move' && d > 1.2) { e.x = q(e.x + (dx / d) * 3 * (dt || 1 / 60), 3); e.z = q(e.z + (dz / d) * 3 * (dt || 1 / 60), 3); }
        if (chance(0.05)) e.state = pick(STATES);
        if (chance(0.02)) e.hp = 0;
      }
      now = q(now + (dt || 1 / 60) * 1000 * (chance(0.05) ? 20 : 1), 3);
    }
    cases.push({ in: { ni: useNav ? ni : -1, useMem, memInit, primary, primaryRange, family, steps }, out: null });
  }
  w('auto_movement', cases);
  console.log('movement steps: dir', dirs, 'null', nulls, 'dodge-goal steps', dodged, 'route steps', routed);
}

// ---------------------------------------------------------------------------------------------------------------------
// C. BossTelegraphs + hazardsFromBossEvent
// ---------------------------------------------------------------------------------------------------------------------
{
  const cases: { in: unknown; out: unknown }[] = [];
  const BOSS_KINDS: [string, string | undefined][] = [
    ['toll', 'prelate'], ['slam', 'prelate'], ['rain', 'prelate'], ['sweep', 'gravedigger'], ['bury', 'gravedigger'], ['pits', 'gravedigger'], ['lance', 'abbess'],
    ['chorus', 'abbess'], ['grasp', 'abbess'], ['grasp', 'congregation'], ['hymn', 'congregation'], ['maul', 'congregation'], ['maul', 'mire'], ['rotRain', 'saint'],
    ['swing', 'saint'], ['coals', 'regent'], ['cleave', 'regent'], ['conflagration', 'regent'], ['surface', 'mire'], ['hands', 'mire'], ['summon', 'prelate'],
    ['link', 'saint'], ['communion', 'abbess'], ['rite', 'mire'], ['toll', undefined], ['maul', undefined],
  ];
  let total = 0;
  for (let i = 0; i < 90; i++) {
    const bt = new BossTelegraphs();
    const ops: any[] = [];
    const evs: any[] = [];
    let now = q(between(0, 2000), 0);
    const nOps = 6 + R(24);
    for (let k = 0; k < nOps; k++) {
      const r = rand();
      if (r < 0.45 || evs.length === 0) {
        const [kind, boss] = pick(BOSS_KINDS);
        const ev: any = { t: 'boss', kind, x: q(between(-20, 20)), z: q(between(-20, 20)), phase: 1 + R(3) };
        if (boss) ev.boss = boss;
        if (chance(0.9)) ev.ms = pick([700, 900, 1200, 1400, 2200, 2700]);
        if (chance(0.7)) ev.r = q(between(1.5, 5));
        if (chance(0.7)) ev.dir = q(between(-3.14, 6.3), 3);
        if (['rain', 'rotRain', 'coals', 'hands', 'bury', 'grasp', 'pits', 'conflagration'].includes(kind) || chance(0.1)) ev.targets = Array.from({ length: 1 + R(5) }, () => [q(between(-20, 20)), q(between(-20, 20))]);
        evs.push(ev);
        ops.push({ op: 'event', ev, now });
        bt.onEvent(ev, now);
      } else if (r < 0.7) {
        const prev = pick(evs);
        const ev = { ...prev };
        delete ev.ms;
        if (chance(0.15)) ev.dir = q((ev.dir ?? 0) + between(-1, 1), 3);
        if (chance(0.1)) delete ev.dir;
        ops.push({ op: 'event', ev, now });
        bt.onEvent(ev, now);
      } else if (r < 0.75) {
        const ev: any = { t: 'boss', kind: pick(['defeated', 'awaken']), x: 0, z: 0, phase: 1 };
        ops.push({ op: 'event', ev, now });
        bt.onEvent(ev, now);
      } else if (r < 0.78) {
        ops.push({ op: 'clear', now });
        bt.clear();
      } else {
        now = q(now + pick([100, 500, 1500, 3000, 6000]), 0);
        ops.push({ op: 'active', now, out: J(bt.active(now)) });
        continue;
      }
      ops[ops.length - 1].out = J(bt.active(now));
      total++;
      now = q(now + pick([0, 50, 300]), 0);
    }
    cases.push({ in: { ops: ops.map(({ out, ...o }) => o) }, out: ops.map((o) => o.out) });
  }
  w('telegraph', cases);
  console.log('telegraph ops:', total);
}

// ---------------------------------------------------------------------------------------------------------------------
// D. dodge geometry: inHazard, nearestSafePoint, dodgeStep, stepIntoHazard, poolHazard
// ---------------------------------------------------------------------------------------------------------------------
{
  const cases: { in: unknown; out: unknown }[] = [];
  for (let i = 0; i < 140; i++) {
    const area = pick(AREAS_PLAY);
    const rect = AREAS[area as keyof typeof AREAS].rect;
    const p = inRect(area, chance(0.2) ? 1 : 4);
    const hazards = Array.from({ length: 1 + R(4) }, () => randHazard(chance(0.7) ? p : inRect(area)));
    const useNav = chance(0.5), ni = R(NAVS.length), useRect = chance(0.8);
    const nav = useNav ? NAVS[ni] : undefined;
    const opts: any = { ...(useRect ? { rect } : {}), ...(nav ? { nav } : {}) };
    const prefer = chance(0.4) ? around(p, 1, 6) : undefined;
    const now = q(between(0, 4000), 0);
    const goal = chance(0.4) ? { ...around(p, 0, 6), until: q(between(0, 6000), 0) } : chance(0.3) ? null : undefined;
    const hasMem = chance(0.8);
    const mem: any = hasMem ? (goal !== undefined ? { goal: J(goal) } : {}) : undefined;
    const memIn = mem ? J(mem) : null;
    const step = dodgeStep(p, hazards, mem, now, opts);
    const dir = { x: q(Math.sin(rand() * 6.28), 3), z: q(Math.cos(rand() * 6.28), 3) };
    const probes: any[] = [];
    for (let k = 0; k < 12; k++) {
      const pt = k < 6 ? around(p, 0, 7) : around(inRect(area, 2), 0, 3);
      const margin = pick([0, 0.25, 0.75, 1.5, 3]);
      probes.push({ x: pt.x, z: pt.z, margin, inside: hazards.map((h) => inHazard(h, pt.x, pt.z, margin)) });
    }
    const len = pick([1.4, 1.4, 3]), margin = pick([0.5, 0.5, 1]);
    cases.push({
      in: { p, hazards, ni: useNav ? ni : -1, useRect, area, prefer, now, mem: memIn, dir, len, margin, probes: probes.map(({ inside, ...pr }) => pr), pool: { x: p.x, z: p.z, r: q(between(1, 5)) }, playerRadius: pick([0.45, 0.5]) },
      out: J({
        probes: probes.map((pr) => pr.inside),
        safe: nearestSafePoint(p, hazards, { ...opts, prefer: prefer ?? null }),
        safeNoPrefer: nearestSafePoint(p, hazards, opts),
        step, mem: mem ?? null,
        stepInto: stepIntoHazard(p, dir, hazards),
        stepInto2: stepIntoHazard(p, dir, hazards, len, margin),
        stepIntoEmpty: stepIntoHazard(p, dir, []),
      }),
    });
  }
  // poolHazard is a pure constructor; one more case each so the runner can compare it
  for (const c of cases as any[]) c.out.pool = J(poolHazard(c.in.pool, c.in.playerRadius));
  w('dodge', cases);
}

// ---------------------------------------------------------------------------------------------------------------------
// E. V8 Math.exp / asin / tan against the engine's (the turn smoothing and cone margins use them)
// ---------------------------------------------------------------------------------------------------------------------
{
  const cases: { in: unknown; out: unknown }[] = [];
  const tanC = Math.tan((35 * Math.PI) / 180);
  for (let i = 0; i < 3000; i++) {
    const dt = pick([1 / 60, 1 / 30, 0.05, 0.1, 0.016, q(between(0.001, 0.5), 5), between(0, 0.4)]);
    const m = rand(), d = between(0.3, 9);
    cases.push({ in: { dt, m, d }, out: { exp: Math.exp(-dt / 0.1), asin: Math.asin(Math.min(1, (m * 3) / d)), asinB: Math.asin(m), tan: tanC } });
  }
  w('math', cases);
}

console.log('autocombat fixtures:', JSON.stringify(counts), 'total', Object.values(counts).reduce((a, b) => a + b, 0));
