import * as THREE from 'three';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { Nav } from '../nav';
import { AbilitySystem, type AbilityContext } from '../AbilitySystem';
import { Player } from '../Player';
import { Effects } from '../../graphics/Effects';
import { DISCIPLINES } from '../../content/disciplines';
import { NECRO_WEAPON_TUNING as T } from '../../content/necroWeapons';
import { RUNE_TUNING, RUNES } from '../../content/runes';
import type { RuneId } from '../../content/runes';
import type { Enemy, Intent } from '../sim/types';
import { resolveWeaponLoadout } from '../weaponLine';
import { CODEX_RUNES_COUNSEL } from '../../content/codex';

vi.mock('../../audio/Audio', () => ({ audio: { play: vi.fn() } }));
vi.mock('../../graphics/fxTextures', () => ({
  fx: Object.fromEntries(['glow', 'smoke', 'disc', 'ring', 'cracks', 'sigil'].map((name) => [name, () => new THREE.Texture()])),
}));
vi.mock('../../graphics/fxImages', () => ({ fxImage: () => new THREE.Texture() }));
afterEach(() => vi.restoreAllMocks());

/** A Gravecaller with a bone scythe and (optionally) a Bone Needle rune socketed. */
function client(rune?: RuneId) {
  const p = new Player({ level: 12, maxHp: 100, spellPower: 20, maxEssence: 150, essenceRegen: 5, moveSpeed: 5.4, thrallHp: 45, thrallDamage: 8, damageBonusPct: 0 }, new Nav());
  p.essence = 50;
  p.loadout = resolveWeaponLoadout({ main_hand: { item_id: 'scythe_bone' } }, 'gravecaller');
  if (rune) p.runes = { bone_needle: rune };
  const effects = new Effects(new THREE.Scene());
  const enemies = new Map<number, Enemy>();
  const send = vi.fn();
  const ctx = {
    selfId: 'solo', player: p, discipline: DISCIPLINES.gravecaller, avatar: { tip: () => new THREE.Vector3(0, 1.4, 0), cast: vi.fn() }, effects,
    enemies: () => enemies, boss: () => ({ active: false }), corpses: () => new Map(),
    thrallCount: () => 0, send, number: vi.fn(), shake: vi.fn(), now: () => 1000,
  } as unknown as AbilityContext;
  return { p, enemies, send, abilities: new AbilitySystem(ctx) };
}
const foe = (id: number, x: number, z: number): Enemy => ({ id, x, z, state: 'move', radius: 0.4 }) as Enemy;
const hits = (send: ReturnType<typeof vi.fn>) => send.mock.calls.map((c) => c[0] as Extract<Intent, { t: 'hit' }>).filter((i) => i.t === 'hit');
/** Two foes inside the arc and one outside it (to the side, 3.5 m from the nearest struck foe). */
const field = (c: ReturnType<typeof client>) => {
  c.enemies.set(1, foe(1, 0, 1.5));
  c.enemies.set(2, foe(2, 0.5, 2));
  c.enemies.set(3, foe(3, 3.5, 1.5));
};

describe('Bone Needle runes under a scythe (once per swing)', () => {
  it('Marrow-Tap: the swing hits softer and returns the bonus essence ONCE, not per enemy', () => {
    vi.spyOn(Math, 'random').mockReturnValue(0.5);
    const plain = client();
    const tap = client('rune_marrow_tap');
    field(plain);
    field(tap);
    const p0 = plain.p.essence;
    const t0 = tap.p.essence;
    plain.abilities.cast('bone_needle', { x: 0, z: 1.5, enemyId: 1 }, 1000);
    tap.abilities.cast('bone_needle', { x: 0, z: 1.5, enemyId: 1 }, 1000);
    const a = hits(plain.send);
    const b = hits(tap.send);
    expect(b).toHaveLength(1);
    expect(b[0].ids).toEqual(a[0].ids);
    expect(b[0].dmg / a[0].dmg).toBeCloseTo(RUNE_TUNING.marrowTap.damageMult, 5);
    expect(plain.p.essence - p0).toBe(T.scythe.essencePerHit * 2);
    expect(tap.p.essence - t0).toBe(T.scythe.essencePerHit * 2 + RUNE_TUNING.marrowTap.essenceBonus);
  });

  it('Marrow-Tap pays nothing for a swing that finds nothing', () => {
    const c = client('rune_marrow_tap');
    c.enemies.set(1, foe(1, 0, 9));
    const before = c.p.essence;
    expect(c.abilities.cast('bone_needle', { x: 0, z: 9, enemyId: 1 }, 1000)).toBe('range');
    expect(c.p.essence).toBe(before);
    expect(hits(c.send)).toHaveLength(0);
  });

  it('Splinters: ONE shard per swing, to the nearest enemy the arc missed, for the rune share of the swing damage', () => {
    vi.spyOn(Math, 'random').mockReturnValue(0.5);
    const c = client('rune_splinter');
    field(c);
    c.abilities.cast('bone_needle', { x: 0, z: 1.5, enemyId: 1 }, 1000);
    const h = hits(c.send);
    expect(h).toHaveLength(2);
    expect(h[0].ids).toEqual([1, 2]);
    expect(h[1].ids).toEqual([3]);
    expect(h[1].dmg).toBeCloseTo(h[0].dmg * RUNE_TUNING.splinter.damageFrac, 5);
  });

  it('Splinters: no shard when the arc struck everyone in reach, and never one at an enemy the swing already hit', () => {
    const c = client('rune_splinter');
    c.enemies.set(1, foe(1, 0, 1.5));
    c.enemies.set(2, foe(2, 0.5, 2));
    c.abilities.cast('bone_needle', { x: 0, z: 1.5, enemyId: 1 }, 1000);
    expect(hits(c.send)).toHaveLength(1);
  });

  it('the Volley stays needle-only: with it socketed a scythe swings exactly like a bare one', () => {
    vi.spyOn(Math, 'random').mockReturnValue(0.5);
    const plain = client();
    const volley = client('rune_volley');
    field(plain);
    field(volley);
    for (let i = 0; i < 8; i++) {
      plain.abilities.cast('bone_needle', { x: 0, z: 1.5, enemyId: 1 }, 1000 + i * 1000);
      volley.abilities.cast('bone_needle', { x: 0, z: 1.5, enemyId: 1 }, 1000 + i * 1000);
    }
    expect(hits(volley.send).length).toBeGreaterThan(0);
    expect(hits(volley.send).map((h) => [h.ids, h.dmg])).toEqual(hits(plain.send).map((h) => [h.ids, h.dmg]));
  });

  it('the Codex and the rune text say the runes work under a scythe (Volley excepted)', () => {
    expect(CODEX_RUNES_COUNSEL).not.toMatch(/not with a scythe/);
    expect(CODEX_RUNES_COUNSEL).toMatch(/scythe/);
    expect(RUNES.rune_splinter.lines.join(' ')).toMatch(/scythe/);
    expect(RUNES.rune_marrow_tap.lines.join(' ')).toMatch(/scythe/);
    expect(RUNES.rune_volley.lines.join(' ')).toMatch(/needle only/i);
  });
});
