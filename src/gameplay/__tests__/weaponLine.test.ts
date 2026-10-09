import * as THREE from 'three';
import { describe, expect, it, vi } from 'vitest';
import { Nav } from '../nav';
import { AbilitySystem, type AbilityContext } from '../AbilitySystem';
import { Player } from '../Player';
import { Effects } from '../../graphics/Effects';
import { DISCIPLINES } from '../../../server/rules/content/disciplines';
import { ABILITIES } from '../../content/abilities';
import { CAST_FLOW } from '../../content/combatFlow';
import { NECRO_WEAPON_TUNING as T } from '../../../server/rules/content/necroWeapons';
import type { Enemy } from '../sim/types';
import { WorldSim } from '../sim/WorldSim';
import { mulberry32 } from '../rng';
import { deriveStats } from '../characterStats';
import { abilityCooldownMs, abilityLockMs, abilityRange, pierceTargets, reapTargets, resolveWeaponLoadout, NO_LOADOUT } from '../weaponLine';
import type { InventorySlot } from '../../net/types';
import { selectAutoCombatAction } from '../autoCombat';

vi.mock('../../audio/Audio', () => ({ audio: { play: vi.fn(), loop: vi.fn(() => () => undefined) } }));
vi.mock('../../graphics/fxTextures', () => ({
  fx: Object.fromEntries(['glow', 'smoke', 'disc', 'ring', 'cracks', 'sigil'].map((name) => [name, () => new THREE.Texture()])),
}));
vi.mock('../../graphics/fxImages', () => ({ fxImage: () => new THREE.Texture() }));

const worn = (main?: string, off?: string) => ({ main_hand: main ? { item_id: main } : undefined, off_hand: off ? { item_id: off } : undefined });
const loadout = (main?: string, off?: string, disc = 'gravecaller') => resolveWeaponLoadout(worn(main, off), disc);

function client(main?: string, off?: string, disc: keyof typeof DISCIPLINES = 'gravecaller') {
  const p = new Player({ level: 12, maxHp: 100, spellPower: 20, maxEssence: 150, essenceRegen: 5, moveSpeed: 5.4, thrallHp: 45, thrallDamage: 8, damageBonusPct: 0 }, new Nav());
  p.essence = 100;
  p.loadout = loadout(main, off, disc);
  const effects = new Effects(new THREE.Scene());
  const enemies = new Map<number, Enemy>();
  const send = vi.fn();
  let clock = 1000;
  const ctx = {
    selfId: 'solo', player: p, discipline: DISCIPLINES[disc], avatar: { tip: () => new THREE.Vector3(0, 1.4, 0), cast: vi.fn() }, effects,
    enemies: () => enemies, boss: () => ({ active: false }), corpses: () => new Map(),
    thrallCount: () => 0, send, number: vi.fn(), shake: vi.fn(), now: () => clock,
  } as unknown as AbilityContext;
  const abilities = new AbilitySystem(ctx);
  const camera = new THREE.PerspectiveCamera();
  const step = (seconds: number) => { for (let i = 0; i < Math.ceil(seconds / 0.01); i++) effects.update(0.01, camera, 720); };
  return { p, enemies, send, abilities, step, ctx, setNow: (t: number) => (clock = t) };
}
const foe = (id: number, x: number, z: number): Enemy => ({ id, x, z, state: 'move', radius: 0.4 }) as Enemy;
const hits = (send: ReturnType<typeof vi.fn>) => send.mock.calls.map((c) => c[0]).filter((i) => i.t === 'hit');

describe('resolveWeaponLoadout', () => {
  it('does nothing for other classes, unknown items, or no gear', () => {
    expect(loadout('staff_gold', undefined, 'hollow_knight')).toBe(NO_LOADOUT);
    expect(loadout('staff_oak')).toBe(NO_LOADOUT);
    expect(loadout()).toBe(NO_LOADOUT);
  });
  it('maps each kind to its modifiers straight from the tuning object', () => {
    const staff = loadout('staff_bone');
    expect(staff).toMatchObject({ main: 'staff', needleRangeMult: T.staff.needleRangeMult, needlePierce: 1, spellMult: T.staff.spellDamageMult, reap: false });
    expect(loadout('scythe_iron')).toMatchObject({ main: 'scythe', reap: true, needleRangeMult: 1 });
    expect(loadout('wand_gold')).toMatchObject({ needleCadenceMult: 1.3, needleDamageMult: 0.85 });
    expect(loadout('sickle_hell')).toMatchObject({ needleWithered: 1, exhumeRefund: 0.2 });
  });
  it('gives the skull focus its thrall at gold and above, the grimoire its rites, and the bell to Mourners only', () => {
    expect(loadout(undefined, 'skull_focus_iron').thrallBonus).toBe(0);
    expect(loadout(undefined, 'skull_focus_gold').thrallBonus).toBe(1);
    expect(loadout(undefined, 'skull_focus_moon').thrallBonus).toBe(1);
    expect(loadout(undefined, 'grimoire_bone').riteCooldownMult).toBe(0.9);
    expect(loadout(undefined, 'mourning_bell_bone', 'mourner').bellAllyHeal).toBe(0.02);
    expect(loadout(undefined, 'mourning_bell_bone', 'gravecaller').bellAllyHeal).toBe(0);
  });
  it('stacks a one-hander with an off-hand', () => {
    const l = loadout('wand_gold', 'skull_focus_gold');
    expect(l.needleCadenceMult).toBe(1.3);
    expect(l.thrallBonus).toBe(1);
  });
});

describe('derived stats', () => {
  const slot = (id: string, where: string, type: InventorySlot['item_type']): InventorySlot =>
    ({ id: 1, slot_index: 105, quantity: 1, equipped: 1, equipped_slot: where, item_id: id, name: id, rarity: 'rare', item_type: type, stat_bonus: { stat_int: id === 'staff_bone' ? 5 : 3 }, icon_id: null, sell_value: 0, crafted: 0 }) as InventorySlot;
  it('a line staff adds +10% spell power on top of its stats, and thralls do not get it', () => {
    const base = deriveStats({ level: 10 } as never, [], DISCIPLINES.ossuary, 0);
    const staff = deriveStats({ level: 10 } as never, [slot('staff_bone', 'main_hand', 'weapon')], DISCIPLINES.ossuary, 0);
    const wand = deriveStats({ level: 10 } as never, [slot('wand_bone', 'main_hand', 'weapon')], DISCIPLINES.ossuary, 0);
    const knight = deriveStats({ level: 10 } as never, [slot('staff_bone', 'main_hand', 'weapon')], DISCIPLINES.hollow_knight, 0);
    // stat_int 5 -> +6.5 spell power before the multiplier.
    expect(staff.spellPower).toBeCloseTo((base.spellPower + 5 * 1.3) * 1.1, 5);
    expect(wand.spellPower).toBeCloseTo(base.spellPower + 3 * 1.3, 5);
    expect(knight.spellPower).toBeCloseTo(base.spellPower + 5 * 1.3, 5);
    expect(staff.thrallDamage).toBeCloseTo((base.spellPower + 5 * 1.3) * 0.4, 5);
  });
});

describe('primary modifiers', () => {
  it('range: staff needle +25%, scythe 3 m, everything else untouched', () => {
    const base = ABILITIES.bone_needle.range;
    expect(abilityRange('bone_needle', base, loadout('staff_bone'))).toBeCloseTo(base * 1.25);
    expect(abilityRange('bone_needle', base, loadout('scythe_bone'))).toBe(3);
    expect(abilityRange('bone_needle', base, loadout('wand_bone'))).toBe(base);
    expect(abilityRange('marrow_spear', 12, loadout('staff_bone'))).toBe(12);
  });

  it('cadence: wand shortens needle cooldown and lock by 1.3x; grimoire trims rites but not the primary', () => {
    const wand = loadout('wand_bone');
    expect(abilityCooldownMs('bone_needle', 380, wand, true)).toBeCloseTo(380 / 1.3);
    expect(abilityLockMs('bone_needle', CAST_FLOW.bone_needle.lockMs, wand)).toBeCloseTo(CAST_FLOW.bone_needle.lockMs / 1.3);
    const grim = loadout(undefined, 'grimoire_gold');
    expect(abilityCooldownMs('miasma', 7000, grim, false)).toBeCloseTo(6300);
    expect(abilityCooldownMs('bone_needle', 380, grim, true)).toBe(380);
    expect(abilityCooldownMs('bone_fan', 500, grim, true)).toBe(500);
  });

  it('wand: the cast sets the shorter cooldown and the needle hits 15% softer', () => {
    const fixed = vi.spyOn(Math, 'random').mockReturnValue(0.5); // no damage jitter, no crit
    const plain = client();
    const wand = client('wand_gold');
    for (const c of [plain, wand]) c.enemies.set(1, foe(1, 0, 6));
    expect(plain.abilities.cast('bone_needle', { x: 0, z: 6, enemyId: 1 }, 1000)).toBe('ok');
    expect(wand.abilities.cast('bone_needle', { x: 0, z: 6, enemyId: 1 }, 1000)).toBe('ok');
    expect(plain.p.cooldownLeft('bone_needle', 1000)).toBe(380);
    expect(wand.p.cooldownLeft('bone_needle', 1000)).toBeCloseTo(380 / 1.3, 3);
    plain.step(1); wand.step(1);
    expect(hits(wand.send)[0].dmg / hits(plain.send)[0].dmg).toBeCloseTo(0.85, 5);
    fixed.mockRestore();
  });

  it('staff: reaches a target the plain needle cannot, and pierces one extra enemy behind it', () => {
    const plain = client();
    const staff = client('staff_bone');
    for (const c of [plain, staff]) c.enemies.set(1, foe(1, 0, 13));
    expect(plain.abilities.cast('bone_needle', { x: 0, z: 13, enemyId: 1 }, 1000)).toBe('range');
    expect(staff.abilities.cast('bone_needle', { x: 0, z: 13, enemyId: 1 }, 1000)).toBe('ok');
    const noCrit = vi.spyOn(Math, 'random').mockReturnValue(0.5); // the needle crits 8% of the time
    const s = client('staff_bone');
    s.enemies.set(1, foe(1, 0, 6));
    s.enemies.set(2, foe(2, 0.3, 8)); // behind, in the lane
    s.enemies.set(3, foe(3, 0.2, 9.5)); // a second one further back: not pierced
    s.enemies.set(4, foe(4, 5, 6)); // beside, out of the lane
    expect(s.abilities.cast('bone_needle', { x: 0, z: 6, enemyId: 1 }, 1000)).toBe('ok');
    s.step(1);
    const h = hits(s.send);
    expect(h.map((i) => i.ids)).toEqual([[1], [2]]);
    expect(h[1].dmg).toBeCloseTo(h[0].dmg * T.staff.pierceDamageMult, 5);
    noCrit.mockRestore();
  });

  it('sickle: each needle asks the host for one Withered stack up to the discipline cap; Exhume refunds 20% essence', () => {
    const c = client('sickle_iron', undefined, 'rotweaver');
    c.enemies.set(1, foe(1, 0, 6));
    expect(c.abilities.cast('bone_needle', { x: 0, z: 6, enemyId: 1 }, 1000)).toBe('ok');
    c.step(1);
    expect(hits(c.send)[0]).toMatchObject({ ids: [1], withered: 1, witheredCap: DISCIPLINES.rotweaver.mods.witheredMaxStacks });
    // Exhume: pays 12, gets 2.4 back.
    const e = client('sickle_iron');
    e.ctx.corpses = () => new Map([[1, { id: 1, x: 0, z: 3, kind: 'normal' } as never]]);
    e.p.essence = 100;
    const res = e.abilities.cast('exhume', { x: 0, z: 3 }, 1000);
    expect(res).toBe('ok');
    expect(e.p.essence).toBeCloseTo(100 - ABILITIES.exhume.essenceCost * 0.8, 5);
    const plain = client();
    plain.ctx.corpses = e.ctx.corpses;
    plain.p.essence = 100;
    plain.abilities.cast('exhume', { x: 0, z: 3 }, 1000);
    expect(plain.p.essence).toBe(100 - ABILITIES.exhume.essenceCost);
  });

  it('bell: Exhume carries the ally-heal claim only for a Mourner with a bell', () => {
    const corpses = () => new Map([[1, { id: 1, x: 0, z: 3, kind: 'normal' } as never]]);
    const mourner = client(undefined, 'mourning_bell_gold', 'mourner');
    mourner.ctx.corpses = corpses;
    mourner.abilities.cast('exhume', { x: 0, z: 3 }, 1000);
    expect(mourner.send.mock.calls.find((c) => c[0].t === 'exhume')![0].allyHeal).toBe(0.02);
    const gc = client(undefined, 'mourning_bell_gold', 'gravecaller');
    gc.ctx.corpses = corpses;
    gc.abilities.cast('exhume', { x: 0, z: 3 }, 1000);
    expect(gc.send.mock.calls.find((c) => c[0].t === 'exhume')![0].allyHeal).toBeUndefined();
  });
});

describe('scythe reaping arc', () => {
  it('hits at most 3 enemies inside the 100 degree cone, never one behind or beyond reach, and sends ONE hit intent', () => {
    const c = client('scythe_bone');
    c.enemies.set(1, foe(1, 0, 1.6));
    c.enemies.set(2, foe(2, 1.2, 1.8)); // ~34 deg off: inside
    c.enemies.set(3, foe(3, -1.2, 1.8));
    c.enemies.set(4, foe(4, 0.3, 2.6)); // a fourth in the arc: over the cap
    c.enemies.set(5, foe(5, 0, -1.5)); // behind
    c.enemies.set(6, foe(6, 0, 6)); // out of reach
    c.enemies.set(7, foe(7, 2.6, 0.4)); // 81 deg off: outside the 50 deg half angle
    expect(c.abilities.cast('bone_needle', { x: 0, z: 1.6, enemyId: 1 }, 1000)).toBe('ok');
    const h = hits(c.send);
    expect(h).toHaveLength(1);
    expect(h[0].ids.length).toBe(3);
    expect(h[0].ids).not.toContain(5);
    expect(h[0].ids).not.toContain(6);
    expect(h[0].ids).not.toContain(7);
    // Nothing flies: no delayed second hit from a projectile.
    c.send.mockClear();
    c.step(1);
    expect(c.send).not.toHaveBeenCalled();
  });

  it('cannot reach a far target (range), sets its own cooldown, and refunds essence per target', () => {
    const c = client('scythe_bone');
    c.enemies.set(1, foe(1, 0, 7));
    expect(c.abilities.cast('bone_needle', { x: 0, z: 7, enemyId: 1 }, 1000)).toBe('range');
    c.enemies.set(2, foe(2, 0, 1.5));
    c.enemies.set(3, foe(3, 0.5, 2));
    const before = c.p.essence;
    expect(c.abilities.cast('bone_needle', { x: 0, z: 1.5, enemyId: 2 }, 1000)).toBe('ok');
    expect(c.p.cooldownLeft('bone_needle', 1000)).toBe(T.scythe.cooldownMs);
    expect(c.p.essence - before).toBe(T.scythe.essencePerHit * 2);
  });

  it('kills the arc delivers pay +1 soul once, inside the window', () => {
    const c = client('scythe_bone');
    c.enemies.set(1, foe(1, 0, 1.5));
    c.enemies.set(2, foe(2, 0.5, 2));
    c.abilities.cast('bone_needle', { x: 0, z: 1.5, enemyId: 1 }, 1000);
    expect(c.abilities.reapedSouls(1)).toBe(1);
    expect(c.abilities.reapedSouls(1)).toBe(0); // consumed
    expect(c.abilities.reapedSouls(99)).toBe(0); // never struck by the arc
    c.setNow(1000 + T.scythe.reapWindowMs + 50);
    expect(c.abilities.reapedSouls(2)).toBe(0); // died too late to be the arc's kill
  });

  it('reapTargets / pierceTargets are pure and ordered nearest first', () => {
    const e = (id: number, x: number, z: number) => ({ id, x, z, radius: 0.4 });
    expect(reapTargets({ x: 0, z: 0 }, { x: 0, z: 1 }, [e(1, 0, 2.5), e(2, 0, 1)]).map((t) => t.id)).toEqual([2, 1]);
    expect(pierceTargets({ x: 0, z: 0 }, { x: 0, z: 5, id: 1 }, [e(1, 0, 5), e(2, 0, 7), e(3, 0, 6)], 1).map((t) => t.id)).toEqual([3]);
    expect(pierceTargets({ x: 0, z: 0 }, { x: 0, z: 5, id: 1 }, [e(2, 0, 7)], 0)).toEqual([]);
  });
});

describe('auto combat reach', () => {
  it('uses the weapon-modified primary reach when choosing whether a target is in range', () => {
    const enemies = [foe(1, 0, 13)].map((e) => ({ ...e, hp: 10, maxHp: 10, area: 'graves' }) as Enemy);
    const input = (range?: number) => ({
      player: { x: 0, z: 0, essence: 10, maxEssence: 150, area: 'graves' as const }, enemies, corpses: [], boss: { active: false } as never,
      thrallCount: 3, thrallCap: 3, ready: (id: string) => id === 'bone_needle', primary: 'bone_needle' as const, primaryRange: range,
    });
    expect(selectAutoCombatAction(input())).toBeNull();
    expect(selectAutoCombatAction(input(abilityRange('bone_needle', 11, loadout('staff_bone'))))?.id).toBe('bone_needle');
  });
});

describe('Mourning Bell on the host', () => {
  it('heals every player near the wraith by a share of THEIR max health, only when the claim is set and clamped', () => {
    const sim = new WorldSim(new Nav(), mulberry32(3));
    sim.setPlayer({ id: 'p1', x: 0, z: -16, alive: true, area: 'graves' });
    sim.setPlayer({ id: 'p2', x: 3, z: -16, alive: true, area: 'graves' });
    sim.setPlayer({ id: 'far', x: 60, z: -16, alive: true, area: 'graves' });
    sim.addCorpse(0.5, -16, 'normal', 'robber', false, 0, 1, 'graves');
    sim.apply({ t: 'exhume', by: 'p1', x: 0.5, z: -16, r: 1, kind: 'wraith', cap: 3, hp: 50, damage: 5, attackSpeedMult: 1, allyHeal: 5 });
    const th = [...sim.thralls.values()][0];
    expect(th.allyHeal).toBeCloseTo(T.mourning_bell.allyHealFrac * 1.5); // a forged 500% claim is clamped
    th.allyHeal = 0.02;
    sim.drain();
    const foeE = sim.spawnEnemy('robber', 'graves', 2, -16, false);
    foeE.state = 'move';
    let heals: { player: string; frac?: number }[] = [];
    for (let t = 0; t < 4 && !heals.length; t += 0.1) heals = sim.step(0.1).filter((e) => e.t === 'heal') as never;
    expect(heals.map((h) => h.player).sort()).toEqual(['p1', 'p2']);
    expect(heals.every((h) => h.frac === 0.02)).toBe(true);
  });
  it('a plain wraith heals nobody', () => {
    const sim = new WorldSim(new Nav(), mulberry32(3));
    sim.setPlayer({ id: 'p1', x: 0, z: -16, alive: true, area: 'graves' });
    sim.addCorpse(0.5, -16, 'normal', 'robber', false, 0, 1, 'graves');
    sim.apply({ t: 'exhume', by: 'p1', x: 0.5, z: -16, r: 1, kind: 'wraith', cap: 3, hp: 50, damage: 5, attackSpeedMult: 1 });
    sim.drain();
    const f = sim.spawnEnemy('robber', 'graves', 2, -16, false);
    f.state = 'move';
    let all: unknown[] = [];
    for (let t = 0; t < 4; t += 0.1) all = all.concat(sim.step(0.1));
    expect(all.filter((e) => (e as { t: string }).t === 'heal')).toHaveLength(0);
  });
});

describe('scythe boss reach (owner, 3 Oct 2026)', () => {
  const scythe = { ...NO_LOADOUT, reap: true };
  it('reaches a boss farther than an ordinary foe', () => {
    expect(T.scythe.bossReach).toBeGreaterThan(T.scythe.reach);
    expect(abilityRange('bone_needle', 10, scythe, true)).toBe(T.scythe.bossReach);
    expect(abilityRange('bone_needle', 10, scythe)).toBe(T.scythe.reach);
  });
  it('an arc at boss reach strikes a boss body that the ordinary arc misses', () => {
    const at = T.scythe.reach + 1.6 + 0.5; // past the normal arc, inside the boss reach
    const boss = [{ x: 0, z: at, radius: 1.6 }];
    expect(reapTargets({ x: 0, z: 0 }, { x: 0, z: 1 }, boss)).toHaveLength(0);
    expect(reapTargets({ x: 0, z: 0 }, { x: 0, z: 1 }, boss, T.scythe.bossReach)).toHaveLength(1);
  });
});
