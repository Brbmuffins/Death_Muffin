import { describe, expect, it } from 'vitest';
import { Nav } from '../nav';
import { addToSlots, rollKill } from '../loot';
import { deriveStats } from '../characterStats';
import { mulberry32 } from '../rng';
import { DAMAGE_UPGRADE, WAVE_UPGRADE, milestones, waveModifiers } from '../../../server/rules/content/upgrades';
import { AREAS, AREA_ORDER } from '../../../server/rules/content/areas';
import { ITEMS } from '../../../server/rules/content/items';
import { DISCIPLINES } from '../../../server/rules/content/disciplines';
import { generateLayout } from '../../content/layout';
import { ABILITIES, HOTBAR, SOUL_HARVEST } from '../../content/abilities';
import { Player } from '../Player';
import type { Character } from '../../net/types';

const char = (over: Partial<Character> = {}): Character => ({
  id: 1,
  class_index: 2,
  class_name: 'Shadowblade',
  level: 1,
  experience: 0,
  gold: 0,
  stat_str: 5,
  stat_agi: 5,
  stat_int: 5,
  stat_vit: 5,
  ...over,
});

describe('navigation', () => {
  it('keeps bodies inside walkable space and out of sealed areas', () => {
    const nav = new Nav();
    const [x, z] = nav.resolve(45, -20, 0.45); // inside the sealed ossuary
    expect(nav.areaAt(x, z)).not.toBe('ossuary');
    nav.setUnlocked(['ossuary']);
    const [x2, z2] = nav.resolve(45, -20, 0.45);
    expect(nav.areaAt(x2, z2)).toBe('ossuary');
  });

  it('routes across areas through door corridors', () => {
    const nav = new Nav();
    nav.setUnlocked(['ossuary', 'nave']);
    const path = nav.route(0, 20, 0, -60); // chapterhouse → graves → nave
    expect(path.length).toBeGreaterThanOrEqual(5);
    expect(path[path.length - 1]).toEqual({ x: 0, z: -60 });
    // Waypoints pass through the chapter→graves corridor first.
    expect(Math.abs(path[0].x)).toBeLessThan(3.5);
  });

  it('pushes bodies out of obstacles', () => {
    const nav = new Nav();
    nav.addObstacle({ kind: 'circle', x: 0, z: -10, r: 1 });
    const [x, z] = nav.resolve(0.2, -10, 0.45);
    expect(Math.hypot(x, z + 10)).toBeGreaterThanOrEqual(1.44);
  });
});

describe('content integrity', () => {
  it('every loot table only references server-known item ids', () => {
    for (const id of AREA_ORDER) for (const l of AREAS[id].loot) expect(ITEMS[l.item], `${id}:${l.item}`).toBeDefined();
  });

  it('breaches sit inside their area', () => {
    for (const id of AREA_ORDER) {
      const r = AREAS[id].rect;
      for (const [x, z] of AREAS[id].breaches) {
        expect(x > r.x0 && x < r.x1 && z > r.z0 && z < r.z1, `${id} breach ${x},${z}`).toBe(true);
      }
    }
  });

  it('the layout is deterministic for a seed', () => {
    const a = generateLayout(7);
    const b = generateLayout(7);
    expect(a.props.length).toBe(b.props.length);
    expect(a.props[10]).toEqual(b.props[10]);
    expect(a.props.length).toBeGreaterThan(150);
  });

  it('interactables are not buried inside prop colliders', () => {
    const nav = new Nav();
    const layout = generateLayout();
    for (const p of layout.props) if (p.prop === 'pillar') nav.addObstacle({ kind: 'circle', x: p.x, z: p.z, r: 0.85 * p.scale });
    for (const id of AREA_ORDER) {
      for (const it of AREAS[id].interactables) {
        const [x, z] = nav.pushOut(it.x, it.z + 1.4, 0.45);
        expect(Math.hypot(x - it.x, z - (it.z + 1.4))).toBeLessThan(1.5);
      }
    }
  });
});

describe('progression math', () => {
  it('upgrade costs rise monotonically', () => {
    for (let t = 1; t < DAMAGE_UPGRADE.maxTier; t++) expect(DAMAGE_UPGRADE.cost(t)).toBeGreaterThan(DAMAGE_UPGRADE.cost(t - 1));
    for (let t = 1; t < WAVE_UPGRADE.maxTier; t++) expect(WAVE_UPGRADE.cost(t)).toBeGreaterThan(WAVE_UPGRADE.cost(t - 1));
  });

  it('wave speed raises pressure and reward together', () => {
    const w0 = waveModifiers(0);
    const w5 = waveModifiers(5);
    expect(w5.intervalMult).toBeLessThan(w0.intervalMult);
    expect(w5.capMult).toBeGreaterThan(w0.capMult);
    expect(w5.rewardMult).toBeGreaterThan(w0.rewardMult);
    expect(milestones(WAVE_UPGRADE.maxTier, WAVE_UPGRADE.maxTier)).toEqual([true, true, true]);
    expect(milestones(0, WAVE_UPGRADE.maxTier)).toEqual([false, false, false]);
  });

  it('damage tiers and gear feed one shared stat formula', () => {
    const base = deriveStats(char(), [], DISCIPLINES.gravecaller, 0);
    const tiered = deriveStats(char(), [], DISCIPLINES.gravecaller, 5);
    expect(tiered.spellPower / base.spellPower).toBeCloseTo(1.4);
    const ossuary = deriveStats(char(), [], DISCIPLINES.ossuary, 0);
    expect(ossuary.maxHp).toBeGreaterThan(base.maxHp);
  });

  it('kill rewards scale with elites and wave speed', () => {
    const avg = (elite: boolean, tier: number) => {
      const rand = mulberry32(3);
      let g = 0;
      for (let i = 0; i < 400; i++) g += rollKill('robber', 'graves', 1, elite, tier, rand).gold;
      return g / 400;
    };
    expect(avg(true, 0)).toBeGreaterThan(avg(false, 0) * 3);
    expect(avg(false, 8)).toBeGreaterThan(avg(false, 0));
    expect(rollKill('robber', 'graves', 1, true, 0, mulberry32(1)).shards).toBeGreaterThan(0);
  });

  it('pickups stack materials and respect the 48-slot bag', () => {
    let slots = addToSlots([], { item_id: 'ore_copper', quantity: 1 })!;
    slots = addToSlots(slots, { item_id: 'ore_copper', quantity: 2 })!;
    expect(slots).toHaveLength(1);
    expect(slots[0].quantity).toBe(3);
    let full = slots;
    for (let i = 0; i < 47; i++) full = addToSlots(full, { item_id: 'helm_copper', quantity: 1 })!;
    expect(full).toHaveLength(48);
    expect(addToSlots(full, { item_id: 'helm_iron', quantity: 1 })).toBeNull();
  });
});

describe('combat depth kit', () => {
  it('hotbar slots line up with ability slots (5 = right-click Corpse Explosion)', () => {
    HOTBAR.forEach((id, i) => expect(ABILITIES[id].slot).toBe(i + 1));
    expect(HOTBAR[4]).toBe('corpse_explosion');
  });

  it('the Soul Harvest meter fills to a charge, holds it, and resets when spent', () => {
    const p = new Player(deriveStats(char(), [], DISCIPLINES.gravecaller, 0), new Nav());
    let fills = 0;
    for (let i = 0; i < SOUL_HARVEST.souls + 10; i++) if (p.addSouls(1)) fills++;
    expect(fills).toBe(1);
    expect(p.soulsCharged).toBe(true);
    expect(p.souls).toBe(SOUL_HARVEST.souls);
    p.spendSouls();
    expect(p.soulsCharged).toBe(false);
    expect(p.souls).toBe(0);
  });
});

describe('click-to-move continuity', () => {
  it('keeps the current door waypoints when the held destination is unchanged', () => {
    let routes = 0;
    const nav = {
      findPath: () => { routes++; return [{ x: 0.1, z: 0 }, { x: 2, z: 0 }]; },
      resolve: (x: number, z: number) => [x, z],
      areaAt: () => 'chapterhouse',
    } as unknown as Nav;
    const player = new Player(deriveStats(char(), [], DISCIPLINES.gravecaller, 0), nav);
    player.moveTo(2, 0);
    player.update(0.1, 100, null);
    player.moveTo(2.1, 0);
    expect(routes).toBe(1);
    expect(player.x).toBeGreaterThan(0.1);
  });

  it('uses the same frame to advance beyond an already reached waypoint', () => {
    const nav = {
      findPath: () => [{ x: 0.1, z: 0 }, { x: 2, z: 0 }],
      resolve: (x: number, z: number) => [x, z],
      areaAt: () => 'chapterhouse',
    } as unknown as Nav;
    const player = new Player(deriveStats(char(), [], DISCIPLINES.gravecaller, 0), nav);
    player.moveTo(2, 0);
    expect(player.update(0.1, 100, null)).toBe(true);
    expect(player.moving).toBe(true);
    expect(player.x).toBeGreaterThan(0.1);
  });
});
