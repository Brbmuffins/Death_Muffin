import { AREAS, AREA_ORDER, DOORS, type AreaId, type Rect } from './areas';
export type { Rect };
import { mulberry32 } from '../gameplay/rng';

/**
 * Deterministic world dressing. Pure data (no three.js) so the navigation
 * colliders and the renderer come from the same placements — what you see is
 * what blocks you. Same seed → same world for every player in a party.
 */
export type PropId =
  | 'tombstone_round'
  | 'tombstone_cross'
  | 'mausoleum'
  | 'pillar'
  | 'arch'
  | 'sarcophagus'
  | 'statue'
  | 'candles'
  | 'bone_pile'
  | 'fence'
  | 'dead_tree'
  | 'brazier'
  | 'bell_altar'
  | 'reliquary'
  | 'workbench'
  | 'waystone';

export interface PropSpec {
  /** Target world height of the generated model. */
  height: number;
  collider?: { kind: 'circle'; r: number } | { kind: 'box'; hw: number; hd: number };
  /** Emits light (candle flames / brazier fire). */
  light?: { color: number; intensity: number; distance: number; y: number; flames: number; spread: number };
}

export const PROPS: Record<PropId, PropSpec> = {
  tombstone_round: { height: 1.25, collider: { kind: 'circle', r: 0.45 } },
  tombstone_cross: { height: 1.7, collider: { kind: 'circle', r: 0.42 } },
  mausoleum: { height: 5.2, collider: { kind: 'box', hw: 2.1, hd: 2.6 } },
  pillar: { height: 6.5, collider: { kind: 'circle', r: 0.85 } },
  arch: { height: 5, collider: { kind: 'box', hw: 0.5, hd: 0.5 } },
  sarcophagus: { height: 1.1, collider: { kind: 'box', hw: 0.65, hd: 1.3 } },
  statue: { height: 3.2, collider: { kind: 'circle', r: 0.8 } },
  candles: { height: 0.7, light: { color: 0xffb46b, intensity: 5, distance: 7, y: 0.9, flames: 5, spread: 0.28 } },
  bone_pile: { height: 0.8, collider: { kind: 'circle', r: 0.55 } },
  fence: { height: 1.6 },
  dead_tree: { height: 5.5, collider: { kind: 'circle', r: 0.55 } },
  brazier: { height: 1.3, collider: { kind: 'circle', r: 0.5 }, light: { color: 0xa66bff, intensity: 14, distance: 11, y: 1.6, flames: 0, spread: 0.3 } },
  bell_altar: { height: 3.6, collider: { kind: 'box', hw: 2.1, hd: 1.6 } },
  reliquary: { height: 1.2, collider: { kind: 'box', hw: 0.9, hd: 0.6 } },
  workbench: { height: 1.4, collider: { kind: 'box', hw: 1.4, hd: 0.8 } },
  waystone: { height: 3, collider: { kind: 'circle', r: 0.6 } },
};

export interface Placement {
  prop: PropId;
  x: number;
  z: number;
  rot: number;
  scale: number;
  /** Small lean for weathered tombstones. */
  tilt?: number;
  area: AreaId;
  /** Group tag (sanctum candle groups extinguish by phase). */
  group?: string;
}

export interface WallSegment {
  x0: number;
  z0: number;
  x1: number;
  z1: number;
  height: number;
  thickness: number;
  texture: 'stone_wall' | 'skull_wall';
  area: AreaId;
}

export interface Decal {
  kind: 'sigil' | 'cracks' | 'blood';
  x: number;
  z: number;
  r: number;
  color: number;
  opacity: number;
  rot: number;
  area: AreaId;
}

export interface Window {
  x: number;
  z: number;
  w: number;
  h: number;
  facing: number;
  y: number;
}

/** A rain puddle in the graveyard soil: a tiny still mirror for the moon. */
export interface Puddle {
  x: number;
  z: number;
  r: number;
  /** Ellipse stretch (x radius = r × sx) and heading. */
  sx: number;
  rot: number;
  area: AreaId;
}

/** Scenery far beyond the walls: fog-tinted shapes, never walkable or collidable. */
export interface Silhouette {
  kind: 'spire' | 'tree' | 'ruin';
  x: number;
  z: number;
  scale: number;
  rot: number;
}

/** Where a Grave Surge can break out: just in front of a mausoleum or sarcophagus. */
export interface Crypt {
  x: number;
  z: number;
  area: AreaId;
  prop: 'mausoleum' | 'sarcophagus';
}

export interface WorldLayout {
  /** Flagstone paths laid over earthen floors. */
  paths: Rect[];
  props: Placement[];
  walls: WallSegment[];
  decals: Decal[];
  windows: Window[];
  /** Shallow standing water (the Drowned Nave). Walkable — it only slows the eye, not the feet. */
  water: Rect[];
  puddles: Puddle[];
  silhouettes: Silhouette[];
  /** Surge origins derived from the crypt props (unsafe areas only). */
  crypts: Crypt[];
}

const inRect = (r: Rect, x: number, z: number, pad = 0) =>
  x >= r.x0 + pad && x <= r.x1 - pad && z >= r.z0 + pad && z <= r.z1 - pad;

/** Door openings in an area's edge so walls leave a gap. */
function gapsFor(area: AreaId) {
  const rect = AREAS[area].rect;
  return DOORS.filter((d) => d.a === area || d.b === area).map((d) => ({
    rect: d.rect,
    onEdge:
      d.axis === 'z'
        ? Math.abs(d.rect.z0 - rect.z1) < 6 || Math.abs(d.rect.z1 - rect.z1) < 6
          ? 'south'
          : 'north'
        : Math.abs(d.rect.x0 - rect.x1) < 6 || Math.abs(d.rect.x1 - rect.x1) < 6
          ? 'east'
          : 'west',
  }));
}

function edgeWalls(area: AreaId, height: number, texture: WallSegment['texture'], out: WallSegment[]) {
  const r = AREAS[area].rect;
  const gaps = gapsFor(area);
  const T = 0.8;
  const run = (edge: 'north' | 'south' | 'east' | 'west') => {
    const horizontal = edge === 'north' || edge === 'south';
    const fixed = edge === 'north' ? r.z0 : edge === 'south' ? r.z1 : edge === 'east' ? r.x1 : r.x0;
    const start = horizontal ? r.x0 : r.z0;
    const end = horizontal ? r.x1 : r.z1;
    const holes = gaps
      .filter((g) => g.onEdge === edge)
      .map((g) => (horizontal ? [g.rect.x0, g.rect.x1] : [g.rect.z0, g.rect.z1]))
      .sort((a, b) => a[0] - b[0]);
    let cursor = start;
    // South walls stay low so they never hide the player from the camera.
    const h = edge === 'south' ? Math.min(height, 1.1) : height;
    const push = (a: number, b: number) => {
      if (b - a < 0.4) return;
      const off = edge === 'north' || edge === 'west' ? -T / 2 : T / 2;
      out.push(
        horizontal
          ? { x0: a, z0: fixed + off, x1: b, z1: fixed + off, height: h, thickness: T, texture, area }
          : { x0: fixed + off, z0: a, x1: fixed + off, z1: b, height: h, thickness: T, texture, area },
      );
    };
    for (const [h0, h1] of holes) {
      push(cursor, h0);
      cursor = h1;
    }
    push(cursor, end);
  };
  run('north');
  run('south');
  run('east');
  run('west');
}

export function generateLayout(seed = 1337): WorldLayout {
  const rand = mulberry32(seed);
  const props: Placement[] = [];
  const walls: WallSegment[] = [];
  const decals: Decal[] = [];
  const windows: Window[] = [];
  const paths: Rect[] = [
    { x0: -2.6, z0: -35.5, x1: 2.6, z1: 4 }, // graves: north-south processional
    { x0: -22, z0: -18.2, x1: 25, z1: -13.8 }, // graves: east-west cross
    { x0: -5.5, z0: -21.5, x1: 5.5, z1: -10.5 }, // graves: crossing plaza
    { x0: 32, z0: -19.5, x1: 63, z1: -16.5 }, // ossuary: central aisle
  ];
  const P = (prop: PropId, x: number, z: number, area: AreaId, rot = rand() * Math.PI * 2, scale = 1, extra: Partial<Placement> = {}) =>
    props.push({ prop, x, z, rot, scale, area, ...extra });
  const clearOf = (x: number, z: number, r: number) => props.every((p) => Math.hypot(p.x - x, p.z - z) > r);

  // --- Chapterhouse ---
  {
    const a: AreaId = 'chapterhouse';
    edgeWalls(a, 5.5, 'stone_wall', walls);
    for (const x of [-6, 6]) for (const z of [12, 17.5, 23, 28.5]) P('pillar', x, z, a, 0);
    P('reliquary', -8.5, 14, a, Math.PI / 2);
    P('workbench', 8.5, 14, a, -Math.PI / 2);
    P('statue', 0, 19.6, a, 0, 0.8);
    P('statue', -9, 27.8, a, Math.PI / 2, 0.75);
    P('waystone', 9, 26.5, a, 0);
    P('sarcophagus', 0, 27, a, 0);
    for (const [x, z] of [[-3, 10.5], [3, 10.5], [-3, 30.5], [3, 30.5]] as const) P('brazier', x, z, a, 0);
    for (const [x, z] of [[-10.5, 11], [10.5, 11], [-10.5, 20], [10.5, 20], [-2, 21.5], [2, 21.5], [-7.2, 26.8], [-10.8, 25.5], [1.8, 28.6], [-1.8, 28.6]] as const)
      P('candles', x, z, a);
    P('bone_pile', -11.2, 30.6, a);
    P('bone_pile', 11.2, 30.3, a);
    decals.push({ kind: 'sigil', x: 0, z: 21, r: 2.6, color: 0x9b5cff, opacity: 0.7, rot: 0, area: a });
  }

  // --- The Hollow Graves ---
  {
    const a: AreaId = 'graves';
    const r = AREAS[a].rect;
    edgeWalls(a, 1.3, 'stone_wall', walls);
    const breaches = AREAS[a].breaches;
    const onPath = (x: number, z: number) =>
      Math.abs(x) < 3.2 || Math.abs(z + 16) < 2.4 || (z > -21 && z < -13 && x > 12) || Math.abs(z + 16) < 3 && Math.abs(x) < 6;
    // Landmarks first so graves avoid them.
    P('mausoleum', -19.5, -30.5, a, 0.15);
    P('mausoleum', 19, -2.5, a, Math.PI + 0.1);
    for (const [x, z] of [[-5, -12], [5, -12], [-5, -20], [5, -20]] as const) P('statue', x, z, a, Math.atan2(-x, -(z + 16)), 0.85);
    P('brazier', -4.6, 2.4, a, 0);
    P('brazier', 4.6, 2.4, a, 0);
    P('waystone', -5.5, 1, a, 0);
    for (let i = 0; i < 3; i++) P('sarcophagus', -14 + i * 13.5 + rand() * 2, -24 + rand() * 4, a, rand() * 0.4 - 0.2);
    for (const [x, z] of [[-23.5, -33.5], [23, -33], [-23, 1.5], [23.5, -26], [-23.6, -18], [12, -34], [-12, -34.4]] as const)
      P('dead_tree', x, z, a, rand() * Math.PI * 2, 0.85 + rand() * 0.35);
    // Rows of graves.
    for (let x = r.x0 + 2.2; x < r.x1 - 1.5; x += 2.7) {
      for (let z = r.z0 + 2.4; z < r.z1 - 2.5; z += 3.3) {
        const gx = x + (rand() - 0.5) * 0.7;
        const gz = z + (rand() - 0.5) * 0.6;
        if (onPath(gx, gz) || rand() > 0.6) continue;
        if (breaches.some(([bx, bz]) => Math.hypot(bx - gx, bz - gz) < 2.8)) continue;
        if (!clearOf(gx, gz, 1.5)) continue;
        P(rand() < 0.62 ? 'tombstone_round' : 'tombstone_cross', gx, gz, a, (rand() - 0.5) * 0.5, 0.85 + rand() * 0.3, {
          tilt: (rand() - 0.5) * 0.22,
        });
        if (rand() < 0.1) P('candles', gx + 0.7, gz + 0.5, a, rand() * 6, 0.8);
      }
    }
    for (let i = 0; i < 9; i++) {
      const x = r.x0 + 3 + rand() * (r.x1 - r.x0 - 6);
      const z = r.z0 + 3 + rand() * (r.z1 - r.z0 - 6);
      if (clearOf(x, z, 1.4) && !onPath(x, z)) P('bone_pile', x, z, a);
    }
    for (const [x, z] of [[-6, -10.5], [6, -10.5], [-6, -21.5], [6, -21.5], [-1.2, -33.8], [1.2, -33.8]] as const) P('candles', x, z, a);
    // Fence line along the west and north edges.
    for (let z = r.z0 + 1.5; z < r.z1 - 1; z += 2.4) P('fence', r.x0 + 0.6, z, a, Math.PI / 2);
    for (let x = r.x0 + 1.5; x < r.x1 - 1; x += 2.4) if (Math.abs(x) > 5) P('fence', x, r.z0 + 0.6, a, 0);
    for (const [bx, bz] of breaches) decals.push({ kind: 'cracks', x: bx, z: bz, r: 1.9, color: 0x7c3aed, opacity: 0.3, rot: rand() * 6, area: a });
    decals.push({ kind: 'sigil', x: 0, z: -16, r: 3.6, color: 0x7c3aed, opacity: 0.25, rot: 0, area: a });
  }

  // --- The Marrow Ossuary ---
  {
    const a: AreaId = 'ossuary';
    const r = AREAS[a].rect;
    edgeWalls(a, 5, 'skull_wall', walls);
    // Interior bone partitions make aisles.
    walls.push({ x0: 42, z0: -31, x1: 42, z1: -23, height: 3.2, thickness: 1, texture: 'skull_wall', area: a });
    walls.push({ x0: 54, z0: -15, x1: 54, z1: -7, height: 3.2, thickness: 1, texture: 'skull_wall', area: a });
    walls.push({ x0: 47, z0: -20, x1: 51, z1: -20, height: 3.2, thickness: 1, texture: 'skull_wall', area: a });
    for (const x of [37.5, 48, 58.5]) for (const z of [-33, -24.5, -12, -6]) if (clearOf(x, z, 2)) P('pillar', x, z, a, 0, 0.85);
    P('waystone', 35.5, -6, a, 0);
    for (let i = 0; i < 18; i++) {
      const x = r.x0 + 1.5 + rand() * (r.x1 - r.x0 - 3);
      const z = r.z0 + 1.5 + rand() * (r.z1 - r.z0 - 3);
      if (!clearOf(x, z, 1.8)) continue;
      P(rand() < 0.55 ? 'bone_pile' : 'candles', x, z, a, rand() * 6, 0.8 + rand() * 0.5);
    }
    for (const [x, z] of [[45, -35.5], [52, -35.5], [61.5, -18], [39, -12]] as const) P('sarcophagus', x, z, a, Math.abs(x - 61.5) < 1 ? Math.PI / 2 : 0);
    for (const [x, z] of [[33.8, -20], [62, -4], [62, -36], [44, -4]] as const) P('brazier', x, z, a, 0);
    for (const [bx, bz] of AREAS[a].breaches) decals.push({ kind: 'cracks', x: bx, z: bz, r: 1.7, color: 0x7c3aed, opacity: 0.5, rot: rand() * 6, area: a });
  }

  // --- The Drowned Nave ---
  {
    const a: AreaId = 'nave';
    edgeWalls(a, 7, 'stone_wall', walls);
    for (const x of [-7.5, 7.5]) for (let z = -50; z >= -90; z -= 6.5) P('pillar', x, z, a, 0, 1.1);
    for (let z = -53; z >= -87; z -= 13) P('arch', 0, z, a, 0, 1.0);
    for (const x of [-12.5, 12.5]) for (let z = -52; z >= -92; z -= 10) P('statue', x, z, a, x < 0 ? Math.PI / 2 : -Math.PI / 2, 0.8);
    P('waystone', 6, -47.5, a, 0);
    P('sarcophagus', 0, -92.5, a, Math.PI / 2, 1.3);
    for (const [x, z] of [[-3, -91.5], [3, -91.5], [-10.5, -60], [10.5, -60], [-10.5, -80], [10.5, -80]] as const) P('brazier', x, z, a, 0);
    for (let z = -50; z >= -90; z -= 6.5) {
      P('candles', -6.2, z + 1.2, a);
      P('candles', 6.2, z - 1.2, a);
    }
    windows.push({ x: 0, z: -95.9, w: 5.5, h: 9.8, facing: 0, y: 6.2 });
    windows.push({ x: -14.9, z: -70, w: 3.2, h: 6, facing: Math.PI / 2, y: 4.8 });
    windows.push({ x: 14.9, z: -70, w: 3.2, h: 6, facing: -Math.PI / 2, y: 4.8 });
    for (const [bx, bz] of AREAS[a].breaches) decals.push({ kind: 'cracks', x: bx, z: bz, r: 1.7, color: 0x7c3aed, opacity: 0.5, rot: rand() * 6, area: a });
  }

  // --- The Bell Sanctum ---
  {
    const a: AreaId = 'sanctum';
    edgeWalls(a, 8, 'stone_wall', walls);
    const cx = 0;
    const cz = -116;
    for (let i = 0; i < 10; i++) {
      const ang = (i / 10) * Math.PI * 2 + Math.PI / 10;
      const x = cx + Math.cos(ang) * 14.5;
      const z = cz + Math.sin(ang) * 11.8;
      if (inRect(AREAS[a].rect, x, z, 1)) P('pillar', x, z, a, 0, 1.15);
    }
    P('bell_altar', 0, -126.5, a, 0, 1);
    P('waystone', 6, -105, a, 0);
    const groups: [string, number, number][] = [
      ['west', -11, -116],
      ['east', 11, -116],
      ['north', 0, -123],
    ];
    for (const [g, gx, gz] of groups) {
      for (let k = 0; k < 4; k++) {
        const ang = (k / 4) * Math.PI * 2;
        P('candles', gx + Math.cos(ang) * 1.6, gz + Math.sin(ang) * 1.2, a, rand() * 6, 1, { group: g });
      }
    }
    for (const [x, z] of [[-15.5, -104.5], [15.5, -104.5], [-15.5, -127.5], [15.5, -127.5]] as const) P('brazier', x, z, a, 0);
    decals.push({ kind: 'sigil', x: cx, z: cz, r: 10.5, color: 0x7c3aed, opacity: 0.5, rot: 0, area: a });
    windows.push({ x: 0, z: -129.9, w: 6.5, h: 11, facing: 0, y: 7.5 });
  }

  // Environment dressing draws from its own stream so adding it never moves a grave.
  const envRand = mulberry32(seed ^ 0x5eed);
  const water = naveWater();
  const puddles = gravePuddles(envRand, props);
  const silhouettes = distantSilhouettes(envRand);

  const crypts = cryptsFrom(props);

  return { paths, props, walls, decals, windows, water, puddles, silhouettes, crypts };
}

/** A point in front of each crypt prop, on the side facing its area's open middle. */
function cryptsFrom(props: Placement[]): Crypt[] {
  const out: Crypt[] = [];
  for (const p of props) {
    if ((p.prop !== 'mausoleum' && p.prop !== 'sarcophagus') || AREAS[p.area].safe) continue;
    const r = AREAS[p.area].rect;
    const dx = (r.x0 + r.x1) / 2 - p.x;
    const dz = (r.z0 + r.z1) / 2 - p.z;
    const d = Math.hypot(dx, dz) || 1;
    const c = PROPS[p.prop].collider;
    const reach = (c?.kind === 'box' ? Math.max(c.hw, c.hd) : 1) * p.scale + 1.2;
    out.push({ x: p.x + (dx / d) * reach, z: p.z + (dz / d) * reach, area: p.area, prop: p.prop });
  }
  return out;
}

/**
 * The Drowned Nave floods everywhere except the raised walkways along the two
 * pillar rows and the dry landings at the entrance (waystone) and the altar.
 */
function naveWater(): Rect[] {
  return [
    { x0: -5.6, z0: -89, x1: 5.6, z1: -50.5 }, // the flooded central aisle, under the arches
    { x0: -14.4, z0: -93.5, x1: -8.8, z1: -49.5 }, // west side aisle
    { x0: 8.8, z0: -93.5, x1: 14.4, z1: -49.5 }, // east side aisle
  ];
}

/** Everything the player walks up to and clicks — water and puddles keep clear of these. */
function interactSpots() {
  return AREA_ORDER.flatMap((id) => AREAS[id].interactables.map((i) => ({ x: i.x, z: i.z })));
}

function gravePuddles(rand: () => number, props: Placement[]): Puddle[] {
  const a: AreaId = 'graves';
  const r = AREAS[a].rect;
  const spots = interactSpots();
  const out: Puddle[] = [];
  for (let tries = 0; tries < 200 && out.length < 12; tries++) {
    const x = r.x0 + 2 + rand() * (r.x1 - r.x0 - 4);
    const z = r.z0 + 2 + rand() * (r.z1 - r.z0 - 4);
    const pr = 0.7 + rand() * 1.1;
    const sx = 1 + rand() * 0.8;
    const reach = pr * sx + 0.5;
    if (props.some((p) => p.area === a && Math.hypot(p.x - x, p.z - z) < reach + 0.6)) continue;
    if (spots.some((s) => Math.hypot(s.x - x, s.z - z) < reach + 1.5)) continue;
    if (out.some((p) => Math.hypot(p.x - x, p.z - z) < reach + p.r * p.sx + 1)) continue;
    out.push({ x, z, r: pr, sx, rot: rand() * Math.PI, area: a });
  }
  return out;
}

/** Nearest distance from a point to any walkable rect (areas + door corridors). */
function distToWorld(x: number, z: number) {
  const rects = [...AREA_ORDER.map((id) => AREAS[id].rect), ...DOORS.map((d) => d.rect)];
  let best = Infinity;
  for (const q of rects) {
    const dx = Math.max(q.x0 - x, 0, x - q.x1);
    const dz = Math.max(q.z0 - z, 0, z - q.z1);
    best = Math.min(best, Math.hypot(dx, dz));
  }
  return best;
}

function distantSilhouettes(rand: () => number): Silhouette[] {
  const out: Silhouette[] = [];
  // A ruined cathedral skyline: spires hand-placed where the camera looks north past walls.
  const spires: [number, number, number][] = [
    [-38, -58, 1.25],
    [30, -62, 1.05],
    [-30, -134, 1.4],
    [34, -126, 1.15],
    [0, -150, 1.6],
    [82, -24, 1.1],
    [48, -58, 0.9],
  ];
  for (const [x, z, scale] of spires) out.push({ kind: 'spire', x, z, scale, rot: rand() * Math.PI * 2 });
  // Broken walls and dead trees scattered in the ring beyond the walls.
  for (let tries = 0; tries < 600 && out.length < 70; tries++) {
    const x = -70 + rand() * 170;
    const z = -165 + rand() * 215;
    const d = distToWorld(x, z);
    if (d < 7 || d > 40) continue;
    if (out.some((s) => Math.hypot(s.x - x, s.z - z) < 5)) continue;
    out.push({ kind: rand() < 0.78 ? 'tree' : 'ruin', x, z, scale: 0.8 + rand() * 0.9, rot: rand() * Math.PI * 2 });
  }
  return out;
}
