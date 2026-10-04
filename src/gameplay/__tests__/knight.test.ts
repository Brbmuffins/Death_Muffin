import * as THREE from 'three';
import { describe, expect, it, vi } from 'vitest';
import { Nav } from '../nav';
import { WorldSim } from '../sim/WorldSim';
import { mulberry32 } from '../rng';
import type { Corpse, Enemy, SimEvent } from '../sim/types';
import { AbilitySystem, type AbilityContext } from '../AbilitySystem';
import { Player } from '../Player';
import { Effects } from '../../graphics/Effects';
import { DISCIPLINES } from '../../content/disciplines';
import { kitFor } from '../../content/kits';
import {
  ABILITIES,
  BULWARK,
  CORPSE_VIGIL,
  GRAVE_BRAND,
  GRAVE_SLAM,
  HOLLOW_CUT,
  KNIGHT_RAGE,
  OATH_UNBROKEN,
  SHIELD_BASH,
} from '../../content/abilities';

vi.mock('../../audio/Audio', () => ({ audio: { play: vi.fn(), loop: vi.fn(() => () => undefined) } }));
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
function corpse(sim: WorldSim, x: number, z: number): Corpse {
  sim.addCorpse(x, z, 'normal', 'robber', false, 0, 1, 'graves');
  return [...sim.corpses.values()].find((c) => c.x === x && c.z === z)!;
}
const of = <T extends SimEvent['t']>(ev: SimEvent[], t: T) => ev.filter((e): e is Extract<SimEvent, { t: T }> => e.t === t);
const sig = (s: 'bash' | 'vigil' | 'brand', x: number, z: number, extra = {}) =>
  ({ t: 'signature', by: 'p1', sig: s, x, z, dx: 0, dz: 1, sp: 100, ...extra }) as const;

describe('Hollow Knight on the host', () => {
  it('Shield Bash stuns the first body along the charge and nothing behind it', () => {
    const { sim } = world();
    const near = sim.spawnEnemy('robber', 'graves', 0, -14, false);
    const far = sim.spawnEnemy('robber', 'graves', 0, -13.5, false);
    // A rising body is deliberately not bashable (same rule as Rally): stand
    // them up without letting them walk.
    near.state = 'move';
    far.state = 'move';
    sim.apply(sig('bash', 0, -16));
    const ev = sim.drain();
    expect(of(ev, 'bash')[0].id).toBe(near.id);
    expect(near.stunT).toBeCloseTo(SHIELD_BASH.stunS, 5);
    expect(far.stunT ?? 0).toBe(0);
  });

  it('a charge into empty air reports no body and stuns nobody', () => {
    const { sim } = world();
    const aside = sim.spawnEnemy('robber', 'graves', 9, -16, false);
    aside.state = 'move';
    sim.apply(sig('bash', 0, -16));
    expect(of(sim.drain(), 'bash')[0].id).toBeNull();
    expect(aside.stunT ?? 0).toBe(0);
  });

  it('Shield Bash damages and briefly staggers the boss when it is the first body hit', () => {
    const { sim } = world();
    sim.setPlayer({ id: 'p1', x: 0, z: -117, alive: true, area: 'sanctum' });
    sim.boss.awaken('p1');
    const boss = sim.boss.state;
    boss.z = -121;
    const hp = boss.hp;
    sim.drain();
    sim.apply(sig('bash', 0, -117, { dz: -1 }));
    expect(boss.hp).toBeLessThan(hp);
    expect(of(sim.drain(), 'bash')).toMatchObject([{ x: 0, z: -121, id: null }]);
    sim.step(SHIELD_BASH.bossStunS / 2);
    expect(boss.z).toBe(-121);
    sim.step(SHIELD_BASH.bossStunS);
    expect(boss.z).toBeGreaterThan(-121);
  });

  it('a stunned body neither acts nor moves, and its windup is cancelled', () => {
    const { sim } = world();
    const e = sim.spawnEnemy('robber', 'graves', 0.5, -15.5, false);
    e.state = 'windup';
    e.stateT = 0;
    e.stunT = 1;
    // Soft body separation still shoves a stunned body around, so the invariant
    // is that it stops *pursuing*: it may not close on the player.
    const before = Math.hypot(e.x - 0, e.z - -16);
    sim.step(0.2);
    expect(e.state).toBe('recover');
    expect(Math.hypot(e.x - 0, e.z - -16)).toBeGreaterThanOrEqual(before - 1e-9);
  });

  it('Corpse Vigil spends exactly one corpse, and reports failure when there is none', () => {
    const { sim } = world();
    const c = corpse(sim, 0.4, -16);
    sim.apply(sig('vigil', 0.4, -16));
    const ev = sim.drain();
    expect(of(ev, 'vigil')[0].ok).toBe(true);
    expect(sim.corpses.has(c.id)).toBe(false);
    // A second vigil over the same spot has nothing left to spend.
    sim.apply(sig('vigil', 0.4, -16));
    expect(of(sim.drain(), 'vigil')[0].ok).toBe(false);
  });

  it('Grave Brand spends the corpse to arm, then roots the first body that reaches it', () => {
    const { sim } = world();
    const c = corpse(sim, 2, -16);
    sim.apply(sig('brand', 2, -16));
    const armed = of(sim.drain(), 'brand')[0];
    expect(armed.ok).toBe(true);
    expect(armed.sprung).toBe(false);
    expect(sim.corpses.has(c.id)).toBe(false);
    expect(sim.brands.size).toBe(1);
    // A body standing on the brand springs it once.
    const e = sim.spawnEnemy('robber', 'graves', 2, -16, false);
    e.state = 'move';
    const ev = sim.step(0.1);
    expect(of(ev, 'brand')[0].sprung).toBe(true);
    // The step that sprang it also ticked one frame of decay off the root.
    expect(e.rootT).toBeGreaterThan(GRAVE_BRAND.rootS - 0.2);
    expect(e.rootT).toBeLessThanOrEqual(GRAVE_BRAND.rootS);
    expect(sim.brands.size).toBe(0);
  });

  it('a rooted body cannot move but is not disarmed', () => {
    const { sim } = world();
    const e = sim.spawnEnemy('robber', 'graves', 3, -16, false);
    e.state = 'move';
    e.rootT = 1;
    const before = Math.hypot(e.x - 0, e.z - -16);
    sim.step(0.3);
    expect(Math.hypot(e.x - 0, e.z - -16)).toBeGreaterThanOrEqual(before - 1e-9);
    // Unlike a stun, a root leaves its state machine running.
    expect(e.state).not.toBe('recover');
  });

  it('a brand with no corpse under it arms nothing', () => {
    const { sim } = world();
    sim.apply(sig('brand', 5, -16));
    expect(of(sim.drain(), 'brand')[0].ok).toBe(false);
    expect(sim.brands.size).toBe(0);
  });
});

// --- client -------------------------------------------------------------------

function knight(overrides: Partial<AbilityContext> = {}) {
  const p = new Player(
    { level: 12, maxHp: 100, spellPower: 20, maxEssence: 150, essenceRegen: 5, moveSpeed: 5.4, thrallHp: 45, thrallDamage: 8, damageBonusPct: 0 },
    new Nav(),
    'knight',
  );
  const effects = new Effects(new THREE.Scene());
  const enemies = new Map<number, Enemy>();
  const send = vi.fn();
  let now = 1000;
  const ctx = {
    selfId: 'solo', player: p, discipline: DISCIPLINES.hollow_knight,
    avatar: { tip: () => new THREE.Vector3(0, 1.4, 0), cast: vi.fn() }, effects,
    enemies: () => enemies, boss: () => ({ active: false }), corpses: () => new Map(),
    thrallCount: () => 0, send, number: vi.fn(), shake: vi.fn(), now: () => now,
    dash: (x: number, z: number) => ({ x, z }),
    ...overrides,
  } as unknown as AbilityContext;
  const abilities = new AbilitySystem(ctx);
  const camera = new THREE.PerspectiveCamera();
  const step = (seconds: number) => {
    for (let i = 0; i < Math.ceil(seconds / 0.01); i++) effects.update(0.01, camera, 720);
  };
  return { p, enemies, send, abilities, step, setNow: (t: number) => (now = t), get now() { return now; } };
}
const foe = (id: number, x: number, z: number): Enemy => ({ id, x, z, state: 'move', radius: 0.4 }) as Enemy;

describe('Hollow Knight kit', () => {
  it('plays Rage, not Grave Essence, and its own seven rites', () => {
    const kit = kitFor('knight');
    const { p } = knight();
    expect(p.resource.kind).toBe('rage');
    expect(p.resource.max).toBe(KNIGHT_RAGE.max);
    expect(kit.defaultPrimary).toBe('hollow_cut');
    expect(kit.rmb).toBe('grave_brand');
    expect(kit.signatures.hollow_knight).toBe('oath_unbroken');
    // No necromancer rite is reachable from the Knight's Grimoire.
    for (const id of kit.grimoire) expect(['shield_bash', 'grave_slam', 'bulwark', 'corpse_vigil']).toContain(id);
  });

  it('Hollow Cut pays Rage for every body in the arc and none outside it', () => {
    const { p, enemies, send, abilities, step } = knight();
    enemies.set(1, foe(1, 0, 1.5));
    enemies.set(2, foe(2, 0.7, 1.6));
    enemies.set(3, foe(3, 0, 9)); // beyond reach
    enemies.set(4, foe(4, 0, -2)); // behind
    expect(abilities.cast('hollow_cut', { x: 0, z: 2 }, 1000)).toBe('ok');
    step(0.5);
    const ids = send.mock.calls.flatMap((c) => c[0].ids).sort();
    expect(ids).toEqual([1, 2]);
    expect(p.resource.value).toBe(HOLLOW_CUT.rage * 2);
  });

  it('Hollow Cut costs nothing, so it works on an empty Rage bar', () => {
    const { p, enemies, abilities } = knight();
    enemies.set(1, foe(1, 0, 1.5));
    p.resource.value = 0;
    expect(ABILITIES.hollow_cut.essenceCost).toBe(0);
    expect(abilities.cast('hollow_cut', { x: 0, z: 2 }, 1000)).toBe('ok');
  });

  it('Grave Slam spends its Rage exactly once and refuses when short', () => {
    const { p, abilities } = knight();
    p.resource.value = ABILITIES.grave_slam.essenceCost - 1;
    expect(abilities.cast('grave_slam', { x: 0, z: 5 }, 1000)).toBe('essence');
    expect(p.resource.value).toBe(ABILITIES.grave_slam.essenceCost - 1);
    p.resource.value = 100;
    expect(abilities.cast('grave_slam', { x: 0, z: 5 }, 1000)).toBe('ok');
    expect(p.resource.value).toBe(100 - ABILITIES.grave_slam.essenceCost);
  });

  it('a failed cast spends no Rage and starts no cooldown', () => {
    const { p, abilities } = knight();
    p.resource.value = 100;
    // Slam onto your own feet: no direction to leap.
    expect(abilities.cast('grave_slam', { x: 0, z: 0 }, 1000)).toBe('no_target');
    expect(p.resource.value).toBe(100);
    expect(p.onCooldown('grave_slam', 1000)).toBe(false);
  });

  it('Grave Slam lands its damage on arrival, not on cast', () => {
    const { p, enemies, send, abilities, setNow } = knight();
    p.resource.value = 100;
    enemies.set(1, foe(1, 0, 5));
    expect(abilities.cast('grave_slam', { x: 0, z: 5 }, 1000)).toBe('ok');
    expect(send.mock.calls.filter((c) => c[0].t === 'hit')).toHaveLength(0);
    setNow(1000 + GRAVE_SLAM.durationS * 1000 + 50);
    abilities.update(1000 + GRAVE_SLAM.durationS * 1000 + 50);
    expect(send.mock.calls.filter((c) => c[0].t === 'hit')[0][0].ids).toEqual([1]);
  });

  it('Corpse Vigil and Grave Brand refuse without a corpse and send nothing', () => {
    const { abilities, send } = knight();
    expect(abilities.cast('corpse_vigil', { x: 0, z: 1 }, 1000)).toBe('no_corpse');
    expect(abilities.cast('grave_brand', { x: 0, z: 1 }, 1000)).toBe('no_corpse');
    expect(send).not.toHaveBeenCalled();
  });

  it('Bulwark cuts frontal damage, pays Rage on a perfect block, and ignores the back', () => {
    const { p, abilities } = knight();
    expect(abilities.cast('bulwark', { x: 0, z: 1 }, 1000)).toBe('ok');
    p.face(0, 1); // facing +z
    // Inside the perfect window, from the front.
    const taken = p.takeDamage(100, 0, 1000, { x: 0, z: 5 });
    expect(taken).toBeCloseTo(100 * (1 - BULWARK.damageCut), 5);
    expect(p.lastBlock).toBe('perfect');
    expect(p.resource.value).toBeGreaterThanOrEqual(KNIGHT_RAGE.perPerfectBlock);
    // After the window but still guarded: mitigated, not perfect.
    const late = 1000 + BULWARK.perfectWindowS * 1000 + 10;
    p.hp = 100;
    expect(p.takeDamage(100, 0, late, { x: 0, z: 5 })).toBeCloseTo(100 * (1 - BULWARK.damageCut), 5);
    expect(p.lastBlock).toBe('front');
    // From behind: the shield does nothing.
    p.hp = 100;
    expect(p.takeDamage(100, 0, late, { x: 0, z: -5 })).toBeCloseTo(100, 5);
    expect(p.lastBlock).toBe('none');
  });

  it('damage taken builds Rage in proportion to the health lost', () => {
    const { p } = knight();
    p.resource.value = 0;
    p.takeDamage(20, 0, 1000); // 20% of 100 max HP
    expect(p.resource.value).toBeCloseTo(20 * KNIGHT_RAGE.perHpPercentLost, 5);
  });

  it('Oath Unbroken holds at 1 health, fills Rage, and expires', () => {
    const { p, abilities, setNow } = knight();
    p.resource.value = 0;
    expect(abilities.cast('oath_unbroken', { x: 0, z: 0 }, 1000)).toBe('ok');
    expect(p.resource.value).toBe(p.resource.max);
    p.takeDamage(1e6, 0, 1100);
    expect(p.alive).toBe(true);
    expect(p.hp).toBe(1);
    // Once the oath lapses the same blow kills.
    setNow(1000 + OATH_UNBROKEN.durationS * 1000 + 100);
    p.takeDamage(1e6, 0, 1000 + OATH_UNBROKEN.durationS * 1000 + 100);
    expect(p.alive).toBe(false);
  });

  it('Corpse Vigil regenerates for its duration and then stops', () => {
    const { p, abilities, setNow } = knight();
    p.hp = 50;
    abilities.onVigil({ x: 0, z: 1, ok: true }, true, () => ({ x: 0, z: 0 }));
    setNow(1500);
    abilities.update(1500);
    const healed = p.hp;
    expect(healed).toBeGreaterThan(50);
    // Past the window, no more regeneration from the vigil.
    setNow(1000 + CORPSE_VIGIL.durationS * 1000 + 500);
    abilities.update(1000 + CORPSE_VIGIL.durationS * 1000 + 500);
    const after = p.hp;
    setNow(1000 + CORPSE_VIGIL.durationS * 1000 + 1500);
    abilities.update(1000 + CORPSE_VIGIL.durationS * 1000 + 1500);
    expect(p.hp).toBeCloseTo(after, 5);
  });

  it('the necromancer never sees a Knight guard', () => {
    const p = new Player(
      { level: 12, maxHp: 100, spellPower: 20, maxEssence: 150, essenceRegen: 5, moveSpeed: 5.4, thrallHp: 45, thrallDamage: 8, damageBonusPct: 0 },
      new Nav(),
    );
    p.resource.value = 0;
    p.takeDamage(20, 0, 1000, { x: 0, z: 5 });
    expect(p.lastBlock).toBe('none');
    // Essence does not grow from being hit.
    expect(p.essence).toBe(0);
  });
});
