import { describe, expect, it } from 'vitest';
import { selectAutoCombatAction, type AutoCombatInput } from '../autoCombat';
import type { BossState, Corpse, Enemy } from '../sim/types';
import type { AbilityId } from '../../content/abilities';

const enemy = (id: number, x = 5, z = 0, over: Partial<Enemy> = {}): Enemy =>
  ({ id, x, z, hp: 100, radius: 0.4, state: 'move', ...over } as Enemy);
const corpse = (x = 5, z = 0, over: Partial<Corpse> = {}): Corpse =>
  ({ id: 1, x, z, kind: 'normal', ...over } as Corpse);
const input = (over: Partial<AutoCombatInput> = {}): AutoCombatInput => ({
  player: { x: 0, z: 0, essence: 55, maxEssence: 100 },
  enemies: [enemy(1)], corpses: [],
  boss: { active: false, hp: 0 } as BossState,
  thrallCount: 0, thrallCap: 3, ready: () => true, ...over,
});
const readyOnly = (...ids: AbilityId[]) => (id: AbilityId) => ids.includes(id);

describe('stationary auto combat', () => {
  it('does nothing without nearby living enemies, even with available corpses', () => {
    expect(selectAutoCombatAction(input({ enemies: [], corpses: [corpse()] }))).toBeNull();
    expect(selectAutoCombatAction(input({ enemies: [enemy(1, 40)] }))).toBeNull();
  });

  it('ignores dead, depleted and rising targets and selects the nearest living target', () => {
    const result = selectAutoCombatAction(input({ ready: readyOnly('bone_needle'), enemies: [
      enemy(1, 1, 0, { hp: 0 }), enemy(2, 2, 0, { state: 'dead' }),
      enemy(3, 3, 0, { state: 'rising' }), enemy(4, 8), enemy(5, 6),
    ] }));
    expect(result).toEqual({ id: 'bone_needle', target: { x: 6, z: 0, enemyId: 5 } });
  });

  it('rebuilds essence with free needles instead of spending low reserves on packs or corpses', () => {
    const p = { x: 0, z: 0, essence: 28, maxEssence: 100 };
    expect(selectAutoCombatAction(input({ player: p, enemies: [enemy(1), enemy(2, 6), enemy(3, 7)], corpses: [corpse()] }))?.id).toBe('bone_needle');
    expect(p.essence).toBe(28);
  });

  it('raises an army up to the selected class cap without replacing existing thralls', () => {
    const base = input({ corpses: [corpse(40), corpse(6), corpse(3)], thrallCount: 1, thrallCap: 2 });
    expect(selectAutoCombatAction(base)).toEqual({ id: 'exhume', target: { x: 3, z: 0 } });
    expect(selectAutoCombatAction({ ...base, thrallCount: 2 })?.id).toBe('bone_needle');
    expect(selectAutoCombatAction({ ...base, thrallCap: 0 })?.id).toBe('bone_needle');
  });

  it('does not try to raise or burst out-of-range corpses', () => {
    const result = selectAutoCombatAction(input({ corpses: [corpse(13.1)], enemies: [enemy(1, 11), enemy(2, 11, 1)], ready: readyOnly('exhume', 'corpse_explosion', 'bone_needle') }));
    expect(result?.id).toBe('bone_needle');
  });

  it('bursts a corpse when it hits a pack, but preserves it against a lone enemy', () => {
    const base = input({ corpses: [corpse()], thrallCount: 3, ready: readyOnly('corpse_explosion', 'bone_needle') });
    expect(selectAutoCombatAction(base)?.id).toBe('bone_needle');
    expect(selectAutoCombatAction({ ...base, enemies: [enemy(1, 5, 1), enemy(2, 6, 0)] })?.id).toBe('corpse_explosion');
  });

  it('accounts for the wider resonant corpse blast', () => {
    const base = input({ corpses: [corpse(5, 0, { kind: 'resonant' })], enemies: [enemy(1, 5, 4), enemy(2, 5, -4)], thrallCount: 3, ready: readyOnly('corpse_explosion', 'bone_needle') });
    expect(selectAutoCombatAction(base)?.id).toBe('corpse_explosion');
    expect(selectAutoCombatAction({ ...base, corpses: [corpse()] })?.id).toBe('bone_needle');
  });

  it('places miasma on a real cluster instead of paying for one straggler', () => {
    const base = input({ ready: readyOnly('miasma', 'bone_needle') });
    expect(selectAutoCombatAction(base)?.id).toBe('bone_needle');
    const packed = [enemy(1, 5), enemy(2, 6), enemy(3, 6, 1)];
    expect(selectAutoCombatAction({ ...base, enemies: packed })?.id).toBe('miasma');
    expect(selectAutoCombatAction({ ...base, enemies: [enemy(1, 5), enemy(2, -6), enemy(3, 0, -8)] })?.id).toBe('bone_needle');
  });

  it('pierces aligned enemies, while holding single-target spear spending until high essence', () => {
    const base = input({ ready: readyOnly('marrow_spear', 'bone_needle') });
    expect(selectAutoCombatAction({ ...base, enemies: [enemy(1, 5), enemy(2, 9)] })?.id).toBe('marrow_spear');
    expect(selectAutoCombatAction(base)?.id).toBe('bone_needle');
    expect(selectAutoCombatAction({ ...base, player: { ...base.player, essence: 90 } })?.id).toBe('marrow_spear');
  });

  it('never sacrifices thralls automatically, and needs a large fight with corpse fuel for litany', () => {
    const base = input({ player: { x: 0, z: 0, essence: 90, maxEssence: 100 }, ready: readyOnly('black_litany', 'bone_needle'), corpses: [corpse(), corpse(6)], thrallCount: 0, thrallCap: 0,
      enemies: Array.from({ length: 6 }, (_, i) => enemy(i, 4, i * 0.3)) });
    expect(selectAutoCombatAction(base)?.id).toBe('black_litany');
    expect(selectAutoCombatAction({ ...base, thrallCount: 1 })?.id).toBe('bone_needle');
    expect(selectAutoCombatAction({ ...base, corpses: [] })?.id).toBe('bone_needle');
    expect(selectAutoCombatAction({ ...base, enemies: [enemy(1)] })?.id).toBe('bone_needle');
  });

  it('handles boss targeting and respects needle reach including the boss radius', () => {
    const base = input({ enemies: [], boss: { active: true, state: 'idle', hp: 500, x: 12, z: 0 } as BossState });
    expect(selectAutoCombatAction(base)).toEqual({ id: 'bone_needle', target: { x: 12, z: 0, boss: true } });
    expect(selectAutoCombatAction({ ...base, boss: { ...base.boss, hp: 0 } })).toBeNull();
    expect(selectAutoCombatAction({ ...base, boss: { ...base.boss, x: 13 }, ready: readyOnly('bone_needle') })).toBeNull();
  });

  it('does not select unavailable spells or out-of-range single targets', () => {
    expect(selectAutoCombatAction(input({ ready: () => false }))).toBeNull();
    expect(selectAutoCombatAction(input({ enemies: [enemy(1, 12.8)], ready: readyOnly('bone_needle', 'marrow_spear') }))).toBeNull();
  });

  it('bounds snapshot inspection and returns one action without modifying input', () => {
    let reads = 0;
    function* crowded(): IterableIterator<Enemy> {
      for (let i = 0; i < 100_000; i++) { reads++; yield enemy(i, 40); }
    }
    expect(selectAutoCombatAction(input({ enemies: crowded() }))).toBeNull();
    expect(reads).toBeLessThanOrEqual(513);
  });
});
