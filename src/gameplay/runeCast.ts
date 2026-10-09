/**
 * Relic runes, client side: the target pickers the cast code and the balance bot share (pure geometry, no DOM). The host-side halves of the
 * runes (Mass Grave, Bone Colossus, Creeping Rot, Contagion, Hollow Choir, Requiem, the Impale root) live in sim/WorldSim.ts.
 */
import { RUNE_TUNING } from '../../server/rules/content/runes';

export interface Foe {
  id: number;
  x: number;
  z: number;
  radius: number;
}
interface Pt {
  x: number;
  z: number;
}

const dist = (a: Pt, b: Pt) => Math.hypot(a.x - b.x, a.z - b.z);

/** Splinters: the living enemy nearest the struck one (other than it) within the rune's reach. */
export function splinterTarget<E extends Foe>(first: Pt & { id: number }, foes: readonly E[]): E | null {
  let best: E | null = null;
  let bestD: number = RUNE_TUNING.splinter.reach;
  for (const e of foes) {
    if (e.id === first.id) continue;
    const d = dist(e, first);
    if (d <= bestD) {
      bestD = d;
      best = e;
    }
  }
  return best;
}

/**
 * Volley: the needle's own target plus the enemies nearest to it, all within the volley's reach of the caster, `needles` in all.
 * Fewer enemies than needles: the list is shorter and the caller aims the rest at the first.
 */
export function volleyTargets<E extends Foe>(caster: Pt, first: E, foes: readonly E[]): E[] {
  const V = RUNE_TUNING.volley;
  const others = foes
    .filter((e) => e.id !== first.id && dist(e, caster) <= V.reach)
    .sort((a, b) => dist(a, first) - dist(b, first))
    .slice(0, V.needles - 1);
  return [first, ...others];
}

/** Ossuary Ring: everything inside the ring (body radius counts). */
export function ringHits<E extends Foe>(center: Pt, radius: number, foes: readonly E[]): E[] {
  return foes.filter((e) => dist(e, center) <= radius + e.radius);
}

/** Where the ring lands: the cursor, pulled back to the spear's reach. */
export function ringCenter(origin: Pt, aim: Pt, reach: number): Pt {
  const d = dist(origin, aim);
  if (d <= reach || d < 1e-6) return { x: aim.x, z: aim.z };
  return { x: origin.x + ((aim.x - origin.x) / d) * reach, z: origin.z + ((aim.z - origin.z) / d) * reach };
}

/** Impaling: the first enemy a spear down (dx, dz) meets within `range` and a half-width, or null. */
export function impaleTarget<E extends Foe>(origin: Pt, dx: number, dz: number, range: number, halfW: number, foes: readonly E[]): { foe: E; along: number } | null {
  let best: { foe: E; along: number } | null = null;
  for (const e of foes) {
    const rx = e.x - origin.x;
    const rz = e.z - origin.z;
    const along = rx * dx + rz * dz;
    if (along > 0 && along < range && Math.abs(rx * dz - rz * dx) < halfW + e.radius && (!best || along < best.along)) best = { foe: e, along };
  }
  return best;
}

/** Mass Grave and the Colossus need corpses: how many a rite can find within `r` of the point. */
export function corpsesWithin<C extends Pt>(point: Pt, r: number, corpses: Iterable<C & { echoOwner?: string }>): C[] {
  const out: C[] = [];
  for (const c of corpses) if (!c.echoOwner && dist(c, point) <= r) out.push(c);
  return out.sort((a, b) => dist(a, point) - dist(b, point));
}
