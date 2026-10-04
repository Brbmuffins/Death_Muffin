import { describe, expect, it } from 'vitest';
import { AREAS } from '../../content/areas';
import { AFFIX_ORDER } from '../../content/enemies';
import { DEPTHS, depthEnemyLevel, depthRoster, extraAffixes, floorKills } from '../../content/depths';
import { roomAt } from '../depthsFloor';
import { Nav } from '../nav';
import { mulberry32 } from '../rng';
import { WorldSim } from '../sim/WorldSim';
import type { SimEvent } from '../sim/types';

function depthsWorld(seed = 5, level = 30, depth = 1) {
  const nav = new Nav();
  const sim = new WorldSim(nav, mulberry32(seed));
  const floor = sim.startDepths('p1', 4242, depth);
  const hero = (x: number, z: number) => sim.setPlayer({ id: 'p1', x, z, alive: true, area: 'depths', level });
  hero(floor.start.x, floor.start.z);
  return { nav, sim, floor, hero };
}

function run(sim: WorldSim, seconds: number, each?: (ev: SimEvent[]) => void) {
  const all: SimEvent[] = [];
  for (let t = 0; t < seconds; t += 0.05) {
    const ev = sim.step(0.05);
    all.push(...ev);
    each?.(ev);
  }
  return all;
}

/** Kill every living enemy in the Depths by hand (a hit that is more than enough). */
function slayAll(sim: WorldSim) {
  for (const e of sim.enemies.values()) if (e.area === 'depths') e.hp = 0;
}

describe('Depths: the run', () => {
  it('opens the instance ground, builds floor 1 and asks for its quota', () => {
    const nav = new Nav();
    const sim = new WorldSim(nav, mulberry32(1));
    expect(nav.isUnlocked('depths')).toBe(false);
    const floor = sim.startDepths('p1', 77);
    expect(nav.isUnlocked('depths')).toBe(true);
    expect(nav.depthsFloor).toBe(floor);
    expect(sim.depths).toMatchObject({ depth: 1, kills: 0, stairOpen: false, need: floorKills(1) });
    const ev = sim.drain();
    expect(ev.find((e) => e.t === 'depthsFloor')).toMatchObject({ depth: 1, need: floorKills(1), chest: false });
  });

  it('enemy level is the hero level (never below the floor) plus the depth, and Ascension ages the floor too', () => {
    const { sim } = depthsWorld(1, 40, 1);
    expect(sim.areaLevel('depths')).toBe(depthEnemyLevel(1, 40));
    expect(depthEnemyLevel(1, 40)).toBe(41);
    expect(depthEnemyLevel(10, 40)).toBe(50);
    expect(depthEnemyLevel(1, 3)).toBe(DEPTHS.minLevel + 1);
    expect(depthEnemyLevel(20, 1)).toBe(DEPTHS.minLevel + 20);
    sim.ascension = 2;
    expect(sim.areaLevel('depths')).toBe(41 + 6);
  });

  it('the first wave climbs out after a moment, away from the hero, in the floor\'s own rooms', () => {
    const { sim, floor } = depthsWorld();
    run(sim, 0.8);
    expect(sim.enemies.size).toBe(0);
    run(sim, 1.5);
    expect(sim.enemies.size).toBeGreaterThan(0);
    const heroRoom = roomAt(floor, floor.start.x, floor.start.z);
    for (const e of sim.enemies.values()) {
      expect(e.area).toBe('depths');
      expect(roomAt(floor, e.x, e.z)).not.toBe(heroRoom);
      expect(e.level).toBe(sim.areaLevel('depths'));
    }
  });

  it('never spawns more than the floor still needs, and never more than 24 alive', () => {
    const { sim } = depthsWorld(3, 30, 25);
    let peak = 0;
    run(sim, 120, () => {
      peak = Math.max(peak, [...sim.enemies.values()].filter((e) => e.area === 'depths').length);
    });
    // Nothing was killed: the floor fills to the cap and stops there (its quota of 30 needs kills to make room).
    expect(peak).toBeLessThanOrEqual(DEPTHS.cap);
    expect(peak).toBeGreaterThanOrEqual(DEPTHS.cap - 2);
    expect(sim.enemies.size).toBeLessThanOrEqual(DEPTHS.cap);
    // A short floor spawns only what it needs: depth 1 asks for 10 and never fields many more than that.
    const small = depthsWorld(3, 30, 1).sim;
    run(small, 60);
    expect(small.enemies.size).toBeLessThanOrEqual(floorKills(1) + 5);
    expect(small.enemies.size).toBeGreaterThanOrEqual(floorKills(1) - 1);
  });

  it('opens the stair when the quota is met, then goes down to a fresh floor with the dead cleared and the thralls kept', () => {
    const { sim, nav, floor, hero } = depthsWorld(7);
    sim.apply({ t: 'exhume', by: 'p1', x: floor.start.x + 1, z: floor.start.z, r: 1, kind: 'warrior', cap: 3, hp: 90, damage: 9, attackSpeedMult: 1 } as never);
    sim.addCorpse(floor.start.x + 1, floor.start.z, 'normal', 'robber', false, 0, 1, 'depths');
    sim.apply({ t: 'exhume', by: 'p1', x: floor.start.x + 1, z: floor.start.z, r: 1, kind: 'warrior', cap: 3, hp: 90, damage: 9, attackSpeedMult: 1 } as never);
    const thralls = sim.thralls.size;
    let cleared: Extract<SimEvent, { t: 'depthsClear' }> | undefined;
    for (let guard = 0; guard < 40 && !sim.depths!.stairOpen; guard++) {
      hero(floor.start.x, floor.start.z);
      const ev = run(sim, 2);
      slayAll(sim);
      ev.push(...sim.step(0.05));
      cleared = ev.find((e): e is Extract<SimEvent, { t: 'depthsClear' }> => e.t === 'depthsClear') ?? cleared;
    }
    expect(sim.depths!.stairOpen).toBe(true);
    expect(sim.depths!.kills).toBeGreaterThanOrEqual(floorKills(1));
    expect(cleared).toMatchObject({ depth: 1, x: floor.stairDown.x, z: floor.stairDown.z });
    // Once the stair is open no more of the dead climb out.
    const before = sim.enemies.size;
    run(sim, 8);
    expect(sim.enemies.size).toBeLessThanOrEqual(before);

    const next = sim.descendDepths()!;
    expect(sim.depths).toMatchObject({ depth: 2, kills: 0, stairOpen: false, peak: 2, floors: 1 });
    expect(nav.depthsFloor).toBe(next);
    expect(next.seed).not.toBe(floor.seed);
    expect([...sim.enemies.values()].filter((e) => e.area === 'depths').length).toBe(0);
    expect([...sim.corpses.values()].filter((c) => c.area === 'depths').length).toBe(0);
    expect(sim.thralls.size).toBeGreaterThanOrEqual(Math.min(1, thralls));
    expect(sim.drain().some((e) => e.t === 'depthsFloor' && e.depth === 2)).toBe(true);
  });

  it('ending the run closes the ground, drops the floor and wipes its dead', () => {
    const { sim, nav } = depthsWorld();
    run(sim, 4);
    expect(sim.enemies.size).toBeGreaterThan(0);
    const ended = sim.endDepths();
    expect(ended).toMatchObject({ depth: 1 });
    expect(sim.depths).toBeNull();
    expect(nav.isUnlocked('depths')).toBe(false);
    expect(nav.depthsFloor).toBeNull();
    expect(sim.enemies.size).toBe(0);
  });

  it('the dead cross the floor through the doorways and reach a hero standing in the stair room', () => {
    const { sim, floor, hero } = depthsWorld(11, 30, 4);
    const room = floor.rooms[floor.stairRoom];
    const spot = { x: floor.stairDown.x, z: floor.stairDown.z + 2 };
    hero(spot.x, spot.z);
    let nearest = Infinity;
    let hurt = 0;
    run(sim, 70, (ev) => {
      hero(spot.x, spot.z);
      hurt += ev.filter((e) => e.t === 'hurt').length;
      for (const e of sim.enemies.values()) nearest = Math.min(nearest, Math.hypot(e.x - spot.x, e.z - spot.z));
    });
    expect(nearest, 'someone reached the hero').toBeLessThan(3);
    expect(hurt).toBeGreaterThan(0);
    expect(room.active).toBe(true);
  });

  it('holds a depth for the balance harness (a cleared floor re-rolls the same depth)', () => {
    const nav = new Nav();
    const sim = new WorldSim(nav, mulberry32(2));
    sim.startDepths('p1', 9, 10, true);
    const first = nav.depthsFloor!.seed;
    sim.descendDepths();
    expect(sim.depths!.depth).toBe(10);
    expect(nav.depthsFloor!.seed).toBe(first);
  });
});

describe('Depths: elites and the roster', () => {
  it('elites gain one more affix every fifth floor, distinct and never the first', () => {
    for (const [depth, extras] of [[1, 0], [4, 0], [5, 1], [9, 1], [10, 2], [15, 3], [40, 3]] as const) {
      expect(extraAffixes(depth)).toBe(extras);
      const { sim } = depthsWorld(depth, 30, depth);
      for (let i = 0; i < 12; i++) {
        const e = sim.spawnEnemy('robber', 'depths', 160, -30, true, false);
        const all = [e.affix, ...(e.extra ?? []).map((x) => x.affix)];
        expect(all.length).toBe(1 + extras);
        expect(new Set(all).size).toBe(all.length);
        for (const a of all) expect(AFFIX_ORDER).toContain(a);
      }
    }
  });

  it('only elites carry extras, and every affix of a deep elite really acts (shrouded halves damage, vengeful bursts)', () => {
    const { sim } = depthsWorld(1, 30, 15);
    const plain = sim.spawnEnemy('robber', 'depths', 160, -30, false, false);
    expect(plain.extra).toBeUndefined();
    const elite = sim.spawnEnemy('robber', 'depths', 160, -30, true, false);
    expect(elite.extra).toHaveLength(3);
    // Force the last two slots to the affixes whose effects are easy to see.
    elite.affix = undefined;
    elite.extra = [{ affix: 'shrouded' }, { affix: 'vengeful' }];
    expect(sim.damageTakenMult(elite)).toBeLessThan(1);
    sim.setPlayer({ id: 'p1', x: 170, z: -30, alive: true, area: 'depths', level: 30 });
    const before = sim.enemies.size;
    elite.hp = 0;
    sim.step(0.05);
    expect(sim.enemies.size).toBeGreaterThanOrEqual(before - 1 + 3); // the vengeful slot burst into three Risen
  });

  it('the roster widens with depth and reuses only enemies that exist', () => {
    const at = (d: number) => new Set(depthRoster(d).map((e) => e.id));
    expect(at(1).has('penitent')).toBe(false);
    expect(at(5).has('penitent')).toBe(true);
    expect(at(10).has('templar')).toBe(true);
    expect(at(15).has('golem')).toBe(true);
    for (const d of [1, 5, 10, 15, 30]) for (const e of depthRoster(d)) expect(e.weight).toBeGreaterThan(0);
    expect(AREAS.depths.instance).toBe(true);
  });
});

describe('Depths: resuming a run', () => {
  it('starts on the deepest floor with that depth\'s quota, level and peak, and still descends from there', () => {
    const { sim, floor } = depthsWorld(3, 40, 17);
    expect(sim.depths!.depth).toBe(17);
    expect(sim.depths!.peak).toBe(17);
    expect(sim.depths!.need).toBe(floorKills(17));
    expect(floor.depth).toBe(17);
    expect(sim.areaLevel('depths')).toBe(depthEnemyLevel(17, 40));
    slayAll(sim);
    run(sim, 3);
    for (let i = 0; i < 60 && !sim.depths!.stairOpen; i++) { slayAll(sim); run(sim, 1); }
    expect(sim.depths!.stairOpen).toBe(true);
    expect(sim.descendDepths()).not.toBeNull();
    expect(sim.depths!.depth).toBe(18);
    expect(sim.depths!.peak).toBe(18);
  });

  it('a run from depth 1 is unchanged', () => {
    const { sim } = depthsWorld(3, 40, 1);
    expect(sim.depths!.depth).toBe(1);
    expect(sim.areaLevel('depths')).toBe(depthEnemyLevel(1, 40));
  });
});
