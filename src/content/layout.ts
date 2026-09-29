import { AREAS, AREA_ORDER, DOORS, type AreaId, type Rect } from './areas';
export type { Rect };
import { mulberry32 } from '../gameplay/rng';
import { NODES, type NodeKind } from '../gameplay/gatheringRules';
import { ABBESS_NICHE_SPOTS, BOSSES, GRAVEDIGGER_PITS, summonSpot, type BossId } from './bosses';

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
  | 'waystone'
  // The Acre's Bone Kiln; loads models/props/prop_node_bone_kiln.glb once the pipeline builds it.
  | 'prop_node_bone_kiln'
  // Chapterhouse centrepieces (the Altar and the Niches had no body before 2026-09-27) and the Acre lectern.
  | 'altar_ascension'
  | 'rite_niches'
  | 'covenant_lectern'
  // Room dressing (world-dressing brief): each combat room gets two or three props of its own.
  | 'coffin_stack'
  | 'gibbet_cage'
  | 'grave_lantern'
  | 'bone_candelabrum'
  | 'skull_wall'
  | 'drowned_statue'
  | 'stained_glass'
  | 'sunken_bell'
  | 'bell_frame'
  | 'organ_pipes'
  | 'church_pew'
  // Area-boss summoning objects and the Bone Abbess's niches (area-bosses brief).
  | 'kings_grave'
  | 'abbess_reliquary'
  | 'drowned_font'
  | 'skull_niche';

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
  prop_node_bone_kiln: { height: 2.2, collider: { kind: 'box', hw: 0.9, hd: 0.8 }, light: { color: 0xff8a3d, intensity: 10, distance: 9, y: 0.9, flames: 0, spread: 0.3 } },
  altar_ascension: { height: 2.8, collider: { kind: 'box', hw: 1.6, hd: 1.2 } },
  rite_niches: { height: 2.6, collider: { kind: 'box', hw: 1.4, hd: 0.4 } },
  covenant_lectern: { height: 1.6, collider: { kind: 'circle', r: 0.45 } },
  coffin_stack: { height: 1.6, collider: { kind: 'box', hw: 1.0, hd: 0.6 } },
  gibbet_cage: { height: 3.4, collider: { kind: 'circle', r: 0.4 } },
  grave_lantern: { height: 2.4, collider: { kind: 'circle', r: 0.25 }, light: { color: 0xffb46b, intensity: 4, distance: 6, y: 2.1, flames: 0, spread: 0.2 } },
  bone_candelabrum: { height: 2.2, collider: { kind: 'circle', r: 0.4 }, light: { color: 0xffb46b, intensity: 4, distance: 6, y: 2, flames: 0, spread: 0.3 } },
  skull_wall: { height: 1.1, collider: { kind: 'box', hw: 1.6, hd: 0.35 } },
  drowned_statue: { height: 2.6, collider: { kind: 'circle', r: 0.6 } },
  stained_glass: { height: 3.6, collider: { kind: 'box', hw: 1.1, hd: 0.3 } },
  sunken_bell: { height: 1.8, collider: { kind: 'circle', r: 1.3 } },
  bell_frame: { height: 3.0, collider: { kind: 'box', hw: 1.4, hd: 0.5 } },
  organ_pipes: { height: 4.2, collider: { kind: 'box', hw: 1.8, hd: 0.6 } },
  church_pew: { height: 1.3, collider: { kind: 'box', hw: 1.4, hd: 0.35 } },
  kings_grave: { height: 1.6, collider: { kind: 'box', hw: 1.5, hd: 1.1 } },
  abbess_reliquary: { height: 1.6, collider: { kind: 'box', hw: 0.9, hd: 0.7 } },
  drowned_font: { height: 1.7, collider: { kind: 'circle', r: 0.9 } },
  skull_niche: { height: 3.4, collider: { kind: 'circle', r: 0.7 } },
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

/** A gathering node in the world (roadmap §4/§6). `type` is a gatheringRules NODES id. */
export interface NodePlacement {
  /** Stable id shared by every player in a party (`<area>_<n>`). */
  id: string;
  type: string;
  x: number;
  z: number;
  area: AreaId;
  /** Hunting-ground variant: ×1.5 yield, ×0.5 respawn. */
  rich?: boolean;
  rot: number;
}

/** Collider radius per node kind (fishing spots sit on the water and block nothing). */
export const NODE_COLLIDER: Record<NodeKind, number> = { tree: 0.6, seam: 0.75, geode: 0.9, pool: 0, grave: 0.7 };
/** How far from a node's centre the gatherer stands to work it. */
export const NODE_REACH: Record<NodeKind, number> = { tree: 1.35, seam: 1.45, geode: 1.6, pool: 1.5, grave: 1.4 };

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
  /** Gathering nodes (the Sexton's Acre has every tier; hunting grounds get a few rich ones). */
  nodes: NodePlacement[];
  /** Deep water: rendered like the nave flood but blocks movement (the Acre's pond). */
  ponds: Rect[];
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
    P('altar_ascension', 0, 20.1, a, 0);
    P('rite_niches', -12.2, 26.5, a, Math.PI / 2);
    P('waystone', 9, 26.5, a, 0);
    P('sarcophagus', 0, 27, a, 0);
    for (const [x, z] of [[-3, 10.5], [3, 10.5], [-3, 30.5], [3, 30.5]] as const) P('brazier', x, z, a, 0);
    for (const [x, z] of [[-10.5, 11], [10.5, 11], [-11, 15.8], [10.5, 20], [-2, 21.5], [2, 21.5], [-7.2, 26.8], [-10.8, 25.5], [1.8, 28.6], [-1.8, 28.6]] as const)
      P('candles', x, z, a);
    P('bone_pile', -11.2, 30.6, a);
    P('bone_pile', 11.2, 30.3, a);
    decals.push({ kind: 'sigil', x: 0, z: 21, r: 2.6, color: 0x9b5cff, opacity: 0.7, rot: 0, area: a });
  }

  // --- The Sexton's Acre (non-combat gathering zone) ---
  const nodes: NodePlacement[] = [];
  const ponds: Rect[] = [];
  {
    const a: AreaId = 'acre';
    const r = AREAS[a].rect;
    edgeWalls(a, 1.6, 'stone_wall', walls);
    // Gravel lane from the Chapterhouse door to the Bone Elder, plus the yard by the door.
    paths.push({ x0: -57, z0: 18.6, x1: -20, z1: 21.4 }, { x0: -28, z0: 11, x1: -20, z1: 34 });
    const N = (type: string, x: number, z: number) =>
      nodes.push({ id: `${a}_${nodes.length}`, type, x, z, area: a, rot: rand() * Math.PI * 2 });
    // Quarry wall along the north edge: low tiers by the door, geodes at the far end.
    const seams: [string, number][] = [
      ['seam_copper', -30], ['seam_tin', -32.6], ['seam_copper', -35.2], ['seam_tin', -37.8], ['seam_iron', -40.6],
      ['seam_iron', -43.4], ['seam_bronze', -46.4], ['seam_silver', -49.4], ['seam_gold', -52.4], ['seam_steel', -55.2],
    ];
    for (const [t, x] of seams) N(t, t === 'seam_copper' && x === -30 ? -31.5 : x, t === 'seam_copper' && x === -30 ? 20.2 : 8.3);
    N('geode_hell', -58.6, 8.8);
    N('geode_moon', -59.4, 12.6);
    // The grove, either side of the lane.
    for (const [t, x, z] of [
      ['coffin_oak', -29.5, 17], ['coffin_oak', -33.5, 17], ['coffin_oak', -27.5, 13.5], ['hangman_elm', -37.5, 14], ['hangman_elm', -41.5, 14],
      ['bleeding_willow', -45.5, 14], ['bleeding_willow', -49.5, 14], ['churchyard_yew', -53.5, 14], ['churchyard_yew', -57.2, 15.2],
      ['blackthorn', -46.5, 25.2], ['blackthorn', -50.3, 25.2], ['ghostwood', -54, 25.2], ['ghostwood', -57.6, 25.6],
      ['bone_elder', -59, 20],
    ] as const) N(t, x, z);
    // Black-water pond; fishing spots sit just inside its shore.
    const pond = { x0: -44, z0: 27.4, x1: -30, z1: 32.2 };
    ponds.push(pond);
    for (const [t, x, z] of [
      ['pool_still', -31.5, 28.2], ['pool_still', -34.8, 28.2], ['pool_eels', -37.8, 28.2], ['pool_carp', -40.8, 28.2],
      ['pool_pike', -43.2, 30.2], ['pool_lantern', -30.8, 30.6], ['pool_coelacanth', -37, 31.4],
    ] as const) N(t, x, z);
    // Burial rows along the south wall.
    for (const [t, x] of [
      ['grave_pauper', -29.5], ['grave_pauper', -32.5], ['grave_pauper', -35.5], ['grave_mound', -39.5], ['grave_mound', -43],
      ['grave_crypt', -47.5], ['grave_crypt', -51.5], ['grave_barrow_king', -57],
    ] as const) N(t, t === 'grave_pauper' && x === -29.5 ? -28.5 : x, t === 'grave_pauper' && x === -29.5 ? 21.5 : 35.6);
    // Stations and dressing.
    P('waystone', -23, 25.5, a, 0);
    P('brazier', -26.5, 28.5, a, 0);
    P('workbench', -23.5, 12.5, a, 0, 0.9);
    P('prop_node_bone_kiln', -23.5, 33.2, a, Math.PI);
    P('covenant_lectern', -24.2, 16.8, a, 0);
    for (const [x, z] of [[-21.2, 15.6], [-21.2, 24.4]] as const) P('candles', x, z, a);
    for (const [x, z] of [[-25.4, 34.4], [-60.6, 36.6], [-44.6, 36.8]] as const) P('bone_pile', x, z, a);
    for (const [x, z] of [[-60.8, 30.5], [-60.8, 33.5], [-26.8, 37], [-54, 37]] as const) P('dead_tree', x, z, a, rand() * 6, 0.7 + rand() * 0.2);
    // Headstones between the burial plots and a fence line along the west wall.
    for (let x = -30.9; x > -56; x -= 3.2) {
      if (nodes.some((n) => n.area === a && Math.hypot(n.x - x, n.z - 37.1) < 1.6)) continue;
      P(rand() < 0.6 ? 'tombstone_round' : 'tombstone_cross', x, 37.1, a, (rand() - 0.5) * 0.4, 0.75, { tilt: (rand() - 0.5) * 0.2 });
    }
    for (let z = r.z0 + 1.5; z < r.z1 - 1; z += 2.4) if (Math.abs(z - 20) > 3 && Math.abs(z - 12.6) > 2.2) P('fence', r.x0 + 0.6, z, a, Math.PI / 2);
    decals.push({ kind: 'sigil', x: -23.5, z: 20, r: 2.2, color: 0x6fae7a, opacity: 0.35, rot: 0, area: a });
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
  richNodes(nodes, props);
  dressRooms(props, nodes, crypts, paths);
  bossArenas(props);

  return { paths, props, walls, decals, windows, water, puddles, silhouettes, crypts, nodes, ponds };
}

/**
 * 2–4 rich nodes per hunting ground, themed to the area (roadmap §6). Each takes
 * the first candidate spot clear of props, breaches, interactables and doors.
 */
function richNodes(nodes: NodePlacement[], props: Placement[]) {
  const wants: [AreaId, string, [number, number][]][] = [
    ['graves', 'coffin_oak', [[-23.4, -9.5], [-23.4, -6], [22.8, -30.5], [-23, -24]]],
    ['graves', 'grave_pauper', [[-16, 1.6], [16.5, 1.4], [-10, -34], [10, -34.2]]],
    ['ossuary', 'seam_silver', [[33.6, -30], [62.4, -13], [33.6, -26]]],
    ['ossuary', 'grave_crypt', [[50, -3.8], [40, -36.2], [57, -36.2]]],
    ['nave', 'pool_eels', [[-11.6, -86], [11.6, -66], [-11.6, -64]]],
    ['nave', 'bleeding_willow', [[-12.8, -47], [12.8, -94]]],
    ['sanctum', 'geode_moon', [[-16.2, -113], [-16.2, -121]]],
    ['sanctum', 'geode_moon', [[16.2, -120], [16.2, -113]]],
  ];
  const spots = interactSpots();
  for (const [area, type, cands] of wants) {
    const [x, z] =
      cands.find(([x, z]) => {
        if (!inRect(AREAS[area].rect, x, z, 0.8)) return false;
        if (props.some((p) => Math.hypot(p.x - x, p.z - z) < 2)) return false;
        if (AREAS[area].breaches.some(([bx, bz]) => Math.hypot(bx - x, bz - z) < 3)) return false;
        if (spots.some((s) => Math.hypot(s.x - x, s.z - z) < 3)) return false;
        if (DOORS.some((d) => inRect({ x0: d.rect.x0 - 2.5, z0: d.rect.z0 - 2.5, x1: d.rect.x1 + 2.5, z1: d.rect.z1 + 2.5 }, x, z))) return false;
        return !nodes.some((n) => Math.hypot(n.x - x, n.z - z) < 3);
      }) ?? [NaN, NaN];
    if (Number.isNaN(x)) continue;
    nodes.push({ id: `${area}_${nodes.filter((n) => n.area === area).length}`, type, x, z, area, rich: true, rot: (x * 7.3 + z * 3.1) % (Math.PI * 2) });
  }
  // Keep only types the rules know (a renamed node must not break old seeds silently).
  for (let i = nodes.length - 1; i >= 0; i--) if (!NODES[nodes[i].type]) nodes.splice(i, 1);
}

/**
 * World dressing (2026-09-27): two or three signature props per combat room, placed last so the seeded layout above
 * never shifts. Each wants a list of candidate spots; the first one clear of props, breaches, doors, interactables,
 * gathering nodes, crypt surge spots and (for blocking props) the main paths is taken.
 */
export const DRESSING: [PropId, AreaId, number, [number, number][]][] = [
  // Hollow Graves: coffins by the mausoleums, gibbets along the cross path, lantern posts at the forks.
  ['coffin_stack', 'graves', 0.3, [[-15.4, -32.8], [-15.6, -28.4], [-22.6, -26.2]]],
  ['coffin_stack', 'graves', 2.8, [[14.8, -0.4], [22.8, -6.2], [15, -4.8]]],
  ['gibbet_cage', 'graves', 1.2, [[-12, -20.8], [-17, -20.8], [-9.5, -11.2]]],
  ['gibbet_cage', 'graves', 4.3, [[12.5, -11.2], [17.5, -11.2], [9.5, -21]]],
  ['grave_lantern', 'graves', 0, [[3.6, -2.6], [3.6, -5.4]]],
  ['grave_lantern', 'graves', 0, [[-3.6, -31.5], [-3.6, -29]]],
  ['grave_lantern', 'graves', 0, [[23.2, -12.6], [23.2, -11]]],
  ['grave_lantern', 'graves', 0, [[-7.2, -13.2], [-7.4, -18.8]]],
  // Marrow Ossuary: candelabra beside the aisle, low skull walls as half-cover lanes.
  ['bone_candelabrum', 'ossuary', 0, [[36.2, -21.6], [36.2, -14.4]]],
  ['bone_candelabrum', 'ossuary', 0, [[44.6, -14.2], [44.6, -22]]],
  ['bone_candelabrum', 'ossuary', 0, [[60.2, -21.8], [60.2, -14.2]]],
  ['skull_wall', 'ossuary', 0, [[38.5, -9], [40, -8.4]]],
  ['skull_wall', 'ossuary', Math.PI / 2, [[46.2, -29.5], [47.4, -30.5]]],
  ['skull_wall', 'ossuary', 0, [[58, -28.5], [57.4, -30]]],
  // Drowned Nave: saints in the flood, broken windows on the side walls, a sunken bell as a landmark, pews.
  ['drowned_statue', 'nave', Math.PI, [[-3.4, -60.5], [-3.4, -58]]],
  ['drowned_statue', 'nave', Math.PI, [[3.4, -73.5], [3.4, -76]]],
  ['stained_glass', 'nave', Math.PI / 2, [[-13.9, -57], [-13.9, -67]]],
  ['stained_glass', 'nave', -Math.PI / 2, [[13.9, -86.5], [13.9, -77]]],
  ['sunken_bell', 'nave', 0.6, [[-2.8, -83.2], [2.8, -83.2]]],
  ['church_pew', 'nave', 0, [[-3.1, -55.6]]],
  ['church_pew', 'nave', 0, [[3.1, -55.6]]],
  ['church_pew', 'nave', 0, [[-3.1, -63.4]]],
  ['church_pew', 'nave', 0, [[3.1, -63.4]]],
  // Bell Sanctum: organ ranks flank the Sundered Bell; bell frames at the entrance corners.
  ['organ_pipes', 'sanctum', 0, [[-6.6, -128.8]]],
  ['organ_pipes', 'sanctum', 0, [[6.6, -128.8]]],
  ['bell_frame', 'sanctum', 0, [[-13.6, -108.2], [-12.6, -107]]],
  ['bell_frame', 'sanctum', 0, [[13.6, -108.2], [12.6, -107]]],
];

function footprint(prop: PropId, scale = 1) {
  const c = PROPS[prop].collider;
  return (c?.kind === 'box' ? Math.hypot(c.hw, c.hd) : c?.kind === 'circle' ? c.r : 0.4) * scale;
}

function dressRooms(props: Placement[], nodes: NodePlacement[], crypts: Crypt[], paths: Rect[]) {
  const spots = interactSpots();
  for (const [prop, area, rot, cands] of DRESSING) {
    const r = footprint(prop);
    const blocks = !!PROPS[prop].collider;
    const spot = cands.find(([x, z]) => {
      // Props may stand against the outer walls (the wall is solid anyway); only the centre must be inside.
      if (!inRect(AREAS[area].rect, x, z, 0.2)) return false;
      if (props.some((p) => Math.hypot(p.x - x, p.z - z) < (r + footprint(p.prop, p.scale)) * 0.8 + 0.2)) return false;
      if (AREAS[area].breaches.some(([bx, bz]) => Math.hypot(bx - x, bz - z) < r + 2.5)) return false;
      if (DOORS.some((d) => inRect({ x0: d.rect.x0 - 2.5, z0: d.rect.z0 - 2.5, x1: d.rect.x1 + 2.5, z1: d.rect.z1 + 2.5 }, x, z))) return false;
      if (spots.some((s) => Math.hypot(s.x - x, s.z - z) < r + 2.2)) return false;
      if (nodes.some((n) => Math.hypot(n.x - x, n.z - z) < r + 2)) return false;
      if (crypts.some((c) => Math.hypot(c.x - x, c.z - z) < r + 2.2)) return false;
      // Main paths stay open (pews and flooded-aisle props are the Nave's intended exceptions).
      if (blocks && area !== 'nave' && paths.some((q) => inRect(q, x, z, -r))) return false;
      return true;
    });
    if (spot) props.push({ prop, x: spot[0], z: spot[1], rot, scale: 1, area });
  }
}

/** Small props an area-boss arena clears out of its fighting ground (crypts, pillars and walls stay). */
const ARENA_CLEAR = new Set<PropId>(['tombstone_round', 'tombstone_cross', 'candles', 'bone_pile', 'dead_tree', 'gibbet_cage', 'coffin_stack', 'statue', 'drowned_statue', 'bone_candelabrum', 'brazier']);

/**
 * Area bosses (2026-09-28), placed last like the dressing so the seeded layout never shifts: clear each arena's
 * small props, stand its summon object at the north edge, keep the Abbess's niche spots and the King's pits open,
 * and give the Congregation two ragged rows of pews to hide behind.
 */
function bossArenas(props: Placement[]) {
  const drop = (keep: (p: Placement) => boolean) => {
    for (let i = props.length - 1; i >= 0; i--) if (!keep(props[i])) props.splice(i, 1);
  };
  for (const id of ['gravedigger', 'abbess', 'congregation'] as BossId[]) {
    const b = BOSSES[id];
    const { x, z, r } = b.arena;
    const [sx, sz] = summonSpot(id);
    drop((p) => p.area !== b.area || !ARENA_CLEAR.has(p.prop) || Math.hypot(p.x - x, p.z - z) > r * 0.8);
    drop((p) => p.area !== b.area || Math.hypot(p.x - sx, p.z - sz) > 2.4 || p.prop === 'mausoleum' || p.prop === 'sarcophagus');
    props.push({ prop: b.summonId as PropId, x: sx, z: sz, rot: 0, scale: 1, area: b.area });
  }
  const open: [BossId, [number, number][]][] = [['abbess', ABBESS_NICHE_SPOTS], ['gravedigger', GRAVEDIGGER_PITS]];
  for (const [id, spots] of open) drop((p) => p.area !== BOSSES[id].area || p.prop === 'mausoleum' || p.prop === 'sarcophagus' || spots.every(([x, z]) => Math.hypot(p.x - x, p.z - z) > 1.9));
  // Pews: the Hymn's only cover. Keep what the dressing placed and add the outer row where it is clear.
  for (const [x, z] of [[-6.4, -57.4], [6.4, -57.4], [-6.4, -64.8], [6.4, -64.8]] as const) {
    if (props.some((p) => Math.hypot(p.x - x, p.z - z) < footprint(p.prop, p.scale) + 1.1)) continue;
    props.push({ prop: 'church_pew', x, z, rot: 0, scale: 1, area: 'nave' });
  }
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
