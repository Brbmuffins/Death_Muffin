// Seeded fuzz over the sim: intents pass through the relay's own validIntent, then the world is checked for corruption every step.
import { it, expect } from 'vitest';
import { createRequire } from 'node:module';
import { Nav } from '../nav';
import { WorldSim } from '../sim/WorldSim';
import { WorldMirror, makeSnapshot } from '../sim/snapshot';
import { mulberry32 } from '../rng';
import { AREA_ORDER, AREAS } from '../../content/areas';
import { BOSSES as BOSS_DEFS } from '../../content/bosses';
process.env.DEV_TRUST_TOKENS = '1';
const require = createRequire(import.meta.url);
const { validIntent } = require('../../../server/realtime/server.js');

const SIGS = ['wall','rend','dirge','bloom','mantle','offering','rally','seed','bash','vigil','brand','lantern_cone','chain_pull','burn_the_dead','watchmans_ward','cremate','last_light','toll','resonant_step','knell','sound_the_corpse','great_toll','hook_throw','harvest','crow_swarm','hook_pull','hex_charm','butcher','murder_of_crows','echo','veil_tear','crossing','lay_to_rest'];
const BOSSES = ['prelate','gravedigger','abbess','congregation','saint','regent','mire'];

function bad(sim: WorldSim, where: string) {
  const issues: string[] = [];
  const fin = (n: number) => Number.isFinite(n);
  for (const e of sim.enemies.values()) { if (!fin(e.x) || !fin(e.z) || !fin(e.hp)) issues.push(`enemy NaN ${e.def} ${e.x} ${e.z} ${e.hp}`); }
  for (const t of sim.thralls.values()) { if (!fin(t.x) || !fin(t.z) || !fin(t.hp)) issues.push(`thrall NaN ${t.kind}`); if (t.hp > t.maxHp + 1e-6) issues.push(`thrall hp>max ${t.hp} ${t.maxHp}`); if (!sim.players.has(t.owner)) issues.push(`orphan thrall ${t.owner}`); }
  const b = sim.bossState; if (!fin(b.hp) || !fin(b.x) || !fin(b.z)) issues.push('boss NaN'); if (b.hp > b.maxHp + 1e-6) issues.push(`boss hp>max ${b.hp}>${b.maxHp}`);
  if (sim.corpses.size > 46) issues.push(`corpses ${sim.corpses.size}`);
  for (const [id, n] of Object.entries([...sim.thralls.values()].reduce((m: any, t) => ((m[t.owner] = (m[t.owner] ?? 0) + 1), m), {}))) if ((n as number) > 8) issues.push(`thralls ${id} ${n}`);
  if (sim.enemies.size > 90) issues.push(`enemies ${sim.enemies.size}`);
  return issues.length ? `${where}: ${issues.slice(0, 5).join(' | ')}` : null;
}

it('random legal intents never corrupt the world (NaN, hp over max, orphan thralls, runaway counts)', () => {
  const fails: string[] = [];
  for (let seed = 1; seed <= 24 && fails.length < 8; seed++) {
    const rnd = mulberry32(seed * 7919);
    const sim = new WorldSim(new Nav(), mulberry32(seed));
    const ids = ['p1', 'p2'];
    const areaPick = () => AREA_ORDER.filter((a) => !AREAS[a].safe && !AREAS[a].instance);
    let area = areaPick()[Math.floor(rnd() * areaPick().length)];
    const rect = AREAS[area].rect;
    const pos = () => ({ x: rect.x0 + 3 + rnd() * (rect.x1 - rect.x0 - 6), z: rect.z0 + 3 + rnd() * (rect.z1 - rect.z0 - 6) });
    const bodies: Record<string, any> = {};
    for (const id of ids) { bodies[id] = { id, ...pos(), alive: true, area, level: 20 + Math.floor(rnd() * 40) }; sim.setPlayer(bodies[id]); }
    sim.waveTier = Math.floor(rnd() * 8);
    for (let step = 0; step < 1500; step++) {
      for (const id of ids) {
        const b = bodies[id];
        if (rnd() < 0.02) b.alive = !b.alive || rnd() < 0.5 ? true : false;
        if (rnd() < 0.3) { b.x += (rnd() - 0.5); b.z += (rnd() - 0.5); }
        sim.setPlayer(b);
      }
      if (rnd() < 0.25) {
        const by = ids[Math.floor(rnd() * 2)];
        const p = bodies[by];
        const near = [...sim.enemies.values()].filter((e) => Math.hypot(e.x - p.x, e.z - p.z) < 14).map((e) => e.id);
        const corp = [...sim.corpses.values()];
        const c = corp[Math.floor(rnd() * corp.length)];
        const r = rnd();
        let raw: any;
        if (r < 0.2) raw = { t: 'hit', ids: near.slice(0, 20), dmg: rnd() * 400, fracture: rnd() < 0.3 ? 1 : 0, bleed: rnd() < 0.3 ? 50 : undefined, withered: rnd() < 0.3 ? 1 : undefined, root: rnd() < 0.2, slow: rnd() < 0.2, chill: rnd() < 0.2, boss: rnd() < 0.1 };
        else if (r < 0.3) raw = { t: 'exhume', x: c ? c.x : p.x, z: c ? c.z : p.z, r: rnd() < 0.2 ? 6 : 1, kind: ['warrior','shieldbearer','hound','wraith'][Math.floor(rnd()*4)], cap: 2 + Math.floor(rnd() * 6), hp: 60, damage: 8, attackSpeedMult: 1, colossus: rnd() < 0.1, count: rnd() < 0.2 ? 3 : 1 };
        else if (r < 0.4) raw = { t: 'miasma', x: p.x + rnd() * 6, z: p.z + rnd() * 6, r: 3, dps: 30, durationMs: 6000, witheredCap: 5, bloom: rnd() < 0.3, creep: rnd() < 0.2 ? 1 : undefined, contagion: rnd() < 0.2 };
        else if (r < 0.5) raw = { t: 'litany', x: p.x, z: p.z, r: 7, spellPower: 30, leaveCorpses: rnd() < 0.5, spare: rnd() < 0.2, delayMs: rnd() < 0.2 ? 1500 : undefined };
        else if (r < 0.58) raw = { t: 'detonate', corpseId: c ? c.id : 1, dmg: 200 };
        else if (r < 0.9) raw = { t: 'signature', sig: SIGS[Math.floor(rnd() * SIGS.length)], x: p.x + (rnd() - 0.5) * 8, z: p.z + (rnd() - 0.5) * 8, dx: rnd() - 0.5, dz: rnd() - 0.5, sp: 40, dur: 5, cap: 5 };
        else if (r < 0.94) raw = { t: 'summonBoss', boss: BOSSES[Math.floor(rnd() * 7)] };
        else if (r < 0.97) raw = { t: 'recallThralls', x: p.x, z: p.z };
        else raw = { t: 'refreshThralls', hpMult: 1.1, damageMult: 1.1, speedMult: 1.1 };
        const clean = validIntent(raw);
        if (clean) { clean.by = by; sim.apply(clean); }
      }
      let ev;
      try { ev = sim.step(1 / 30); } catch (e: any) { fails.push(`seed ${seed} step ${step} THROW ${e.stack?.split('\n').slice(0,3).join(' <- ')}`); break; }
      if (step % 50 === 0) { const m = new WorldMirror(); m.applySnapshot(JSON.parse(JSON.stringify(makeSnapshot(sim, true)))); m.applyEvents(ev); }
      const issue = bad(sim, `seed ${seed} step ${step}`);
      if (issue) { fails.push(issue); break; }
    }
  }
  expect(fails).toEqual([]);
});
it('every boss survives wipes, deaths and a host migration without throwing or corrupting', () => {
  const fails: string[] = [];
  for (const boss of BOSSES) for (let seed = 1; seed <= 2; seed++) {
    const rnd = mulberry32(seed * 31 + boss.length);
    const B = (BOSS_DEFS as any)[boss];
    let sim = new WorldSim(new Nav(), mulberry32(seed));
    const a = B.arena;
    const area = B.area;
    const bodies: any = { p1: { id: 'p1', x: a.x + 6, z: a.z + 4, alive: true, area, level: 40 }, p2: { id: 'p2', x: a.x - 6, z: a.z + 2, alive: true, area, level: 40 } };
    for (const b of Object.values(bodies)) sim.setPlayer(b as any);
    sim.apply({ t: 'summonBoss', by: 'p1', boss } as any);
    for (let step = 0; step < 2500; step++) {
      for (const id of ['p1', 'p2']) {
        const b = bodies[id];
        b.x = a.x + Math.sin(step / 25 + (id === 'p1' ? 0 : 3)) * (4 + rnd() * 8);
        b.z = a.z + Math.cos(step / 25 + (id === 'p1' ? 0 : 3)) * (4 + rnd() * 8);
        if (rnd() < 0.003) b.alive = !b.alive;
        sim.setPlayer(b);
      }
      if (rnd() < 0.2) sim.apply({ t: 'hit', by: 'p1', ids: [...sim.enemies.keys()].slice(0, 5), dmg: 80 + rnd() * 80, boss: true, fracture: rnd() < 0.2 ? 1 : 0 } as any);
      if (rnd() < 0.05) { const c = [...sim.corpses.values()][0]; if (c) sim.apply({ t: 'exhume', by: 'p1', x: c.x, z: c.z, r: 1, kind: 'warrior', cap: 5, hp: 80, damage: 10, attackSpeedMult: 1 } as any); }
      let ev;
      try { ev = sim.step(1 / 30); } catch (e: any) { fails.push(`${boss} seed ${seed} step ${step} THROW ${e.stack?.split('\n').slice(0, 3).join(' <- ')}`); break; }
      if (step % 700 === 699) {
        // host migration
        const m = new WorldMirror();
        m.applySnapshot(JSON.parse(JSON.stringify(makeSnapshot(sim, true))));
        const ns = new WorldSim(new Nav(), mulberry32(seed + 99));
        m.seed(ns);
        for (const a2 of Object.values(AREAS)) if (!a2.safe) ns.markVisited(a2.id as any);
        sim = ns;
        for (const b of Object.values(bodies)) sim.setPlayer(b as any);
      }
      const issue = bad(sim, `${boss} seed ${seed} step ${step}`);
      if (issue) { fails.push(issue); break; }
    }
  }
  expect(fails).toEqual([]);
});
