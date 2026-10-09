import { describe, expect, it } from 'vitest';
import { AREAS, AREA_ORDER, DOORS } from '../../../server/rules/content/areas';
import { BuildQueue, buildOrder, doorNeighbours, loadProgress, rectDistance, requiredAreas, visibleAreas } from '../areaStreaming';

describe('area streaming rules', () => {
  it('door neighbours follow DOORS both ways', () => {
    for (const d of DOORS) {
      expect(doorNeighbours(d.a)).toContain(d.b);
      expect(doorNeighbours(d.b)).toContain(d.a);
    }
    expect(doorNeighbours('chapterhouse').sort()).toEqual(['acre', 'alchemist_wing', 'graves']);
  });

  it('always draws the current area and never leaves a hole at a door', () => {
    for (const d of DOORS) {
      const cx = (d.rect.x0 + d.rect.x1) / 2;
      const cz = (d.rect.z0 + d.rect.z1) / 2;
      const v = visibleAreas(cx, cz, d.a);
      expect(v.has(d.a)).toBe(true);
      expect(v.has(d.b)).toBe(true);
    }
  });

  it('hides far areas', () => {
    const v = visibleAreas(AREAS.sanctum.rect.x0 + 5, AREAS.sanctum.rect.z0 + 5, 'sanctum');
    expect(v.has('chapterhouse')).toBe(false);
    expect(v.has('pyre')).toBe(false);
    expect(v.size).toBeLessThan(AREA_ORDER.length / 2);
  });

  it('measures distance to a rectangle', () => {
    const r = { x0: 0, z0: 0, x1: 10, z1: 10 };
    expect(rectDistance(r, 5, 5)).toBe(0);
    expect(rectDistance(r, 13, 14)).toBe(5);
  });

  it('requires the start area plus its neighbours, and orders every area breadth-first', () => {
    expect(requiredAreas('acre')).toEqual(['acre', 'chapterhouse']);
    const order = buildOrder('acre');
    expect(order[0]).toBe('acre');
    expect(order.slice(0, 2)).toEqual(['acre', 'chapterhouse']);
    expect([...order].sort()).toEqual([...AREA_ORDER].sort());
    expect(new Set(order).size).toBe(order.length);
  });

  it('runs build tasks by priority, a time-boxed slice at a time', () => {
    let t = 0;
    const q = new BuildQueue(() => t);
    const ran: string[] = [];
    const add = (name: string, prio: number, cost = 1) => q.add({ prio, run: () => { ran.push(name); t += cost; } });
    add('b1', 2); add('a1', 1); add('b2', 2); add('a2', 1);
    expect(q.runSlice(0)).toBe(1); // always at least one
    expect(q.runSlice(2)).toBe(2);
    expect(ran).toEqual(['a1', 'a2', 'b1']);
    expect(q.size).toBe(1);
    q.add({ prio: 0, run: () => ran.push('urgent') });
    expect(q.runWhere((x) => x.prio === 0)).toBe(1);
    q.runSlice(10);
    expect(ran).toEqual(['a1', 'a2', 'b1', 'urgent', 'b2']);
  });

  it('reports progress', () => {
    expect(loadProgress(0, 0)).toBe(1);
    expect(loadProgress(5, 10)).toBe(0.5);
    expect(loadProgress(12, 10)).toBe(1);
  });
});
