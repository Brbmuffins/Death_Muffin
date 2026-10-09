import * as THREE from 'three';
import { describe, expect, it, vi } from 'vitest';

// CameraRig reads the window size and settings when built.
vi.stubGlobal('window', { innerWidth: 1600, innerHeight: 900 });
import { AREAS } from '../../../server/rules/content/areas';
import { visibleAreas } from '../areaStreaming';
import { CameraRig } from '../CameraRig';
import { footprintPoints, footprintReach, footprintRect, rectsOverlap, shadowHalfExtent } from '../viewFootprint';

/** The game's own camera at (x, z), `zoom`, for a window of `aspect`. */
function gameCamera(x: number, z: number, zoom: number, aspect: number) {
  const rig = new CameraRig();
  rig.camera.aspect = aspect;
  rig.camera.updateProjectionMatrix();
  rig.setZoom(zoom);
  rig.snap(x, z);
  rig.camera.updateMatrixWorld();
  return rig.camera;
}

/** The moon exactly as WorldScene sets it up. */
function moonView(x: number, z: number) {
  const m = new THREE.OrthographicCamera(-30, 30, 30, -30, 1, 90);
  m.position.set(x - 14, 30, z + 12);
  m.lookAt(x, 0, z);
  m.updateMatrixWorld();
  return m.matrixWorldInverse;
}

describe('camera ground footprint', () => {
  it('surrounds the hero and grows with zoom and window width', () => {
    const reach = (zoom: number, aspect: number) => footprintReach(gameCamera(0, 0, zoom, aspect), 0, 0);
    expect(reach(1, 16 / 9)).toBeGreaterThan(15);
    expect(reach(1.45, 16 / 9)).toBeGreaterThan(reach(1, 16 / 9));
    expect(reach(1, 21 / 9)).toBeGreaterThan(reach(1, 16 / 9));
    const r = footprintRect(gameCamera(10, -20, 1, 16 / 9), 0);
    expect(r.x0).toBeLessThan(10);
    expect(r.x1).toBeGreaterThan(10);
    expect(r.z0).toBeLessThan(-20);
    expect(r.z1).toBeGreaterThan(-20);
  });

  it('a ray that never reaches the ground ends far away instead of producing NaN', () => {
    const cam = new THREE.PerspectiveCamera(40, 1.6, 0.5, 260);
    cam.position.set(0, 5, 0);
    cam.lookAt(0, 30, -50); // looking up
    cam.updateMatrixWorld();
    for (const p of footprintPoints(cam)) {
      expect(Number.isFinite(p.x) && Number.isFinite(p.z)).toBe(true);
    }
  });

  it('sees areas the 45 m radius missed (ultrawide window, widest zoom): every footprint point has its area drawn', () => {
    // Hero at the Coliseum's west edge looking at the widest zoom on a 21:9 window: the far corner is past 45 m.
    const cam = gameCamera(AREAS.coliseum.rect.x0 + 2, -28, 1.6, 21 / 9);
    const view = footprintRect(cam);
    expect(footprintReach(cam, AREAS.coliseum.rect.x0 + 2, -28)).toBeGreaterThan(45);
    const withView = visibleAreas(AREAS.coliseum.rect.x0 + 2, -28, 'coliseum', undefined, view);
    const radiusOnly = visibleAreas(AREAS.coliseum.rect.x0 + 2, -28, 'coliseum');
    for (const id of radiusOnly) expect(withView.has(id)).toBe(true); // never draws less than before
    for (const [id, a] of Object.entries(AREAS)) {
      if (rectsOverlap(a.rect, view)) expect(withView.has(id as keyof typeof AREAS)).toBe(true);
    }
    expect(withView.size).toBeGreaterThanOrEqual(radiusOnly.size);
  });

  it('keeps the moon box at exactly 30 m for the default view and grows it (capped) for the wide ones', () => {
    const half = (zoom: number, aspect: number) => shadowHalfExtent(gameCamera(0, 0, zoom, aspect), moonView(0, 0));
    expect(half(1, 16 / 9)).toBe(30);
    expect(half(0.7, 16 / 9)).toBe(30);
    expect(half(1.45, 16 / 9)).toBeGreaterThan(30);
    expect(half(1.45, 16 / 9) % 4).toBe(0);
    expect(half(1.6, 32 / 9)).toBe(48);
  });
});
