import * as THREE from 'three';
import { describe, expect, it, vi } from 'vitest';
import { AbilitySystem, type AbilityContext } from '../AbilitySystem';
import { Player } from '../Player';
import { Nav } from '../nav';
import { Effects } from '../../graphics/Effects';
import { DISCIPLINES } from '../../content/disciplines';
import { CAST_FLOW } from '../../content/combatFlow';
import type { Enemy } from '../sim/types';

vi.mock('../../audio/Audio', () => ({ audio: { play: vi.fn() } }));
vi.mock('../../graphics/fxTextures', () => ({
  fx: Object.fromEntries(['glow', 'smoke', 'disc', 'ring', 'cracks', 'sigil'].map((name) => [name, () => new THREE.Texture()])),
}));

function setup() {
  const p = new Player({ level: 10, maxHp: 100, spellPower: 20, maxEssence: 150, essenceRegen: 5, moveSpeed: 5.4, thrallHp: 45, thrallDamage: 8, damageBonusPct: 0 }, new Nav());
  p.essence = 150;
  const effects = new Effects(new THREE.Scene());
  const enemies = new Map<number, Enemy>();
  const send = vi.fn();
  const avatar = { tip: () => new THREE.Vector3(0, 1.4, 0), cast: vi.fn() };
  const context = {
    selfId: 'solo', player: p, discipline: DISCIPLINES.ossuary, avatar, effects,
    enemies: () => enemies, boss: () => ({ active: false }), corpses: () => new Map(),
    thrallCount: () => 0, send, number: vi.fn(), shake: vi.fn(), now: () => 1000,
  } as unknown as AbilityContext;
  const abilities = new AbilitySystem(context);
  const camera = new THREE.PerspectiveCamera();
  const step = (seconds: number) => {
    for (let i = 0; i < Math.ceil(seconds / 0.01); i++) effects.update(0.01, camera, 720);
  };
  return { p, effects, enemies, send, avatar, abilities, step };
}

function enemy(id: number, x: number, z: number): Enemy {
  return { id, x, z, state: 'move', radius: 0.4 } as Enemy;
}

describe('spell presentation and hit timing', () => {
  it('activates miasma exactly once when its visible orb lands, with the original cast power', () => {
    const { p, abilities, send, step } = setup();
    expect(abilities.cast('miasma', { x: 14, z: 0 }, 1000)).toBe('ok');
    expect(send).not.toHaveBeenCalled();
    p.stats.spellPower = 500;
    step(0.5);
    expect(send).not.toHaveBeenCalled();
    step(0.3);
    expect(send).toHaveBeenCalledTimes(1);
    expect(send.mock.calls[0][0]).toMatchObject({ t: 'miasma', x: 14, z: 0, dps: 4.4, durationMs: 6000 });
    step(2);
    expect(send).toHaveBeenCalledTimes(1);
  });

  it('resolves spear against the live line at impact and does not damage enemies before the release arrives', () => {
    const { abilities, enemies, send, step } = setup();
    enemies.set(1, enemy(1, 6, 0));
    enemies.set(2, enemy(2, 6, 5));
    expect(abilities.cast('marrow_spear', { x: 12, z: 0 }, 1000)).toBe('ok');
    expect(send).not.toHaveBeenCalled();
    enemies.get(1)!.z = 5;
    enemies.get(2)!.z = 0;
    step(0.2);
    expect(send).not.toHaveBeenCalled();
    step(0.1);
    expect(send).toHaveBeenCalledTimes(1);
    expect(send.mock.calls[0][0]).toMatchObject({ t: 'hit', ids: [2], fracture: 1, dmg: 42 });
  });

  it.each(['miasma', 'marrow_spear'] as const)('cancels pending %s impact if the caster dies', (id) => {
    const { p, abilities, send, step } = setup();
    expect(abilities.cast(id, { x: 12, z: 0 }, 1000)).toBe('ok');
    p.alive = false;
    step(1);
    expect(send).not.toHaveBeenCalled();
  });

  it('applies a short shared recovery only to successful casts without spending resources on a busy attempt', () => {
    const { p, abilities, avatar } = setup();
    expect(abilities.cast('bone_needle', { x: 4, z: 0 }, 1000)).toBe('no_target');
    expect(p.castUntil).toBe(0);
    expect(abilities.cast('miasma', { x: 4, z: 0 }, 1000)).toBe('ok');
    expect(p.castUntil).toBe(1000 + CAST_FLOW.miasma.lockMs);
    expect(avatar.cast).toHaveBeenCalledWith('cast', 2.2, p.facing, CAST_FLOW.miasma.gestureSeconds, 'miasma');
    const essence = p.essence;
    expect(abilities.ready('marrow_spear', 1010)).toBe(false);
    expect(abilities.cast('marrow_spear', { x: 12, z: 0 }, 1010)).toBe('busy');
    expect(p.essence).toBe(essence);
    expect(p.onCooldown('marrow_spear', 1010)).toBe(false);
    expect(abilities.ready('marrow_spear', p.castUntil)).toBe(true);
    expect(abilities.cast('marrow_spear', { x: 12, z: 0 }, p.castUntil)).toBe('ok');
  });

  it('bounds cosmetic mesh growth during crowded bursts and clears expired effects', () => {
    const { effects, step } = setup();
    const baseline = effects.group.children.length;
    const tex = new THREE.Texture();
    for (let i = 0; i < 300; i++) effects.decal({ tex, x: i, z: 0, r: 1, color: 0xffffff, duration: 0.5 });
    // Live decals are capped at 160 and share one instanced layer per texture.
    expect(effects.transientLoad).toBe(160);
    expect(effects.group.children.length).toBe(baseline + 1);
    step(0.6);
    expect(effects.transientLoad).toBe(0);
    // One-off textures each get a layer; an emptied layer is freed after a few idle seconds.
    for (let i = 0; i < 20; i++) effects.decal({ tex: new THREE.Texture(), x: i, z: 0, r: 1, color: 0xffffff, duration: 0.5 });
    step(6);
    expect(effects.group.children.length).toBe(baseline);
    effects.dispose();
  });
});
