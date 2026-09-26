import { AREAS, AREA_ORDER, DOORS, type AreaId, type DoorDef, type Rect } from '../content/areas';

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
  private grid = new Map<string, Obstacle[]>();
  private unlocked = new Set<AreaId>(['chapterhouse', 'graves']);

  setUnlocked(areas: Iterable<AreaId>) {
    this.unlocked = new Set(areas);
    this.unlocked.add('chapterhouse');
    this.unlocked.add('graves');
  }

  isUnlocked(area: AreaId) {
    return this.unlocked.has(area);
  }

  isDoorOpen(door: DoorDef) {
    return this.unlocked.has(door.a) && this.unlocked.has(door.b);
  }

  addObstacle(o: Obstacle) {
    this.obstacles.push(o);
    const [x0, z0, x1, z1] =
      o.kind === 'circle' ? [o.x - o.r, o.z - o.r, o.x + o.r, o.z + o.r] : [o.x0, o.z0, o.x1, o.z1];
    for (let cx = Math.floor(x0 / CELL); cx <= Math.floor(x1 / CELL); cx++) {
      for (let cz = Math.floor(z0 / CELL); cz <= Math.floor(z1 / CELL); cz++) {
        const k = `${cx},${cz}`;
        let list = this.grid.get(k);
        if (!list) this.grid.set(k, (list = []));
        list.push(o);
      }
    }
  }

  get obstacleCount() {
    return this.obstacles.length;
  }

  private walkables(): Rect[] {
    const list: Rect[] = [];
    for (const id of AREA_ORDER) if (this.unlocked.has(id)) list.push(AREAS[id].rect);
    for (const d of DOORS) if (this.isDoorOpen(d)) list.push(d.rect);
    return list;
  }

  areaAt(x: number, z: number): AreaId | null {
    for (const id of AREA_ORDER) if (inRect(AREAS[id].rect, x, z)) return id;
    return null;
  }

  /** Push a body of radius r out of obstacles. */
  pushOut(x: number, z: number, r: number): [number, number] {
    for (let pass = 0; pass < 2; pass++) {
      const list = this.grid.get(`${Math.floor(x / CELL)},${Math.floor(z / CELL)}`);
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
