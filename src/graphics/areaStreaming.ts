import { AREAS, AREA_ORDER, DOORS, type AreaId, type Rect } from '../content/areas';

/**
 * Pure rules for "layering the levels": which areas are drawn around the player, in what order areas are built, and the
 * small work queue that builds them a slice at a time. WorldView owns the meshes; this owns the decisions (unit-tested).
 */

/** An area is always drawn when its rectangle is this close (m) to the player (a floor under the camera-footprint rule below, which is what reaches the screen corners of wide windows). */
export const VISIBLE_RADIUS = 45;

export function rectDistance(r: Rect, x: number, z: number) {
  const dx = Math.max(r.x0 - x, 0, x - r.x1);
  const dz = Math.max(r.z0 - z, 0, z - r.z1);
  return Math.hypot(dx, dz);
}

/** Areas that share a door with `area`. */
export function doorNeighbours(area: AreaId): AreaId[] {
  const out: AreaId[] = [];
  for (const d of DOORS) {
    if (d.a === area && !out.includes(d.b)) out.push(d.b);
    else if (d.b === area && !out.includes(d.a)) out.push(d.a);
  }
  return out;
}

/** The areas to draw for a player at (x, z) standing in `current`: the current area, and every area near enough to be on screen (so a door never shows a hole). */
export function visibleAreas(x: number, z: number, current: AreaId | null, radius = VISIBLE_RADIUS, view?: Rect | null): Set<AreaId> {
  const out = new Set<AreaId>();
  if (current) out.add(current);
  for (const id of AREA_ORDER) {
    const r = AREAS[id].rect;
    // Near enough to the hero, or touching what the camera really sees (its ground footprint: wider than `radius` on a wide window / the widest zoom).
    if (rectDistance(r, x, z) <= radius || (view && r.x0 <= view.x1 && r.x1 >= view.x0 && r.z0 <= view.z1 && r.z1 >= view.z0)) out.add(id);
  }
  return out;
}

/** What must be built before play: the starting area and its door neighbours. */
export function requiredAreas(start: AreaId): AreaId[] {
  return [start, ...doorNeighbours(start)];
}

/** `start` plus every area within `hops` door-steps of it (hops 1 = requiredAreas). */
export function areasWithin(start: AreaId, hops: number): AreaId[] {
  const out: AreaId[] = [start];
  let frontier: AreaId[] = [start];
  for (let h = 0; h < hops; h++) {
    const next: AreaId[] = [];
    for (const a of frontier) for (const n of doorNeighbours(a)) if (!out.includes(n)) {
      out.push(n);
      next.push(n);
    }
    frontier = next;
  }
  return out;
}

/** Build order: breadth-first over the door graph from `start`, then anything not reachable by doors (the Depths). Every area is eventually built, nearest first. */
export function buildOrder(start: AreaId): AreaId[] {
  const seen = new Set<AreaId>([start]);
  const order: AreaId[] = [start];
  for (let i = 0; i < order.length; i++) {
    for (const n of doorNeighbours(order[i])) {
      if (!seen.has(n)) {
        seen.add(n);
        order.push(n);
      }
    }
  }
  for (const id of AREA_ORDER) if (!seen.has(id)) order.push(id);
  return order;
}

export interface BuildTask {
  /** Lower runs first. */
  prio: number;
  run: () => void;
  /** Free-form label (WorldView uses the area id) so a whole group of steps can be drained or re-ranked. */
  tag?: string;
}

/** A priority queue of small synchronous build steps, run a time-boxed slice at a time. */
export class BuildQueue {
  private tasks: BuildTask[] = [];
  constructor(private now: () => number = () => performance.now()) {}

  get size() {
    return this.tasks.length;
  }

  add(task: BuildTask) {
    // Stable insert: after the last task with prio <= this one.
    let i = this.tasks.length;
    while (i > 0 && this.tasks[i - 1].prio > task.prio) i--;
    this.tasks.splice(i, 0, task);
  }

  /** Re-rank (a teleport changed what is needed next). */
  reprioritise(prio: (t: BuildTask) => number) {
    for (const t of this.tasks) t.prio = prio(t);
    this.tasks.sort((a, b) => a.prio - b.prio);
  }

  /** Runs tasks until `budgetMs` is spent (always at least one). Returns how many ran. */
  runSlice(budgetMs: number): number {
    const t0 = this.now();
    let n = 0;
    while (this.tasks.length) {
      this.tasks.shift()!.run();
      n++;
      if (this.now() - t0 >= budgetMs) break;
    }
    return n;
  }

  /** Drains tasks matching `pred` right now (an area that must be on screen this frame). */
  runWhere(pred: (t: BuildTask) => boolean) {
    const mine = this.tasks.filter(pred);
    this.tasks = this.tasks.filter((t) => !pred(t));
    for (const t of mine) t.run();
    return mine.length;
  }
}

/** Fraction of the veil's work finished (0..1). Empty work counts as done. */
export const loadProgress = (done: number, total: number) => (total <= 0 ? 1 : Math.max(0, Math.min(1, done / total)));
