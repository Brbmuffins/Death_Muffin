import { AREAS, AREA_ORDER, DOORS, isAlwaysOpen, type AreaId, type DoorDef, type Rect } from '../../server/rules/content/areas';
import { floorHop, floorObstacles, floorPath, floorSightBoxes, type DepthsFloor } from './depthsFloor';

export interface CircleObstacle {
  kind: 'circle';
  x: number;
  z: number;
  r: number;
}
export interface BoxObstacle {
  kind: 'box';
  x0: number;
  z0: number;
  x1: number;
  z1: number;
}
export type Obstacle = CircleObstacle | BoxObstacle;

const CELL = 4;
/** Integer key of a grid cell (world coordinates stay far inside ±32k cells). */
const gk = (cx: number, cz: number) => (cx + 32768) * 65536 + (cz + 32768);
const NONE: readonly Obstacle[] = [];

function inRect(r: Rect, x: number, z: number, pad = 0) {
  return x >= r.x0 + pad && x <= r.x1 - pad && z >= r.z0 + pad && z <= r.z1 - pad;
}

function clampToRect(r: Rect, x: number, z: number, pad: number): [number, number] {
  return [
    Math.min(Math.max(x, r.x0 + pad), r.x1 - pad),
    Math.min(Math.max(z, r.z0 + pad), r.z1 - pad),
  ];
}

export function rectCenter(r: Rect) {
  return { x: (r.x0 + r.x1) / 2, z: (r.z0 + r.z1) / 2 };
}

/**
 * World navigation: walkable space is the union of area rectangles plus the
 * corridors of open doors. Obstacles (pillars, tombs, walls) push bodies out.
 * Cross-area movement routes through door centres (BFS over the area graph),
 * which is all the pathfinding a rooms-and-corridors layout needs.
 */
export class Nav {
  private obstacles: Obstacle[] = [];
  /** Obstacles by 4 m cell; numeric keys (gk) because blocked() looks cells up per A* cell and per 0.25 m of a line check. */
  private grid = new Map<number, Obstacle[]>();
  private unlocked = new Set<AreaId>(AREA_ORDER.filter(isAlwaysOpen));
  /** Instance areas (the Depths) that a run has opened. Kept apart from `unlocked` so setUnlocked (called on every seal) never closes one. */
  private instances = new Set<AreaId>();

  setUnlocked(areas: Iterable<AreaId>) {
    // An instance is opened by its run, never by a seal or by dev access.
    this.dropFree();
    this.unlocked = new Set([...areas].filter((id) => !AREAS[id].instance));
    for (const id of AREA_ORDER) if (isAlwaysOpen(id)) this.unlocked.add(id);
  }

  isUnlocked(area: AreaId) {
    return this.unlocked.has(area) || this.instances.has(area);
  }

  isDoorOpen(door: DoorDef) {
    return this.isUnlocked(door.a) && this.isUnlocked(door.b);
  }

  /** The current floor of the Catacomb Depths (null between runs). Its walls and props are obstacles, its tall walls block sight, and it routes walkers through its doorways. */
  private floor: DepthsFloor | null = null;
  private floorObs: Obstacle[] = [];
  private floorSight: BoxObstacle[] = [];

  get depthsFloor(): DepthsFloor | null {
    return this.floor;
  }

  /** Open an instance area to walkers (a run began). */
  openInstance(id: AreaId) {
    this.instances.add(id);
    this.dropFree();
  }

  closeInstance(id: AreaId) {
    this.instances.delete(id);
    this.dropFree();
  }

  /** Replace the Depths' floor: the old floor's colliders go, the new one's come in. */
  loadDepthsFloor(floor: DepthsFloor) {
    this.clearDepthsFloor();
    this.floor = floor;
    this.floorObs = floorObstacles(floor);
    for (const o of this.floorObs) this.addObstacle(o);
    this.floorSight = floorSightBoxes(floor);
  }

  clearDepthsFloor() {
    for (const o of this.floorObs) this.removeObstacle(o);
    this.floorObs = [];
    this.floorSight = [];
    this.floor = null;
  }

  /** The next place to steer for when walking across the Depths floor (null = straight on, or not on the floor). */
  depthsHop(fx: number, fz: number, tx: number, tz: number): { x: number; z: number } | null {
    return this.floor ? floorHop(this.floor, fx, fz, tx, tz) : null;
  }

  /** Tall standing walls (dungeon partitions): they stop cones as well as bodies. */
  private sightBlockers: BoxObstacle[] = [];

  addSightBlocker(b: BoxObstacle) {
    this.sightBlockers.push(b);
  }

  private removeObstacle(o: Obstacle) {
    this.dropFree();
    const i = this.obstacles.indexOf(o);
    if (i >= 0) this.obstacles.splice(i, 1);
    const [x0, z0, x1, z1] = o.kind === 'circle' ? [o.x - o.r, o.z - o.r, o.x + o.r, o.z + o.r] : [o.x0, o.z0, o.x1, o.z1];
    for (let cx = Math.floor(x0 / CELL); cx <= Math.floor(x1 / CELL); cx++) {
      for (let cz = Math.floor(z0 / CELL); cz <= Math.floor(z1 / CELL); cz++) {
        const k = gk(cx, cz);
        const list = this.grid.get(k);
        if (!list) continue;
        const at = list.indexOf(o);
        if (at >= 0) list.splice(at, 1);
        if (!list.length) this.grid.delete(k);
      }
    }
  }

  /** Does the straight line a→b pass through a tall wall? (Liang–Barsky against each box.) */
  sightBlocked(ax: number, az: number, bx: number, bz: number): boolean {
    const dx = bx - ax;
    const dz = bz - az;
    for (const w of this.floorSight.length ? [...this.sightBlockers, ...this.floorSight] : this.sightBlockers) {
      let t0 = 0;
      let t1 = 1;
      let hit = true;
      for (const [p, q] of [[-dx, ax - w.x0], [dx, w.x1 - ax], [-dz, az - w.z0], [dz, w.z1 - az]] as const) {
        if (p === 0) {
          if (q < 0) { hit = false; break; }
        } else {
          const r = q / p;
          if (p < 0) { if (r > t1) { hit = false; break; } if (r > t0) t0 = r; }
          else { if (r < t0) { hit = false; break; } if (r < t1) t1 = r; }
        }
      }
      if (hit) return true;
    }
    return false;
  }

  addObstacle(o: Obstacle) {
    this.dropFree();
    this.obstacles.push(o);
    const [x0, z0, x1, z1] =
      o.kind === 'circle' ? [o.x - o.r, o.z - o.r, o.x + o.r, o.z + o.r] : [o.x0, o.z0, o.x1, o.z1];
    for (let cx = Math.floor(x0 / CELL); cx <= Math.floor(x1 / CELL); cx++) {
      for (let cz = Math.floor(z0 / CELL); cz <= Math.floor(z1 / CELL); cz++) {
        const k = gk(cx, cz);
        let list = this.grid.get(k);
        if (!list) this.grid.set(k, (list = []));
        list.push(o);
      }
    }
  }

  get obstacleCount() {
    return this.obstacles.length;
  }

  /** Walkable rects, cached: blocked() runs per A* cell and per 0.25 m of every line check, and the set only changes on unlock / instance. */
  private walkCache: Rect[] | null = null;
  /** Free/blocked flags of an area's 0.5 m path grid per body radius, filled lazily and kept: rooms do not move, so only the first long route in a room pays for the cells it explores. Cleared when obstacles or walkable space change. */
  private freeCache = new Map<string, Int8Array>();
  private dropFree() { this.walkCache = null; if (this.freeCache.size) this.freeCache.clear(); }
  private walkables(): Rect[] {
    if (this.walkCache) return this.walkCache;
    const list: Rect[] = [];
    for (const id of AREA_ORDER) if (this.isUnlocked(id)) list.push(AREAS[id].rect);
    for (const d of DOORS) if (this.isDoorOpen(d)) list.push(d.rect);
    return (this.walkCache = list);
  }

  areaAt(x: number, z: number): AreaId | null {
    for (const id of AREA_ORDER) if (inRect(AREAS[id].rect, x, z)) return id;
    return null;
  }

  /** Push a body of radius r out of obstacles. */
  pushOut(x: number, z: number, r: number): [number, number] {
    for (let pass = 0; pass < 2; pass++) {
      const list = this.grid.get(gk(Math.floor(x / CELL), Math.floor(z / CELL)));
      if (!list) break;
      let moved = false;
      for (const o of list) {
        if (o.kind === 'circle') {
          const dx = x - o.x;
          const dz = z - o.z;
          const d = Math.hypot(dx, dz);
          const min = o.r + r;
          if (d < min) {
            const nx = d > 1e-4 ? dx / d : 1;
            const nz = d > 1e-4 ? dz / d : 0;
            x = o.x + nx * min;
            z = o.z + nz * min;
            moved = true;
          }
        } else {
          const cx = Math.min(Math.max(x, o.x0), o.x1);
          const cz = Math.min(Math.max(z, o.z0), o.z1);
          const dx = x - cx;
          const dz = z - cz;
          const d = Math.hypot(dx, dz);
          if (d < r) {
            if (d > 1e-4) {
              x = cx + (dx / d) * r;
              z = cz + (dz / d) * r;
            } else {
              // Centre inside the box: exit via the nearest face.
              const exits = [x - o.x0, o.x1 - x, z - o.z0, o.z1 - z];
              const i = exits.indexOf(Math.min(...exits));
              if (i === 0) x = o.x0 - r;
              else if (i === 1) x = o.x1 + r;
              else if (i === 2) z = o.z0 - r;
              else z = o.z1 + r;
            }
            moved = true;
          }
        }
      }
      if (!moved) break;
    }
    return [x, z];
  }

  /** Clamp into walkable space (areas + open doors), then out of obstacles. */
  resolve(x: number, z: number, r: number): [number, number] {
    [x, z] = this.pushOut(x, z, r);
    const rects = this.walkables();
    for (const rect of rects) if (inRect(rect, x, z, r)) return [x, z];
    let best: [number, number] = [x, z];
    let bestD = Infinity;
    for (const rect of rects) {
      const p = clampToRect(rect, x, z, r);
      const d = (p[0] - x) ** 2 + (p[1] - z) ** 2;
      if (d < bestD) {
        bestD = d;
        best = p;
      }
    }
    return best;
  }

  /** Enemies stay inside their own area (never the chapterhouse or corridors). */
  resolveInArea(area: AreaId, x: number, z: number, r: number): [number, number] {
    [x, z] = this.pushOut(x, z, r);
    return clampToRect(AREAS[area].rect, x, z, r);
  }

  /** Waypoints from one point to another, via door centres when crossing areas. */
  route(fx: number, fz: number, tx: number, tz: number): { x: number; z: number }[] {
    const from = this.areaAt(fx, fz) ?? this.nearestArea(fx, fz);
    const to = this.areaAt(tx, tz) ?? this.nearestArea(tx, tz);
    if (from === 'depths' && to === 'depths' && this.floor) return floorPath(this.floor, fx, fz, tx, tz);
    if (!from || !to || from === to) return [{ x: tx, z: tz }];
    // BFS over open doors.
    const prev = new Map<AreaId, { area: AreaId; door: DoorDef }>();
    const queue: AreaId[] = [from];
    const seen = new Set<AreaId>([from]);
    while (queue.length) {
      const cur = queue.shift()!;
      if (cur === to) break;
      for (const d of DOORS) {
        if (!this.isDoorOpen(d)) continue;
        const next = d.a === cur ? d.b : d.b === cur ? d.a : null;
        if (!next || seen.has(next)) continue;
        seen.add(next);
        prev.set(next, { area: cur, door: d });
        queue.push(next);
      }
    }
    if (!prev.has(to)) {
      // Unreachable (sealed): walk as far as the current area allows.
      const [cx, cz] = clampToRect(AREAS[from].rect, tx, tz, 0.6);
      return [{ x: cx, z: cz }];
    }
    const doors: DoorDef[] = [];
    for (let a: AreaId = to; a !== from; ) {
      const p = prev.get(a)!;
      doors.unshift(p.door);
      a = p.area;
    }
    const pts: { x: number; z: number }[] = [];
    for (const d of doors) {
      const c = rectCenter(d.rect);
      // Enter along the corridor axis so bodies don't clip the door frame.
      if (d.axis === 'z') {
        const fromSouth = fz > c.z;
        pts.push({ x: c.x, z: fromSouth ? d.rect.z1 : d.rect.z0 });
        pts.push({ x: c.x, z: fromSouth ? d.rect.z0 : d.rect.z1 });
      } else {
        const fromWest = fx < c.x;
        pts.push({ x: fromWest ? d.rect.x0 : d.rect.x1, z: c.z });
        pts.push({ x: fromWest ? d.rect.x1 : d.rect.x0, z: c.z });
      }
      fx = pts[pts.length - 1].x;
      fz = pts[pts.length - 1].z;
    }
    pts.push({ x: tx, z: tz });
    return pts;
  }

  /** True when a body of radius r at (x, z) overlaps an obstacle or leaves walkable space. */
  blocked(x: number, z: number, r: number): boolean {
    const rects = this.walkables();
    let inside = false;
    for (let i = 0; i < rects.length && !inside; i++) inside = inRect(rects[i], x, z, r);
    if (!inside) return true;
    for (let cx = Math.floor((x - r) / CELL); cx <= Math.floor((x + r) / CELL); cx++) {
      for (let cz = Math.floor((z - r) / CELL); cz <= Math.floor((z + r) / CELL); cz++) {
        for (const o of this.grid.get(gk(cx, cz)) ?? NONE) {
          if (o.kind === 'circle') {
            if (Math.hypot(x - o.x, z - o.z) < o.r + r) return true;
          } else {
            const px = Math.min(Math.max(x, o.x0), o.x1);
            const pz = Math.min(Math.max(z, o.z0), o.z1);
            if (Math.hypot(x - px, z - pz) < r) return true;
          }
        }
      }
    }
    return false;
  }

  /** Pure query: is the straight segment walkable for a body of radius r? (Easy auto uses it too.) */
  clearLine(ax: number, az: number, bx: number, bz: number, r: number) {
    const n = Math.max(1, Math.ceil(Math.hypot(bx - ax, bz - az) / 0.25));
    for (let i = 1; i <= n; i++) if (this.blocked(ax + ((bx - ax) * i) / n, az + ((bz - az) * i) / n, r)) return false;
    return true;
  }

  /**
   * Obstacle-aware waypoints (used for walking up to gathering nodes): the door
   * route from `route()`, then an A* over a 0.5 m grid inside the destination
   * area for the last leg, string-pulled to a few straight segments. Falls back
   * to the plain route when the goal is unreachable.
   */
  findPath(fx: number, fz: number, tx: number, tz: number, r = 0.45): { x: number; z: number }[] {
    const legs = this.route(fx, fz, tx, tz);
    const out: { x: number; z: number }[] = [];
    let at = { x: fx, z: fz };
    for (const p of legs) {
      // Door corridors are straight; only legs inside a room need to dodge its props.
      const area = this.areaAt((at.x + p.x) / 2, (at.z + p.z) / 2) ?? this.areaAt(p.x, p.z);
      const inner = area && !this.clearLine(at.x, at.z, p.x, p.z, r) ? this.gridPath(AREAS[area].rect, at, p, r) : null;
      if (inner) out.push(...inner);
      else out.push(p);
      at = p;
    }
    return out;
  }

  private gridPath(rect: Rect, from: { x: number; z: number }, to: { x: number; z: number }, r: number) {
    const S = 0.5;
    const w = Math.ceil((rect.x1 - rect.x0) / S);
    const h = Math.ceil((rect.z1 - rect.z0) / S);
    const cx = (i: number) => rect.x0 + (i % w) * S + S / 2;
    const cz = (i: number) => rect.z0 + Math.floor(i / w) * S + S / 2;
    const ck = `${rect.x0},${rect.z0},${rect.x1},${rect.z1},${r}`;
    let free = this.freeCache.get(ck);
    if (!free) this.freeCache.set(ck, (free = new Int8Array(w * h).fill(-1))); // -1 unknown, 0 blocked, 1 free
    const isFree = (i: number) => {
      if (free[i] < 0) free[i] = this.blocked(cx(i), cz(i), r) ? 0 : 1;
      return free[i] === 1;
    };
    const cellOf = (x: number, z: number) => {
      const i = Math.min(w - 1, Math.max(0, Math.floor((x - rect.x0) / S)));
      const j = Math.min(h - 1, Math.max(0, Math.floor((z - rect.z0) / S)));
      return j * w + i;
    };
    // Snap start and goal to the nearest free cell (the goal may hug a collider).
    const snap = (c: number) => {
      if (isFree(c)) return c;
      for (let ring = 1; ring < 6; ring++) {
        let best = -1;
        let bestD = Infinity;
        const ci = c % w;
        const cj = Math.floor(c / w);
        for (let dj = -ring; dj <= ring; dj++)
          for (let di = -ring; di <= ring; di++) {
            const i = ci + di;
            const j = cj + dj;
            if (i < 0 || j < 0 || i >= w || j >= h) continue;
            const k = j * w + i;
            const d = di * di + dj * dj;
            if (d < bestD && isFree(k)) {
              bestD = d;
              best = k;
            }
          }
        if (best >= 0) return best;
      }
      return -1;
    };
    const s = snap(cellOf(from.x, from.z));
    const g = snap(cellOf(to.x, to.z));
    if (s < 0 || g < 0) return null;
    const gx = g % w;
    const gy = Math.floor(g / w);
    const heur = (k: number) => Math.hypot((k % w) - gx, Math.floor(k / w) - gy);
    const cost = new Float32Array(w * h).fill(Infinity);
    const prev = new Int32Array(w * h).fill(-1);
    // Cells already expanded: the heap keeps stale duplicates (no decrease-key), and without this they were expanded again,
    // up to 4x the room's cell count on long routes (2026-10-04: a 40 m click took ~25 ms).
    const closed = new Uint8Array(w * h);
    // Binary heap of [f, cell].
    const heap: [number, number][] = [];
    const push = (f: number, k: number) => {
      heap.push([f, k]);
      for (let i = heap.length - 1; i > 0; ) {
        const p = (i - 1) >> 1;
        if (heap[p][0] <= heap[i][0]) break;
        [heap[p], heap[i]] = [heap[i], heap[p]];
        i = p;
      }
    };
    const pop = () => {
      const top = heap[0];
      const last = heap.pop()!;
      if (heap.length) {
        heap[0] = last;
        for (let i = 0; ; ) {
          const l = i * 2 + 1;
          const rr = l + 1;
          let m = i;
          if (l < heap.length && heap[l][0] < heap[m][0]) m = l;
          if (rr < heap.length && heap[rr][0] < heap[m][0]) m = rr;
          if (m === i) break;
          [heap[m], heap[i]] = [heap[i], heap[m]];
          i = m;
        }
      }
      return top;
    };
    cost[s] = 0;
    push(heur(s), s);
    let found = false;
    for (let guard = 0; heap.length && guard < w * h * 4; guard++) {
      const [, k] = pop();
      if (closed[k]) continue;
      closed[k] = 1;
      if (k === g) {
        found = true;
        break;
      }
      const ki = k % w;
      const kj = Math.floor(k / w);
      for (let dj = -1; dj <= 1; dj++)
        for (let di = -1; di <= 1; di++) {
          if (!di && !dj) continue;
          const i = ki + di;
          const j = kj + dj;
          if (i < 0 || j < 0 || i >= w || j >= h) continue;
          const n = j * w + i;
          if (!isFree(n)) continue;
          // No corner cutting past a blocked cell.
          if (di && dj && (!isFree(kj * w + i) || !isFree(j * w + ki))) continue;
          const c = cost[k] + (di && dj ? Math.SQRT2 : 1);
          if (c < cost[n]) {
            cost[n] = c;
            prev[n] = k;
            push(c + heur(n), n);
          }
        }
    }
    if (!found) return null;
    const cells: { x: number; z: number }[] = [];
    for (let k = g; k >= 0; k = prev[k]) cells.unshift({ x: cx(k), z: cz(k) });
    cells.push({ x: to.x, z: to.z });
    // String-pull: keep only the corners that line of sight needs.
    const out: { x: number; z: number }[] = [];
    let at = { x: from.x, z: from.z };
    let i = 0;
    while (i < cells.length) {
      // Walk forward while the corner is still in sight (linear, where scanning back from the end was quadratic on long routes).
      let far = i;
      while (far + 1 < cells.length && this.clearLine(at.x, at.z, cells[far + 1].x, cells[far + 1].z, r * 0.9)) far++;
      out.push(cells[far]);
      at = cells[far];
      i = far + 1;
    }
    return out;
  }

  nearestArea(x: number, z: number): AreaId | null {
    let best: AreaId | null = null;
    let bestD = Infinity;
    for (const id of AREA_ORDER) {
      const [cx, cz] = clampToRect(AREAS[id].rect, x, z, 0);
      const d = (cx - x) ** 2 + (cz - z) ** 2;
      if (d < bestD) {
        bestD = d;
        best = id;
      }
    }
    return best;
  }
}
