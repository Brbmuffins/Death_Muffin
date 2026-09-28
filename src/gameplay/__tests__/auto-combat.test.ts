import { ABILITIES } from '../../content/abilities';
import { describe, expect, it } from 'vitest';
import { selectAutoCombatAction, selectAutoCombatMovement, type AutoCombatInput, type AutoMoveMemory } from '../autoCombat';
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
/** A starting bar: the free needle, the default four and Corpse Explosion (no level-gated Grimoire rites). */
const DEFAULT_BAR = readyOnly('bone_needle', 'marrow_spear', 'exhume', 'miasma', 'black_litany', 'corpse_explosion');

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
    const base = input({ corpses: [corpse(40), corpse(6), corpse(3)], thrallCount: 1, thrallCap: 2, ready: readyOnly('exhume', 'bone_needle') });
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
    const base = input({ enemies: [], boss: { active: true, state: 'idle', hp: 500, x: 12, z: 0 } as BossState, ready: DEFAULT_BAR });
    expect(selectAutoCombatAction(base)).toEqual({ id: 'bone_needle', target: { x: 12, z: 0, boss: true } });
    expect(selectAutoCombatAction({ ...base, boss: { ...base.boss, hp: 0 } })).toBeNull();
    expect(selectAutoCombatAction({ ...base, boss: { ...base.boss, x: 13 }, ready: readyOnly('bone_needle') })).toBeNull();
  });

  it('does not select unavailable spells or out-of-range single targets', () => {
    expect(selectAutoCombatAction(input({ ready: () => false }))).toBeNull();
    expect(selectAutoCombatAction(input({ enemies: [enemy(1, 12.8)], ready: readyOnly('bone_needle', 'marrow_spear') }))).toBeNull();
  });

  it('sends the Wailing Skull at a boss or elite, and through a knot it can leap along', () => {
    const skull = readyOnly('wailing_skull', 'bone_needle');
    const boss = input({ enemies: [], boss: { active: true, state: 'idle', hp: 500, x: 12, z: 0 } as BossState, ready: skull });
    expect(selectAutoCombatAction(boss)).toEqual({ id: 'wailing_skull', target: { x: 12, z: 0, boss: true } });
    const elite = input({ enemies: [enemy(1, 4), enemy(2, 8, 0, { elite: true })], ready: skull });
    expect(selectAutoCombatAction(elite)?.target).toEqual({ x: 8, z: 0, enemyId: 2 });
    // A lone common is left to the needle.
    expect(selectAutoCombatAction(input({ enemies: [enemy(1, 6)], ready: skull }))?.id).toBe('bone_needle');
    expect(selectAutoCombatAction(input({ enemies: [enemy(1, 6), enemy(2, 7, 1), enemy(3, 8, -1)], ready: skull }))?.id).toBe('wailing_skull');
  });

  it('breathes Grave Frost only into a cone of three or more', () => {
    const frost = readyOnly('grave_frost', 'bone_needle');
    const pack = [enemy(1, 4), enemy(2, 5, 1), enemy(3, 6, -1.5)];
    expect(selectAutoCombatAction(input({ enemies: pack, ready: frost }))?.id).toBe('grave_frost');
    // Two in front and one behind is not a cone.
    expect(selectAutoCombatAction(input({ enemies: [enemy(1, 4), enemy(2, 5), enemy(3, -5)], ready: frost }))?.id).toBe('bone_needle');
  });

  it('raises Bone Mantle when pressed and hurt, or standing on corpse fuel', () => {
    const mantle = readyOnly('bone_mantle', 'bone_needle');
    const close = [enemy(1, 1.5), enemy(2, -1.5)];
    const hurt = { x: 0, z: 0, essence: 60, maxEssence: 100, hp: 40, maxHp: 100 };
    expect(selectAutoCombatAction(input({ enemies: close, ready: mantle, player: hurt }))).toEqual({ id: 'bone_mantle', target: { x: 0, z: 0 } });
    const healthy = { ...hurt, hp: 95 };
    expect(selectAutoCombatAction(input({ enemies: close, ready: mantle, player: healthy }))?.id).toBe('bone_needle');
    const fuel = [corpse(1, 1), corpse(2, 2), corpse(-2, 1)];
    expect(selectAutoCombatAction(input({ enemies: close, corpses: fuel, thrallCount: 3, ready: mantle, player: healthy }))?.id).toBe('bone_mantle');
    // Nobody close: no mantle, however many bodies lie around.
    expect(selectAutoCombatAction(input({ enemies: [enemy(1, 8)], corpses: fuel, ready: mantle, player: hurt }))?.id).toBe('bone_needle');
  });

  it('never casts Grave Step (auto combat never moves you)', () => {
    const everything = input({ enemies: [enemy(1, 3), enemy(2, 4)], corpses: [corpse(6)], thrallCount: 3 });
    for (let essence = 0; essence <= 100; essence += 10) {
      expect(selectAutoCombatAction({ ...everything, player: { ...everything.player, essence } })?.id).not.toBe('grave_step');
    }
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

describe('Easy auto for New Blood', () => {
  it('uses Knight defense before offense, then uses Slam on a pack', () => {
    const pack = [enemy(1, 2), enemy(2, 2.5, 0.5)];
    const base = input({ family: 'knight', primary: 'hollow_cut', enemies: pack,
      player: { x: 0, z: 0, essence: 50, maxEssence: 100, hp: 25, maxHp: 100 },
      ready: readyOnly('oath_unbroken', 'grave_slam', 'hollow_cut') });
    expect(selectAutoCombatAction(base)?.id).toBe('oath_unbroken');
    expect(selectAutoCombatAction({ ...base, player: { ...base.player, hp: 100 } })?.id).toBe('grave_slam');
  });

  it('uses Warden control and Witch corpse fuel', () => {
    const pack = [enemy(1, 4), enemy(2, 4.5, 0.5)];
    expect(selectAutoCombatAction(input({ family: 'warden', primary: 'flail_swing', enemies: pack,
      ready: readyOnly('lantern_cone', 'flail_swing') }))?.id).toBe('lantern_cone');
    expect(selectAutoCombatAction(input({ family: 'witch', primary: 'hook_throw', enemies: pack, corpses: [corpse(2)],
      player: { x: 0, z: 0, essence: 0, maxEssence: 100 }, ready: readyOnly('harvest', 'hook_throw') }))?.id).toBe('harvest');
  });

  it('uses Monk control and toggles Veil form based on threat and meter', () => {
    expect(selectAutoCombatAction(input({ family: 'monk', primary: 'palm_strike', enemies: [enemy(1, 3), enemy(2, 3.5)],
      ready: readyOnly('toll', 'palm_strike') }))?.id).toBe('toll');
    const veil = input({ family: 'veil', primary: 'spirit_bolt', enemies: [enemy(1, 3)],
      player: { x: 0, z: 0, essence: 45, maxEssence: 100, veilForm: false }, ready: readyOnly('veil_form', 'spirit_bolt') });
    expect(selectAutoCombatAction(veil)?.id).toBe('spirit_bolt');
    expect(selectAutoCombatAction({ ...veil, player: { ...veil.player, hp: 65, maxHp: 100 } })?.id).toBe('veil_form');
    expect(selectAutoCombatAction({ ...veil, player: { ...veil.player, essence: 10, veilForm: true } })?.id).toBe('veil_form');
  });

  it('approaches only nearby targets and dodges a close windup', () => {
    const p = { x: 0, z: 0, essence: 0, maxEssence: 100 };
    expect(selectAutoCombatMovement({ player: p, enemies: [enemy(1, 6)], primary: 'hollow_cut' })).toEqual({ x: 1, z: 0 });
    expect(selectAutoCombatMovement({ player: p, enemies: [enemy(1, 40)], primary: 'hollow_cut' })).toBeNull();
    expect(selectAutoCombatMovement({ player: p, enemies: [enemy(1, 2, 0, { state: 'windup' })], primary: 'hollow_cut' })).toEqual({ x: -0, z: 1 });
  });

  it('moves smoothly with memory: no walk/stop flicker at the edge of reach, sticky target, committed dodge', () => {
    const p = { x: 0, z: 0, essence: 0, maxEssence: 100 };
    const reach = ABILITIES.bone_needle.range;
    const mem: AutoMoveMemory = {};
    // Just beyond reach: start closing, and keep closing while only slightly inside it.
    expect(selectAutoCombatMovement({ player: p, enemies: [enemy(1, reach + 0.1)] }, mem, 0, 0.016)).not.toBeNull();
    expect(selectAutoCombatMovement({ player: p, enemies: [enemy(1, reach - 0.5)] }, mem, 16, 0.016)).not.toBeNull();
    // Comfortably inside: stop, and stay stopped until it is past reach again.
    expect(selectAutoCombatMovement({ player: p, enemies: [enemy(1, reach - 1.5)] }, mem, 32, 0.016)).toBeNull();
    expect(selectAutoCombatMovement({ player: p, enemies: [enemy(1, reach - 0.3)] }, mem, 48, 0.016)).toBeNull();
    // Sticky: a second enemy only slightly nearer does not steal the heading.
    const m2: AutoMoveMemory = {};
    selectAutoCombatMovement({ player: p, enemies: [enemy(1, 20, 0)] }, m2, 0, 0.016);
    expect(m2.targetId).toBe(1);
    selectAutoCombatMovement({ player: p, enemies: [enemy(1, 20, 0), enemy(2, 0, 19)] }, m2, 16, 0.016);
    expect(m2.targetId).toBe(1);
    // A dodge side is held for a moment even after the windup ends.
    const m3: AutoMoveMemory = {};
    const dodge = selectAutoCombatMovement({ player: p, enemies: [enemy(1, 2, 0, { state: 'windup' })] }, m3, 0, 0);
    expect(selectAutoCombatMovement({ player: p, enemies: [enemy(1, 2, 0)] }, m3, 200, 0)).toEqual(dodge);
  });

  it('walks the nav path around a prop instead of grinding into it when the target is out of sight', () => {
    const p = { x: 0, z: 0, essence: 0, maxEssence: 100 };
    const mem: AutoMoveMemory = {};
    const nav = { clearLine: () => false, findPath: () => [{ x: 0, z: 5 }, { x: 20, z: 0 }] };
    // The target is due east, but the route goes north first.
    expect(selectAutoCombatMovement({ player: p, enemies: [enemy(1, 20, 0)], nav }, mem, 0, 0)).toEqual({ x: 0, z: 1 });
    // Clear line of sight: straight at it again.
    const open = { clearLine: () => true, findPath: () => [] };
    expect(selectAutoCombatMovement({ player: p, enemies: [enemy(1, 20, 0)], nav: open }, mem, 300, 0)).toEqual({ x: 1, z: 0 });
  });
});

