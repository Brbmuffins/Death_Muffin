import { describe, expect, it } from 'vitest';
import { AREAS, DEPTHS_RECT } from '../../content/areas';
import { Nav } from '../nav';
import { FLOOR_COLS, FLOOR_ROWS, floorHop, floorPath, floorProblems, floorSeed, generateFloor, roomAt, type DepthsFloor } from '../depthsFloor';

const SEEDS = Array.from({ length: 160 }, (_, i) => i * 7919 + 13);
const DEPTH_SAMPLE = [1, 2, 4, 5, 9, 10, 15, 20, 35, 60];

/** A walker that follows the same steering the dead and the hero's clicks use, to the stair, through the real nav. */
function walkTo(f: DepthsFloor, nav: Nav, from: { x: number; z: number }, to: { x: number; z: number }, maxSteps = 4000) {
  let x = from.x;
  let z = from.z;
  const goal = { x: to.x, z: to.z + 1.4 };
  for (let i = 0; i < maxSteps; i++) {
    if (Math.hypot(goal.x - x, goal.z - z) < 0.7) return { reached: true, steps: i };
    const hop = floorHop(f, x, z, goal.x, goal.z) ?? goal;
    const dx = hop.x - x;
    const dz = hop.z - z;
    const d = Math.hypot(dx, dz) || 1;
    [x, z] = nav.resolve(x + (dx / d) * 0.12, z + (dz / d) * 0.12, 0.45);
  }
  return { reached: false, steps: maxSteps };
}

describe('Depths floor generator', () => {
  it('is deterministic: the same seed and depth always build the same floor', () => {
    for (const seed of SEEDS.slice(0, 20)) {
      expect(JSON.stringify(generateFloor(seed, 7))).toBe(JSON.stringify(generateFloor(seed, 7)));
    }
  });

  it('differs between seeds and between depths of one run', () => {
    const sigs = new Set(SEEDS.slice(0, 40).map((s) => JSON.stringify(generateFloor(s, 3).doors.map((d) => [d.a, d.b, Math.round(d.x * 10), Math.round(d.z * 10)]))));
    expect(sigs.size).toBeGreaterThan(30);
    const run = 12345;
    const floors = new Set([1, 2, 3, 4, 5, 6].map((d) => JSON.stringify(generateFloor(floorSeed(run, d), d).doors)));
    expect(floors.size).toBeGreaterThan(4);
  });

  it('builds sound floors: connected, navigable, every point reachable, over many seeds and depths', () => {
    for (const seed of SEEDS) {
      for (const depth of DEPTH_SAMPLE) {
        const f = generateFloor(seed, depth);
        expect(floorProblems(f), `seed ${seed} depth ${depth}`).toEqual([]);
      }
    }
  });

  it('has seven to nine rooms, a spanning tree of doors plus loops, and a stair far from the way in', () => {
    let loops = 0;
    for (const seed of SEEDS.slice(0, 80)) {
      const f = generateFloor(seed, 4);
      const active = f.rooms.filter((r) => r.active);
      expect(active.length).toBeGreaterThanOrEqual(7);
      expect(active.length).toBeLessThanOrEqual(9);
      expect(f.doors.length).toBeGreaterThanOrEqual(active.length - 1); // a spanning tree at the least
      expect(f.doors.length).toBeLessThanOrEqual(active.length + 2);
      if (f.doors.length >= active.length) loops++;
      expect(f.rooms[f.stairRoom].dist).toBe(Math.max(...active.map((r) => r.dist)));
      expect(f.rooms[f.stairRoom].dist).toBeGreaterThanOrEqual(2);
      expect(f.startRoom).not.toBe(f.stairRoom);
      // The middle chamber is never filled in (so the grid always stays one piece).
      expect(f.rooms[4].active).toBe(true);
    }
    // Most floors have a loop to run round (a tree of seven rooms has no spare wall to open).
    expect(loops).toBeGreaterThan(60);
  });

  it('holds a chest every fifth floor, in a room that is neither the way in nor the stair', () => {
    for (const seed of SEEDS.slice(0, 40)) {
      for (const depth of [1, 3, 4, 5, 6, 10, 15, 25]) {
        const f = generateFloor(seed, depth);
        if (depth % 5 === 0) {
          expect(f.chest, `seed ${seed} depth ${depth}`).not.toBeNull();
          expect(f.chestRoom).not.toBe(f.startRoom);
          expect(f.chestRoom).not.toBe(f.stairRoom);
          expect(roomAt(f, f.chest!.x, f.chest!.z)).toBe(f.chestRoom);
        } else expect(f.chest).toBeNull();
      }
    }
  });

  it('keeps everything inside the Depths rectangle and out of the doorways', () => {
    const r = DEPTHS_RECT;
    expect(AREAS.depths.rect).toBe(DEPTHS_RECT);
    for (const seed of SEEDS.slice(0, 60)) {
      const f = generateFloor(seed, 10);
      for (const p of [f.start, f.stairUp, f.stairDown, ...(f.chest ? [f.chest] : []), ...f.breaches]) {
        expect(p.x).toBeGreaterThan(r.x0);
        expect(p.x).toBeLessThan(r.x1);
        expect(p.z).toBeGreaterThan(r.z0);
        expect(p.z).toBeLessThan(r.z1);
      }
      for (const prop of f.props) {
        if (prop.prop === 'grave_lantern') continue;
        for (const d of f.doors) expect(Math.hypot(prop.x - d.x, prop.z - d.z), `${prop.prop} in a doorway`).toBeGreaterThan(2.9);
      }
      // Spawn points: none in the chamber the hero arrives in, two in every other.
      expect(f.breaches.some((b) => b.room === f.startRoom)).toBe(false);
      for (const room of f.rooms.filter((q) => q.active && q.id !== f.startRoom)) expect(f.breaches.filter((b) => b.room === room.id).length).toBeGreaterThanOrEqual(1);
    }
  });

  it('routes: every room reaches every room through doorways, and walkers get from the way in to the stair on foot', () => {
    for (const seed of SEEDS.slice(0, 40)) {
      const f = generateFloor(seed, 6 + (seed % 3) * 5);
      const active = f.rooms.filter((r) => r.active);
      for (const a of active) for (const b of active) if (a !== b) expect(f.next[a.id][b.id], `${a.id}->${b.id}`).toBeGreaterThanOrEqual(0);
      const nav = new Nav();
      nav.openInstance('depths');
      nav.loadDepthsFloor(f);
      expect(walkTo(f, nav, f.start, f.stairDown).reached, `seed ${seed}`).toBe(true);
      if (f.chest) expect(walkTo(f, nav, f.start, f.chest).reached, `seed ${seed} chest`).toBe(true);
      // The planned route is a chain of doorways ending at the goal.
      const path = floorPath(f, f.start.x, f.start.z, f.stairDown.x, f.stairDown.z);
      expect(path[path.length - 1]).toEqual({ x: f.stairDown.x, z: f.stairDown.z });
      expect(path.length).toBe(1 + 2 * f.rooms[f.stairRoom].dist);
    }
  });

  it('a body in a doorway gets clear of the wall\'s end to reach a target hard against the wall (it used to jitter in the mouth forever)', () => {
    for (const seed of SEEDS.slice(0, 40)) {
      const f = generateFloor(seed, 3);
      const nav = new Nav();
      nav.openInstance('depths');
      nav.loadDepthsFloor(f);
      for (const d of f.doors) {
        const perp = { x: -d.dir.z, z: d.dir.x };
        for (const side of [1, -1]) for (const bias of [1, -1]) {
          // Start in the middle of the mouth; the goal is 1.5 m out on one side and just beside the wall's end.
          let x = d.x + d.dir.x * side * -0.2;
          let z = d.z + d.dir.z * side * -0.2;
          const goal = { x: d.x + d.dir.x * side * 1.5 + perp.x * bias * 3.2, z: d.z + d.dir.z * side * 1.5 + perp.z * bias * 3.2 };
          // Goals that sit behind a lantern or in a prop's lee are not the test (the layout check covers reachability); the wall is.
          if (nav.blocked(goal.x, goal.z, 0.9) || f.props.some((p) => Math.hypot(p.x - goal.x, p.z - goal.z) < 1.6)) continue;
          let reached = false;
          for (let i = 0; i < 700 && !reached; i++) {
            if (Math.hypot(goal.x - x, goal.z - z) < 0.5) reached = true;
            const hop = floorHop(f, x, z, goal.x, goal.z) ?? goal;
            const dx = hop.x - x;
            const dz = hop.z - z;
            const len = Math.hypot(dx, dz) || 1;
            [x, z] = nav.resolve(x + (dx / len) * 0.12, z + (dz / len) * 0.12, 0.35);
          }
          expect(reached, `seed ${seed} door ${d.a}-${d.b} side ${side} bias ${bias}`).toBe(true);
        }
      }
    }
  });

  it('the tall partitions block sight and bodies; the nav forgets a floor when it is cleared', () => {
    const f = generateFloor(99, 5);
    const nav = new Nav();
    nav.openInstance('depths');
    nav.loadDepthsFloor(f);
    const before = nav.obstacleCount;
    expect(before).toBeGreaterThan(20);
    // Two points in rooms that share a wall with no doorway between them are out of each other's sight.
    const a = f.rooms.find((r) => r.active && r.row === 0 && r.col === 0) ?? f.rooms[4];
    const b = f.rooms[4];
    if (a !== b && !a.adj.some((x) => x.to === b.id)) expect(nav.sightBlocked(a.cx, a.cz, b.cx, b.cz)).toBe(true);
    nav.loadDepthsFloor(generateFloor(100, 5));
    expect(Math.abs(nav.obstacleCount - before)).toBeLessThan(60);
    nav.clearDepthsFloor();
    nav.closeInstance('depths');
    expect(nav.depthsFloor).toBeNull();
    expect(nav.isUnlocked('depths')).toBe(false);
    expect(nav.sightBlocked(a.cx, a.cz, b.cx, b.cz)).toBe(false);
  });

  it('is an instance: closed to the nav until a run opens it, and setUnlocked never opens it', () => {
    const nav = new Nav();
    expect(nav.isUnlocked('depths')).toBe(false);
    nav.setUnlocked(['ossuary', 'depths']);
    expect(nav.isUnlocked('depths')).toBe(false);
    nav.openInstance('depths');
    nav.setUnlocked(['ossuary']);
    expect(nav.isUnlocked('depths')).toBe(true);
    // A body told to stand in the closed Depths is put back in an open hall.
    nav.closeInstance('depths');
    const [x] = nav.resolve(DEPTHS_RECT.x0 + 5, DEPTHS_RECT.z0 + 5, 0.45);
    expect(x).toBeLessThan(DEPTHS_RECT.x0);
  });

  it('the grid is 3 x 3', () => {
    expect(FLOOR_COLS * FLOOR_ROWS).toBe(generateFloor(1, 1).rooms.length);
  });
});
