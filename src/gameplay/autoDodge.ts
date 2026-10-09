/**
 * Easy auto's dodge (owner decision 2026-10-03): leave boss telegraphs, hymn cones and hostile ground pools, then carry on attacking.
 *
 * The shapes come from the same data the renderer draws and `BossBrain.resolve` tests: the host's `boss` events (kind, centre, radius,
 * facing, targets) and the sim's hostile zones. Each shape here is the hit test with its pads (a boss ring strikes `BOSS_RING_PAD` past
 * its radius, a cone 0.3 m, hands and grasp 0.2 m), so standing outside a shape here is standing outside the blow. A test runs the real
 * brain against these tests to keep the two from drifting apart.
 *
 * Pure geometry, no DOM and no scene: the scene feeds `BossTelegraphs.onEvent` and passes `active()` plus the pools to
 * `selectAutoCombatMovement`, which calls `dodgeStep` before anything else.
 */
import { ABBESS, CONGREGATION, GRAVEDIGGER, MIRE, REGENT, SAINT } from '../../server/rules/content/bosses';
import { BOSS_RING_PAD } from './sim/BossBrain';
import type { SimEvent } from './sim/types';

type BossEvent = Extract<SimEvent, { t: 'boss' }>;
type Pt = { x: number; z: number };

export type Hazard = (
  | { k: 'circle'; x: number; z: number; r: number }
  | { k: 'cone'; x: number; z: number; dir: number; r: number; half: number }
  | { k: 'seg'; x: number; z: number; dir: number; len: number; hw: number }
  | { k: 'rect'; x: number; z: number; hw: number; hd: number }
  /** Conflagration: everywhere inside the arena burns except the ash circles. */
  | { k: 'except'; x: number; z: number; r: number; spots: [number, number][]; safeR: number }
) & {
  /** The boss event that made it (to clear it when the blow lands) and when to give up on it (ms on the scene clock). */
  src?: string;
  dir0?: number;
  until: number;
};

/** A hostile ground pool (`Zone.hostile`): damage over time to anything inside `r` of its centre plus the player's body. */
export const poolHazard = (z: { x: number; z: number; r: number }, playerRadius: number): Hazard => ({ k: 'circle', x: z.x, z: z.z, r: z.r + playerRadius, until: Infinity });

const angleTo = (fx: number, fz: number, tx: number, tz: number) => Math.atan2(tx - fx, tz - fz);
const angleDiff = (a: number, b: number) => {
  const d = Math.abs(a - b) % (Math.PI * 2);
  return d > Math.PI ? Math.PI * 2 - d : d;
};
function segDist(px: number, pz: number, ax: number, az: number, bx: number, bz: number) {
  const vx = bx - ax;
  const vz = bz - az;
  const l2 = vx * vx + vz * vz || 1;
  const t = Math.max(0, Math.min(1, ((px - ax) * vx + (pz - az) * vz) / l2));
  return Math.hypot(px - (ax + vx * t), pz - (az + vz * t));
}
const deg = (d: number) => (d * Math.PI) / 180;

/** The half-angle of a boss's melee cone for this event kind (they differ by boss). */
function coneHalf(ev: BossEvent): number {
  switch (ev.kind) {
    case 'sweep': return deg(GRAVEDIGGER.sweep.halfDeg);
    case 'swing': return deg(SAINT.swing.halfDeg);
    case 'cleave': return deg(REGENT.cleave.halfDeg);
    case 'hymn': return deg(CONGREGATION.hymn.halfDeg);
    case 'grasp': return deg(ABBESS.grasp.halfDeg);
    default: return deg(ev.boss === 'mire' ? MIRE.maul.halfDeg : CONGREGATION.melee.halfDeg); // maul
  }
}

/**
 * The shapes one boss event warns of: a telegraph (`ms > 0`) gives its blow, the Gravedigger's open pits (phase 3) are standing
 * hazards. Events that warn of nothing you can step out of (summons, links, communion, the Mire Mother's rite) give none.
 * `now` is the scene clock in ms.
 */
export function hazardsFromBossEvent(ev: BossEvent, now: number): Hazard[] {
  const until = now + (ev.ms ?? 0) + 2500; // resolve normally clears it first; this is only the fallback (a missed event, a host change)
  const src = `${ev.boss ?? 'prelate'}:${ev.kind}:${Math.round(ev.x * 10)}:${Math.round(ev.z * 10)}`;
  const tag = { src, dir0: ev.dir, until };
  const targets = ev.targets ?? [];
  if (ev.kind === 'pits') return targets.map(([x, z]) => ({ k: 'circle', x, z, r: GRAVEDIGGER.pits.r + 0.1, src: `pits:${x}:${z}`, until: Infinity }));
  if ((ev.ms ?? 0) <= 0) return [];
  const r = ev.r ?? 0;
  switch (ev.kind) {
    case 'toll':
    case 'slam':
      return [{ k: 'circle', x: ev.x, z: ev.z, r: r + BOSS_RING_PAD, ...tag }];
    case 'rain':
    case 'rotRain':
    case 'coals':
      return targets.map(([x, z]) => ({ k: 'circle', x, z, r: r + BOSS_RING_PAD, ...tag }));
    case 'surface':
      return [{ k: 'circle', x: ev.x, z: ev.z, r: MIRE.surface.r + 0.3, ...tag }];
    case 'hands':
      return targets.map(([x, z]) => ({ k: 'circle', x, z, r: MIRE.hands.r + 0.2, ...tag }));
    case 'bury':
      return targets.map(([x, z]) => ({ k: 'rect', x, z, hw: GRAVEDIGGER.burial.hw + 0.3, hd: GRAVEDIGGER.burial.hd + 0.3, ...tag }));
    case 'sweep':
    case 'swing':
    case 'cleave':
    case 'maul':
      return [{ k: 'cone', x: ev.x, z: ev.z, dir: ev.dir ?? 0, r: r + 0.3, half: coneHalf(ev), ...tag }];
    case 'hymn':
      return [{ k: 'cone', x: ev.x, z: ev.z, dir: ev.dir ?? 0, r: CONGREGATION.hymn.reach, half: coneHalf(ev), ...tag }];
    case 'grasp':
      if (ev.boss === 'abbess') return [{ k: 'cone', x: ev.x, z: ev.z, dir: ev.dir ?? 0, r: ABBESS.grasp.r + 0.3, half: coneHalf(ev), ...tag }];
      return targets.map(([x, z]) => ({ k: 'circle', x, z, r: CONGREGATION.grasp.r + 0.2, ...tag }));
    case 'lance':
      return [{ k: 'seg', x: ev.x, z: ev.z, dir: ev.dir ?? 0, len: ABBESS.lance.len, hw: ABBESS.lance.halfWidth, ...tag }];
    case 'chorus':
      return Array.from({ length: ABBESS.chorus.spokes }, (_, i) => ({ k: 'seg' as const, x: ev.x, z: ev.z, dir: (ev.dir ?? 0) + (i * Math.PI * 2) / ABBESS.chorus.spokes, len: ABBESS.chorus.len, hw: ABBESS.chorus.halfWidth, ...tag }));
    case 'conflagration':
      return [{ k: 'except', x: ev.x, z: ev.z, r: r + 0.5, spots: targets, safeR: REGENT.conflagration.safeR, ...tag }];
    default:
      return [];
  }
}

/**
 * Is (x, z) struck by the shape? `margin` fattens the shape (or, for `except`, shrinks the safe circles), so a margin of 0 is exactly
 * the host's hit test and a larger one is "stand clear with room to spare".
 */
export function inHazard(h: Hazard, x: number, z: number, margin = 0): boolean {
  switch (h.k) {
    case 'circle':
      return Math.hypot(x - h.x, z - h.z) <= h.r + margin;
    case 'cone': {
      const d = Math.hypot(x - h.x, z - h.z);
      if (d > h.r + margin) return false;
      if (d <= margin) return true;
      // A margin of m metres is an angular margin of asin(m / d) at distance d.
      return angleDiff(angleTo(h.x, h.z, x, z), h.dir) <= h.half + Math.asin(Math.min(1, margin / d));
    }
    case 'seg':
      return segDist(x, z, h.x, h.z, h.x + Math.sin(h.dir) * h.len, h.z + Math.cos(h.dir) * h.len) <= h.hw + margin;
    case 'rect':
      return Math.abs(x - h.x) <= h.hw + margin && Math.abs(z - h.z) <= h.hd + margin;
    case 'except':
      return Math.hypot(x - h.x, z - h.z) <= h.r && !h.spots.some(([sx, sz]) => Math.hypot(x - sx, z - sz) <= h.safeR - margin);
  }
}

const anyHazard = (hs: readonly Hazard[], x: number, z: number, margin: number) => {
  for (const h of hs) if (inHazard(h, x, z, margin)) return true;
  return false;
};

/** The scene's record of live boss telegraphs, fed from the same events that draw them. */
export class BossTelegraphs {
  private list: Hazard[] = [];

  onEvent(ev: BossEvent, now: number) {
    if (ev.kind === 'defeated' || ev.kind === 'awaken') {
      this.list = [];
      return;
    }
    if ((ev.ms ?? 0) > 0 || ev.kind === 'pits') {
      this.list.push(...hazardsFromBossEvent(ev, now));
      return;
    }
    // The blow landed: forget the telegraph it came from (one per matching kind and centre; a second sweep at another angle stays).
    const src = `${ev.boss ?? 'prelate'}:${ev.kind}:${Math.round(ev.x * 10)}:${Math.round(ev.z * 10)}`;
    const at = this.list.findIndex((h) => h.src === src && (ev.dir === undefined || h.dir0 === undefined || Math.abs(angleDiff(h.dir0, ev.dir)) < 1e-6));
    if (at < 0) return;
    const dir0 = this.list[at].dir0;
    this.list = this.list.filter((h) => !(h.src === src && h.dir0 === dir0));
  }

  /** What is live now (expired shapes dropped). The array is reused between calls: do not keep it. */
  active(now: number): readonly Hazard[] {
    if (this.list.some((h) => h.until < now)) this.list = this.list.filter((h) => h.until >= now);
    return this.list;
  }

  clear() {
    this.list = [];
  }
}

// --- Choosing where to stand ------------------------------------------------------------------------------------------

/** You are "in" a telegraph with this much to spare (so a foot on the edge still counts). */
const IN_MARGIN = 0.25;
/** A place to stand must be this clear of every shape (body radius 0.45 plus room). */
const SAFE_MARGIN = 0.75;
const RING_STEP = 0.6;
/** The most clearance a candidate is credited with when ranking safe points at the same distance. */
const MAX_ROOM = 3;
const MAX_RING = 19;
const ANGLES = 36;
const ARRIVED = 0.35;
const GOAL_MS = 2500;

export interface DodgeMemory {
  /** The place we chose to stand and when to drop it (ms). Kept while it stays safe, so two equally near exits never make the hero wobble. */
  goal?: { x: number; z: number; until: number } | null;
}
export interface DodgeNav {
  clearLine(x0: number, z0: number, x1: number, z1: number, r?: number): boolean;
}
export interface DodgeRect {
  x0: number;
  z0: number;
  x1: number;
  z1: number;
}

/** The nearest reachable point clear of every shape, or null. Rings of candidates by distance; ties go to the exit closest to `prefer`. */
export function nearestSafePoint(p: Pt, hazards: readonly Hazard[], opts: { rect?: DodgeRect | null; nav?: DodgeNav; prefer?: Pt | null } = {}): Pt | null {
  const { rect, nav, prefer } = opts;
  const ok = (x: number, z: number) => {
    if (rect && (x < rect.x0 + 1 || x > rect.x1 - 1 || z < rect.z0 + 1 || z > rect.z1 - 1)) return false;
    if (anyHazard(hazards, x, z, SAFE_MARGIN)) return false;
    return !nav || nav.clearLine(p.x, p.z, x, z, 0.45);
  };
  // Ash circles and other named safe spots are worth trying by their centres (a ring search can step over a small one).
  const named: Pt[] = [];
  for (const h of hazards) if (h.k === 'except') for (const [sx, sz] of h.spots) named.push({ x: sx, z: sz });
  const spotDist = (s: Pt) => Math.hypot(s.x - p.x, s.z - p.z);
  named.sort((a, b) => spotDist(a) - spotDist(b));
  const ph = prefer ? Math.atan2(prefer.x - p.x, prefer.z - p.z) : null;
  let ni = 0;
  for (let ring = 1; ring * RING_STEP <= MAX_RING; ring++) {
    const r = ring * RING_STEP;
    while (ni < named.length && spotDist(named[ni]) <= r) {
      const s = named[ni++];
      if (ok(s.x, s.z)) return s;
    }
    // Of the safe points at this distance take the one with the most room around it (the middle of the way out, not its edge), then the
    // one nearest the last choice.
    let best: Pt | null = null;
    let bestRoom = -1;
    let bestTurn = Infinity;
    for (let a = 0; a < ANGLES; a++) {
      const ang = (a / ANGLES) * Math.PI * 2;
      const x = p.x + Math.sin(ang) * r;
      const z = p.z + Math.cos(ang) * r;
      if (!ok(x, z)) continue;
      // Room: how much further than the bare safe margin this point could be fattened by before a shape reaches it (bisected, 0.75 to 3 m).
      let lo = SAFE_MARGIN;
      let hi = MAX_ROOM;
      for (let k = 0; k < 6; k++) {
        const mid = (lo + hi) / 2;
        if (anyHazard(hazards, x, z, mid)) hi = mid;
        else lo = mid;
      }
      const room = Math.round(lo * 20) / 20;
      const turn = ph === null ? 0 : angleDiff(ang, ph);
      if (room > bestRoom || (room === bestRoom && turn < bestTurn)) {
        best = { x, z };
        bestRoom = room;
        bestTurn = turn;
      }
    }
    if (best) return best;
  }
  return null;
}

/**
 * Easy auto's dodge: a unit direction toward where to stand when the hero is inside a shape (or still on its way to the spot chosen
 * for it), null when there is nothing to do. The goal is the nearest safe point, chosen once and kept while it stays safe.
 */
export function dodgeStep(
  p: Pt,
  hazards: readonly Hazard[],
  mem: DodgeMemory | undefined,
  now: number,
  opts: { rect?: DodgeRect | null; nav?: DodgeNav } = {},
): Pt | null {
  if (!hazards.length) {
    if (mem) mem.goal = null;
    return null;
  }
  const inside = anyHazard(hazards, p.x, p.z, IN_MARGIN);
  let goal = mem?.goal ?? null;
  if (goal && (now > goal.until || Math.hypot(goal.x - p.x, goal.z - p.z) <= ARRIVED)) goal = null;
  // A kept goal must still be clear of what is on the floor now (a new telegraph can land on it).
  if (goal && anyHazard(hazards, goal.x, goal.z, SAFE_MARGIN - 0.2)) goal = null;
  if (!goal) {
    if (!inside) {
      if (mem) mem.goal = null;
      return null;
    }
    const pt = nearestSafePoint(p, hazards, { ...opts, prefer: mem?.goal });
    if (!pt) {
      if (mem) mem.goal = null;
      return null;
    }
    goal = { x: pt.x, z: pt.z, until: now + GOAL_MS };
  }
  if (mem) mem.goal = goal;
  const d = Math.hypot(goal.x - p.x, goal.z - p.z);
  return d < 1e-6 ? null : { x: (goal.x - p.x) / d, z: (goal.z - p.z) / d };
}

/** Would a step of `len` metres along `dir` land in (or too near) a live shape? Used to stop the hero walking back into a telegraph. */
export function stepIntoHazard(p: Pt, dir: Pt, hazards: readonly Hazard[], len = 1.4, margin = 0.5): boolean {
  return hazards.length > 0 && anyHazard(hazards, p.x + dir.x * len, p.z + dir.z * len, margin);
}
