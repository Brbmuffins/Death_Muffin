import { describe, expect, it } from 'vitest';
import { AREAS, AREA_ORDER, DOORS, type AreaId } from '../../content/areas';
import { generateLayout, PROPS } from '../../content/layout';
import { ENEMIES } from '../../content/enemies';
import { CODEX_AREAS } from '../../content/codex';

const layout = generateLayout();

/** Flood-fill an area on a 0.5 m grid (hero radius 0.5) and report which points can be reached from `from`. */
function reach(area: AreaId, from: [number, number], targets: [number, number][]) {
  const r = AREAS[area].rect;
  const S = 0.5;
  const boxes = layout.walls.filter((w) => w.area === area).map((w) => {
    const t = w.thickness / 2 + 0.5;
    return [Math.min(w.x0, w.x1) - t, Math.min(w.z0, w.z1) - t, Math.max(w.x0, w.x1) + t, Math.max(w.z0, w.z1) + t];
  });
  const circles: [number, number, number][] = [];
  const rects: number[][] = [];
  for (const p of layout.props.filter((q) => q.area === area)) {
    const c = PROPS[p.prop].collider;
    if (c?.kind === 'circle') circles.push([p.x, p.z, c.r * p.scale + 0.5]);
    else if (c?.kind === 'box') rects.push([p.x - c.hw * p.scale - 0.5, p.z - c.hd * p.scale - 0.5, p.x + c.hw * p.scale + 0.5, p.z + c.hd * p.scale + 0.5]);
  }
  const blocked = (x: number, z: number) =>
    x < r.x0 + 0.5 || x > r.x1 - 0.5 || z < r.z0 + 0.5 || z > r.z1 - 0.5 ||
    boxes.some((b) => x > b[0] && x < b[2] && z > b[1] && z < b[3]) ||
    rects.some((b) => x > b[0] && x < b[2] && z > b[1] && z < b[3]) ||
    circles.some(([cx, cz, cr]) => Math.hypot(x - cx, z - cz) < cr);
  const key = (i: number, j: number) => i * 10000 + j;
  const seen = new Set<number>();
  const start: [number, number] = [Math.round((from[0] - r.x0) / S), Math.round((from[1] - r.z0) / S)];
  const q = [start];
  seen.add(key(...start));
  while (q.length) {
    const [i, j] = q.pop()!;
    for (const [di, dj] of [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
      const ni = i + di;
      const nj = j + dj;
      if (seen.has(key(ni, nj)) || blocked(r.x0 + ni * S, r.z0 + nj * S)) continue;
      seen.add(key(ni, nj));
      q.push([ni, nj]);
    }
  }
  return targets.map(([x, z]) => seen.has(key(Math.round((x - r.x0) / S), Math.round((z - r.z0) / S))));
}

describe('level layouts', () => {
  it('no two areas overlap, and every area is reachable through the door graph', () => {
    for (const a of AREA_ORDER) for (const b of AREA_ORDER) {
      if (a >= b) continue;
      const p = AREAS[a].rect;
      const q = AREAS[b].rect;
      expect(p.x1 <= q.x0 || p.x0 >= q.x1 || p.z1 <= q.z0 || p.z0 >= q.z1, `${a} overlaps ${b}`).toBe(true);
    }
    const seen = new Set<AreaId>(['chapterhouse']);
    for (let n = 0; n < AREA_ORDER.length; n++) for (const d of DOORS) if (seen.has(d.a) || seen.has(d.b)) { seen.add(d.a); seen.add(d.b); }
    // The Catacomb Depths are an instance: no door leads there, a run opens it (gameplay/depthsFloor.ts, depths-floor.test.ts).
    expect([...seen].sort()).toEqual(AREA_ORDER.filter((id) => !AREAS[id].instance).sort());
  });

  it('every unlock chain leads back to an open area and needs a real number of kills', () => {
    for (const id of AREA_ORDER) {
      let cur: AreaId = id;
      for (let n = 0; n < 12 && AREAS[cur].unlock; n++) {
        expect(AREAS[cur].unlock!.kills).toBeGreaterThan(0);
        cur = AREAS[cur].unlock!.area;
      }
      expect(AREAS[cur].unlock, `${id} unlock chain`).toBeUndefined();
    }
  });

  it('combat areas only spawn known mobs, with breaches inside the area and clear of props and walls', () => {
    for (const id of AREA_ORDER) {
      const a = AREAS[id];
      for (const e of a.enemies) expect(ENEMIES[e.id], `${id}: ${e.id}`).toBeDefined();
      for (const [x, z] of a.breaches) {
        expect(x > a.rect.x0 && x < a.rect.x1 && z > a.rect.z0 && z < a.rect.z1, `${id} breach ${x},${z}`).toBe(true);
      }
    }
  });

  it.each(['warren', 'coliseum', 'pyre', 'cloister'] as AreaId[])('%s: every spawn breach can be walked to from its waystone', (id) => {
    const a = AREAS[id];
    const way = a.interactables.find((i) => i.kind === 'waystone')!;
    // The waystone is a prop: stand just beside it. Every breach must be an open floor cell joined to that spot.
    const start: [number, number] = [way.x, way.z + 1.6];
    const ok = reach(id, start, a.breaches as [number, number][]);
    const bad = a.breaches.filter((_, i) => !ok[i]);
    expect(bad, `${id} unreachable`).toEqual([]);
  });

  it('the Warren\'s stair down to the Depths stands in a clear spot, reachable on foot from the waystone', () => {
    const stair = AREAS.warren.interactables.find((i) => i.kind === 'stair')!;
    expect(stair).toBeDefined();
    expect(stair.id).toBe('depths_stair');
    const way = AREAS.warren.interactables.find((i) => i.kind === 'waystone')!;
    // The player stands 1.4 m south of an interactable to use it.
    expect(reach('warren', [way.x, way.z + 1.6], [[stair.x, stair.z + 1.4]])[0]).toBe(true);
    // No Warren prop sits on or crowds the stair.
    for (const p of generateLayout().props) if (p.area === 'warren') expect(Math.hypot(p.x - stair.x, p.z - stair.z), `${p.prop} at ${p.x.toFixed(1)},${p.z.toFixed(1)}`).toBeGreaterThan(2.4);
  });

  it('the Warren has nine chambers whose gaps all connect (the vault is reachable from the door)', () => {
    const door = DOORS.find((d) => d.b === 'warren')!;
    const start: [number, number] = [-34, (door.rect.z0 + door.rect.z1) / 2];
    const vault: [number, number] = [-55.5, -30];
    expect(reach('warren', start, [vault])[0]).toBe(true);
    expect(CODEX_AREAS.warren.dangers.length).toBeGreaterThan(40);
  });
});
