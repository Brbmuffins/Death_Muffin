import * as THREE from 'three';
import { describe, expect, it, vi } from 'vitest';
import { AbilitySystem, type AbilityContext } from '../AbilitySystem';
import { Player } from '../Player';
import { Nav } from '../nav';
import { Effects } from '../../graphics/Effects';
import { DISCIPLINES, type DisciplineMods } from '../../content/disciplines';
import { WorldSim } from '../sim/WorldSim';
import { mulberry32 } from '../rng';
import type { Corpse, Enemy, SimEvent, Thrall } from '../sim/types';
import { LEGEND, type SimLegend, clampSimLegend, colossusActive, damageTakenMult, effectiveWitheredCap, simLegendActive, simLegendOf, wardReflectDamage } from '../legendary';

vi.mock('../../audio/Audio', () => ({ audio: { play: vi.fn(), loop: vi.fn(() => () => undefined) } }));
vi.mock('../../graphics/fxTextures', () => ({
  fx: Object.fromEntries(['glow', 'smoke', 'disc', 'ring', 'cracks', 'sigil'].map((name) => [name, () => new THREE.Texture()])),
}));
vi.mock('../../graphics/fxImages', () => ({ fxImage: () => new THREE.Texture() }));

// ---------------------------------------------------------------------------------------------------------------------
// Rules
// ---------------------------------------------------------------------------------------------------------------------
describe('legendary rules', () => {
  it('guard 0 is exactly the old Bone Ward maths; the stack never reduces more than 75%', () => {
    expect(damageTakenMult(0.3, 0)).toBeCloseTo(0.7);
    expect(damageTakenMult(0.9, 0)).toBeCloseTo(0.4); // Bone Ward's own 60% cap
    expect(damageTakenMult(0.6, 0.25)).toBeCloseTo(0.3); // multiplicative: 0.4 * 0.75
    expect(damageTakenMult(0.6, 0.5)).toBeCloseTo(0.25); // would be 0.2: capped
    expect(damageTakenMult(0.6, 0.9)).toBeCloseTo(0.25);
  });

  it('colossus guard needs three thralls', () => {
    expect(colossusActive({ colossusGuard: 0.25 }, 2)).toBe(false);
    expect(colossusActive({ colossusGuard: 0.25 }, 3)).toBe(true);
    expect(colossusActive({ colossusGuard: 0 }, 9)).toBe(false);
  });

  it('reflects a share of what the ward alone prevented', () => {
    expect(wardReflectDamage(100, 0.4, 0.4)).toBeCloseTo(16);
    expect(wardReflectDamage(100, 0.9, 0.4)).toBeCloseTo(24); // ward capped at 60%
    expect(wardReflectDamage(100, 0, 0.4)).toBe(0);
    expect(wardReflectDamage(100, 0.4, 0)).toBe(0);
  });

  it('the sim clamps whatever a client claims, and defaults are all off', () => {
    expect(simLegendActive(simLegendOf(DISCIPLINES.ossuary.mods))).toBe(false);
    const c = clampSimLegend({ thrallDeathBurst: 99, championEvery: -4, spearRally: NaN, miasmaSpreadsWithered: 7, witheredBurstAt: 500 });
    expect(c).toEqual({ thrallDeathBurst: 2, championEvery: 0, spearRally: 0, miasmaSpreadsWithered: 1, witheredBurstAt: 12 });
    expect(effectiveWitheredCap({ witheredMaxStacks: 8, witheredBurstAt: 10 })).toBe(10);
    expect(effectiveWitheredCap({ witheredMaxStacks: 8, witheredBurstAt: 0 })).toBe(8);
  });
});

// ---------------------------------------------------------------------------------------------------------------------
// Player: soul rate, barrier shatter bookkeeping, guard
// ---------------------------------------------------------------------------------------------------------------------
const stats = { level: 10, maxHp: 100, spellPower: 20, maxEssence: 150, essenceRegen: 5, moveSpeed: 5.4, thrallHp: 45, thrallDamage: 8, damageBonusPct: 0 };

describe('Player legendary hooks', () => {
  it('soul harvest rate 2 fills in half the kills; 1 is untouched; fractions carry', () => {
    const a = new Player(stats, new Nav());
    let kills = 0;
    while (!a.addSouls(1)) kills++;
    expect(kills + 1).toBe(a.soulsMax);
    const b = new Player(stats, new Nav());
    b.soulRateMult = 2;
    kills = 0;
    while (!b.addSouls(1)) kills++;
    expect(kills + 1).toBe(b.soulsMax / 2);
    const c = new Player(stats, new Nav());
    c.soulRateMult = 1.5;
    for (let i = 0; i < 4; i++) c.addSouls(1);
    expect(c.souls).toBe(6);
  });

  it('reports the size of a Litany barrier that damage broke, not one that merely decayed', () => {
    const p = new Player(stats, new Nav());
    p.barrier = 30;
    p.barrierPeak = 50; // decayed from 50
    p.takeDamage(10, 0, 0);
    expect(p.barrierBroke).toBe(0);
    p.takeDamage(40, 0, 0);
    expect(p.barrierBroke).toBe(50);
    expect(p.barrierPeak).toBe(0);
    p.barrierBroke = 0;
    p.barrier = 20; // a Mantle barrier (no Litany peak) breaking reports nothing
    p.takeDamage(40, 0, 0);
    expect(p.barrierBroke).toBe(0);
  });

  it('takeDamage honours the guard and the 75% cap, and is unchanged at guard 0', () => {
    const p = new Player({ ...stats, maxHp: 1000 }, new Nav());
    expect(p.takeDamage(100, 0.6, 0)).toBeCloseTo(40);
    expect(p.takeDamage(100, 0.6, 0, undefined, undefined, 0.25)).toBeCloseTo(30);
    expect(p.takeDamage(100, 0.6, 0, undefined, undefined, 0.6)).toBeCloseTo(25);
  });
});

// ---------------------------------------------------------------------------------------------------------------------
// WorldSim mechanics
// ---------------------------------------------------------------------------------------------------------------------
function world() {
  const sim = new WorldSim(new Nav(), mulberry32(7));
  sim.setPlayer({ id: 'p1', x: 0, z: -16, alive: true, area: 'graves' });
  sim.step(0.016); // the opening wave
  sim.enemies.clear();
  return sim;
}
const legend = (sim: WorldSim, mods: Partial<SimLegend>) => sim.apply({ t: 'legend', by: 'p1', mods });
const foe = (sim: WorldSim, x: number, z: number, hp = 1e6) => {
  const e = sim.spawnEnemy('robber', 'graves', x, z, false, false);
  e.hp = e.maxHp = hp;
  e.stunT = 1e6; // stands where it is put
  return e;
};
function raise(sim: WorldSim, x = 0, z = -16, cap = 12) {
  sim.addCorpse(x, z, 'normal', 'robber', false, 0, 1, 'graves');
  const c = [...sim.corpses.values()].find((k: Corpse) => k.x === x && k.z === z)!;
  sim.apply({ t: 'exhume', by: 'p1', x: c.x, z: c.z, r: 1, kind: 'warrior', cap, hp: 50, damage: 5, attackSpeedMult: 1 });
  return [...sim.thralls.values()].at(-1)!;
}
const evOf = <T extends SimEvent['t']>(ev: SimEvent[], t: T) => ev.filter((e): e is Extract<SimEvent, { t: T }> => e.t === t);

describe('Legion of the Unburied (sim)', () => {
  it('a killed thrall bursts for thrallDeathBurst x its max HP; sacrificed and crumbled ones do not', () => {
    const sim = world();
    legend(sim, { thrallDeathBurst: 0.6 });
    const t = raise(sim);
    const near = foe(sim, t.x + 2, t.z);
    const far = foe(sim, t.x + 9, t.z);
    sim.killThrall(t, 'killed');
    expect(near.hp).toBeCloseTo(near.maxHp - 0.6 * 50, 4);
    expect(far.hp).toBe(far.maxHp);
    expect(evOf(sim.drain(), 'legend').some((e) => e.kind === 'deathBurst')).toBe(true);
    const t2 = raise(sim);
    const t3 = raise(sim);
    const before = near.hp;
    sim.killThrall(t2, 'sacrificed');
    sim.killThrall(t3, 'crumbled');
    expect(near.hp).toBe(before);
  });

  it('does nothing with the mod at 0', () => {
    const sim = world();
    const t = raise(sim);
    const e = foe(sim, t.x + 1, t.z);
    sim.killThrall(t, 'killed');
    expect(e.hp).toBe(e.maxHp);
    expect(evOf(sim.drain(), 'legend')).toHaveLength(0);
  });

  it('every 5th thrall raised is a Champion with double health and damage', () => {
    const sim = world();
    legend(sim, { championEvery: 5 });
    const made: Thrall[] = [];
    for (let i = 0; i < 10; i++) made.push(raise(sim, i * 0.5, -16));
    expect(made.map((t) => !!t.champion)).toEqual([false, false, false, false, true, false, false, false, false, true]);
    expect(made[4].maxHp).toBe(made[3].maxHp * LEGEND.championHp);
    expect(made[4].damage).toBe(made[3].damage * LEGEND.championDamage);
  });

  it('no Champions without the mod', () => {
    const sim = world();
    for (let i = 0; i < 6; i++) expect(raise(sim, i * 0.5, -16).champion).toBeUndefined();
  });

  it('a Marrow Spear hit rallies the legion onto the nearest struck enemy for +spearRally damage for 4 s', () => {
    const run = (spear: boolean, rally: number) => {
      const sim = world();
      if (rally) legend(sim, { spearRally: rally });
      const t = raise(sim, 0, -15);
      t.state = 'idle';
      const e = foe(sim, 1.5, -15, 1e9);
      const other = foe(sim, 6, -15, 1e9);
      sim.apply({ t: 'hit', by: 'p1', ids: [other.id, e.id], dmg: 1, ...(spear ? { spear: true } : {}) });
      const ev: SimEvent[] = [];
      for (let i = 0; i < 40 && !ev.some((x) => x.t === 'thrallHit'); i++) ev.push(...sim.step(0.05));
      return { t, e, other, hit: evOf(ev, 'thrallHit')[0], ev };
    };
    const base = run(false, 0.75);
    expect(base.e.markT).toBeUndefined();
    const marked = run(true, 0.75);
    expect(marked.e.markT).toBeGreaterThan(3.5);
    expect(marked.other.markT).toBeUndefined();
    expect(marked.t.target).toBe(marked.e.id);
    expect(marked.hit.target).toBe(marked.e.id);
    expect(marked.hit.dmg).toBeGreaterThanOrEqual(Math.round(marked.t.damage * 1.75) - 1);
    expect(base.hit.dmg).toBeLessThan(marked.hit.dmg);
    // The spear flag without the mod does nothing.
    expect(run(true, 0).e.markT).toBeUndefined();
  });
});

describe('Plague Choir (sim)', () => {
  const cloud = (sim: WorldSim, x: number, z: number, r = 2) => sim.apply({ t: 'miasma', by: 'p1', x, z, r, dps: 0, durationMs: 6000, witheredCap: 10, bloom: false });

  it('Contagion: an enemy dying in your Miasma passes its Withered to up to 3 neighbours within 4 m', () => {
    const sim = world();
    legend(sim, { miasmaSpreadsWithered: 1 });
    cloud(sim, 0, -10);
    const a = foe(sim, 0, -10, 1);
    a.withered = 4;
    a.witheredT = 5;
    a.witheredDps = 3;
    a.witheredOwner = 'p1';
    // Four neighbours around it (clear of the 2 m cloud and of each other), the 4th a little farther out.
    const ns = [[3, 0], [0, 3], [-3, 0], [0, -3.6]].map(([dx, dz]) => foe(sim, dx, -10 + dz));
    const outside = foe(sim, 12, -10);
    a.hp = 0;
    const ev = sim.step(0.016);
    const got = ns.filter((n) => n.withered >= 4);
    expect(got).toHaveLength(3);
    expect(ns.filter((n) => n.withered === 0)).toHaveLength(1);
    expect(outside.withered).toBe(0);
    expect(got.every((n) => n.witheredOwner === 'p1' && n.witheredDps >= 3)).toBe(true);
    expect(evOf(ev, 'legend').some((e) => e.kind === 'spread')).toBe(true);
  });

  it('Contagion needs the mod, and a death outside the Miasma spreads nothing', () => {
    const off = world();
    cloud(off, 0, -10);
    const a = foe(off, 0, -10, 1);
    Object.assign(a, { withered: 4, witheredT: 5, witheredDps: 3, witheredOwner: 'p1', hp: 0 });
    const n = foe(off, 3, -10);
    off.step(0.016);
    expect(n.withered).toBe(0);
    const on = world();
    legend(on, { miasmaSpreadsWithered: 1 });
    const b = foe(on, 0, -10, 1);
    Object.assign(b, { withered: 4, witheredT: 5, witheredDps: 3, witheredOwner: 'p1', hp: 0 });
    const m = foe(on, 3, -10);
    on.step(0.016);
    expect(m.withered).toBe(0);
  });

  it('Chain Plague: reaching witheredBurstAt consumes the stacks and opens a fresh Miasma on the enemy, 1 s cooldown, 4 clouds max', () => {
    const sim = world();
    legend(sim, { witheredBurstAt: 10 });
    cloud(sim, 20, -16, 3.3); // the real cast the burst copies
    const zones = () => [...sim.zones.values()].filter((z) => z.kind === 'miasma');
    expect(zones()).toHaveLength(1);
    const e = foe(sim, -8, -16);
    Object.assign(e, { withered: 10, witheredT: 5, witheredDps: 2, witheredOwner: 'p1' });
    const ev = sim.step(0.016);
    expect(e.withered).toBe(0);
    expect(zones()).toHaveLength(2);
    const z = zones().find((k) => k.x === -8)!;
    expect(z.r).toBe(3.3);
    expect(z.witheredCap).toBeGreaterThanOrEqual(10);
    expect(evOf(ev, 'legend').some((k) => k.kind === 'plague')).toBe(true);
    // Straight back to 10 stacks: the per-enemy cooldown holds it.
    Object.assign(e, { withered: 10, witheredT: 5, witheredOwner: 'p1' });
    sim.step(0.016);
    expect(e.withered).toBe(10);
    expect(zones()).toHaveLength(2);
    e.withered = 0;
    for (let i = 0; i < 21; i++) sim.step(0.05);
    Object.assign(e, { withered: 10, witheredT: 5, witheredOwner: 'p1' });
    sim.step(0.016);
    expect(e.withered).toBe(0);
  });

  it('Chain Plague never keeps more than 4 burst clouds alive', () => {
    const sim = world();
    legend(sim, { witheredBurstAt: 6 });
    const es = Array.from({ length: 9 }, (_, i) => foe(sim, -30 + i * 7, -16));
    for (const e of es) Object.assign(e, { withered: 6, witheredT: 5, witheredDps: 1, witheredOwner: 'p1' });
    for (let i = 0; i < 3; i++) sim.step(0.016);
    expect([...sim.zones.values()].filter((z) => z.kind === 'miasma')).toHaveLength(LEGEND.burstClouds);
  });

  it('no burst at all without the mod', () => {
    const sim = world();
    const e = foe(sim, 0, -10);
    Object.assign(e, { withered: 12, witheredT: 5, witheredDps: 1, witheredOwner: 'p1' });
    sim.step(0.016);
    expect(e.withered).toBe(12);
    expect(sim.zones.size).toBe(0);
  });
});

// ---------------------------------------------------------------------------------------------------------------------
// AbilitySystem (client-resolved mechanics)
// ---------------------------------------------------------------------------------------------------------------------
function setup(mods: Partial<DisciplineMods>, base: 'ossuary' | 'mourner' | 'gravecaller' | 'rotweaver' = 'mourner') {
  const p = new Player(stats, new Nav());
  p.essence = 150;
  const effects = new Effects(new THREE.Scene());
  const enemies = new Map<number, Enemy>();
  const thralls = new Map<number, Thrall>();
  const send = vi.fn();
  const number = vi.fn();
  const note = vi.fn();
  let now = 1000;
  const avatar = { tip: () => new THREE.Vector3(0, 1.4, 0), cast: vi.fn() };
  const discipline = { ...DISCIPLINES[base], mods: { ...DISCIPLINES[base].mods, ...mods } };
  const ctx = {
    selfId: 'solo', player: p, discipline, avatar, effects, enemies: () => enemies, boss: () => ({ active: false }), corpses: () => new Map(),
    thrallCount: () => thralls.size, thralls: () => thralls, send, number, note, shake: vi.fn(), now: () => now,
  } as unknown as AbilityContext;
  const abilities = new AbilitySystem(ctx);
  return { p, effects, enemies, thralls, send, number, note, abilities, advance: (ms: number) => (now += ms), at: () => now };
}
const foe2 = (id: number, x: number, z: number) => ({ id, x, z, state: 'move', radius: 0.4 }) as Enemy;

describe('Requiem of Wraiths (client)', () => {
  it('wisps: summoned per consumed corpse, capped at 3, 2% max HP per second each, gone after corpseWisp seconds', () => {
    const { p, abilities, advance, at } = setup({ corpseWisp: 8 });
    for (let i = 0; i < 5; i++) abilities.onCorpseConsumed();
    expect(abilities.wispCount).toBe(LEGEND.wispCap);
    p.hp = 10;
    advance(1000);
    abilities.update(at());
    expect(p.hp).toBeCloseTo(10 + 3 * 2, 5); // 3 wisps x 2% of 100
    advance(8000);
    abilities.update(at());
    expect(abilities.wispCount).toBe(0);
  });

  it('no wisps without the mod', () => {
    const { abilities } = setup({});
    abilities.onCorpseConsumed();
    expect(abilities.wispCount).toBe(0);
  });

  it('an empowered rite makes each wraith and wisp nova for wraithNova x spell power around itself', () => {
    const { p, abilities, enemies, thralls, send, number } = setup({ wraithNova: 0.8, corpseWisp: 8 });
    abilities.onCorpseConsumed(); // one wisp, orbiting the caster
    thralls.set(1, { id: 1, owner: 'solo', kind: 'wraith', x: 20, z: 0, state: 'idle' } as Thrall);
    enemies.set(1, foe2(1, 20.5, 1)); // by the wraith
    enemies.set(2, foe2(2, 1.0, 0.2)); // by the caster (the wisp)
    enemies.set(3, foe2(3, 40, 40)); // by nobody
    p.souls = p.soulsMax;
    expect(abilities.cast('miasma', { x: 12, z: 0 }, 1000)).toBe('ok');
    const hits = send.mock.calls.map((c) => c[0]).filter((i) => i.t === 'hit');
    const dmg = 20 * 0.8;
    expect(hits.some((h) => h.ids.includes(1) && Math.abs(h.dmg - dmg) < 1e-6)).toBe(true);
    expect(hits.flatMap((h) => h.ids)).not.toContain(3);
    expect(number).toHaveBeenCalled();
  });

  it('no nova when the cast is not empowered, or the mod is 0', () => {
    const a = setup({ wraithNova: 0.8 });
    a.thralls.set(1, { id: 1, owner: 'solo', kind: 'wraith', x: 0, z: 0, state: 'idle' } as Thrall);
    a.enemies.set(1, foe2(1, 1, 0));
    a.abilities.cast('miasma', { x: 12, z: 0 }, 1000);
    expect(a.send.mock.calls.some((c) => c[0].t === 'hit')).toBe(false);
    const b = setup({});
    b.thralls.set(1, { id: 1, owner: 'solo', kind: 'wraith', x: 0, z: 0, state: 'idle' } as Thrall);
    b.enemies.set(1, foe2(1, 1, 0));
    b.p.souls = b.p.soulsMax;
    b.abilities.cast('miasma', { x: 12, z: 0 }, 1000);
    expect(b.send.mock.calls.some((c) => c[0].t === 'hit')).toBe(false);
  });
});

describe('Colossus Mantle (client)', () => {
  it('Litany Shatter hits enemies within 4 m for litanyShatter x the barrier size', () => {
    const { abilities, enemies, send } = setup({ litanyShatter: 3 }, 'ossuary');
    enemies.set(1, foe2(1, 3, 0));
    enemies.set(2, foe2(2, 9, 0));
    abilities.litanyShatter(40);
    const hit = send.mock.calls[0][0];
    expect(hit).toMatchObject({ t: 'hit', ids: [1], dmg: 120 });
  });

  it('Litany Shatter is silent at 0', () => {
    const { abilities, enemies, send } = setup({}, 'ossuary');
    enemies.set(1, foe2(1, 3, 0));
    abilities.litanyShatter(40);
    expect(send).not.toHaveBeenCalled();
  });

  it('Bone Ward reflect strikes the enemy at the blow origin for wardReflect x what the ward prevented', () => {
    const { abilities, enemies, send } = setup({ wardReflect: 0.4 }, 'ossuary');
    enemies.set(1, foe2(1, 5, 5));
    enemies.set(2, foe2(2, 9, 9));
    abilities.reflectWard(100, 0.4, 5.1, 5);
    expect(send.mock.calls[0][0]).toMatchObject({ t: 'hit', ids: [1] });
    expect(send.mock.calls[0][0].dmg).toBeCloseTo(16);
    send.mockClear();
    abilities.reflectWard(100, 0.4, 20, 20); // a zone, nobody there
    expect(send).not.toHaveBeenCalled();
  });
});

describe('Marrow Spear flags the rally only with the mod', () => {
  const cast = (mods: Partial<DisciplineMods>) => {
    const t = setup(mods, 'gravecaller');
    t.enemies.set(1, foe2(1, 6, 0));
    expect(t.abilities.cast('marrow_spear', { x: 12, z: 0 }, 1000)).toBe('ok');
    const camera = new THREE.PerspectiveCamera();
    for (let i = 0; i < 40; i++) t.effects.update(0.01, camera, 720);
    return t.send.mock.calls.map((c) => c[0]).find((i) => i.t === 'hit');
  };
  it('sends spear:true with spearRally, and the old intent without', () => {
    expect(cast({ spearRally: 0.75 })).toMatchObject({ t: 'hit', ids: [1], spear: true });
    const plain = cast({});
    expect(plain).toMatchObject({ t: 'hit', ids: [1] });
    expect(plain).not.toHaveProperty('spear');
  });
});
