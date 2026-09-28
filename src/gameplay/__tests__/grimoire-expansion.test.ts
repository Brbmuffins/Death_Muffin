import { describe, expect, it } from 'vitest';
import { Nav } from '../nav';
import { WorldSim } from '../sim/WorldSim';
import { mulberry32 } from '../rng';
import { selectAutoCombatAction, type AutoCombatInput } from '../autoCombat';
import { AREAS } from '../../content/areas';
import { ABILITIES, BONE_PRISON, GRIMOIRE, type AbilityId } from '../../content/abilities';
import { CODEX_RITES } from '../../content/codex';
import type { Enemy } from '../sim/types';

const NEW: AbilityId[] = ['soul_siphon', 'bone_prison', 'grave_hands', 'bone_storm'];

function world() {
  const nav = new Nav();
  nav.setUnlocked(['chapterhouse', 'graves']);
  const sim = new WorldSim(nav, mulberry32(3));
  const r = AREAS.graves.rect;
  sim.setPlayer({ id: 'p1', x: (r.x0 + r.x1) / 2, z: (r.z0 + r.z1) / 2, alive: true, area: 'graves' });
  return sim;
}

const enemy = (id: number, x = 5, z = 0, over: Partial<Enemy> = {}): Enemy =>
  ({ id, def: 'robber', area: 'graves', level: 1, elite: false, x, z, facing: 0, hp: 50, maxHp: 50, damage: 5, speed: 2, radius: 0.45, scale: 1, state: 'move', stateT: 0, attackCd: 0, targetPlayer: null, targetThrall: null, aimX: 0, aimZ: 0, channelCorpse: null, flankSide: 1, fracture: 0, fractureT: 0, withered: 0, witheredT: 0, witheredDps: 0, witheredOwner: '', slowT: 0, lastHitBy: '', flash: 0, gait: 0, moving: false, ...over });

const input = (over: Partial<AutoCombatInput>): AutoCombatInput => ({
  player: { x: 0, z: 0, essence: 100, maxEssence: 100 }, enemies: [], corpses: [],
  boss: { active: false } as AutoCombatInput['boss'], thrallCount: 3, thrallCap: 3, ready: () => false, ...over,
});

describe('Grimoire expansion', () => {
  it('the four new rites are in the Grimoire with Codex help and an icon', () => {
    for (const id of NEW) {
      expect(GRIMOIRE).toContain(id);
      expect(CODEX_RITES[id].tip.length).toBeGreaterThan(40);
      expect(ABILITIES[id].icon).toMatch(/necro-/);
    }
  });

  it('a Bone Prison hit roots on the host for the host-owned duration; Grave Hands slows', () => {
    const sim = world();
    const p = sim.players.get('p1')!;
    const a = sim.spawnEnemy('golem', 'graves', p.x + 4, p.z, false, false);
    const b = sim.spawnEnemy('golem', 'graves', p.x - 4, p.z, false, false);
    sim.apply({ t: 'hit', by: 'p1', ids: [a.id], dmg: 1, root: true });
    sim.apply({ t: 'hit', by: 'p1', ids: [b.id], dmg: 1, slow: true });
    expect(a.rootT).toBeCloseTo(BONE_PRISON.rootS, 5);
    expect(b.slowT).toBeGreaterThan(0);
    // Rooted: it does not walk toward the player.
    const x0 = a.x;
    sim.step(0.5);
    expect(a.x).toBeCloseTo(x0, 5);
  });

  it('Easy auto cages a knot, siphons an elite, and ignores new rites that are not on the bar', () => {
    const knot = [enemy(1, 6, 0), enemy(2, 6.5, 0.5), enemy(3, 5.5, -0.5)];
    expect(selectAutoCombatAction(input({ enemies: knot, ready: (id) => id === 'bone_prison' }))?.id).toBe('bone_prison');
    expect(selectAutoCombatAction(input({ enemies: knot, ready: (id) => id === 'grave_hands' }))?.id).toBe('grave_hands');
    expect(selectAutoCombatAction(input({ enemies: knot, ready: (id) => id === 'bone_storm' }))?.id).toBe('bone_storm');
    const elite = [enemy(9, 5, 0, { elite: true })];
    expect(selectAutoCombatAction(input({ enemies: elite, ready: (id) => id === 'soul_siphon' }))?.id).toBe('soul_siphon');
    expect(selectAutoCombatAction(input({ enemies: [enemy(9, 5, 0)], ready: (id) => id === 'soul_siphon' }))).toBeNull();
  });
});
