import * as THREE from 'three';
import { describe, expect, it, vi } from 'vitest';
import { Nav } from '../nav';
import { WorldSim } from '../sim/WorldSim';
import { WorldMirror, makeSnapshot } from '../sim/snapshot';
import { mulberry32 } from '../rng';
import type { Corpse, Enemy, SimEvent } from '../sim/types';
import { AbilitySystem, veilTarget, type AbilityContext } from '../AbilitySystem';
import { Player } from '../Player';
import { Effects } from '../../graphics/Effects';
import { DISCIPLINES } from '../../content/disciplines';
import { BONE_FAN, CARRION_SEED, RALLY, ROT_LANCE } from '../../content/abilities';
import { AREAS, DOORS } from '../../content/areas';
import { selectAutoCombatAction } from '../autoCombat';

vi.mock('../../audio/Audio', () => ({ audio: { play: vi.fn() } }));
vi.mock('../../graphics/fxTextures', () => ({
  fx: Object.fromEntries(['glow', 'smoke', 'disc', 'ring', 'cracks', 'sigil'].map((name) => [name, () => new THREE.Texture()])),
}));
vi.mock('../../graphics/fxImages', () => ({ fxImage: () => new THREE.Texture() }));

// --- host ---------------------------------------------------------------------

function world(seed = 1) {
  const nav = new Nav();
  const sim = new WorldSim(nav, mulberry32(seed));
  sim.setPlayer({ id: 'p1', x: 0, z: -16, alive: true, area: 'graves' });
  return { nav, sim };
}
function corpse(sim: WorldSim, x: number, z: number, kind: Corpse['kind'] = 'normal', elite = false): Corpse {
  const enemy = kind === 'resonant' ? 'penitent' : kind === 'toxic' ? 'sac' : 'robber';
  sim.addCorpse(x, z, kind, enemy, elite, 0, 1, 'graves');
  return [...sim.corpses.values()].find((c) => c.x === x && c.z === z)!;
}
const of = <T extends SimEvent['t']>(ev: SimEvent[], t: T) => ev.filter((e): e is Extract<SimEvent, { t: T }> => e.t === t);
const sig = (s: 'offering' | 'rally' | 'seed', x: number, z: number, extra = {}) => ({ t: 'signature', by: 'p1', sig: s, x, z, dx: 0, dz: 0, sp: 100, ...extra }) as const;

describe('spell variety on the host', () => {
  it('Rot Lance hits add one Withered stack, capped by the (clamped) claim', () => {
    const { sim } = world();
    const e = sim.spawnEnemy('robber', 'graves', 2, -16, false);
    for (let i = 0; i < 5; i++) sim.apply({ t: 'hit', by: 'p1', ids: [e.id], dmg: 1, withered: 3, witheredCap: 3 });
    expect(e.withered).toBe(3);
    expect(e.witheredOwner).toBe('p1');
    sim.apply({ t: 'hit', by: 'p1', ids: [e.id], dmg: 1, withered: 1, witheredCap: 999 });
    expect(e.withered).toBe(4);
  });

  it('Grave Offering consumes the corpse exactly once', () => {
    const { sim } = world();
    corpse(sim, 1, -16, 'resonant', true);
    sim.drain();
    sim.apply(sig('offering', 1.3, -16));
    const ev = sim.drain();
    expect(of(ev, 'corpseGone')).toHaveLength(1);
    expect(of(ev, 'offering')[0]).toMatchObject({ ok: true, corpseKind: 'resonant', elite: true });
    sim.apply(sig('offering', 1.3, -16));
    const again = sim.drain();
    expect(of(again, 'corpseGone')).toHaveLength(0);
    expect(of(again, 'offering')[0].ok).toBe(false);
  });

  it('Rally with no thralls rallies nobody; with thralls it buffs, heals, focuses and shows in snapshots', () => {
    const { sim } = world();
    sim.apply(sig('rally', 0, -18));
    expect(of(sim.drain(), 'rally')[0].ids).toEqual([]);
    corpse(sim, 0.5, -16);
    sim.apply({ t: 'exhume', by: 'p1', x: 0.5, z: -16, r: 1, kind: 'warrior', cap: 3, hp: 50, damage: 5, attackSpeedMult: 1 });
    const th = [...sim.thralls.values()][0];
    th.hp = 10;
    const foe = sim.spawnEnemy('robber', 'graves', 3, -18, false);
    foe.state = 'move';
    sim.apply(sig('rally', 3, -18, { dur: 99 }));
    const ev = of(sim.drain(), 'rally')[0];
    expect(ev.ids).toEqual([th.id]);
    expect(th.rallyT).toBe(RALLY.durationS + RALLY.gravecallerBonusS);
    expect(th.hp).toBe(10 + th.maxHp * RALLY.healFrac);
    expect(th.target).toBe(foe.id);
    const mirror = new WorldMirror();
    mirror.applySnapshot(makeSnapshot(sim, false));
    expect(mirror.thralls.get(th.id)!.rallyT).toBeGreaterThan(0);
  });

  it('Carrion Seed arms, bursts once when an enemy comes close, and one seed per caster', () => {
    const { sim } = world();
    const a = corpse(sim, -4, -16);
    const b = corpse(sim, 4, -16);
    sim.drain();
    sim.apply(sig('seed', -4, -16, { cap: 40 }));
    expect(of(sim.drain(), 'seeded')[0]).toMatchObject({ corpseId: a.id });
    expect(a.seedCap).toBe(12);
    // A new seed withers the old one harmlessly.
    sim.apply(sig('seed', 4, -16));
    const swap = sim.drain();
    expect(of(swap, 'seedGone')[0].corpseId).toBe(a.id);
    expect(a.seedOwner).toBeUndefined();
    expect(b.seedOwner).toBe('p1');
    // An enemy walks up before it arms: nothing; after arming: one burst.
    const e = sim.spawnEnemy('robber', 'graves', 4.5, -16, false);
    e.state = 'move';
    sim.step(0.1);
    expect(sim.corpses.has(b.id)).toBe(true);
    let burst: SimEvent[] = [];
    for (let t = 0; t < 1 && !of(burst, 'seedBurst').length; t += 0.1) burst = sim.step(0.1);
    expect(of(burst, 'seedBurst')).toHaveLength(1);
    expect(sim.corpses.has(b.id)).toBe(false);
    expect(e.withered).toBeGreaterThanOrEqual(CARRION_SEED.withered);
  });

  it('an unarmed seed withers away after its life', () => {
    const { sim } = world();
    const c = corpse(sim, -4, -20);
    sim.apply(sig('seed', -4, -20));
    sim.drain();
    // Nobody fighting here, so no wave walks into the seed.
    sim.setPlayer({ id: 'p1', x: 0, z: -16, alive: false, area: null });
    let gone: SimEvent[] = [];
    for (let t = 0; t < CARRION_SEED.lifeS + 1 && !of(gone, 'seedGone').length; t += 0.5) gone = sim.step(0.5);
    expect(of(gone, 'seedGone')[0].corpseId).toBe(c.id);
    expect(c.seedOwner).toBeUndefined();
    expect(sim.corpses.has(c.id)).toBe(true);
  });
});

// --- client -------------------------------------------------------------------

function client(overrides: Partial<AbilityContext> = {}) {
  const p = new Player({ level: 12, maxHp: 100, spellPower: 20, maxEssence: 150, essenceRegen: 5, moveSpeed: 5.4, thrallHp: 45, thrallDamage: 8, damageBonusPct: 0 }, new Nav());
  p.essence = 100;
  const effects = new Effects(new THREE.Scene());
  const enemies = new Map<number, Enemy>();
  const send = vi.fn();
  let boss = { active: false } as { active: boolean; x?: number; z?: number };
  const ctx = {
    selfId: 'solo', player: p, discipline: DISCIPLINES.ossuary, avatar: { tip: () => new THREE.Vector3(0, 1.4, 0), cast: vi.fn() }, effects,
    enemies: () => enemies, boss: () => boss, corpses: () => new Map(),
    thrallCount: () => 0, send, number: vi.fn(), shake: vi.fn(), now: () => 1000,
    ...overrides,
  } as unknown as AbilityContext;
  const abilities = new AbilitySystem(ctx);
  const camera = new THREE.PerspectiveCamera();
  const step = (seconds: number) => {
    for (let i = 0; i < Math.ceil(seconds / 0.01); i++) effects.update(0.01, camera, 720);
  };
  return { p, enemies, send, abilities, step, setBoss: (b: typeof boss) => (boss = b) };
}
const foe = (id: number, x: number, z: number): Enemy => ({ id, x, z, state: 'move', radius: 0.4 }) as Enemy;

describe('spell variety casts', () => {
  it('Bone Fan sends each sliver to a distinct enemy and caps the essence refund', () => {
    const { p, enemies, send, abilities, step } = client();
    enemies.set(1, foe(1, 0, 6));
    enemies.set(2, foe(2, 0.8, 6.2));
    enemies.set(3, foe(3, -0.8, 6.2));
    enemies.set(4, foe(4, 6, 0)); // outside the cone
    const before = p.essence;
    expect(abilities.cast('bone_fan', { x: 0, z: 6, enemyId: 1 }, 1000)).toBe('ok');
    step(1);
    const ids = send.mock.calls.map((c) => c[0].ids[0]).sort();
    expect(ids).toEqual([1, 2, 3]);
    expect(p.essence - before).toBe(BONE_FAN.essenceCap);
  });

  it('Bone Fan hits the Prelate with one sliver only', () => {
    const { send, abilities, step, setBoss } = client();
    setBoss({ active: true, x: 0, z: 6 });
    expect(abilities.cast('bone_fan', { x: 0, z: 6, boss: true }, 1000)).toBe('ok');
    step(1);
    expect(send.mock.calls.filter((c) => c[0].boss)).toHaveLength(1);
  });

  it('Rot Lance pierces only the first two in line and asks for Withered', () => {
    const { enemies, send, abilities, step } = client();
    enemies.set(1, foe(1, 0, 3));
    enemies.set(2, foe(2, 0, 6));
    enemies.set(3, foe(3, 0, 9));
    expect(abilities.cast('rot_lance', { x: 0, z: 3, enemyId: 1 }, 1000)).toBe('ok');
    step(1);
    expect(send).toHaveBeenCalledTimes(1);
    expect(send.mock.calls[0][0]).toMatchObject({ ids: [1, 2], withered: ROT_LANCE.withered });
  });

  it('failed casts spend nothing: Offering without a corpse, Rally without thralls', () => {
    const { p, send, abilities } = client();
    const before = p.essence;
    expect(abilities.cast('grave_offering', { x: 3, z: 3 }, 1000)).toBe('no_corpse');
    expect(abilities.cast('rally_dead', { x: 3, z: 3 }, 1000)).toBe('no_thralls');
    expect(abilities.cast('carrion_seed', { x: 3, z: 3 }, 1000)).toBe('no_corpse');
    expect(p.essence).toBe(before);
    expect(p.onCooldown('rally_dead', 1001)).toBe(false);
    expect(send).not.toHaveBeenCalled();
  });

  it('Ivory Cleave cuts the arc in front, not behind, and Fractures', () => {
    const { enemies, send, abilities } = client();
    enemies.set(1, foe(1, 0, 2));
    enemies.set(2, foe(2, 1.5, 1.5));
    enemies.set(3, foe(3, 0, -2)); // behind
    enemies.set(4, foe(4, 0, 6)); // too far
    expect(abilities.cast('ivory_cleave', { x: 0, z: 5 }, 1000)).toBe('ok');
    expect(send.mock.calls[0][0]).toMatchObject({ ids: [1, 2], fracture: 1 });
  });
});

describe('Veil Step', () => {
  it('stops before a sealed door and never leaves the hall', () => {
    const nav = new Nav();
    nav.setUnlocked(['chapterhouse', 'graves', 'acre']);
    const door = DOORS.find((d) => d.id === 'graves_nave')!;
    // Stand in the Graves just south of the sealed Nave door and dash north through it.
    const x = (door.rect.x0 + door.rect.x1) / 2;
    const z = AREAS.graves.rect.z0 + 2;
    const to = veilTarget(nav, x, z, x, z - 5.5);
    expect(nav.areaAt(to.x, to.z)).toBe('graves');
    expect(to.z).toBeGreaterThanOrEqual(AREAS.graves.rect.z0);
  });

  it('goes the full distance on open ground', () => {
    const nav = new Nav();
    const to = veilTarget(nav, 0, -16, 5.5, -16);
    expect(to.x).toBeCloseTo(5.5, 5);
  });
});

describe('auto combat with the new rites', () => {
  const base = (over: Partial<Parameters<typeof selectAutoCombatAction>[0]> = {}) => ({
    player: { x: 0, z: 0, essence: 100, maxEssence: 150 },
    enemies: [foe(1, 0, 3)],
    corpses: [],
    boss: { active: false } as never,
    thrallCount: 0,
    thrallCap: 3,
    ready: () => true,
    ...over,
  });

  it('never casts Veil Step', () => {
    for (let i = 0; i < 5; i++) expect(selectAutoCombatAction(base())?.id).not.toBe('veil_step');
  });

  it('offers a corpse only when essence is low and the legion is full', () => {
    const body = { id: 9, x: 1, z: 1, kind: 'normal' } as Corpse;
    const full = selectAutoCombatAction(base({ player: { x: 0, z: 0, essence: 20, maxEssence: 150 }, corpses: [body], thrallCount: 3, ready: (id) => id === 'grave_offering' }));
    expect(full?.id).toBe('grave_offering');
    const room = selectAutoCombatAction(base({ player: { x: 0, z: 0, essence: 20, maxEssence: 150 }, corpses: [body], thrallCount: 1, ready: (id) => id === 'grave_offering' }));
    expect(room?.id).not.toBe('grave_offering');
  });

  it('uses the equipped primary instead of Bone Needle', () => {
    const act = selectAutoCombatAction(base({ player: { x: 0, z: 0, essence: 10, maxEssence: 150 }, primary: 'rot_lance', ready: (id) => id === 'rot_lance' }));
    expect(act?.id).toBe('rot_lance');
  });
});
