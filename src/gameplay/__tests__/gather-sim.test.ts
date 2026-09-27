import { describe, expect, it } from 'vitest';
import { Nav } from '../nav';
import { WorldSim } from '../sim/WorldSim';
import { WorldMirror, makeSnapshot } from '../sim/snapshot';
import { mulberry32 } from '../rng';
import { NODES, RICH_RESPAWN } from '../gatheringRules';
import { generateLayout } from '../../content/layout';
import { nextAutoNode, standSpot, gatherBlocker, type LiveNode } from '../gatherPlan';

const layout = generateLayout();

function world() {
  const nav = new Nav();
  const sim = new WorldSim(nav, mulberry32(9));
  sim.setNodes(layout.nodes);
  return sim;
}

const oak = () => layout.nodes.find((n) => n.type === 'coffin_oak' && n.area === 'acre')!;

describe('gathering nodes in the sim', () => {
  it('seeds every layout node with a yield inside its range', () => {
    const sim = world();
    expect(sim.nodes.size).toBe(layout.nodes.length);
    for (const n of sim.nodes.values()) {
      const [lo, hi] = NODES[n.type].yields;
      expect(n.remaining).toBeGreaterThanOrEqual(lo);
      expect(n.remaining).toBeLessThanOrEqual(Math.round(hi * (n.rich ? 1.5 : 1)));
    }
  });

  it('depletes on reported successes, emits nodeGone, and respawns on its timer', () => {
    const sim = world();
    const o = oak();
    sim.setPlayer({ id: 'p1', x: o.x + 1.2, z: o.z, alive: true, area: 'acre' });
    const n = sim.nodes.get(o.id)!;
    const start = n.remaining;
    const events = [];
    for (let i = 0; i < start; i++) {
      sim.apply({ t: 'gather', by: 'p1', nodeId: o.id, successes: 1 });
      events.push(...sim.step(0.01));
    }
    expect(n.remaining).toBe(0);
    const gone = events.find((e) => e.t === 'nodeGone');
    expect(gone).toMatchObject({ id: o.id, by: 'p1', respawnS: NODES.coffin_oak.respawnS });
    expect(sim.depletedNodes().map(([id]) => id)).toContain(o.id);
    // Extra gathering on a depleted node does nothing.
    sim.apply({ t: 'gather', by: 'p1', nodeId: o.id, successes: 3 });
    expect(n.remaining).toBe(0);
    let back = false;
    for (let t = 0; t < NODES.coffin_oak.respawnS + 1 && !back; t += 0.5) back = sim.step(0.5).some((e) => e.t === 'nodeBack' && e.id === o.id);
    expect(back).toBe(true);
    expect(n.remaining).toBeGreaterThan(0);
  });

  it('ignores gathering from a player who is not standing at the node', () => {
    const sim = world();
    const o = oak();
    sim.setPlayer({ id: 'far', x: o.x + 20, z: o.z, alive: true, area: 'acre' });
    const before = sim.nodes.get(o.id)!.remaining;
    sim.apply({ t: 'gather', by: 'far', nodeId: o.id, successes: 1 });
    expect(sim.nodes.get(o.id)!.remaining).toBe(before);
  });

  it('two gatherers on one node deplete it together', () => {
    const sim = world();
    const o = layout.nodes.find((n) => n.type === 'churchyard_yew')!;
    sim.setPlayer({ id: 'a', x: o.x + 1.3, z: o.z, alive: true, area: 'acre' });
    sim.setPlayer({ id: 'b', x: o.x - 1.3, z: o.z, alive: true, area: 'acre' });
    const n = sim.nodes.get(o.id)!;
    const start = n.remaining;
    let turns = 0;
    while (n.remaining > 0 && turns < 100) {
      sim.apply({ t: 'gather', by: turns % 2 ? 'a' : 'b', nodeId: o.id, successes: 1 });
      turns++;
    }
    expect(turns).toBe(start);
  });

  it('rich nodes come back twice as fast', () => {
    const sim = world();
    const rich = layout.nodes.find((n) => n.rich)!;
    const n = sim.nodes.get(rich.id)!;
    sim.setPlayer({ id: 'p', x: rich.x + 1, z: rich.z, alive: true, area: rich.area });
    const events = [];
    while (n.remaining > 0) {
      sim.apply({ t: 'gather', by: 'p', nodeId: rich.id, successes: 3 });
      events.push(...sim.step(0.01));
    }
    const gone = events.find((e) => e.t === 'nodeGone');
    expect(gone && gone.t === 'nodeGone' && gone.respawnS).toBe(NODES[rich.type].respawnS * RICH_RESPAWN);
  });

  it('depleted nodes survive a snapshot → mirror → new host round trip', () => {
    const sim = world();
    const o = oak();
    sim.setPlayer({ id: 'p1', x: o.x + 1.2, z: o.z, alive: true, area: 'acre' });
    const n = sim.nodes.get(o.id)!;
    while (n.remaining > 0) sim.apply({ t: 'gather', by: 'p1', nodeId: o.id, successes: 3 });
    const mirror = new WorldMirror();
    mirror.applyEvents(sim.step(0.1));
    expect(mirror.depleted.has(o.id)).toBe(true);
    mirror.applySnapshot(makeSnapshot(sim, false));
    expect(mirror.depleted.has(o.id)).toBe(true);
    const heir = world();
    mirror.seed(heir);
    expect(heir.nodes.get(o.id)!.remaining).toBe(0);
    let back = false;
    for (let t = 0; t < 12 && !back; t += 0.5) back = heir.step(0.5).some((e) => e.t === 'nodeBack' && e.id === o.id);
    expect(back).toBe(true);
    mirror.applyEvents([{ t: 'nodeBack', id: o.id }]);
    expect(mirror.depleted.has(o.id)).toBe(false);
  });
});

describe('auto-gathering decisions', () => {
  const live = (over: Partial<LiveNode>[]): LiveNode[] =>
    over.map((o, i) => ({ id: `acre_${i}`, type: 'coffin_oak', x: i * 4, z: 0, area: 'acre', rot: 0, remaining: 3, ...o }));

  it('moves to the nearest live node of the same type in the same area', () => {
    const nodes = live([{ x: 0, remaining: 0 }, { x: 10 }, { x: 5 }, { x: 3, type: 'hangman_elm' }, { x: 2, area: 'graves' }]);
    const next = nextAutoNode({ from: nodes[0], nodes, level: 20, x: 0, z: 0 });
    expect(next?.x).toBe(5);
  });

  it('waits (null) when nothing of that type is live, and never goes above the level', () => {
    const nodes = live([{ x: 0, remaining: 0 }, { x: 4, remaining: 0 }]);
    expect(nextAutoNode({ from: nodes[0], nodes, level: 5, x: 0, z: 0 })).toBeNull();
    const yews = live([{ type: 'churchyard_yew', remaining: 0 }, { type: 'churchyard_yew', x: 4 }]);
    expect(nextAutoNode({ from: yews[0], nodes: yews, level: 10, x: 0, z: 0 })).toBeNull();
  });

  it('explains a level gate in words', () => {
    expect(gatherBlocker('churchyard_yew', 10)).toBe('Requires Woodcutting level 45');
    expect(gatherBlocker('coffin_oak', 1)).toBeNull();
  });

  it('stands on a free spot of the ring, nearest to the hero', () => {
    const nav = { blocked: (x: number) => x > 0 };
    const spot = standSpot(nav, { type: 'coffin_oak', x: 0, z: 0 }, -10, 0)!;
    expect(spot.x).toBeLessThan(0);
    expect(Math.hypot(spot.x, spot.z)).toBeCloseTo(1.35, 2);
    expect(standSpot({ blocked: () => true }, { type: 'coffin_oak', x: 0, z: 0 }, 0, 0)).toBeNull();
  });
});
