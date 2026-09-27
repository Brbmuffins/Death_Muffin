import { describe, expect, it } from 'vitest';
import { Nav } from '../nav';
import { WorldSim } from '../sim/WorldSim';
import { WorldMirror, makeSnapshot } from '../sim/snapshot';
import { mulberry32 } from '../rng';
import type { Corpse, SimEvent } from '../sim/types';
import { AFFIX_ORDER, AFFIX_TUNING, SURGE } from '../../content/enemies';
import { BONE_MANTLE, DETONATE, GRAVE_FROST } from '../../content/abilities';
import { RESTLESS_SURGE_MULT, waveModifiers } from '../../content/upgrades';
import { generateLayout } from '../../content/layout';
import { BONE_HEX, CHILL, HEMORRHAGE, SANCTIFIED } from '../../content/statuses';
import type { EnemyRow } from '../../net/contracts';

function world(seed = 1) {
  const nav = new Nav();
  const sim = new WorldSim(nav, mulberry32(seed));
  sim.setPlayer({ id: 'p1', x: 0, z: -16, alive: true, area: 'graves' });
  return { nav, sim };
}

const exhume = (x: number, z: number, cap = 3) =>
  ({ t: 'exhume', by: 'p1', x, z, r: 1, kind: 'warrior', cap, hp: 50, damage: 5, attackSpeedMult: 1 }) as const;

/** Drop a corpse and return it (addCorpse doesn't hand it back). */
function corpse(sim: WorldSim, x: number, z: number, kind: Corpse['kind'] = 'normal', elite = false): Corpse {
  const enemy = kind === 'resonant' ? 'penitent' : kind === 'toxic' ? 'sac' : 'robber';
  sim.addCorpse(x, z, kind, enemy, elite, 0, 1, 'graves');
  return [...sim.corpses.values()].find((c) => c.x === x && c.z === z)!;
}

const of = <T extends SimEvent['t']>(ev: SimEvent[], t: T) => ev.filter((e): e is Extract<SimEvent, { t: T }> => e.t === t);

/** Step the sim, collecting every event, until `until` returns true (or the time budget runs out). */
function run(sim: WorldSim, seconds: number, until?: (ev: SimEvent[]) => boolean, each?: () => void) {
  const all: SimEvent[] = [];
  for (let t = 0; t < seconds; t += 0.05) {
    each?.();
    const ev = sim.step(0.05);
    all.push(...ev);
    if (until?.(ev)) break;
  }
  return all;
}

describe('WorldSim', () => {
  it('opens an area with a wave when a player first enters it', () => {
    const { sim } = world();
    const ev = sim.step(0.016);
    expect(ev.some((e) => e.t === 'wave')).toBe(true);
    expect(sim.enemies.size).toBeGreaterThan(0);
    for (const e of sim.enemies.values()) expect(e.area).toBe('graves');
  });

  it('never spawns into the safe chapterhouse', () => {
    const { sim } = world();
    sim.setPlayer({ id: 'p1', x: 0, z: 20, alive: true, area: 'chapterhouse' });
    for (let i = 0; i < 300; i++) sim.step(0.05);
    expect(sim.enemies.size).toBe(0);
  });

  it('kills leave corpses; exhume consumes one and raises a thrall', () => {
    const { sim } = world();
    const e = sim.spawnEnemy('robber', 'graves', 2, -16, false, false);
    sim.apply({ t: 'hit', by: 'p1', ids: [e.id], dmg: 9999 });
    const ev = sim.step(0.016);
    const death = ev.find((x): x is Extract<SimEvent, { t: 'death' }> => x.t === 'death');
    expect(death?.killer).toBe('p1');
    expect(sim.corpses.size).toBe(1);
    const corpse = [...sim.corpses.values()][0];
    sim.apply(exhume(corpse.x, corpse.z));
    expect(sim.corpses.size).toBe(0);
    expect(sim.thralls.size).toBe(1);
  });

  it('the thrall cap crumbles the oldest thrall', () => {
    const { sim } = world();
    for (let i = 0; i < 4; i++) {
      sim.addCorpse(1 + i, -16, 'normal', 'robber', false, 0, 1, 'graves');
      sim.step(0.1);
      sim.apply(exhume(1 + i, -16, 3));
    }
    expect(sim.thralls.size).toBe(3);
  });

  it('fracture amplifies later hits', () => {
    const { sim } = world();
    const e = sim.spawnEnemy('sac', 'graves', 3, -16, false, false);
    const start = e.hp;
    sim.apply({ t: 'hit', by: 'p1', ids: [e.id], dmg: 10, fracture: 1 });
    const afterFirst = e.hp;
    sim.apply({ t: 'hit', by: 'p1', ids: [e.id], dmg: 10 });
    expect(start - afterFirst).toBeCloseTo(10);
    expect(afterFirst - e.hp).toBeCloseTo(11.5);
  });

  it('black litany consumes corpses in radius, sacrifices thralls and scales damage', () => {
    const { sim } = world();
    sim.clearArea('graves');
    const e = sim.spawnEnemy('sac', 'graves', 0, -19, false, false);
    const hp0 = e.hp;
    for (let i = 0; i < 4; i++) sim.addCorpse(i - 2, -15, 'normal', 'robber', false, 0, 1, 'graves');
    sim.addCorpse(10, -16, 'normal', 'robber', false, 0, 1, 'graves'); // outside radius
    sim.apply({ t: 'litany', by: 'p1', x: 0, z: -16, r: 7, spellPower: 10, leaveCorpses: false });
    const ev = sim.drain();
    const res = ev.find((x): x is Extract<SimEvent, { t: 'litanyResult' }> => x.t === 'litanyResult')!;
    expect(res.corpses).toBe(4);
    expect(sim.corpses.size).toBe(1);
    // 1.5 base + 0.6 × 4 corpses = 3.9 × spell power.
    expect(hp0 - e.hp).toBeCloseTo(39, 0);
  });

  it('toxic corpses rupture into a hostile zone that hurts players', () => {
    const { sim } = world();
    sim.clearArea('graves');
    sim.addCorpse(0, -16, 'toxic', 'sac', false, 0, 1, 'graves');
    let hurt = 0;
    for (let i = 0; i < 140; i++) for (const ev of sim.step(0.05)) if (ev.t === 'hurt' && ev.from === 'toxic') hurt++;
    expect(hurt).toBeGreaterThan(0);
  });

  it('deacons steal unclaimed corpses and raise Risen', () => {
    const { sim } = world();
    sim.clearArea('graves');
    sim.setPlayer({ id: 'p1', x: 15, z: -30, alive: true, area: 'graves' });
    sim.spawnEnemy('deacon', 'graves', -10, -10, false, false);
    sim.addCorpse(-8, -10, 'normal', 'robber', false, 0, 1, 'graves');
    let raised = false;
    for (let i = 0; i < 200 && !raised; i++) for (const ev of sim.step(0.05)) if (ev.t === 'corpseGone' && ev.reason === 'raised') raised = true;
    expect(raised).toBe(true);
    expect([...sim.enemies.values()].some((e) => e.def === 'risen')).toBe(true);
  });

  it('snapshots round-trip into a mirror and can seed a new host', () => {
    const { sim, nav } = world();
    for (let i = 0; i < 20; i++) sim.step(0.05);
    sim.addCorpse(1, -16, 'normal', 'robber', false, 0, 1, 'graves');
    const mirror = new WorldMirror();
    mirror.applySnapshot(makeSnapshot(sim, true));
    expect(mirror.enemies.size).toBe(sim.enemies.size);
    expect(mirror.corpses.size).toBe(sim.corpses.size);
    const next = new WorldSim(nav);
    mirror.seed(next);
    expect(next.enemies.size).toBe(sim.enemies.size);
    // New ids never collide with inherited ones.
    const maxInherited = Math.max(...next.enemies.keys(), ...next.corpses.keys());
    expect(next.id()).toBeGreaterThan(maxInherited);
  });

  it('the Prelate awakens, changes phase and can be defeated', () => {
    const { sim } = world();
    sim.setPlayer({ id: 'p1', x: 0, z: -110, alive: true, area: 'sanctum' });
    sim.apply({ t: 'summonBoss', by: 'p1' });
    expect(sim.bossState.active).toBe(true);
    sim.apply({ t: 'hit', by: 'p1', ids: [], dmg: sim.bossState.maxHp * 0.5, boss: true });
    sim.step(0.05);
    expect(sim.bossState.phase).toBe(2);
    sim.apply({ t: 'hit', by: 'p1', ids: [], dmg: sim.bossState.maxHp, boss: true });
    const ev = sim.step(0.05);
    expect(ev.some((e) => e.t === 'boss' && e.kind === 'defeated' && e.killer === 'p1')).toBe(true);
  });
});

describe('Corpse Explosion (detonate intent)', () => {
  it('bursts the named corpse and damages enemies within 3m only', () => {
    const { sim } = world();
    const c = corpse(sim, 0, -16);
    const near = sim.spawnEnemy('sac', 'graves', 2, -16, false, false);
    const far = sim.spawnEnemy('robber', 'graves', 0, -12.4, false, false); // 3.6m: outside 3 + 0.45
    const [nearHp, farHp] = [near.hp, far.hp];
    sim.apply({ t: 'detonate', by: 'p1', corpseId: c.id, dmg: 20 });
    const ev = sim.drain();
    expect(sim.corpses.has(c.id)).toBe(false);
    const gone = of(ev, 'corpseGone')[0];
    expect(gone).toMatchObject({ id: c.id, reason: 'burst', by: 'p1' });
    const det = of(ev, 'detonated')[0];
    expect(det).toMatchObject({ ok: true, corpseId: c.id, r: DETONATE.radius, targets: 1, corpseKind: 'normal' });
    // Views learn about the blast before the corpse disappears.
    expect(ev.indexOf(det)).toBeLessThan(ev.indexOf(gone));
    expect(nearHp - near.hp).toBeCloseTo(20);
    expect(far.hp).toBe(farHp);
    expect(near.lastHitBy).toBe('p1');
  });

  it('resonant corpses blast wider, elite corpses hit twice as hard', () => {
    const { sim } = world();
    const res = corpse(sim, -10, -16, 'resonant');
    const e1 = sim.spawnEnemy('sac', 'graves', -10, -11.5, false, false); // 4.5m: only inside the resonant blast
    const hp1 = e1.hp;
    sim.apply({ t: 'detonate', by: 'p1', corpseId: res.id, dmg: 10 });
    expect(of(sim.drain(), 'detonated')[0].r).toBeCloseTo(DETONATE.radius * DETONATE.resonantRadiusMult);
    expect(hp1 - e1.hp).toBeCloseTo(10);

    const el = corpse(sim, 10, -16, 'normal', true);
    const e2 = sim.spawnEnemy('sac', 'graves', 11, -16, false, false);
    const hp2 = e2.hp;
    sim.apply({ t: 'detonate', by: 'p1', corpseId: el.id, dmg: 10 });
    expect(hp2 - e2.hp).toBeCloseTo(10 * DETONATE.eliteDamageMult);
  });

  it('toxic corpses leave a friendly rot pool instead of rupturing', () => {
    const { sim } = world();
    sim.clearArea('graves');
    sim.markVisited('graves'); // no waves wandering in during the check
    const c = corpse(sim, 0, -20, 'toxic');
    sim.apply({ t: 'detonate', by: 'p1', corpseId: c.id, dmg: 50 });
    const zone = of(sim.drain(), 'zone')[0]?.zone;
    expect(zone).toMatchObject({ kind: 'rot', owner: 'p1', hostile: false, x: 0, z: -20 });
    // Nothing is left to rupture into a hostile pool (toxic corpses burst after 5s).
    const ev = run(sim, 6);
    expect(ev.some((e) => e.t === 'hurt' && e.from === 'toxic')).toBe(false);
    expect(ev.some((e) => e.t === 'zone' && e.zone.kind === 'toxic')).toBe(false);
  });

  it('clamps claimed damage and refuses a corpse that is already gone', () => {
    const { sim } = world();
    const c = corpse(sim, 0, -16);
    const e = sim.spawnEnemy('sac', 'graves', 1, -16, false, false);
    e.hp = e.maxHp = 1e9;
    sim.apply({ t: 'detonate', by: 'p1', corpseId: c.id, dmg: 1e12 });
    expect(1e9 - e.hp).toBeCloseTo(DETONATE.maxDamage);
    sim.drain();
    sim.apply({ t: 'detonate', by: 'p1', corpseId: c.id, dmg: 10 });
    expect(of(sim.drain(), 'detonated')[0]).toMatchObject({ ok: false, by: 'p1', corpseId: c.id });
  });
});

describe('Elite affixes', () => {
  it('every elite rolls an affix, and snapshots carry it to mirrors', () => {
    const { sim } = world(7);
    for (let i = 0; i < 24; i++) sim.spawnEnemy('robber', 'graves', -20 + i, -30, true, false);
    const plain = sim.spawnEnemy('robber', 'graves', 0, -5, false, false);
    const elites = [...sim.enemies.values()].filter((e) => e.elite);
    for (const e of elites) expect(AFFIX_ORDER).toContain(e.affix);
    expect(new Set(elites.map((e) => e.affix)).size).toBeGreaterThan(1);
    expect(plain.affix).toBeUndefined();

    const mirror = new WorldMirror();
    mirror.applySnapshot(makeSnapshot(sim, false));
    for (const e of sim.enemies.values()) expect(mirror.enemies.get(e.id)?.affix).toBe(e.affix);
    // Rows from an older host (13 fields, no affix) still parse.
    const snap = makeSnapshot(sim, false);
    snap.enemies = snap.enemies.map((r) => r.slice(0, 13) as EnemyRow);
    const old = new WorldMirror();
    old.applySnapshot(snap);
    expect([...old.enemies.values()].every((e) => e.affix === undefined)).toBe(true);
  });

  it('Bell-Tolled telegraphs a ring, then hurts (stuns) players still inside it', () => {
    const { sim } = world();
    sim.markVisited('graves');
    const e = sim.spawnEnemy('robber', 'graves', 1.5, -16, true, false, 'bellTolled');
    e.speed = 0;
    e.attackCd = 1e9; // isolate the affix from its normal swings
    const ev = run(sim, AFFIX_TUNING.bellTolled.intervalS + 2, (b) => b.some((x) => x.t === 'affix'));
    const tele = of(ev, 'telegraph').find((t) => t.kind === 'toll');
    expect(tele).toMatchObject({ id: e.id, r: AFFIX_TUNING.bellTolled.r });
    const hurt = of(ev, 'hurt').filter((h) => h.from === 'toll');
    expect(hurt.map((h) => h.player)).toEqual(['p1']);
    expect(of(ev, 'affix')[0]).toMatchObject({ id: e.id, affix: 'bellTolled' });

    // Stepping out of the anchored ring before it sounds avoids it.
    const ev2 = run(sim, AFFIX_TUNING.bellTolled.intervalS + 2, (b) => {
      if (b.some((x) => x.t === 'telegraph' && x.kind === 'toll')) sim.setPlayer({ id: 'p1', x: 12, z: -16, alive: true, area: 'graves' });
      return b.some((x) => x.t === 'affix');
    });
    expect(ev2.some((x) => x.t === 'affix')).toBe(true);
    expect(ev2.some((x) => x.t === 'hurt' && x.from === 'toll')).toBe(false);
  });

  it('Hungering devours a nearby corpse to heal 15%, but only when wounded', () => {
    const { sim } = world();
    sim.setPlayer({ id: 'p1', x: 20, z: -2, alive: true, area: 'graves' }); // same area, out of aggro
    sim.markVisited('graves');
    const e = sim.spawnEnemy('robber', 'graves', -10, -20, true, false, 'hungering');
    e.speed = 0;
    const c = corpse(sim, -8, -20);
    run(sim, AFFIX_TUNING.hungering.intervalS + 1);
    expect(sim.corpses.has(c.id)).toBe(true); // full HP: no feeding

    e.hp = e.maxHp * 0.5;
    const ev = run(sim, AFFIX_TUNING.hungering.intervalS + 1, (b) => b.some((x) => x.t === 'corpseGone'));
    expect(of(ev, 'corpseGone')[0]).toMatchObject({ id: c.id, reason: 'devoured' });
    expect(of(ev, 'affix')[0]).toMatchObject({ id: e.id, affix: 'hungering', tx: c.x, tz: c.z });
    expect(e.hp).toBeCloseTo(e.maxHp * (0.5 + AFFIX_TUNING.hungering.healFrac), 0);
  });

  it('Shrouded takes half damage unless it stands in a player Miasma', () => {
    const { sim } = world();
    const e = sim.spawnEnemy('sac', 'graves', 5, -20, true, false, 'shrouded');
    let hp = e.hp;
    sim.apply({ t: 'hit', by: 'p1', ids: [e.id], dmg: 20 });
    expect(hp - e.hp).toBeCloseTo(20 * AFFIX_TUNING.shrouded.damageTakenMult);
    sim.apply({ t: 'miasma', by: 'p1', x: 5, z: -20, r: 3.8, dps: 1, durationMs: 6000, witheredCap: 5, bloom: false });
    hp = e.hp;
    sim.apply({ t: 'hit', by: 'p1', ids: [e.id], dmg: 20 });
    expect(hp - e.hp).toBeCloseTo(20);
  });

  it('Vengeful bursts into three Risen on death', () => {
    const { sim } = world();
    sim.clearArea('graves');
    sim.markVisited('graves');
    const e = sim.spawnEnemy('robber', 'graves', 4, -20, true, false, 'vengeful');
    sim.drain();
    sim.apply({ t: 'hit', by: 'p1', ids: [e.id], dmg: 1e6 });
    const ev = sim.step(0.05);
    expect(of(ev, 'death')[0]?.id).toBe(e.id);
    expect(of(ev, 'affix')[0]).toMatchObject({ id: e.id, affix: 'vengeful' });
    const risen = of(ev, 'spawn').filter((s) => s.def === 'risen');
    expect(risen).toHaveLength(AFFIX_TUNING.vengeful.risen);
    for (const r of risen) expect(Math.hypot(r.x - e.x, r.z - e.z)).toBeLessThan(2.5);
    expect(sim.corpses.size).toBe(1); // the elite still leaves its corpse
  });
});

describe('Grave Surges', () => {
  const opened = (ev: SimEvent[]) => ev.some((e) => e.t === 'surge');

  it('never surges while everyone is safe in the chapterhouse', () => {
    const { sim } = world();
    sim.setPlayer({ id: 'p1', x: 0, z: 20, alive: true, area: 'chapterhouse' });
    sim.surgeIn = 0.1;
    expect(opened(run(sim, 5))).toBe(false);
    expect(sim.surgeIn).toBeCloseTo(0.1);
  });

  it('opens after the combat timer, pours three waves, and is cleared by killing ≥80%', () => {
    const { sim } = world(3);
    sim.markVisited('graves');
    sim.surgeIn = 0.2;
    const start = run(sim, 2, opened);
    const s = of(start, 'surge')[0];
    expect(s).toMatchObject({ area: 'graves', durationMs: SURGE.durationS * 1000 });
    expect(sim.surge).not.toBeNull();
    const opensAt = sim.time;

    let spawned = 0;
    let waves = 0;
    const ev = run(
      sim,
      SURGE.durationS + 2,
      (b) => b.some((x) => x.t === 'surgeCleared' || x.t === 'surgeFailed'),
      () => {
        if (!sim.surge) return;
        spawned = sim.surge.spawned;
        waves = sim.surge.wavesSpawned;
        // The party mows down everything the crypt spits out.
        sim.apply({ t: 'hit', by: 'p1', ids: [...sim.surge.ids], dmg: 1e6 });
      },
    );
    const cleared = of(ev, 'surgeCleared')[0];
    expect(cleared).toMatchObject({ area: 'graves', x: s.x, z: s.z });
    expect(of(ev, 'surgeFailed')).toHaveLength(0);
    expect(waves).toBe(SURGE.waveAtS.length);
    expect(spawned).toBeGreaterThanOrEqual(SURGE.waveAtS.length);
    // Can't be cleared before the last wave climbs out, and it beat the clock.
    expect(sim.time - opensAt).toBeGreaterThanOrEqual(SURGE.waveAtS[SURGE.waveAtS.length - 1]);
    expect(sim.time - opensAt).toBeLessThan(SURGE.durationS);
    expect(sim.surge).toBeNull();
    expect(sim.surgeIn).toBeGreaterThanOrEqual(SURGE.minIntervalS);
    expect(sim.surgeIn).toBeLessThanOrEqual(SURGE.maxIntervalS);
  });

  it('an ignored surge fails when its time runs out', () => {
    const { sim } = world(5);
    sim.markVisited('graves');
    sim.surgeIn = 0.1;
    run(sim, 2, opened);
    expect(sim.surge).not.toBeNull();
    let ids = new Set<number>();
    const ev = run(
      sim,
      SURGE.durationS + 1,
      (b) => b.some((x) => x.t === 'surgeFailed'),
      () => {
        if (sim.surge) ids = new Set(sim.surge.ids);
      },
    );
    expect(ids.size).toBeGreaterThan(0);
    expect(of(ev, 'surgeFailed')).toHaveLength(1);
    expect(of(ev, 'surgeCleared')).toHaveLength(0);
    expect(sim.surge).toBeNull();
    // The surge's dead stay in the world; only the bookkeeping ends.
    expect([...ids].some((id) => sim.enemies.has(id))).toBe(true);
  });
});

describe('Wave Speed milestones', () => {
  /** Step until a regular (non-greeting) wave climbs out; return that step's spawns. */
  function nextWave(tier: number, seed = 5) {
    const { sim } = world(seed);
    sim.waveTier = tier;
    sim.markVisited('graves');
    for (let i = 0; i < 400; i++) {
      const ev = sim.step(0.05);
      if (of(ev, 'wave').length) return { sim, spawns: of(ev, 'spawn') };
    }
    throw new Error('no wave');
  }

  it('Elite Vanguard (tier 3) puts an elite in the first regular wave (then every other one)', () => {
    for (let seed = 0; seed < 3; seed++) {
      const { spawns } = nextWave(3, seed + 11);
      expect(spawns.some((s) => s.elite)).toBe(true);
    }
    // Below the milestone, a wave can be all commons.
    const { spawns } = nextWave(2);
    expect(spawns.filter((s) => s.elite).length).toBeLessThan(spawns.length);
  });

  it('Restless Crypts (tier 6) brings the next surge sooner', () => {
    const { sim } = world(2);
    sim.waveTier = 6;
    (sim as unknown as { endSurge(): void }).endSurge();
    expect(sim.surgeIn).toBeLessThanOrEqual(SURGE.maxIntervalS * RESTLESS_SURGE_MULT + 1e-9);
    sim.waveTier = 5;
    const lows = Array.from({ length: 20 }, () => {
      (sim as unknown as { endSurge(): void }).endSurge();
      return sim.surgeIn;
    });
    expect(Math.min(...lows)).toBeGreaterThanOrEqual(SURGE.minIntervalS);
  });

  it('Nightfall (tier 8) shrouds about half the common dead and pays more', () => {
    let commons = 0;
    let shrouded = 0;
    let sim: WorldSim | null = null;
    let id = -1;
    for (let seed = 0; seed < 6; seed++) {
      const r = nextWave(8, seed + 30);
      for (const s of r.spawns.filter((x) => !x.elite)) {
        commons++;
        if (s.affix === 'shrouded') {
          shrouded++;
          sim = r.sim;
          id = s.id;
        } else expect(s.affix).toBeUndefined();
      }
    }
    expect(shrouded / commons).toBeGreaterThan(0.25);
    expect(shrouded / commons).toBeLessThan(0.75);
    expect(waveModifiers(8).rewardMult - waveModifiers(7).rewardMult).toBeGreaterThan(0.3);
    // The shroud survives the snapshot round trip.
    const mirror = new WorldMirror();
    mirror.applySnapshot(makeSnapshot(sim!, true));
    expect(mirror.enemies.get(id)?.affix).toBe('shrouded');
  });
});

describe('Grave Surges from crypts', () => {
  it('break out of a fair crypt when one exists, else a breach', () => {
    const { sim } = world(4);
    const crypts = generateLayout().crypts;
    sim.setCrypts(crypts);
    const ev: SimEvent[] = [];
    sim.startSurge('graves');
    ev.push(...sim.step(0.05));
    const s = of(ev, 'surge')[0];
    expect(s.crypt).toBe(true);
    expect(crypts.some((c) => c.area === 'graves' && c.x === s.x && c.z === s.z)).toBe(true);
    // No crypts known (or none fair): the old breach behaviour.
    const { sim: bare } = world(4);
    bare.startSurge('graves');
    const b = of(bare.step(0.05), 'surge')[0];
    expect(b.crypt).toBeUndefined();
  });
});

describe('Status matrix', () => {
  it('Hemorrhage: a spear hit bleeds its owner a capped share per second', () => {
    const { sim } = world(6);
    const e = sim.spawnEnemy('sac', 'graves', 0, -20, false, false);
    const hp0 = e.hp;
    sim.apply({ t: 'hit', by: 'p1', ids: [e.id], dmg: 10, bleed: 1e6 });
    expect(e.bleedDps).toBeCloseTo(10 * HEMORRHAGE.maxFrac);
    const afterHit = e.hp;
    expect(hp0 - afterHit).toBeCloseTo(10);
    sim.step(1);
    expect(afterHit - e.hp).toBeCloseTo(10 * HEMORRHAGE.maxFrac, 1);
    // It runs out.
    for (let i = 0; i < 6; i++) sim.step(1);
    expect(e.bleedDps).toBe(0);
  });

  it("Chill: the Mourner's wraith hits slow the dead", () => {
    const { sim } = world(7);
    const e = sim.spawnEnemy('robber', 'graves', 0, -19, false, false);
    sim.addCorpse(0.5, -16, 'normal', 'robber', false, 0, 1, 'graves');
    sim.apply({ ...exhume(0.5, -16), kind: 'wraith', damage: 1 });
    let chilled = false;
    for (let i = 0; i < 80 && !chilled; i++) {
      sim.step(0.05);
      chilled = (e.chillT ?? 0) > 0;
    }
    expect(chilled).toBe(true);
    // Chilled feet: the same step covers less ground.
    const a = sim.spawnEnemy('robber', 'graves', -10, -30, false, false);
    const b = sim.spawnEnemy('robber', 'graves', 10, -30, false, false);
    a.speed = b.speed = 3;
    b.chillT = 5;
    const [ax, az, bx, bz] = [a.x, a.z, b.x, b.z];
    sim.step(0.2);
    expect(Math.hypot(b.x - bx, b.z - bz)).toBeLessThan(Math.hypot(a.x - ax, a.z - az));
    expect(CHILL.moveMult).toBeLessThan(1);
  });

  it('Sanctified: a Deacon with no corpse blesses a wounded ally, which then takes less damage', () => {
    const { sim } = world(8);
    const deacon = sim.spawnEnemy('deacon', 'graves', 0, -24, false, false);
    const ally = sim.spawnEnemy('robber', 'graves', 1.5, -24, false, false);
    ally.hp = ally.maxHp * 0.5;
    deacon.attackCd = 0;
    const ev = sim.step(0.05);
    expect(of(ev, 'sanctify').some((s) => s.id === deacon.id && s.target === ally.id)).toBe(true);
    expect(ally.sanctT).toBeGreaterThan(0);
    const hp = ally.hp;
    sim.apply({ t: 'hit', by: 'p1', ids: [ally.id], dmg: 10 });
    expect(hp - ally.hp).toBeCloseTo(10 * SANCTIFIED.damageTakenMult);
  });

  it('statuses ride snapshot flags to guests', () => {
    const { sim } = world(9);
    const e = sim.spawnEnemy('robber', 'graves', 0, -20, false, false);
    e.bleedT = 2;
    e.bleedDps = 3;
    e.chillT = 1;
    e.sanctT = 1;
    const mirror = new WorldMirror();
    mirror.applySnapshot(makeSnapshot(sim, true));
    const m = mirror.enemies.get(e.id)!;
    expect(m.bleedT).toBeGreaterThan(0);
    expect(m.chillT).toBeGreaterThan(0);
    expect(m.sanctT).toBeGreaterThan(0);
  });
});

describe('Thrall variety', () => {
  const raise = (sim: WorldSim, c: Corpse, kind: 'warrior' | 'wraith' = 'warrior') => {
    const ev: SimEvent[] = [];
    sim.apply({ ...exhume(c.x, c.z), kind });
    ev.push(...sim.step(0.01));
    return of(ev, 'thrall')[0];
  };

  it('a corpse remembers what it was', () => {
    const { sim } = world(12);
    expect(raise(sim, corpse(sim, 1, -16, 'resonant')).kind).toBe('archer');
    expect(raise(sim, corpse(sim, 2, -16, 'toxic')).kind).toBe('plaguebearer');
    sim.addCorpse(3, -16, 'normal', 'deacon', false, 0, 1, 'graves');
    const deacon = [...sim.corpses.values()].find((c) => c.enemy === 'deacon')!;
    expect(raise(sim, deacon).kind).toBe('bonemage');
    expect(raise(sim, corpse(sim, 4, -16, 'normal')).kind).toBe('warrior');
    // The Mourner's discipline overrides: everything rises a wraith.
    const { sim: m } = world(13);
    expect(raise(m, corpse(m, 1, -16, 'toxic'), 'wraith').kind).toBe('wraith');
  });

  it('a fallen plague bearer bursts and leaves a friendly rot pool', () => {
    const { sim } = world(14);
    const t = raise(sim, corpse(sim, 0, -18, 'toxic'));
    const thrall = sim.thralls.get(t.id)!;
    const e = sim.spawnEnemy('sac', 'graves', thrall.x + 1, thrall.z, false, false);
    const hp = e.hp;
    sim.killThrall(thrall, 'killed');
    const ev = sim.step(0.01);
    expect(e.hp).toBeLessThan(hp);
    const rot = [...sim.zones.values()].find((z) => z.kind === 'rot');
    expect(rot?.hostile).toBe(false);
    expect(of(ev, 'burst').length).toBeGreaterThan(0);
    // Crumbling (legion over cap) is quiet: no burst.
    const t2 = raise(sim, corpse(sim, 5, -18, 'toxic'));
    const zones = sim.zones.size;
    sim.killThrall(sim.thralls.get(t2.id)!, 'crumbled');
    expect(sim.zones.size).toBe(zones);
  });

  it("a bone mage's hex softens the enemy's blows", () => {
    const { sim } = world(15);
    const e = sim.spawnEnemy('robber', 'graves', 0, -19, false, false);
    sim.addCorpse(0.5, -16, 'normal', 'deacon', false, 0, 1, 'graves');
    raise(sim, [...sim.corpses.values()].find((c) => c.enemy === 'deacon')!);
    for (let i = 0; i < 120 && !((e.hexT ?? 0) > 0); i++) sim.step(0.05);
    expect(e.hexT).toBeGreaterThan(0);
    const blow = (sim as unknown as { blow(e: unknown): number }).blow(e);
    expect(blow).toBeCloseTo(e.damage * BONE_HEX.damageMult);
  });
});

describe('Signature rites', () => {
  const sig = (sim: WorldSim, s: 'wall' | 'rend' | 'dirge' | 'bloom', x: number, z: number, dx = 0, dz = -1, sp = 20) =>
    sim.apply({ t: 'signature', by: 'p1', sig: s, x, z, dx, dz, sp });

  it('Ossuary Wall stops the dead and breaks Penitent cones', () => {
    const { sim } = world(21);
    // Player at (0,-16); wall across the aim line 4m north.
    sig(sim, 'wall', 0, -20, 0, -1);
    const ev = sim.step(0.01);
    expect(of(ev, 'wall').length).toBe(1);
    const e = sim.spawnEnemy('robber', 'graves', 0, -26, false, false);
    e.speed = 4;
    for (let i = 0; i < 60; i++) sim.step(0.05);
    expect(e.z).toBeLessThan(-20); // still on the far side
    // A cone through the wall misses.
    const pen = sim.spawnEnemy('penitent', 'graves', 0, -24, false, false);
    pen.aimX = 0;
    pen.aimZ = -16;
    const hurts: SimEvent[] = [];
    (sim as unknown as { strike(e: unknown, k: string): void }).strike(pen, 'cone');
    hurts.push(...sim.step(0.01));
    expect(of(hurts, 'hurt').filter((h) => h.from === 'cone').length).toBe(0);
    // It crumbles on time.
    let gone = false;
    for (let i = 0; i < 80 && !gone; i++) gone = of(sim.step(0.1), 'wallGone').length > 0;
    expect(gone).toBe(true);
    expect(sim.walls.size).toBe(0);
  });

  it('Command: Rend leaps the legion onto the target and bills their health', () => {
    const { sim } = world(22);
    for (const x of [1, 2]) {
      corpse(sim, x, -16);
      sim.apply(exhume(x, -16));
    }
    for (let i = 0; i < 25; i++) sim.step(0.05); // rise
    const target = sim.spawnEnemy('sac', 'graves', 0, -24, false, false);
    const hp = target.hp;
    sig(sim, 'rend', 0, -24);
    const ev = sim.step(0.01);
    const r = of(ev, 'rend')[0];
    expect(r.leaps.length).toBe(2);
    expect(target.hp).toBeLessThan(hp);
    for (const t of sim.thralls.values()) {
      expect(Math.hypot(t.x - 0, t.z + 24)).toBeLessThan(2);
      expect(t.hp).toBeLessThan(t.maxHp);
    }
  });

  it('Dirge mends the singer and Silences casters inside', () => {
    const { sim } = world(23);
    const pen = sim.spawnEnemy('penitent', 'graves', 2, -18, false, false);
    pen.attackCd = 0;
    sig(sim, 'dirge', 0, -16, 0, 0, 30);
    const ev: SimEvent[] = [];
    for (let i = 0; i < 30; i++) ev.push(...sim.step(0.05));
    expect(of(ev, 'heal').some((h) => h.player === 'p1' && h.amount > 0)).toBe(true);
    expect(pen.silenceT).toBeGreaterThan(0);
    expect(of(ev, 'telegraph').filter((t) => t.id === pen.id).length).toBe(0);
  });

  it('Plague Bloom seeds the nearest corpse, chaining through the field', () => {
    const { sim } = world(24);
    const c1 = corpse(sim, 3, -20);
    corpse(sim, 6, -20);
    sig(sim, 'bloom', 0, -20);
    for (let i = 0; i < 90; i++) sim.step(0.05); // 4.5 s: two spreads
    const flowers = [...sim.zones.values()].filter((z) => z.kind === 'flower');
    expect(flowers.length).toBeGreaterThanOrEqual(3);
    expect(sim.corpses.has(c1.id)).toBe(false);
    expect(Math.max(...flowers.map((f) => f.gen ?? 0))).toBe(2);
  });
});

describe('Grimoire rites (host side)', () => {
  it('Grave Frost hits Chill for the host-owned duration, whatever the claim', () => {
    const { sim } = world(31);
    const e = sim.spawnEnemy('robber', 'graves', 2, -16, false, false);
    sim.apply({ t: 'hit', by: 'p1', ids: [e.id], dmg: 1, chill: true });
    expect(e.chillT).toBe(GRAVE_FROST.chillS);
    // A plain hit never chills, and a second breath refreshes rather than stacks.
    const other = sim.spawnEnemy('robber', 'graves', -2, -16, false, false);
    sim.apply({ t: 'hit', by: 'p1', ids: [other.id], dmg: 1 });
    expect(other.chillT ?? 0).toBe(0);
    sim.step(0.5);
    sim.apply({ t: 'hit', by: 'p1', ids: [e.id], dmg: 1, chill: true });
    expect(e.chillT).toBe(GRAVE_FROST.chillS);
  });

  it('Bone Mantle consumes up to five of the nearest corpses around the caster', () => {
    const { sim } = world(32);
    // Player at (0,-16). Seven bodies in reach, one outside the 6m radius.
    const near = Array.from({ length: 7 }, (_, i) => corpse(sim, -3 + i, -15));
    const far = corpse(sim, 0, -24);
    sim.step(0.01);
    // The client proposes a far-away centre; the host clamps it to the caster.
    sim.apply({ t: 'signature', by: 'p1', sig: 'mantle', x: 40, z: 40, dx: 0, dz: 0, sp: 20 });
    const ev = sim.step(0.01);
    const [m] = of(ev, 'mantle');
    expect(m.corpses).toBe(BONE_MANTLE.maxCorpses);
    expect(m.tethers.length).toBe(BONE_MANTLE.maxCorpses);
    expect(Math.hypot(m.x - 0, m.z + 16)).toBeLessThan(1.01);
    expect(sim.corpses.has(far.id)).toBe(true);
    // The two farthest of the seven survive.
    expect(near.filter((c) => sim.corpses.has(c.id)).length).toBe(2);
    expect(of(ev, 'corpseGone').every((g) => g.reason === 'consumed' && g.by === 'p1')).toBe(true);
  });

  it('Bone Mantle with no corpses still answers (a thin mantle)', () => {
    const { sim } = world(33);
    sim.apply({ t: 'signature', by: 'p1', sig: 'mantle', x: 0, z: -16, dx: 0, dz: 0, sp: 20 });
    const [m] = of(sim.step(0.01), 'mantle');
    expect(m.corpses).toBe(0);
  });
});
