import * as THREE from 'three';
import { describe, expect, it, vi } from 'vitest';
import { DECAL_ORDER, Effects, OTHER_DECAL_ALPHA } from '../Effects';
import { fx } from '../fxTextures';

vi.mock('../fxTextures', () => ({
  fx: Object.fromEntries(['glow', 'smoke', 'disc', 'ring', 'cracks', 'sigil'].map((name) => [name, (() => {
    const t = new THREE.Texture();
    t.name = name;
    return t;
  })()]).map(([k, t]) => [k, () => t])),
}));
vi.mock('../fxImages', () => ({ fxImage: () => new THREE.Texture() }));

interface Layer { items: { opacity: number; rim: number }[]; mesh: THREE.InstancedMesh }
const layers = (e: Effects) => [...(e as unknown as { decalLayers: Map<string, Layer> }).decalLayers.values()];
const step = (e: Effects, s: number) => {
  const cam = new THREE.PerspectiveCamera();
  for (let i = 0; i < Math.round(s * 30); i++) e.update(1 / 30, cam, 700);
};
const only = (e: Effects) => layers(e).flatMap((l) => l.items)[0];

describe('ground-effect clarity', () => {
  it('draws our own long area in full at the cast, then eases it to an outline', () => {
    const e = new Effects(new THREE.Scene());
    e.decal({ tex: fx.sigil(), color: 0x88ff88, x: 0, z: 0, r: 3, duration: 8, opacity: 0.8 });
    step(e, 0.5);
    expect(only(e).rim).toBe(0);
    step(e, 2.5);
    expect(only(e).rim).toBe(1);
    expect(only(e).opacity).toBeGreaterThan(0.5);
    const ring = layers(e).filter((l) => l.items.length > 0);
    expect(ring).toHaveLength(1);
  });

  it('leaves short decals, rings and scenery alone', () => {
    const e = new Effects(new THREE.Scene());
    e.decal({ tex: fx.disc(), color: 0xffffff, x: 0, z: 0, r: 2, duration: 1.2 });
    e.decal({ tex: fx.ring(), color: 0xffffff, x: 0, z: 0, r: 2, duration: 10 });
    e.decal({ tex: fx.glow(), color: 0xffffff, x: 0, z: 0, r: 2, duration: 1e9, persistent: true });
    step(e, 3);
    expect(layers(e).flatMap((l) => l.items).every((d) => d.rim === 0)).toBe(true);
  });

  it("draws another player's areas faint and outline-only, in their own hue", () => {
    const e = new Effects(new THREE.Scene());
    e.role = 'other';
    e.decal({ tex: fx.disc(), color: 0x3366ff, x: 0, z: 0, r: 3, duration: 5, opacity: 0.8, fadeIn: 0.01 });
    e.role = 'self';
    step(e, 0.3);
    const d = only(e);
    expect(d.rim).toBe(1);
    expect(d.opacity).toBeCloseTo(0.8 * OTHER_DECAL_ALPHA, 2);
  });

  it('sends an older own area to outline early when a newer one lands on it', () => {
    const e = new Effects(new THREE.Scene());
    e.decal({ tex: fx.sigil(), color: 0x88ff88, x: 0, z: 0, r: 3, duration: 8 });
    step(e, 0.2);
    e.decal({ tex: fx.sigil(), color: 0x88ff88, x: 0.5, z: 0, r: 3, duration: 8 });
    e.decal({ tex: fx.sigil(), color: 0x88ff88, x: 40, z: 0, r: 3, duration: 8 });
    step(e, 0.6);
    const items = layers(e).flatMap((l) => l.items);
    expect(items.map((d) => d.rim).sort()).toEqual([0, 0, 1]);
  });

  it('draws a disc outline with the ring texture, and a partner thrall ring faint', () => {
    const e = new Effects(new THREE.Scene());
    e.decal({ tex: fx.disc(), color: 0x88ff88, x: 0, z: 0, r: 3, duration: 8 });
    step(e, 2);
    const ringLayer = layers(e).find((l) => (l.mesh.material as THREE.MeshBasicMaterial).map === fx.ring())!;
    expect(ringLayer.items).toHaveLength(1);
    expect(ringLayer.items[0].opacity).toBeGreaterThan(0.5);
    e.decal({ tex: fx.ring(), color: 0xffffff, x: 9, z: 9, r: 1, duration: 1e9, other: true, opacity: 0.7, fadeIn: 0.01 });
    step(e, 0.2);
    expect(ringLayer.items[1].opacity).toBeCloseTo(0.7 * OTHER_DECAL_ALPHA, 2);
  });

  it('draws danger telegraphs in a layer above every friendly decal and never fades them', () => {
    const e = new Effects(new THREE.Scene());
    e.decal({ tex: fx.disc(), color: 0x88ff88, x: 0, z: 0, r: 3, duration: 8 });
    e.role = 'other';
    // A hostile ground marker made while a partner's event is being handled is still a full-strength danger marker.
    e.danger(() => e.decal({ tex: fx.disc(), color: 0xff4422, x: 0, z: 0, r: 3, duration: 8, opacity: 0.7, fadeIn: 0.01 }));
    e.role = 'self';
    e.decal({ tex: fx.glow(), blending: THREE.NormalBlending, color: 0x000000, x: 0, z: 0, r: 1, duration: 1e9, persistent: true, hero: true });
    step(e, 3);
    const orders = [...new Set(layers(e).map((l) => l.mesh.renderOrder))].sort();
    expect(orders).toEqual([DECAL_ORDER.friendly, DECAL_ORDER.hero, DECAL_ORDER.danger]);
    const dangerLayer = layers(e).find((l) => l.mesh.renderOrder === DECAL_ORDER.danger)!;
    expect(dangerLayer.items[0].rim).toBe(0);
    expect(dangerLayer.items[0].opacity).toBeGreaterThan(0.6);
    expect(DECAL_ORDER.danger).toBeGreaterThan(DECAL_ORDER.hero);
    expect(DECAL_ORDER.hero).toBeGreaterThan(DECAL_ORDER.friendly);
  });
});
