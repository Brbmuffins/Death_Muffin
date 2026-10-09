import { describe, expect, it } from 'vitest';
import { Nav } from '../nav';
import { WorldSim } from '../sim/WorldSim';
import { WorldMirror, makeSnapshot } from '../sim/snapshot';
import { mulberry32 } from '../rng';
import type { SimEvent, Thrall } from '../sim/types';
import { BURROW, ENEMIES, TEMPLAR_SHIELD, UNBIND } from '../../../server/rules/content/enemies';
import { AREAS } from '../../../server/rules/content/areas';
import { CODEX_DEAD, DEAD_ORDER } from '../../content/codex';

function world(area: 'graves' | 'nave' | 'sanctum' = 'graves', seed = 5) {
  const nav = new Nav();
  nav.setUnlocked(['chapterhouse', 'graves', 'ossuary', 'nave', 'sanctum']);
  const sim = new WorldSim(nav, mulberry32(seed));
  const r = AREAS[area].rect;
  sim.setPlayer({ id: 'p1', x: (r.x0 + r.x1) / 2, z: (r.z0 + r.z1) / 2, alive: true, area });
  sim.markVisited(area); // no opening wave: each test watches only the bodies it spawns
  return sim;
}
const of = <T extends SimEvent['t']>(ev: SimEvent[], t: T) => ev.filter((e): e is Extract<SimEvent, { t: T }> => e.t === t);
const thrall = (sim: WorldSim, x: number, z: number): Thrall => {
  sim.addCorpse(x, z, 'normal', 'robber', false, 0, 1, sim.players.get('p1')!.area!);
  sim.apply({ t: 'exhume', by: 'p1', x, z, r: 1, kind: 'warrior', cap: 8, hp: 50, damage: 5, attackSpeedMult: 1 });
  sim.step(0.01);
  return [...sim.thralls.values()].at(-1)!;
};

describe('Backlog mobs', () => {
  it('each has a Codex entry and a place in the world', () => {
    const rostered = new Set(Object.values(AREAS).flatMap((a) => a.enemies.map((e) => e.id)));
    for (const id of ['ghoul', 'acolyte', 'templar'] as const) {
      expect(DEAD_ORDER).toContain(id);
      expect(CODEX_DEAD[id].counter.length).toBeGreaterThan(30);
      expect(rostered.has(id)).toBe(true);
    }
  });

  it('a Barrow Ghoul climbs out burrowed and immune, erupts once in its ring, and survives the snapshot', () => {
    const sim = world();
    const p = sim.players.get('p1')!;
    const g = sim.spawnEnemy('ghoul', 'graves', p.x + 7, p.z, false);
    expect(g.state).toBe('burrow');
    sim.apply({ t: 'hit', by: 'p1', ids: [g.id], dmg: 1000 });
    expect(g.hp).toBe(g.maxHp);
    const mirror = new WorldMirror();
    mirror.applySnapshot(makeSnapshot(sim, true));
    expect(mirror.enemies.get(g.id)?.state).toBe('burrow');
    const ev: SimEvent[] = [];
    for (let i = 0; i < 80 && !of(ev, 'erupt').length; i++) ev.push(...sim.step(0.05));
    expect(of(ev, 'telegraph').some((t) => t.id === g.id && t.kind === 'erupt' && t.ms === BURROW.eruptMsGraves)).toBe(true);
    expect(of(ev, 'erupt').length).toBe(1);
    expect(of(ev, 'hurt').filter((h) => h.from === 'erupt').length).toBe(1);
    expect(g.state).not.toBe('burrow');
  });

  it('an eruption misses a player who stepped out of the ring', () => {
    const sim = world('graves', 6);
    const p = sim.players.get('p1')!;
    const g = sim.spawnEnemy('ghoul', 'graves', p.x + 2, p.z, false);
    const ev: SimEvent[] = [];
    for (let i = 0; i < 10 && !of(ev, 'telegraph').length; i++) ev.push(...sim.step(0.05));
    sim.setPlayer({ ...p, x: p.x - BURROW.eruptR - 2 });
    for (let i = 0; i < 40 && !of(ev, 'erupt').length; i++) ev.push(...sim.step(0.05));
    expect(of(ev, 'erupt').length).toBe(1);
    expect(of(ev, 'hurt').filter((h) => h.from === 'erupt').length).toBe(0);
    expect(g).toBeDefined();
  });

  it('a ghoul digs back in once below half health, then never again', () => {
    const sim = world();
    const p = sim.players.get('p1')!;
    const g = sim.spawnEnemy('ghoul', 'graves', p.x + 3, p.z, false, false);
    const hit = (dmg: number) => sim.apply({ t: 'hit', by: 'p1', ids: [g.id], dmg });
    hit(g.maxHp * 0.6);
    expect(g.digPending).toBe(true);
    sim.step(BURROW.digS + 0.05);
    expect(g.state).toBe('burrow');
    g.state = 'move';
    g.hp = g.maxHp * 0.4;
    hit(1);
    expect(g.digPending).toBeFalsy();
  });

  it('a Lich Acolyte unbinds a killed thrall (not a sacrificed one), on a cooldown, and a dead acolyte cancels it', () => {
    const sim = world('nave');
    const p = sim.players.get('p1')!;
    const a = sim.spawnEnemy('acolyte', 'nave', p.x + 3, p.z, false, false);
    const risen = () => [...sim.enemies.values()].filter((e) => e.def === 'risen' && e.unboundBy === a.id).length;
    sim.killThrall(thrall(sim, p.x + 2, p.z), 'sacrificed');
    sim.step(UNBIND.delayS + 0.1);
    expect(risen()).toBe(0);
    sim.killThrall(thrall(sim, p.x + 2, p.z), 'killed');
    sim.killThrall(thrall(sim, p.x + 2, p.z), 'killed'); // on cooldown
    sim.step(UNBIND.delayS + 0.1);
    expect(risen()).toBe(1);
    a.unbindCd = 0;
    sim.killThrall(thrall(sim, p.x + 2, p.z), 'killed');
    sim.apply({ t: 'hit', by: 'p1', ids: [a.id], dmg: 1e6 });
    sim.step(UNBIND.delayS + 0.1);
    expect(risen()).toBe(1);
  });

  it("a Bell Templar's shield blocks directed blows from the front only, and Fracture breaks it", () => {
    const sim = world('sanctum');
    const p = sim.players.get('p1')!;
    const t = sim.spawnEnemy('templar', 'sanctum', p.x, p.z + 3, false, false);
    t.facing = Math.PI; // facing the player (−z)
    const before = t.hp;
    sim.damageEnemy(t, 100, 'p1', { x: p.x, z: p.z });
    expect(before - t.hp).toBeCloseTo(100 * TEMPLAR_SHIELD.passThrough, 3);
    const mid = t.hp;
    sim.damageEnemy(t, 100, 'p1', { x: t.x, z: t.z + 3 }); // from behind
    expect(mid - t.hp).toBeCloseTo(100, 3);
    const z = t.hp;
    sim.damageEnemy(t, 100, 'p1'); // area / DoT: no source, no shield
    expect(z - t.hp).toBeCloseTo(100, 3);
    t.fracture = 1;
    const f = t.hp;
    sim.damageEnemy(t, 100, 'p1', { x: p.x, z: p.z });
    expect(f - t.hp).toBeGreaterThan(100);
    expect(ENEMIES.templar.corpse).toBe('resonant');
  });
});
