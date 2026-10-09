import { describe, expect, it, vi } from 'vitest';

vi.mock('../../audio/Audio', () => ({ audio: { play: vi.fn() } }));
vi.mock('../../graphics/DepthsView', () => ({ DepthsView: class { load() {} clear() {} update() {} dispose() {} setStairOpen() {} setChestOpened() {} } }));
vi.mock('../../graphics/StairView', () => ({ StairView: class { group = {}; update() {} dispose() {} } }));

import { DepthsController, type DepthsHost } from '../DepthsController';
import { Nav } from '../../gameplay/nav';
import { WorldSim } from '../../gameplay/sim/WorldSim';
import { mulberry32 } from '../../gameplay/rng';
import { depthEnemyLevel } from '../../../server/rules/content/depths';

function setup(peak: number | undefined) {
  const nav = new Nav();
  const sim = new WorldSim(nav, mulberry32(1));
  const life: Record<string, number> = peak === undefined ? {} : { 'peak.depth': peak };
  const maxed: Array<[string, number]> = [];
  const toasts: string[] = [];
  const host = {
    scene: { add() {} },
    nav,
    worldView: { lightSources: [] },
    player: { alive: true, facing: 0 },
    hud: { toast: (m: string) => toasts.push(m), banner() {} },
    effects: { lightFlash() {} },
    rig: { snap() {} },
    chronicle: { view: () => ({ life }), add() {}, max: (k: string, v: number) => maxed.push([k, v]), flush: async () => {} },
    sim: () => sim,
    selfId: () => 'p1',
    partySize: () => 0,
    inParty: () => false,
    stepOutOfParty() {},
    stepBackIntoParty() {},
    level: () => 40,
    teleportTo() {},
    loot: { clearWithin: () => 0 },
    tip() {},
  } as unknown as DepthsHost;
  const ctl = new DepthsController(host);
  const hero = () => sim.setPlayer({ id: 'p1', x: 0, z: 0, alive: true, area: 'depths', level: 40 });
  return { hero, ctl, sim, maxed, toasts, host };
}

describe('Depths stair: start at 1 or resume at the deepest floor', () => {
  it('offers no choice on a fresh character, or one that never passed depth 1', () => {
    for (const peak of [undefined, 0, 1]) {
      const { ctl, sim } = setup(peak);
      expect(ctl.resumeAt()).toBe(0);
      expect(ctl.stairClicked()).toBe(0);
      expect(sim.depths?.depth).toBe(1);
    }
  });

  it('offers the choice from depth 2 on, and starts nothing until a pick is made', () => {
    const { ctl, sim } = setup(17);
    expect(ctl.stairClicked()).toBe(17);
    expect(sim.depths).toBeNull();
    expect(ctl.prompt({ id: 'depths_stair', kind: 'stair', label: '', x: 0, z: 0 })).toContain('resume at depth 17');
  });

  it('resuming starts at the deepest depth, level-scaled, without lowering the record', () => {
    const { ctl, sim, maxed, hero } = setup(17);
    expect(ctl.enter(5, 17)).toBe(true);
    hero();
    expect(sim.depths!.depth).toBe(17);
    expect(sim.areaLevel('depths')).toBe(depthEnemyLevel(17, 40));
    expect(maxed).toContainEqual(['peak.depth', 17]);
  });

  it('starting at depth 1 still works from a deep character', () => {
    const { ctl, sim, hero } = setup(17);
    expect(ctl.enter(5, 1)).toBe(true);
    hero();
    expect(sim.depths!.depth).toBe(1);
    expect(sim.areaLevel('depths')).toBe(depthEnemyLevel(1, 40));
  });

  it('a fallen hero gets the usual refusal, not the choice', () => {
    const { ctl, host, toasts } = setup(17);
    (host.player as { alive: boolean }).alive = false;
    expect(ctl.stairClicked()).toBe(0);
    expect(toasts.length).toBe(1);
  });
});
