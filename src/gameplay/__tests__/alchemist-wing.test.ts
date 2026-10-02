import { describe, expect, it } from 'vitest';
import { AREAS, AREA_ORDER, DOORS, WING_APOTHECARY_SPOT, isAlwaysOpen } from '../../content/areas';
import { PROPS, WING_PROPS, generateLayout } from '../../content/layout';
import { SHELF_IDS, bonusAvailable, brewOfTheDay, claimBonus, loadFound, recordFound } from '../../content/wing';
import { REAGENT_BREW_LIST } from '../../content/reagents';
import { itemMeta } from '../../content/items';

const layout = generateLayout();
const wing = AREAS.alchemist_wing;
const store = () => {
  const m = new Map<string, string>();
  return { getItem: (k: string) => m.get(k) ?? null, setItem: (k: string, v: string) => void m.set(k, v) };
};

describe("the Alchemist's Wing", () => {
  it('is a safe, always-open room reached from the Chapterhouse', () => {
    expect(wing.safe).toBe(true);
    expect(wing.enemies).toEqual([]);
    expect(wing.cap).toBe(0);
    expect(isAlwaysOpen('alchemist_wing')).toBe(true);
    expect(AREA_ORDER).toContain('alchemist_wing');
    expect(DOORS.find((d) => d.id === 'chapter_wing')).toMatchObject({ a: 'chapterhouse', b: 'alchemist_wing', axis: 'x' });
  });

  it('overlaps no other area', () => {
    for (const id of AREA_ORDER) {
      if (id === 'alchemist_wing') continue;
      const r = AREAS[id].rect;
      expect(r.x1 <= wing.rect.x0 || r.x0 >= wing.rect.x1 || r.z1 <= wing.rect.z0 || r.z0 >= wing.rect.z1, id).toBe(true);
    }
  });

  it('dresses the room densely with all twelve alch_ props, inside the walls, clear of the door and each other', () => {
    expect(new Set(WING_PROPS.map((p) => p.prop).filter((id) => id.startsWith('alch_'))).size).toBe(12);
    expect(WING_PROPS.length).toBeGreaterThanOrEqual(60);
    const door = DOORS.find((d) => d.id === 'chapter_wing')!.rect;
    const solid = layout.props.filter((p) => p.area === 'alchemist_wing' && PROPS[p.prop].collider && !p.y);
    for (const p of layout.props.filter((q) => q.area === 'alchemist_wing')) {
      expect(p.x).toBeGreaterThan(wing.rect.x0 + 0.5);
      expect(p.x).toBeLessThan(wing.rect.x1 - 0.5);
      expect(p.z).toBeGreaterThan(wing.rect.z0);
      expect(p.z).toBeLessThan(wing.rect.z1 - 0.5);
      // Nothing solid stands in the doorway lane.
      if (PROPS[p.prop].collider && !p.y) expect(p.x > door.x1 + 1 || p.z < door.z0 - 0.5 || p.z > door.z1 + 0.5, p.prop).toBe(true);
    }
    for (const a of solid) for (const b of solid) if (a !== b) expect(Math.hypot(a.x - b.x, a.z - b.z), `${a.prop}/${b.prop}`).toBeGreaterThan(0.6);
  });

  it('keeps a walkable ring around every station (no solid prop within 1.1 of its click point, except the thing it is)', () => {
    for (const it of wing.interactables) {
      if (it.id.startsWith('npc_')) continue;
      for (const p of layout.props.filter((q) => q.area === 'alchemist_wing' && PROPS[q.prop].collider && !q.y)) {
        if (/cauldron|alembic|reagent_shelf/.test(p.prop)) continue;
        expect(Math.hypot(p.x - it.x, p.z - it.z), `${p.prop} near ${it.id}`).toBeGreaterThan(1.6);
      }
    }
    // The Apothecary's standing spot is open floor.
    const npc = wing.interactables.find((i) => i.id.startsWith('npc_apothecary'))!;
    for (const p of layout.props.filter((q) => q.area === 'alchemist_wing' && PROPS[q.prop].collider && !q.y && !/counter/.test(q.prop))) {
      expect(Math.hypot(p.x - npc.x, p.z - npc.z), p.prop).toBeGreaterThan(1.4);
    }
  });

  it('keeps every station reachable and the Apothecary anchor inside the room', () => {
    for (const it of wing.interactables) {
      const near = layout.props.some((p) => p.area === 'alchemist_wing' && Math.hypot(p.x - it.x, p.z - it.z) < 2.6);
      expect(near, it.id).toBe(true);
    }
    expect(WING_APOTHECARY_SPOT.x).toBeGreaterThan(wing.rect.x0);
    expect(WING_APOTHECARY_SPOT.x).toBeLessThan(wing.rect.x1);
  });

  it('does not move any other area\'s dressing (the Wing draws no random numbers)', () => {
    const others = layout.props.filter((p) => p.area !== 'alchemist_wing');
    expect(others.length).toBeGreaterThan(100);
  });
});

describe('reagent shelf and brew of the day', () => {
  it('lists only real items', () => {
    for (const id of SHELF_IDS) expect(itemMeta(id).name, id).not.toBe(id.replace(/_/g, ' '));
  });
  it('records found reagents once and ignores other items', () => {
    const s = store();
    expect(recordFound(s, 1, ['reagent_grave_dust', 'sword_x']).grew).toBe(true);
    expect(recordFound(s, 1, ['reagent_grave_dust']).grew).toBe(false);
    expect([...loadFound(s, 1)]).toEqual(['reagent_grave_dust']);
    expect(loadFound(s, 2).size).toBe(0);
  });
  it('picks a stable reachable brew per day', () => {
    const a = brewOfTheDay('2026-10-02');
    expect(brewOfTheDay('2026-10-02')).toEqual(a);
    const entry = REAGENT_BREW_LIST.find(([id]) => id === a.brewId)!;
    expect(entry[1].recipe.id).toBe(a.recipeId);
    expect(entry[1].recipe.level).toBeLessThanOrEqual(62);
    const picks = new Set(Array.from({ length: 40 }, (_, i) => brewOfTheDay(`2026-11-${String(i + 1).padStart(2, '0')}`).brewId));
    expect(picks.size).toBeGreaterThan(2);
  });
  it('gives the daily bonus once a day', () => {
    const s = store();
    expect(bonusAvailable(s, 1, '2026-10-02')).toBe(true);
    claimBonus(s, 1, '2026-10-02');
    expect(bonusAvailable(s, 1, '2026-10-02')).toBe(false);
    expect(bonusAvailable(s, 1, '2026-10-03')).toBe(true);
  });
});
