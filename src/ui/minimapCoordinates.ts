import { AREAS, AREA_ORDER, DOORS, type AreaId, type Rect } from '../../server/rules/content/areas';

export const MINIMAP_SIZE = 190;
export const MINIMAP_SCALE = 2.1;

/** Invert the drawn north-up map, independently of DPR or CSS display size. */
export function minimapWorldPoint(
  clientX: number,
  clientY: number,
  rect: { left: number; top: number; width: number; height: number },
  px: number,
  pz: number,
): { x: number; z: number } | null {
  if (!Number.isFinite(clientX + clientY + px + pz + rect.left + rect.top + rect.width + rect.height) || rect.width <= 0 || rect.height <= 0) return null;
  const half = MINIMAP_SIZE / 2;
  const dx = ((clientX - rect.left) / rect.width) * MINIMAP_SIZE - half;
  const dz = ((clientY - rect.top) / rect.height) * MINIMAP_SIZE - half;
  if (dx * dx + dz * dz > half * half) return null;
  return { x: px + dx / MINIMAP_SCALE, z: pz + dz / MINIMAP_SCALE };
}

/** The map draws area floors and open corridors; blank/hatched ground isn't a destination. */
export function minimapWalkable(x: number, z: number, unlocked: (a: AreaId) => boolean): boolean {
  const inside = (r: Rect) => x >= r.x0 && x <= r.x1 && z >= r.z0 && z <= r.z1;
  return AREA_ORDER.some(id => unlocked(id) && inside(AREAS[id].rect)) ||
    DOORS.some(door => unlocked(door.a) && unlocked(door.b) && inside(door.rect));
}
