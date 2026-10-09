import { DEPTHS_RECT, type Rect } from '../../server/rules/content/areas';
import { placementObstacle, wallObstacle, type Placement, type PropId, type WallSegment } from '../content/layout';
import type { Obstacle } from './nav';
import { mulberry32 } from './rng';

/**
 * The Catacomb Depths' floor generator (docs/ALCHEMY-AND-WORLDS-PLAN.md W2). Pure and deterministic: the same (seed, depth) always builds
 * the same floor, so a run can be replayed and tested, and a future co-op host could send two numbers instead of a map.
 *
 * A floor is the Warren's chamber kit reassembled: a 3 x 3 grid of small chambers (13.3 x 12 m) divided by tall half-walls
 * (sight blockers, so cones and blows stop at them) with doorways in them. Up to two chambers are filled in solid, so floors have
 * seven to nine rooms; the doorways form a random spanning tree plus one to three extra loops, so every room is reachable and the
 * route is never a single corridor. Each chamber then gets its dressing (pillars, cages, coffins, bone, a sarcophagus and candelabra)
 * kept clear of doorways and of the places a floor needs open (the way in, the stair down, the chest).
 *
 * Connectivity is not hoped for: after the props are down the whole floor is flood-filled at 0.5 m for a body of the hero's size, and a
 * layout that leaves anything (a room, a doorway, the stairs, the chest, a spawn point) cut off is thrown away and rebuilt with the dressing
 * thinned, ending (if it ever came to it) at bare rooms. `floorProblems` is the same check, used by the tests.
 */

export const FLOOR_COLS = 3;
export const FLOOR_ROWS = 3;
/** Wall height and thickness of the partitions (the Warren's half-walls: tall enough to stop cones and blows). */
export const FLOOR_WALL_H = 3.4;
const WALL_T = 1;
const DOOR_W = 4.6;
/** Props keep this far from a doorway's centre, so a doorway never has furniture in its mouth. */
const DOOR_KEEPOUT = 3.4;
/** Half the width of the lane kept free from each doorway to the middle of its room. */
const LANE_HALF = 1.2;
/** The body radius the floor must stay navigable for (the hero is 0.45; thralls and enemies are smaller or comparable). */
const BODY = 0.45;
/** The stairs and the chest block a circle this wide (the hero stands 1.4 m south of one to use it). */
export const STAIR_R = 0.8;
export const CHEST_R = 0.7;

export type RoomKind = 'plain' | 'pillars' | 'crypt' | 'cages' | 'bones' | 'ossuary';

export interface FloorRoom {
  id: number;
  col: number;
  row: number;
  /** Walkable inside of the chamber (the partitions take half a metre each side of the shared border). */
  rect: Rect;
  cx: number;
  cz: number;
  /** False for a chamber filled in solid. */
  active: boolean;
  kind: RoomKind;
  /** Doors out of this room: the neighbour and the index into `doors`. */
  adj: { to: number; door: number }[];
  /** Doorway steps from the way in. */
  dist: number;
}

export interface FloorDoor {
  a: number;
  b: number;
  x: number;
  z: number;
  /** The wall the door is cut in runs along this axis (`x`: a vertical wall, so you cross it moving along x). */
  wall: 'x' | 'z';
  /** The direction of travel from room `a` into room `b`. */
  dir: { x: number; z: number };
}

export interface FloorBreach {
  x: number;
  z: number;
  room: number;
}

export interface DepthsFloor {
  seed: number;
  depth: number;
  rect: Rect;
  rooms: FloorRoom[];
  doors: FloorDoor[];
  walls: WallSegment[];
  props: Placement[];
  /** The way back up (the exit stair) and where the hero is put when a floor begins. */
  stairUp: { x: number; z: number };
  start: { x: number; z: number };
  stairDown: { x: number; z: number };
  /** Every fifth floor holds a chest in the farthest side room. */
  chest: { x: number; z: number } | null;
  startRoom: number;
  stairRoom: number;
  chestRoom: number | null;
  /** Where the dead climb out: two per room except the way in. */
  breaches: FloorBreach[];
  /** `next[a][b]`: the door to take from room a toward room b (-1 = same room / unreachable). */
  next: number[][];
}

export interface FloorOptions {
  /** Every Nth floor holds a chest (content/depths.ts DEPTHS.chestEvery). */
  chestEvery?: number;
}

const cellW = (r: Rect) => (r.x1 - r.x0) / FLOOR_COLS;
const cellH = (r: Rect) => (r.z1 - r.z0) / FLOOR_ROWS;

// ---------------------------------------------------------------------------
// Queries
// ---------------------------------------------------------------------------

/** The room a point stands in (the walkable cell it falls in); -1 outside the grid or inside a filled chamber. */
export function roomAt(f: DepthsFloor, x: number, z: number): number {
  const r = f.rect;
  if (x < r.x0 || x > r.x1 || z < r.z0 || z > r.z1) return -1;
  const col = Math.min(FLOOR_COLS - 1, Math.floor((x - r.x0) / cellW(r)));
  const row = Math.min(FLOOR_ROWS - 1, Math.floor((z - r.z0) / cellH(r)));
  const room = f.rooms[row * FLOOR_COLS + col];
  return room.active ? room.id : -1;
}

/** The point just past a doorway, inside the room on its far side. */
function beyond(d: FloorDoor, toward: 'b' | 'a'): { x: number; z: number } {
  const s = toward === 'b' ? 1 : -1;
  return { x: d.x + d.dir.x * s * 2, z: d.z + d.dir.z * s * 2 };
}

/** A doorway's mouth: how far either side of its wall line a body is still "in the doorway", and how far it is allowed from the doorway's middle. */
const MOUTH_DEPTH = 1.6;
const MOUTH_HALF = DOOR_W / 2 + 0.5;

/**
 * The next place to head for when walking from (fx, fz) to (tx, tz): null when both are in the same room and clear of its doorways, otherwise
 * the doorway to cross (then the point just past it), or, from inside a doorway's mouth, the point that takes a body clear of the wall's end.
 * Everything that walks a floor steers by this: enemies, thralls and the hero's click-to-move. O(1).
 *
 * A body standing in a doorway belongs to whichever chamber its coordinates fall in, and the straight line to a target hard against that wall
 * would clip the wall's end: so from inside the mouth the walker first steps straight out, on the side it is heading for (the far side when it is
 * crossing, its own room's side when it is not), and only then turns for the target.
 */
export function floorHop(f: DepthsFloor, fx: number, fz: number, tx: number, tz: number): { x: number; z: number } | null {
  const a = roomAt(f, fx, fz);
  const b = roomAt(f, tx, tz);
  if (a < 0 || b < 0) return null;
  const through = a === b ? -1 : f.next[a][b];
  if (a !== b && through < 0) return null;
  // Inside the mouth of a doorway that leads where we are going (or, in the same room, of any doorway of the room)?
  const doors = a === b ? f.rooms[a].adj.map((x) => x.door) : [through];
  for (const di of doors) {
    const d = f.doors[di];
    const along = (fx - d.x) * d.dir.x + (fz - d.z) * d.dir.z;
    const across = (fx - d.x) * -d.dir.z + (fz - d.z) * d.dir.x;
    if (Math.abs(along) >= MOUTH_DEPTH || Math.abs(across) >= MOUTH_HALF) continue;
    // Which side to step out on: the far side when crossing, the side of our own room's middle otherwise.
    const room = f.rooms[a];
    const side = a === b ? Math.sign((room.cx - d.x) * d.dir.x + (room.cz - d.z) * d.dir.z) || 1 : d.a === a ? 1 : -1;
    const t = Math.max(-(DOOR_W / 2 - 0.6), Math.min(DOOR_W / 2 - 0.6, across));
    return { x: d.x + -d.dir.z * t + d.dir.x * side * 2.1, z: d.z + d.dir.x * t + d.dir.z * side * 2.1 };
  }
  if (a === b) return null;
  return { x: f.doors[through].x, z: f.doors[through].z };
}

/** Doorways between two rooms on the shortest route (0 = the same room, -1 = unreachable). */
export function floorHops(f: DepthsFloor, a: number, b: number): number {
  if (a < 0 || b < 0) return -1;
  let n = 0;
  for (let at = a; at !== b; n++) {
    const di = f.next[at][b];
    if (di < 0 || n > f.rooms.length) return -1;
    const d = f.doors[di];
    at = d.a === at ? d.b : d.a;
  }
  return n;
}

/** Waypoints from one point to another across the floor (doorway, past the doorway, ... then the goal). Empty route = walk straight. */
export function floorPath(f: DepthsFloor, fx: number, fz: number, tx: number, tz: number): { x: number; z: number }[] {
  let a = roomAt(f, fx, fz);
  const b = roomAt(f, tx, tz);
  const out: { x: number; z: number }[] = [];
  if (a < 0 || b < 0) return [{ x: tx, z: tz }];
  for (let guard = 0; a !== b && guard < f.rooms.length; guard++) {
    const di = f.next[a][b];
    if (di < 0) break;
    const d = f.doors[di];
    const fromA = d.a === a;
    out.push({ x: d.x, z: d.z }, beyond(d, fromA ? 'b' : 'a'));
    a = fromA ? d.b : d.a;
  }
  out.push({ x: tx, z: tz });
  return out;
}

/** Every solid thing on the floor as navigation obstacles (partitions, filled chambers, props, cover). */
export function floorObstacles(f: DepthsFloor): Obstacle[] {
  const out: Obstacle[] = [];
  for (const w of f.walls) out.push(wallObstacle(w));
  for (const p of f.props) {
    const o = placementObstacle(p);
    if (o) out.push(o);
  }
  // The stairs and the chest are things you walk up to, not through.
  out.push({ kind: 'circle', x: f.stairUp.x, z: f.stairUp.z, r: STAIR_R }, { kind: 'circle', x: f.stairDown.x, z: f.stairDown.z, r: STAIR_R });
  if (f.chest) out.push({ kind: 'circle', x: f.chest.x, z: f.chest.z, r: CHEST_R });
  return out;
}

/** The walls tall enough to stop a cone or a blow (the half-walls and filled chambers; low cover and the south edge do not). */
export function floorSightBoxes(f: DepthsFloor) {
  return f.walls.filter((w) => w.height >= 2.5).map((w) => wallObstacle(w));
}

// ---------------------------------------------------------------------------
// Walkability check (also the generator's own safety net)
// ---------------------------------------------------------------------------

/** Names everything on the floor that cannot be walked to from the way in; empty = a sound floor. */
export function floorProblems(f: DepthsFloor): string[] {
  const problems: string[] = [];
  const obstacles = floorObstacles(f);
  const r = f.rect;
  const S = 0.5;
  const w = Math.ceil((r.x1 - r.x0) / S);
  const h = Math.ceil((r.z1 - r.z0) / S);
  const cx = (i: number) => r.x0 + i * S + S / 2;
  const cz = (j: number) => r.z0 + j * S + S / 2;
  // Rasterise: a cell is free unless its centre is within BODY of an obstacle (or of the rectangle's edge).
  const free = new Uint8Array(w * h).fill(1);
  for (let j = 0; j < h; j++) for (let i = 0; i < w; i++) {
    const x = cx(i);
    const z = cz(j);
    if (x < r.x0 + BODY || x > r.x1 - BODY || z < r.z0 + BODY || z > r.z1 - BODY) free[j * w + i] = 0;
  }
  for (const o of obstacles) {
    const [x0, z0, x1, z1] = o.kind === 'circle' ? [o.x - o.r, o.z - o.r, o.x + o.r, o.z + o.r] : [o.x0, o.z0, o.x1, o.z1];
    const i0 = Math.max(0, Math.floor((x0 - BODY - r.x0) / S));
    const i1 = Math.min(w - 1, Math.floor((x1 + BODY - r.x0) / S));
    const j0 = Math.max(0, Math.floor((z0 - BODY - r.z0) / S));
    const j1 = Math.min(h - 1, Math.floor((z1 + BODY - r.z0) / S));
    for (let j = j0; j <= j1; j++) for (let i = i0; i <= i1; i++) {
      const x = cx(i);
      const z = cz(j);
      const blocked = o.kind === 'circle'
        ? Math.hypot(x - o.x, z - o.z) < o.r + BODY
        : Math.hypot(x - Math.min(Math.max(x, o.x0), o.x1), z - Math.min(Math.max(z, o.z0), o.z1)) < BODY;
      if (blocked) free[j * w + i] = 0;
    }
  }
  const cell = (x: number, y: number) => Math.min(h - 1, Math.max(0, Math.floor((y - r.z0) / S))) * w + Math.min(w - 1, Math.max(0, Math.floor((x - r.x0) / S)));
  const from = cell(f.start.x, f.start.z);
  if (!free[from]) return ['the way in is blocked'];
  const seen = new Uint8Array(w * h);
  const queue = [from];
  seen[from] = 1;
  for (let q = 0; q < queue.length; q++) {
    const k = queue[q];
    const ki = k % w;
    const kj = Math.floor(k / w);
    for (const [di, dj] of [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
      const i = ki + di;
      const j = kj + dj;
      if (i < 0 || j < 0 || i >= w || j >= h) continue;
      const n = j * w + i;
      if (seen[n] || !free[n]) continue;
      seen[n] = 1;
      queue.push(n);
    }
  }
  const reach = (label: string, x: number, z: number) => {
    const k = cell(x, z);
    if (!free[k] || !seen[k]) problems.push(`${label} at ${x.toFixed(1)},${z.toFixed(1)} cannot be walked to`);
  };
  // Every chamber has walkable floor connected to the way in (a sarcophagus may sit on its centre).
  for (const room of f.rooms) {
    if (!room.active) continue;
    let ok = false;
    for (let j = Math.ceil((room.rect.z0 - r.z0) / S); j < Math.floor((room.rect.z1 - r.z0) / S) && !ok; j++) {
      for (let i = Math.ceil((room.rect.x0 - r.x0) / S); i < Math.floor((room.rect.x1 - r.x0) / S); i++) {
        if (seen[j * w + i]) { ok = true; break; }
      }
    }
    if (!ok) problems.push(`room ${room.id} cannot be walked to`);
  }
  f.doors.forEach((d, i) => { reach(`door ${i}`, d.x, d.z); reach(`door ${i} (a side)`, d.x - d.dir.x * 2, d.z - d.dir.z * 2); reach(`door ${i} (b side)`, d.x + d.dir.x * 2, d.z + d.dir.z * 2); });
  reach('stair up', f.stairUp.x, f.stairUp.z + 1.4);
  reach('stair down', f.stairDown.x, f.stairDown.z + 1.4);
  if (f.chest) reach('chest', f.chest.x, f.chest.z + 1.4);
  f.breaches.forEach((b, i) => reach(`spawn point ${i}`, b.x, b.z));
  return problems;
}

// ---------------------------------------------------------------------------
// Generation
// ---------------------------------------------------------------------------

const ROOM_KINDS: RoomKind[] = ['pillars', 'crypt', 'cages', 'bones', 'ossuary', 'plain'];

/** The depth's stable seed for a run: floor n of run `runSeed`. */
export function floorSeed(runSeed: number, depth: number): number {
  return (Math.imul(runSeed ^ 0x9e3779b9, 0x85ebca6b) ^ Math.imul(depth + 1, 0xc2b2ae35)) >>> 0;
}

export function generateFloor(seed: number, depth: number, opts: FloorOptions = {}): DepthsFloor {
  const chestEvery = opts.chestEvery ?? 5;
  // The skeleton (which rooms, which doors) never changes between attempts; only the dressing is retried.
  const base = skeleton(seed, depth, chestEvery);
  for (let attempt = 0; attempt < 10; attempt++) {
    const f = dress(base, seed, attempt);
    if (!floorProblems(f).length) return f;
  }
  // Practically unreachable; bare rooms are always sound.
  return dress(base, seed, -1);
}

function skeleton(seed: number, depth: number, chestEvery: number): DepthsFloor {
  const rand = mulberry32(seed ^ 0x51ed);
  const rect = DEPTHS_RECT;
  const cw = cellW(rect);
  const ch = cellH(rect);
  const rooms: FloorRoom[] = [];
  for (let row = 0; row < FLOOR_ROWS; row++) {
    for (let col = 0; col < FLOOR_COLS; col++) {
      const x0 = rect.x0 + col * cw;
      const z0 = rect.z0 + row * ch;
      // The partitions take half a metre each side of the border; the outer ring is already outside the rect.
      const inner: Rect = { x0: x0 + (col > 0 ? WALL_T / 2 : 0), z0: z0 + (row > 0 ? WALL_T / 2 : 0), x1: x0 + cw - (col < FLOOR_COLS - 1 ? WALL_T / 2 : 0), z1: z0 + ch - (row < FLOOR_ROWS - 1 ? WALL_T / 2 : 0) };
      rooms.push({ id: row * FLOOR_COLS + col, col, row, rect: inner, cx: (inner.x0 + inner.x1) / 2, cz: (inner.z0 + inner.z1) / 2, active: true, kind: 'plain', adj: [], dist: 0 });
    }
  }
  const at = (col: number, row: number) => (col < 0 || row < 0 || col >= FLOOR_COLS || row >= FLOOR_ROWS ? null : rooms[row * FLOOR_COLS + col]);
  const neighbours = (r: FloorRoom) => [at(r.col + 1, r.row), at(r.col - 1, r.row), at(r.col, r.row + 1), at(r.col, r.row - 1)].filter((n): n is FloorRoom => !!n && n.active);

  // Fill in up to two chambers (never the middle one), keeping the rest in one piece.
  const reachableCount = () => {
    const start = rooms.find((r) => r.active)!;
    const seen = new Set([start.id]);
    const stack = [start];
    while (stack.length) for (const n of neighbours(stack.pop()!)) if (!seen.has(n.id)) { seen.add(n.id); stack.push(n); }
    return seen.size;
  };
  const removals = Math.floor(rand() * 3);
  const candidates = rooms.filter((r) => r.id !== 4);
  for (let i = candidates.length - 1; i > 0; i--) {
    const j = Math.floor(rand() * (i + 1));
    [candidates[i], candidates[j]] = [candidates[j], candidates[i]];
  }
  let removed = 0;
  for (const c of candidates) {
    if (removed >= removals) break;
    c.active = false;
    if (reachableCount() === rooms.filter((r) => r.active).length) removed++;
    else c.active = true;
  }

  // Doorways: a random spanning tree, then one to three extra loops.
  const pairs: [FloorRoom, FloorRoom][] = [];
  for (const r of rooms) {
    if (!r.active) continue;
    const e = at(r.col + 1, r.row);
    const s = at(r.col, r.row + 1);
    if (e?.active) pairs.push([r, e]);
    if (s?.active) pairs.push([r, s]);
  }
  for (let i = pairs.length - 1; i > 0; i--) {
    const j = Math.floor(rand() * (i + 1));
    [pairs[i], pairs[j]] = [pairs[j], pairs[i]];
  }
  const parent = rooms.map((r) => r.id);
  const find = (i: number): number => (parent[i] === i ? i : (parent[i] = find(parent[i])));
  const chosen: [FloorRoom, FloorRoom][] = [];
  const spare: [FloorRoom, FloorRoom][] = [];
  for (const p of pairs) {
    const a = find(p[0].id);
    const b = find(p[1].id);
    if (a !== b) {
      parent[a] = b;
      chosen.push(p);
    } else spare.push(p);
  }
  chosen.push(...spare.slice(0, 1 + Math.floor(rand() * 3)));

  const doors: FloorDoor[] = [];
  const margin = DOOR_W / 2 + 1.4;
  for (const [a, b] of chosen) {
    const horizontalNeighbour = b.col !== a.col; // b is east of a: the wall between them is vertical
    let door: FloorDoor;
    if (horizontalNeighbour) {
      const x = rect.x0 + (a.col + 1) * cw;
      const z = rect.z0 + a.row * ch + margin + rand() * (ch - 2 * margin);
      door = { a: a.id, b: b.id, x, z, wall: 'x', dir: { x: 1, z: 0 } };
    } else {
      const z = rect.z0 + (a.row + 1) * ch;
      const x = rect.x0 + a.col * cw + margin + rand() * (cw - 2 * margin);
      door = { a: a.id, b: b.id, x, z, wall: 'z', dir: { x: 0, z: 1 } };
    }
    doors.push(door);
    a.adj.push({ to: b.id, door: doors.length - 1 });
    b.adj.push({ to: a.id, door: doors.length - 1 });
  }

  // The way in is on the south side (the camera looks north); the stair down is the farthest room by doorway steps.
  const active = rooms.filter((r) => r.active);
  const southern = active.filter((r) => r.row === Math.max(...active.map((x) => x.row)));
  const startRoom = southern[Math.floor(rand() * southern.length)];
  const bfs = (from: FloorRoom) => {
    const dist = new Map([[from.id, 0]]);
    const queue = [from];
    for (let q = 0; q < queue.length; q++) for (const { to } of queue[q].adj) if (!dist.has(to)) { dist.set(to, dist.get(queue[q].id)! + 1); queue.push(rooms[to]); }
    return dist;
  };
  const dist = bfs(startRoom);
  for (const r of active) r.dist = dist.get(r.id) ?? 0;
  const far = [...active].sort((a, b) => b.dist - a.dist || a.id - b.id);
  const topDist = far[0].dist;
  const topRooms = far.filter((r) => r.dist === topDist);
  const stairRoom = topRooms[Math.floor(rand() * topRooms.length)];
  let chestRoom: FloorRoom | null = null;
  if (chestEvery > 0 && depth % chestEvery === 0) {
    const rest = active.filter((r) => r.id !== startRoom.id && r.id !== stairRoom.id);
    // A dead end if there is one, else the farthest of what is left.
    rest.sort((a, b) => (a.adj.length === 1 ? 0 : 1) - (b.adj.length === 1 ? 0 : 1) || b.dist - a.dist || a.id - b.id);
    chestRoom = rest[0] ?? stairRoom;
    if (chestRoom === stairRoom) chestRoom = null;
  }
  for (const r of active) r.kind = r === startRoom || r === stairRoom || r === chestRoom ? (r === startRoom ? 'plain' : 'crypt') : ROOM_KINDS[Math.floor(rand() * ROOM_KINDS.length)];

  // next[a][b]: the door to take from a toward b (BFS from every b).
  const n = rooms.length;
  const next: number[][] = Array.from({ length: n }, () => Array<number>(n).fill(-1));
  for (const target of active) {
    const seen = new Set([target.id]);
    const queue = [target];
    for (let q = 0; q < queue.length; q++) {
      for (const { to, door } of queue[q].adj) {
        if (seen.has(to)) continue;
        seen.add(to);
        next[to][target.id] = door;
        queue.push(rooms[to]);
      }
    }
  }

  const walls = partitionWalls(rect, rooms, doors);
  return {
    seed,
    depth,
    rect,
    rooms,
    doors,
    walls,
    props: [],
    stairUp: { x: startRoom.cx, z: startRoom.rect.z1 - 2.6 },
    start: { x: startRoom.cx, z: startRoom.rect.z1 - 5.2 },
    stairDown: { x: stairRoom.cx, z: stairRoom.cz - 1.5 },
    chest: chestRoom ? { x: chestRoom.cx, z: chestRoom.cz - 1 } : null,
    startRoom: startRoom.id,
    stairRoom: stairRoom.id,
    chestRoom: chestRoom ? chestRoom.id : null,
    breaches: [],
    next,
  };
}

/** The partitions: every border between chambers is a wall (with a doorway cut where a door is), the outer ring closes the grid. */
function partitionWalls(rect: Rect, rooms: FloorRoom[], doors: FloorDoor[]): WallSegment[] {
  const walls: WallSegment[] = [];
  const cw = cellW(rect);
  const ch = cellH(rect);
  const T = 0.8;
  const tall = (x0: number, z0: number, x1: number, z1: number, thickness = WALL_T, height = FLOOR_WALL_H, texture: WallSegment['texture'] = 'stone_wall'): WallSegment => ({ x0, z0, x1, z1, height, thickness, texture, area: 'depths' });
  // Outer ring (just outside the walkable rect; the south edge stays low so it never hides the hero from the camera).
  walls.push(tall(rect.x0, rect.z0 - T / 2, rect.x1, rect.z0 - T / 2, T));
  walls.push(tall(rect.x0, rect.z1 + T / 2, rect.x1, rect.z1 + T / 2, T, 1.1));
  walls.push(tall(rect.x0 - T / 2, rect.z0, rect.x0 - T / 2, rect.z1, T));
  walls.push(tall(rect.x1 + T / 2, rect.z0, rect.x1 + T / 2, rect.z1, T));
  const doorAt = (wall: 'x' | 'z', fixed: number, from: number) =>
    doors.find((d) => d.wall === wall && Math.abs((wall === 'x' ? d.x : d.z) - fixed) < 1e-6 && (wall === 'x' ? d.z : d.x) >= from - 1e-6 && (wall === 'x' ? d.z : d.x) <= from + (wall === 'x' ? ch : cw) + 1e-6);
  // Vertical borders (between columns), one segment run per row.
  for (let c = 1; c < FLOOR_COLS; c++) {
    const x = rect.x0 + c * cw;
    for (let r = 0; r < FLOOR_ROWS; r++) {
      const z0 = rect.z0 + r * ch;
      const z1 = z0 + ch;
      const d = doorAt('x', x, z0);
      if (!d) walls.push(tall(x, z0 - (r > 0 ? WALL_T / 2 : 0), x, z1 + (r < FLOOR_ROWS - 1 ? WALL_T / 2 : 0)));
      else {
        walls.push(tall(x, z0 - (r > 0 ? WALL_T / 2 : 0), x, d.z - DOOR_W / 2));
        walls.push(tall(x, d.z + DOOR_W / 2, x, z1 + (r < FLOOR_ROWS - 1 ? WALL_T / 2 : 0)));
      }
    }
  }
  // Horizontal borders (between rows).
  for (let r = 1; r < FLOOR_ROWS; r++) {
    const z = rect.z0 + r * ch;
    for (let c = 0; c < FLOOR_COLS; c++) {
      const x0 = rect.x0 + c * cw;
      const x1 = x0 + cw;
      const d = doorAt('z', z, x0);
      if (!d) walls.push(tall(x0 - (c > 0 ? WALL_T / 2 : 0), z, x1 + (c < FLOOR_COLS - 1 ? WALL_T / 2 : 0), z));
      else {
        walls.push(tall(x0 - (c > 0 ? WALL_T / 2 : 0), z, d.x - DOOR_W / 2, z));
        walls.push(tall(d.x + DOOR_W / 2, z, x1 + (c < FLOOR_COLS - 1 ? WALL_T / 2 : 0), z));
      }
    }
  }
  // A filled chamber is one solid block (its borders are already walls, this makes the inside a wall too).
  for (const room of rooms) {
    if (room.active) continue;
    const b = { x0: room.rect.x0, x1: room.rect.x1, z0: room.rect.z0, z1: room.rect.z1 };
    walls.push(tall(b.x0, (b.z0 + b.z1) / 2, b.x1, (b.z0 + b.z1) / 2, b.z1 - b.z0));
  }
  return walls;
}

/** Add the dressing, lights, cover and spawn points to a skeleton; `attempt` thins the dressing on retries (-1 = bare). */
function dress(base: DepthsFloor, seed: number, attempt: number): DepthsFloor {
  const rand = mulberry32(seed ^ (0x7a1e + attempt * 0x1f3d));
  const props: Placement[] = [];
  const walls = base.walls;
  const breaches: FloorBreach[] = [];
  const density = attempt < 0 ? 0 : Math.max(0.25, 1 - attempt * 0.12);
  const P = (prop: PropId, x: number, z: number, rot = rand() * Math.PI * 2, scale = 1, extra: Partial<Placement> = {}) => props.push({ prop, x, z, rot, scale, area: 'depths', ...extra });
  const nearDoor = (x: number, z: number, pad = 0) => base.doors.some((d) => Math.hypot(d.x - x, d.z - z) < DOOR_KEEPOUT + pad);
  const keepClear: { x: number; z: number; r: number }[] = [
    { x: base.stairUp.x, z: base.stairUp.z, r: 3.2 },
    { x: base.start.x, z: base.start.z, r: 2.4 },
    { x: base.stairDown.x, z: base.stairDown.z, r: 3.2 },
    ...(base.chest ? [{ x: base.chest.x, z: base.chest.z, r: 3.2 }] : []),
  ];
  // Lanes: from every doorway to its room's middle stays free, so walkers lined up on a doorway never meet a pillar head-on.
  const lanes: { ax: number; az: number; bx: number; bz: number }[] = [];
  for (const room of base.rooms) {
    if (!room.active) continue;
    for (const { door } of room.adj) lanes.push({ ax: base.doors[door].x, az: base.doors[door].z, bx: room.cx, bz: room.cz });
  }
  const onLane = (x: number, z: number, r: number) =>
    lanes.some((l) => {
      const dx = l.bx - l.ax;
      const dz = l.bz - l.az;
      const t = Math.max(0, Math.min(1, ((x - l.ax) * dx + (z - l.az) * dz) / (dx * dx + dz * dz || 1)));
      return Math.hypot(x - (l.ax + dx * t), z - (l.az + dz * t)) < r + LANE_HALF;
    });
  const clearOfProps = (x: number, z: number, r: number) => props.every((p) => Math.hypot(p.x - x, p.z - z) > r) && keepClear.every((k) => Math.hypot(k.x - x, k.z - z) > k.r + r * 0.5);
  const fits = (room: FloorRoom, x: number, z: number, r: number) =>
    x > room.rect.x0 + r + 0.8 && x < room.rect.x1 - r - 0.8 && z > room.rect.z0 + r + 0.8 && z < room.rect.z1 - r - 0.8 && !nearDoor(x, z) && !onLane(x, z, r) && clearOfProps(x, z, r);
  const lowWalls: WallSegment[] = [];

  // Spawn points first, so the dressing works around them: two per room except the way in, in the corners, clear of the doorways.
  for (const room of base.rooms) {
    if (!room.active || room.id === base.startRoom) continue;
    // Corners first, then the quarter points, then the middle: every room gets at least one (a bare middle always fits).
    const hw = (room.rect.x1 - room.rect.x0) / 2;
    const hh = (room.rect.z1 - room.rect.z0) / 2;
    const spots: [number, number][] = [[-1, -1], [1, 1], [1, -1], [-1, 1]].map(([sx, sz]) => [room.cx + sx * (hw - 2.4), room.cz + sz * (hh - 2.4)] as [number, number]);
    for (let i = spots.length - 1; i > 0; i--) {
      const j = Math.floor(rand() * (i + 1));
      [spots[i], spots[j]] = [spots[j], spots[i]];
    }
    spots.push(...([[-0.5, -0.5], [0.5, 0.5], [0.5, -0.5], [-0.5, 0.5], [0, 0.7], [0, -0.7]] as const).map(([sx, sz]) => [room.cx + sx * hw, room.cz + sz * hh] as [number, number]));
    let n = 0;
    for (const [x, z] of spots) {
      if (n >= 2) break;
      if (nearDoor(x, z, -0.4) || keepClear.some((k) => Math.hypot(k.x - x, k.z - z) < 1.6)) continue;
      breaches.push({ x, z, room: room.id });
      // Reserved: the dressing keeps clear of a spawn point (the dead climb out of bare ground).
      keepClear.push({ x, z, r: 1.4 });
      n++;
    }
  }
  for (const room of base.rooms) {
    if (!room.active) continue;
    // Lanterns on the room side of each doorway's wall end: lit doorways say where the chambers join (the Warren's trick).
    if (attempt >= 0) {
      for (const { to, door } of room.adj) {
        if (to < room.id) continue; // one pair of lanterns per doorway, from the lower room
        const d = base.doors[door];
        const side = d.wall === 'x' ? { x: d.x + 0.9, z: d.z - DOOR_W / 2 - 0.5 } : { x: d.x - DOOR_W / 2 - 0.5, z: d.z + 0.9 };
        P('grave_lantern', side.x, side.z, 0);
        const other = d.wall === 'x' ? { x: d.x - 0.9, z: d.z + DOOR_W / 2 + 0.5 } : { x: d.x + DOOR_W / 2 + 0.5, z: d.z - 0.9 };
        P('grave_lantern', other.x, other.z, 0);
      }
    }
    if (attempt < 0) continue;
    const w = room.rect.x1 - room.rect.x0;
    const h = room.rect.z1 - room.rect.z0;
    const special = room.id === base.startRoom || room.id === base.stairRoom || room.id === base.chestRoom;
    switch (room.kind) {
      case 'pillars':
        for (const [sx, sz] of [[-1, -1], [1, -1], [-1, 1], [1, 1]] as const) {
          const x = room.cx + sx * w * 0.27;
          const z = room.cz + sz * h * 0.27;
          if (fits(room, x, z, 0.85)) P('pillar', x, z, 0);
        }
        break;
      case 'crypt':
        if (!special) {
          for (const [dx, dz] of [[0, -1], [-3.6, 2.4], [3.6, 2.4], [-3.6, -2.4], [3.6, -2.4]] as const) {
            if (fits(room, room.cx + dx, room.cz + dz, 1.4)) { P('sarcophagus', room.cx + dx, room.cz + dz, Math.PI / 2); break; }
          }
          for (const [dx, dz] of [[-3.6, -3], [3.6, -3], [-3.6, 3], [3.6, 3]] as const) if (fits(room, room.cx + dx, room.cz + dz, 0.4)) P('bone_candelabrum', room.cx + dx, room.cz + dz, 0);
        } else {
          for (const [dx, dz] of [[-4, -3.4], [4, -3.4]] as const) if (fits(room, room.cx + dx, room.cz + dz, 0.4)) P('bone_candelabrum', room.cx + dx, room.cz + dz, 0);
        }
        break;
      case 'cages':
        for (let k = 0; k < 3; k++) {
          const x = room.cx + (rand() - 0.5) * (w - 6);
          const z = room.cz + (rand() - 0.5) * (h - 6);
          if (fits(room, x, z, 0.8)) P('gibbet_cage', x, z);
        }
        break;
      case 'bones':
        for (let k = 0; k < 4; k++) {
          const x = room.cx + (rand() - 0.5) * (w - 4);
          const z = room.cz + (rand() - 0.5) * (h - 4);
          if (fits(room, x, z, 0.8)) P(rand() < 0.6 ? 'bone_pile' : 'tombstone_round', x, z);
        }
        break;
      case 'ossuary':
        for (let k = 0; k < 2; k++) {
          const x = room.cx + (rand() - 0.5) * (w - 6);
          const z = room.cz + (rand() - 0.5) * (h - 6);
          if (fits(room, x, z, 1.2)) P(k % 2 ? 'coffin_stack' : 'tombstone_cross', x, z);
        }
        break;
      default:
        break;
    }
    // A touch of scatter everywhere, thinned by density.
    const scatter = Math.round((2 + Math.floor(rand() * 3)) * density);
    for (let k = 0; k < scatter; k++) {
      const x = room.rect.x0 + 1.6 + rand() * (w - 3.2);
      const z = room.rect.z0 + 1.6 + rand() * (h - 3.2);
      if (fits(room, x, z, 0.9)) P(rand() < 0.55 ? 'bone_pile' : rand() < 0.5 ? 'tombstone_round' : 'candles', x, z);
    }
    // Low cover: short skull walls (below the sight line, so they shelter bodies but not casters' view).
    const covers = Math.round((room.kind === 'plain' && !special ? 2 : 1) * density * (0.5 + rand()));
    for (let k = 0; k < covers; k++) {
      const horizontal = rand() < 0.5;
      const len = 3.2;
      const x = room.cx + (rand() - 0.5) * (w - 8);
      const z = room.cz + (rand() - 0.5) * (h - 7);
      const x0 = horizontal ? x - len / 2 : x;
      const x1 = horizontal ? x + len / 2 : x;
      const z0 = horizontal ? z : z - len / 2;
      const z1 = horizontal ? z : z + len / 2;
      const probes: [number, number][] = [[x0, z0], [x1, z1], [(x0 + x1) / 2, (z0 + z1) / 2]];
      if (!probes.every(([px, pz]) => fits(room, px, pz, 1.1))) continue;
      if (lowWalls.some((o) => Math.hypot((o.x0 + o.x1) / 2 - x, (o.z0 + o.z1) / 2 - z) < 4)) continue;
      lowWalls.push({ x0, z0, x1, z1, height: 1.1, thickness: 0.9, texture: 'skull_wall', area: 'depths' });
    }
  }
  return { ...base, walls: [...walls, ...lowWalls], props, breaches };
}
