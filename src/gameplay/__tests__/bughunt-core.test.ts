import { describe, expect, it } from 'vitest';
import { Nav } from '../nav';
import { WorldMirror, makeSnapshot } from '../sim/snapshot';
import { Player } from '../Player';
import type { DerivedStats } from '../characterStats';
import { WorldSim } from '../sim/WorldSim';
import { mulberry32 } from '../rng';
import { SURGE } from '../../content/enemies';
import { BOSSES } from '../../content/bosses';

function world(seed = 1) {
  const nav = new Nav();
  const sim = new WorldSim(nav, mulberry32(seed));
  sim.setPlayer({ id: 'p1', x: 0, z: -16, alive: true, area: 'graves' });
  return { nav, sim };
}

describe('core bug hunt: surge', () => {
  it('a surge abandoned with the area (everyone left) restarts the surge clock instead of leaving it expired', () => {
    const { sim } = world();
    sim.step(0.05);
    sim.startSurge('graves');
    expect(sim.surge).not.toBeNull();
    sim.surgeIn = -1; // the clock that opened it has long lapsed
    // the hero walks home; the hunting ground crumbles after its vacancy delay
    sim.setPlayer({ id: 'p1', x: 0, z: 20, alive: true, area: 'chapterhouse' });
    for (let i = 0; i < 200; i++) sim.step(0.05);
    expect(sim.surge).toBeNull();
    expect(sim.surgeIn).toBeGreaterThanOrEqual(SURGE.minIntervalS * 0.5);
  });
});

describe('core bug hunt: surge cleared by Ascension', () => {
  it('clearArea (Ascension wipes the grounds) ends an open surge properly and restarts its clock', () => {
    const { sim } = world();
    sim.step(0.05);
    sim.startSurge('graves');
    sim.surgeIn = -1;
    sim.clearArea('graves');
    expect(sim.surge).toBeNull();
    expect(sim.surgeIn).toBeGreaterThanOrEqual(SURGE.minIntervalS * 0.5);
    expect(sim.drain().some((e) => e.t === 'surgeFailed')).toBe(true);
  });
});

describe('core bug hunt: burrowed ghoul', () => {
  it('Withered and bleed damage over time cannot reach a ghoul that is underground', () => {
    const { sim } = world();
    const g = sim.spawnEnemy('ghoul', 'graves', 7, -16, false);
    expect(g.state).toBe('burrow');
    const hp = g.hp;
    g.withered = 5;
    g.witheredT = 5;
    g.witheredDps = 1e6;
    g.bleedT = 5;
    g.bleedDps = 1e6;
    for (let i = 0; i < 5; i++) sim.step(0.05);
    expect(g.state).toBe('burrow');
    expect(g.hp).toBe(hp);
  });
});

describe('core bug hunt: Mire Mother under the water', () => {
  it('Withered rot cannot hurt her while she is sunk', () => {
    const { sim } = world(60);
    const a = BOSSES.mire.arena;
    const keep = () => sim.setPlayer({ id: 'p1', x: a.x + 8, z: a.z + 6, alive: true, area: 'fen', level: 60 });
    keep();
    sim.apply({ t: 'summonBoss', by: 'p1', boss: 'mire' });
    let sunk = false;
    for (let t = 0; t < 25 && !sunk; t += 0.05) {
      keep();
      sim.step(0.05);
      sunk = sim.bossState.state === 'sunk';
    }
    expect(sunk).toBe(true);
    const b = sim.bossState;
    const hp = b.hp;
    b.withered = 5;
    b.witheredT = 5;
    b.witheredDps = 1000;
    keep();
    sim.step(0.05);
    expect(b.state).toBe('sunk');
    expect(b.hp).toBe(hp);
  });
});

describe('core bug hunt: socket id change (join / rejoin)', () => {
  it('retagPlayer hands the legion, rites and credit to the new id instead of crumbling them', () => {
    const { sim } = world();
    sim.setPlayer({ id: 'old', x: 0, z: -16, alive: true, area: 'graves' });
    sim.addCorpse(1, -16, 'normal', 'robber', false, 0, 1, 'graves');
    const c = [...sim.corpses.values()][0];
    sim.apply({ t: 'exhume', by: 'old', x: c.x, z: c.z, r: 1, kind: 'warrior', cap: 3, hp: 50, damage: 5, attackSpeedMult: 1 });
    sim.apply({ t: 'miasma', by: 'old', x: 0, z: -16, r: 3, dps: 5, durationMs: 6000, witheredCap: 5, bloom: false });
    expect(sim.thralls.size).toBe(1);
    sim.retagPlayer('old', 'new');
    sim.setPlayer({ id: 'new', x: 0, z: -16, alive: true, area: 'graves' });
    sim.step(0.05);
    expect(sim.thralls.size).toBe(1);
    expect([...sim.thralls.values()][0].owner).toBe('new');
    expect([...sim.zones.values()].every((z) => z.owner !== 'old')).toBe(true);
    expect(sim.players.has('old')).toBe(false);
  });
});

describe('core bug hunt: respawn state', () => {
  const stats: DerivedStats = { level: 12, maxHp: 100, spellPower: 20, maxEssence: 150, essenceRegen: 5, moveSpeed: 5.4, thrallHp: 45, thrallDamage: 8, damageBonusPct: 0 };

  it('a Veilwalker who dies in Veil form (toxic and burn get through it) does not rise still in Veil form', () => {
    const p = new Player(stats, new Nav(), 'veil');
    p.veilForm = true;
    p.takeDamage(1000, 0, 1000, undefined, 'toxic');
    expect(p.alive).toBe(false);
    p.revive();
    expect(p.veilForm).toBe(false);
  });

  it('revive clears roots, guards and timers left from before the death', () => {
    const p = new Player(stats, new Nav(), 'warden');
    p.rootedUntil = 1e9;
    p.bulwarkUntil = 1e9;
    p.unbreakableUntil = 1e9;
    p.betweenUntil = 1e9;
    p.castUntil = 1e9;
    p.takeDamage(1e6, 0, 5);
    p.unbreakableUntil = 0;
    p.takeDamage(1e6, 0, 5);
    p.revive();
    expect(p.rootedUntil).toBe(0);
    expect(p.bulwarkUntil).toBe(0);
    expect(p.unbreakableUntil).toBe(0);
    expect(p.betweenUntil).toBe(0);
    expect(p.castUntil).toBe(0);
  });
});

describe('core bug hunt: bookkeeping leaks', () => {
  it('a hall that crumbles around its enemies does not keep their damage-over-time accumulators', () => {
    const { sim } = world();
    const e = sim.spawnEnemy('robber', 'graves', 2, -16, false, false);
    e.bleedT = 5;
    e.bleedDps = 3;
    e.maxHp = e.hp = 1e6;
    for (let i = 0; i < 20; i++) sim.step(0.05);
    expect((sim as unknown as { dotAccum: Map<number, number> }).dotAccum.has(e.id)).toBe(true);
    sim.setPlayer({ id: 'p1', x: 0, z: 20, alive: true, area: 'chapterhouse' });
    for (let i = 0; i < 400; i++) sim.step(0.05);
    expect(sim.enemies.has(e.id)).toBe(false);
    expect((sim as unknown as { dotAccum: Map<number, number> }).dotAccum.size).toBe(0);
  });
});

describe('core bug hunt: host migration', () => {
  /** What a guest's mirror hands a fresh sim when the host drops (WorldMirror.seed). */
  const migrate = (sim: WorldSim) => {
    const m = new WorldMirror();
    m.applySnapshot(JSON.parse(JSON.stringify(makeSnapshot(sim, true))));
    const next = new WorldSim(new Nav(), mulberry32(9));
    m.seed(next);
    return next;
  };

  it('the legion keeps its damage, swing speed, reach and formation seats', () => {
    const { sim } = world();
    sim.setPlayer({ id: 'p1', x: 0, z: -16, alive: true, area: 'graves', level: 30 });
    const kinds: [string, number, number][] = [['robber', 1, -16], ['penitent', 2, -16], ['deacon', 3, -16], ['robber', 4, -16]];
    for (const [enemy, x, z] of kinds) {
      sim.addCorpse(x, z, 'normal', enemy as never, false, 0, 1, 'graves');
      const c = [...sim.corpses.values()].find((o) => o.x === x && o.z === z)!;
      sim.apply({ t: 'exhume', by: 'p1', x, z, r: 0.8, kind: 'warrior', cap: 8, hp: 90, damage: 37.5, attackSpeedMult: 1.4 });
      expect(sim.corpses.has(c.id)).toBe(false);
    }
    for (let i = 0; i < 40; i++) sim.step(0.05);
    expect(sim.thralls.size).toBe(4);
    const before = [...sim.thralls.values()];
    expect(before.map((t) => t.kind).sort()).toEqual(['archer', 'bonemage', 'warrior', 'warrior']);
    const next = migrate(sim);
    const after = [...next.thralls.values()];
    expect(after).toHaveLength(4);
    for (const b of before) {
      const a = next.thralls.get(b.id)!;
      expect(a.damage, `${b.kind} damage`).toBeCloseTo(b.damage, 1);
      expect(a.attackInterval, `${b.kind} swing`).toBeCloseTo(b.attackInterval, 1);
      expect(a.range, `${b.kind} reach`).toBe(b.range);
    }
    expect(new Set(after.map((t) => t.slot)).size).toBe(4);
    expect(new Set(after.map((t) => t.bornAt)).size).toBe(4);
  });

  it('enemies keep their level, damage and size', () => {
    const { sim } = world();
    sim.setPlayer({ id: 'p1', x: 0, z: -16, alive: true, area: 'graves', level: 30 });
    sim.ascension = 3;
    const e = sim.spawnEnemy('robber', 'graves', 2, -16, true, false);
    const next = migrate(sim);
    const a = next.enemies.get(e.id)!;
    expect(a.level).toBe(e.level);
    expect(a.damage).toBeCloseTo(e.damage, 0);
    expect(a.radius).toBeCloseTo(e.radius, 5);
  });
});

describe('core bug hunt: malformed co-op intents never reach the world as NaN or throw', () => {
  it('recallThralls without a point leaves the legion where it stands, and neighbours unharmed', () => {
    const { sim } = world();
    sim.addCorpse(1, -16, 'normal', 'robber', false, 0, 1, 'graves');
    sim.apply({ t: 'exhume', by: 'p1', x: 1, z: -16, r: 1, kind: 'warrior', cap: 3, hp: 50, damage: 5, attackSpeedMult: 1 });
    const e = sim.spawnEnemy('robber', 'graves', 1.2, -16, false, false);
    sim.apply({ t: 'recallThralls', by: 'p1' } as never);
    for (let i = 0; i < 20; i++) sim.step(0.05);
    for (const t of sim.thralls.values()) expect(Number.isFinite(t.x) && Number.isFinite(t.z)).toBe(true);
    expect(Number.isFinite(e.x) && Number.isFinite(e.z)).toBe(true);
  });

  it('an exhume naming an unknown thrall kind raises an ordinary thrall instead of throwing', () => {
    const { sim } = world();
    sim.addCorpse(1, -16, 'normal', 'robber', false, 0, 1, 'graves');
    expect(() => sim.apply({ t: 'exhume', by: 'p1', x: 1, z: -16, r: 1, kind: 'dragon', cap: 3, hp: 50, damage: 5, attackSpeedMult: 1 } as never)).not.toThrow();
    expect([...sim.thralls.values()].map((t) => t.kind)).toEqual(['warrior']);
  });
});
