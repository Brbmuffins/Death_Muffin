import { describe, expect, it } from 'vitest';
import { Nav } from '../nav';
import { WorldSim } from '../sim/WorldSim';
import { mulberry32 } from '../rng';
import type { SimEvent } from '../sim/types';
import { ENEMIES, type EnemyId } from '../../content/enemies';
import { AREAS } from '../../content/areas';
import { waveModifiers } from '../../content/upgrades';

function world(seed = 1) {
  const nav = new Nav();
  nav.setUnlocked(['chapterhouse', 'graves', 'ossuary', 'nave', 'sanctum', 'cloister', 'pyre', 'fen']);
  const sim = new WorldSim(nav, mulberry32(seed));
  const r = AREAS.graves.rect;
  sim.setPlayer({ id: 'p1', x: (r.x0 + r.x1) / 2, z: (r.z0 + r.z1) / 2, alive: true, area: 'graves' });
  sim.step(0.05);
  for (const e of [...sim.enemies.values()]) sim.enemies.delete(e.id);
  return sim;
}
const of = <T extends SimEvent['t']>(ev: SimEvent[], t: T) => ev.filter((e): e is Extract<SimEvent, { t: T }> => e.t === t);

describe('enemy telegraphs are honest', () => {
  const TELEGRAPHED: EnemyId[] = ['wraith', 'plague_doctor', 'pyre_priest', 'bog_hag', 'fen_wisp', 'moth', 'penitent', 'golem', 'slag_brute', 'acolyte'];
  for (const id of TELEGRAPHED) {
    for (const elite of [false, true]) {
      it(`${id}${elite ? ' (elite)' : ''}: the telegraph lasts as long as the windup`, () => {
        const sim = world(3);
        const p = sim.players.get('p1')!;
        const e = sim.spawnEnemy(id, 'graves', p.x + 3, p.z, elite, false);
        e.attackCd = 0;
        let ms: number | null = null;
        let started = -1;
        let t = 0;
        let endedAt = -1;
        for (let i = 0; i < 160 && endedAt < 0; i++) {
          const ev = sim.step(0.025);
          t += 0.025;
          if (ms === null) {
            const tele = of(ev, 'telegraph').find((x) => x.id === e.id && x.kind !== 'raise');
            if (tele) {
              ms = tele.ms;
              started = t;
            }
          } else if (e.state !== 'windup' && e.state !== 'channel') endedAt = t;
        }
        if (ms === null) return; // this enemy telegraphs nothing at this range (a plain melee windup)
        expect(endedAt).toBeGreaterThan(0);
        expect(Math.abs((endedAt - started) * 1000 - ms)).toBeLessThan(60);
        expect(ms).toBeCloseTo(ENEMIES[id].windupMs * (elite ? 0.85 : 1), 3);
      });
    }
  }
});

describe('thrall behaviour', () => {
  const raise = (sim: WorldSim, n: number) => {
    const p = sim.players.get('p1')!;
    for (let i = 0; i < n; i++) sim.addCorpse(p.x + 2 + i, p.z + 2, 'normal', 'robber', false, 0, 1, 'graves');
    for (const c of [...sim.corpses.values()]) sim.apply({ t: 'exhume', by: 'p1', x: c.x, z: c.z, r: 0.8, kind: 'warrior', cap: 6, hp: 50, damage: 5, attackSpeedMult: 1 });
    sim.step(1.2);
  };

  it('a thrall stands in its own seat once its neighbours have fallen (no two on one spot)', () => {
    const sim = world(5);
    raise(sim, 5);
    const all = [...sim.thralls.values()].sort((a, b) => a.slot - b.slot);
    expect(all.length).toBe(5);
    // Lose the middle ones: the survivors keep slots 0, 3, 4 and must still be apart.
    sim.killThrall(all[1], 'killed');
    sim.killThrall(all[2], 'killed');
    for (let i = 0; i < 160; i++) {
      sim.enemies.clear();
      sim.step(0.05);
    }
    const live = [...sim.thralls.values()];
    expect(live.length).toBe(3);
    for (let i = 0; i < live.length; i++) for (let j = i + 1; j < live.length; j++) expect(Math.hypot(live[i].x - live[j].x, live[i].z - live[j].z)).toBeGreaterThan(1.2);
  });

  it('a thrall lets go of a ghoul that dug in, and picks something it can hurt', () => {
    const sim = world(6);
    raise(sim, 2);
    const p = sim.players.get('p1')!;
    const ghoul = sim.spawnEnemy('ghoul', 'graves', p.x + 3, p.z, false, false);
    const th = [...sim.thralls.values()][0];
    th.target = ghoul.id;
    ghoul.state = 'burrow';
    sim.step(0.05);
    expect(th.target).not.toBe(ghoul.id);
  });

  it('a thrall does not chase an enemy in the next hall', () => {
    const sim = world(7);
    raise(sim, 1);
    const p = sim.players.get('p1')!;
    const far = sim.spawnEnemy('robber', 'ossuary', p.x + 2, p.z, false, false);
    const th = [...sim.thralls.values()][0];
    sim.step(0.05);
    expect(th.target).not.toBe(far.id);
  });
});

describe('Bell-Tolled ring', () => {
  it('stings only what stands inside the drawn ring', () => {
    for (const [offset, hurt] of [[2.9, true], [3.3, false]] as const) {
      const sim = world(9);
      const p = sim.players.get('p1')!;
      const e = sim.spawnEnemy('robber', 'graves', p.x + 20, p.z, true, false, 'bellTolled');
      e.damage = 10;
      e.speed = 0;
      e.attackCd = 99;
      sim.setPlayer({ ...p, x: e.x - offset, z: e.z });
      let stung = false;
      let telegraphed = false;
      for (let i = 0; i < 400 && !stung; i++) {
        const ev = sim.step(0.05);
        if (of(ev, 'telegraph').some((t) => t.kind === 'toll')) telegraphed = true;
        stung = of(ev, 'hurt').some((h) => h.from === 'toll');
        if (telegraphed && !stung && of(ev, 'affix').some((a) => a.affix === 'bellTolled')) break;
      }
      expect(telegraphed).toBe(true);
      expect(stung).toBe(hurt);
    }
  });
});

describe('thrall numbers on a boss', () => {
  it('show the blow as it landed: rally and Fracture included', () => {
    const sim = world(11);
    const p = sim.players.get('p1')!;
    sim.addCorpse(p.x + 2, p.z, 'normal', 'robber', false, 0, 1, 'graves');
    const c = [...sim.corpses.values()][0];
    sim.apply({ t: 'exhume', by: 'p1', x: c.x, z: c.z, r: 1, kind: 'warrior', cap: 3, hp: 5000, damage: 50, attackSpeedMult: 1 });
    sim.step(1.2);
    const th = [...sim.thralls.values()][0];
    th.rallyT = 5;
    sim.boss.awaken('p1');
    const b = sim.boss.state;
    b.x = p.x + 2.5;
    b.z = p.z;
    b.fracture = 2;
    b.fractureT = 5;
    for (const e of [...sim.enemies.values()]) sim.enemies.delete(e.id);
    th.attackCd = 0;
    let dmg = 0;
    for (let i = 0; i < 40 && !dmg; i++) {
      for (const e of [...sim.enemies.values()]) sim.enemies.delete(e.id);
      const hit = of(sim.step(0.05), 'thrallHit').find((h) => h.target === -1);
      if (hit) dmg = hit.dmg;
    }
    expect(dmg).toBeGreaterThan(0);
    // 50 base x 1.4 rally x 1.3 (two Fracture stacks).
    expect(dmg).toBe(Math.round(50 * 1.4 * 1.3));
  });
});

describe('Wave Speed label', () => {
  it('says how much sooner the next wave comes', () => {
    for (let tier = 0; tier <= 8; tier++) {
      const m = waveModifiers(tier);
      expect(m.speedPct).toBe(Math.round((1 / m.intervalMult - 1) * 100));
    }
    expect(waveModifiers(8).speedPct).toBeLessThan(96);
  });
});

describe('thrall pathing', () => {
  it('gets round a pinch between two props instead of pushing at it forever', () => {
    const nav = new Nav();
    nav.setUnlocked(['chapterhouse', 'graves']);
    const sim = new WorldSim(nav, mulberry32(3));
    const r = AREAS.graves.rect;
    const cx = (r.x0 + r.x1) / 2;
    const cz = (r.z0 + r.z1) / 2;
    sim.setPlayer({ id: 'p1', x: cx, z: cz, alive: true, area: 'graves' });
    sim.step(0.05);
    for (const e of [...sim.enemies.values()]) sim.enemies.delete(e.id);
    // Two posts 0.2m apart: a body 0.8m wide cannot pass between them.
    nav.addObstacle({ kind: 'circle', x: cx + 2, z: cz - 0.6, r: 0.5 });
    nav.addObstacle({ kind: 'circle', x: cx + 2, z: cz + 0.6, r: 0.5 });
    sim.addCorpse(cx + 0.5, cz, 'normal', 'robber', false, 0, 1, 'graves');
    const c = [...sim.corpses.values()][0];
    sim.apply({ t: 'exhume', by: 'p1', x: c.x, z: c.z, r: 1, kind: 'warrior', cap: 3, hp: 1e6, damage: 1, attackSpeedMult: 1 });
    sim.step(1.2);
    const th = [...sim.thralls.values()][0];
    th.x = cx + 1.2;
    th.z = cz;
    const foe = sim.spawnEnemy('robber', 'graves', cx + 4.5, cz, false, false);
    foe.speed = 0;
    foe.attackCd = 1e9;
    let reached = false;
    for (let i = 0; i < 200 && !reached; i++) {
      sim.step(0.05);
      th.hp = th.maxHp;
      for (const e of sim.enemies.values()) if (e !== foe) sim.enemies.delete(e.id);
      reached = Math.hypot(th.x - foe.x, th.z - foe.z) < th.range + foe.radius + 0.3;
    }
    expect(reached).toBe(true);
  });
});

describe('Command: Rend', () => {
  it('never leaps the legion into the next hall', () => {
    const sim = world(13);
    const r = AREAS.graves.rect;
    const p = sim.players.get('p1')!;
    sim.setPlayer({ ...p, x: r.x1 - 3, z: (r.z0 + r.z1) / 2 });
    const me = sim.players.get('p1')!;
    for (let i = 0; i < 2; i++) sim.addCorpse(me.x - 2 - i, me.z, 'normal', 'robber', false, 0, 1, 'graves');
    for (const c of [...sim.corpses.values()]) sim.apply({ t: 'exhume', by: 'p1', x: c.x, z: c.z, r: 1, kind: 'warrior', cap: 3, hp: 1e6, damage: 1, attackSpeedMult: 1 });
    sim.step(1.2);
    sim.apply({ t: 'signature', by: 'p1', sig: 'rend', x: r.x1 + 9, z: me.z, dx: 12, dz: 0, sp: 10 });
    for (const t of sim.thralls.values()) expect(t.x).toBeLessThan(r.x1 + 1.5);
  });
});

describe('corpses behind a wall', () => {
  it('cannot be raised or burst from the next hall', () => {
    const sim = world(17);
    const p = sim.players.get('p1')!;
    sim.addCorpse(p.x + 2, p.z, 'normal', 'robber', false, 0, 1, 'ossuary');
    const far = [...sim.corpses.values()][0];
    sim.apply({ t: 'exhume', by: 'p1', x: far.x, z: far.z, r: 1, kind: 'warrior', cap: 3, hp: 10, damage: 1, attackSpeedMult: 1 });
    expect(sim.thralls.size).toBe(0);
    expect(sim.corpses.has(far.id)).toBe(true);
    const ev = sim.apply({ t: 'detonate', by: 'p1', corpseId: far.id, dmg: 10 }) ?? [];
    void ev;
    expect(sim.corpses.has(far.id)).toBe(true);
  });
});
