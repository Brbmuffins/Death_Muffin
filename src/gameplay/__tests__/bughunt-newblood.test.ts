import * as THREE from 'three';
import { describe, expect, it, vi } from 'vitest';
import { Nav } from '../nav';
import { AbilitySystem, type AbilityContext } from '../AbilitySystem';
import { Player } from '../Player';
import { Effects } from '../../graphics/Effects';
import { DISCIPLINES } from '../../content/disciplines';
import type { Intent } from '../sim/types';

vi.mock('../../audio/Audio', () => ({ audio: { play: vi.fn() } }));
vi.mock('../../graphics/fxTextures', () => ({
  fx: Object.fromEntries(['glow', 'smoke', 'disc', 'ring', 'cracks', 'sigil'].map((name) => [name, () => new THREE.Texture()])),
}));
vi.mock('../../graphics/fxImages', () => ({ fxImage: () => new THREE.Texture() }));

describe('core bug hunt: New Blood timed rites', () => {
  it('Choir of One stops with its caster: a death does not leave it ringing after the respawn', () => {
    const p = new Player({ level: 12, maxHp: 100, spellPower: 20, maxEssence: 150, essenceRegen: 5, moveSpeed: 5.4, thrallHp: 45, thrallDamage: 8, damageBonusPct: 0 }, new Nav(), 'monk');
    p.resource.value = 80;
    let now = 1000;
    const send = vi.fn();
    const ctx = {
      selfId: 'solo', player: p, discipline: DISCIPLINES.bell_monk, avatar: { tip: () => new THREE.Vector3(0, 1.4, 0), cast: vi.fn() }, effects: new Effects(new THREE.Scene()),
      enemies: () => new Map(), boss: () => ({ active: false }), corpses: () => new Map(), thrallCount: () => 0, send, number: vi.fn(), shake: vi.fn(), now: () => now,
    } as unknown as AbilityContext;
    const abilities = new AbilitySystem(ctx);
    expect(abilities.cast('choir_of_one', { x: 0, z: 1 }, now)).toBe('ok');
    const tolls = () => send.mock.calls.map((c) => c[0] as Intent).filter((i) => i.t === 'signature' && i.sig === 'toll').length;
    now = 2300;
    abilities.update(now);
    expect(tolls()).toBe(1); // the choir sings while she lives
    p.takeDamage(1e6, 0, now);
    expect(p.alive).toBe(false);
    now = 3500;
    abilities.update(now); // dead: silent
    p.revive();
    const before = tolls();
    now = 4800; // still inside the six-second window the cast opened
    abilities.update(now);
    expect(tolls()).toBe(before);
  });
});
