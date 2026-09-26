import { describe, expect, it } from 'vitest';
import { AREAS, AREA_ORDER, DOORS } from '../../content/areas';
import { generateLayout, PROPS } from '../../content/layout';

const inside = (r: { x0: number; z0: number; x1: number; z1: number }, x: number, z: number, pad = 0) =>
  x >= r.x0 - pad && x <= r.x1 + pad && z >= r.z0 - pad && z <= r.z1 + pad;

const interactables = AREA_ORDER.flatMap((id) => AREAS[id].interactables);

describe('environment layout', () => {
  const layout = generateLayout();

  it('floods only the Drowned Nave', () => {
    const nave = AREAS.nave.rect;
    expect(layout.water.length).toBeGreaterThan(0);
    for (const w of layout.water) {
      expect(w.x0).toBeLessThan(w.x1);
      expect(w.z0).toBeLessThan(w.z1);
      expect(w.x0).toBeGreaterThanOrEqual(nave.x0);
      expect(w.x1).toBeLessThanOrEqual(nave.x1);
      expect(w.z0).toBeGreaterThanOrEqual(nave.z0);
      expect(w.z1).toBeLessThanOrEqual(nave.z1);
    }
  });

  it('covers most of the nave floor but leaves dry walkways', () => {
    const nave = AREAS.nave.rect;
    const area = (r: { x0: number; z0: number; x1: number; z1: number }) => (r.x1 - r.x0) * (r.z1 - r.z0);
    const wet = layout.water.reduce((s, w) => s + area(w), 0);
    expect(wet / area(nave)).toBeGreaterThan(0.5);
    expect(wet / area(nave)).toBeLessThan(0.9);
    // The pillar rows stand on raised walkways.
    for (const p of layout.props.filter((q) => q.area === 'nave' && (q.prop === 'pillar' || q.prop === 'candles'))) {
      expect(layout.water.some((w) => inside(w, p.x, p.z)), `${p.prop} at ${p.x},${p.z}`).toBe(false);
    }
  });

  it('never puts water or puddles over an interactable', () => {
    for (const i of interactables) {
      expect(layout.water.some((w) => inside(w, i.x, i.z, 1.5)), i.id).toBe(false);
      for (const p of layout.puddles) expect(Math.hypot(p.x - i.x, p.z - i.z), i.id).toBeGreaterThan(p.r * p.sx + 1.5);
    }
  });

  it('scatters puddles in the graveyard clear of props', () => {
    expect(layout.puddles.length).toBeGreaterThanOrEqual(6);
    for (const p of layout.puddles) {
      expect(p.area).toBe('graves');
      expect(inside(AREAS.graves.rect, p.x, p.z)).toBe(true);
      for (const q of layout.props) {
        if (!PROPS[q.prop].collider) continue;
        expect(Math.hypot(q.x - p.x, q.z - p.z)).toBeGreaterThan(p.r * p.sx);
      }
    }
  });

  it('keeps distant silhouettes outside every walkable space', () => {
    expect(layout.silhouettes.some((s) => s.kind === 'spire')).toBe(true);
    expect(layout.silhouettes.some((s) => s.kind === 'tree')).toBe(true);
    const rects = [...AREA_ORDER.map((id) => AREAS[id].rect), ...DOORS.map((d) => d.rect)];
    for (const s of layout.silhouettes) {
      for (const r of rects) expect(inside(r, s.x, s.z, 5), `${s.kind} at ${s.x},${s.z}`).toBe(false);
    }
  });

  it('is deterministic and leaves the original placements untouched', () => {
    const again = generateLayout();
    expect(again.water).toEqual(layout.water);
    expect(again.puddles).toEqual(layout.puddles);
    expect(again.silhouettes).toEqual(layout.silhouettes);
    expect(again.props).toEqual(layout.props);
  });
});

describe('surge crypts', () => {
  const layout = generateLayout();

  it('sit in front of a crypt prop, inside an unsafe area, off every collider', () => {
    expect(layout.crypts.length).toBeGreaterThanOrEqual(6);
    for (const c of layout.crypts) {
      expect(AREAS[c.area].safe).toBe(false);
      expect(inside(AREAS[c.area].rect, c.x, c.z, -0.5)).toBe(true);
      const src = layout.props.filter((p) => p.prop === c.prop && p.area === c.area);
      expect(Math.min(...src.map((p) => Math.hypot(p.x - c.x, p.z - c.z)))).toBeLessThan(4.5);
      for (const p of layout.props) {
        const col = PROPS[p.prop].collider;
        if (!col) continue;
        const r = col.kind === 'circle' ? col.r : Math.min(col.hw, col.hd);
        expect(Math.hypot(p.x - c.x, p.z - c.z), `${c.prop} crypt vs ${p.prop}`).toBeGreaterThan(r * p.scale);
      }
    }
    expect(new Set(layout.crypts.map((c) => c.area))).toEqual(new Set(['graves', 'ossuary', 'nave']));
  });
});
