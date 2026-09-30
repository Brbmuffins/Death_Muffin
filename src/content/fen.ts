/**
 * The Mourning Fen (2026-09-30): the geometry and numbers shared by the layout, the sim, the views and the tests.
 * Pure data + two tiny helpers; nothing here imports game systems, so content/areas, content/bosses and the sim can all use it.
 *
 * The whole marsh floor is bog water. Wading is slow, so the dry hummocks (and the dry landing by the Nave door) are where you
 * want to stand: the Fen is about reading the ground. The water is drawn by the existing Drowned Nave water mesh and the slow
 * rides the existing `Player.moveMult` hook, exactly like the Drowned Congregation's rising water. No new per-frame system.
 */

export interface FenRect {
  x0: number;
  z0: number;
  x1: number;
  z1: number;
}

/** The Mire Mother's arena (the marsh's heart). Kept here so the hummock ring is built around it. */
export const FEN_ARENA = { x: -42, z: -80, r: 12 };

/** The marsh water: everything inside the Fen walls except the dry landing on the east bank (x −31…−22, z −88…−70). */
export const FEN_BOG: FenRect[] = [
  { x0: -59.4, z0: -99.4, x1: -31, z1: -60.6 },
  { x0: -31, z0: -99.4, x1: -22.6, z1: -88 },
  { x0: -31, z0: -70, x1: -22.6, z1: -60.6 },
];

export interface Hummock {
  x: number;
  z: number;
  /** Dry radius in calm water (phase 1). */
  r: number;
}

/**
 * Dry hummocks. Index 0 carries the Mire Altar on the arena's north rim, index 1 is the big central one, 2-6 ring it (the
 * boss's resurfacing spots live here), the rest are footholds around the marsh so every breach has somewhere to fight from.
 */
export const FEN_HUMMOCKS: Hummock[] = [
  { x: -42, z: -90.2, r: 2.7 },
  { x: -42, z: -80, r: 3.2 },
  { x: -42, z: -73.4, r: 2.4 },
  { x: -36.3, z: -76.7, r: 2.3 },
  { x: -36.3, z: -83.3, r: 2.4 },
  { x: -47.7, z: -83.3, r: 2.4 },
  { x: -47.7, z: -76.7, r: 2.3 },
  { x: -55.5, z: -95, r: 2.6 },
  { x: -33, z: -95.5, r: 2.5 },
  { x: -56, z: -82, r: 2.6 },
  { x: -55, z: -68.5, r: 2.5 },
  { x: -47, z: -64.5, r: 2.4 },
  { x: -34, z: -65.5, r: 2.5 },
  { x: -52, z: -90.5, r: 2.3 },
];

/** Hummocks the Mire Mother may surface under (the ring around the centre, and the centre itself). */
export const FEN_SURFACE_SPOTS = [1, 2, 3, 4, 5, 6];

/** Dry-ground radius multiplier per Mire Mother phase: the arena floods, the hummocks shrink (1 outside the fight). */
export const FEN_FLOOD_SCALE: Record<1 | 2 | 3, number> = { 1: 1, 2: 0.72, 3: 0.5 };

/** Bog wading: the movement multiplier outside dry ground (phase 1 of the boss, or no boss), and as the arena floods. */
export const BOG = { slow: 0.78, slowP2: 0.68, slowP3: 0.58 };

export const inFenRect = (r: FenRect, x: number, z: number) => x >= r.x0 && x <= r.x1 && z >= r.z0 && z <= r.z1;

/** Is this point in the marsh water at all (dry hummocks still count; see `onDryGround`)? */
export function inBog(x: number, z: number): boolean {
  for (const r of FEN_BOG) if (inFenRect(r, x, z)) return true;
  return false;
}

/** The hummock a point stands on (dry radius scaled by the flood), or null. */
export function hummockAt(x: number, z: number, scale = 1, pad = 0): Hummock | null {
  for (const h of FEN_HUMMOCKS) if (Math.hypot(x - h.x, z - h.z) <= h.r * scale + pad) return h;
  return null;
}

/** Bog wading slow for a body at (x, z): 1 on dry ground, `BOG.*` in the water. `phase` is the awake Mire Mother's (0 = none). */
export function bogMult(x: number, z: number, phase = 0): number {
  if (!inBog(x, z)) return 1;
  const scale = phase >= 1 ? FEN_FLOOD_SCALE[Math.min(3, phase) as 1 | 2 | 3] : 1;
  if (hummockAt(x, z, scale)) return 1;
  return phase >= 3 ? BOG.slowP3 : phase === 2 ? BOG.slowP2 : BOG.slow;
}

/** Where the marsh's wisps drift when they kite: the open water at the heart of the Fen (they lure you toward it). */
export const FEN_LURE = { x: -44, z: -79 };

// --- Monster numbers -------------------------------------------------------------------------------------------------

/** Bog Hag's hex: a ring around the thrall cluster she picks; thralls inside it deal less for a few seconds. */
export const HAG_HEX = { radius: 3.1, durationS: 6, thrallDamageMult: 0.7, blowMult: 0.55, chillMs: 1800 };
/** Fen Wisp pulse: a ring where you stood; the cold it leaves slows you (a wading bog and a chill do stack, so it is short). */
export const WISP_PULSE = { radius: 2.3, chillMs: 1800 };
/** Drowned Sexton's grave-hook: a chain along a line, then a short drag toward him. */
export const SEXTON_HOOK = { minRange: 3.4, range: 8.5, halfWidth: 0.95, windupMs: 950, cooldownS: 6.5, pullM: 4.5, blowMult: 0.7, rootMs: 500 };
