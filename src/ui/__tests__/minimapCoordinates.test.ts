import { describe, expect, it } from 'vitest';
import { minimapWalkable, minimapWorldPoint, MINIMAP_SCALE } from '../minimapCoordinates';
import type { AreaId } from '../../../server/rules/content/areas';

describe('minimap click destinations', () => {
  it('maps the displayed player centre and north/east ground through CSS scaling', () => {
    for (const factor of [0.6, 1, 1.25, 2]) {
      const rect = { left: 123, top: 48, width: 190 * factor, height: 190 * factor };
      const centerX = rect.left + rect.width / 2;
      const centerY = rect.top + rect.height / 2;
      expect(minimapWorldPoint(centerX, centerY, rect, 7, 24)).toEqual({ x: 7, z: 24 });
      const point = minimapWorldPoint(centerX + 8 * MINIMAP_SCALE * factor, centerY - 12 * MINIMAP_SCALE * factor, rect, 7, 24)!;
      expect(point.x).toBeCloseTo(15);
      expect(point.z).toBeCloseTo(12);
    }
  });

  it('rejects clipped corners, points beyond the map and unavailable canvas dimensions', () => {
    const rect = { left: 20, top: 30, width: 190, height: 190 };
    expect(minimapWorldPoint(20, 30, rect, 0, 24)).toBeNull();
    expect(minimapWorldPoint(211, 125, rect, 0, 24)).toBeNull();
    expect(minimapWorldPoint(115, 125, { ...rect, width: 0 }, 0, 24)).toBeNull();
    expect(minimapWorldPoint(NaN, 125, rect, 0, 24)).toBeNull();
  });

  it('allows unlocked floors and corridors while rejecting blank and sealed ground', () => {
    const unlocked = (id: AreaId) => id === 'chapterhouse' || id === 'graves';
    expect(minimapWalkable(0, 24, unlocked)).toBe(true);
    expect(minimapWalkable(0, 6, unlocked)).toBe(true);
    expect(minimapWalkable(20, -10, unlocked)).toBe(true);
    expect(minimapWalkable(30, 20, unlocked)).toBe(false);
    expect(minimapWalkable(40, -20, unlocked)).toBe(false);
    expect(minimapWalkable(29, -18, unlocked)).toBe(false);
    expect(minimapWalkable(29, -18, () => true)).toBe(true);
  });
});
