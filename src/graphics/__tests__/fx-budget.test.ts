import * as THREE from 'three';
import { describe, expect, it, vi } from 'vitest';
import { settings } from '../../app/settings';
import { Effects } from '../Effects';
import { BeamLayer, SpriteLayer, footprintGeometry } from '../fxLayers';

vi.mock('../fxTextures', () => ({
  fx: Object.fromEntries(['glow', 'smoke', 'disc', 'ring', 'cracks', 'sigil'].map((name) => [name, (() => {
    const t = new THREE.Texture();
    t.name = name;
    return t;
  })()]).map(([k, t]) => [k, () => t])),
}));
vi.mock('../fxImages', () => ({ fxImage: () => new THREE.Texture() }));

const drawn = (e: Effects) => {
  let n = 0;
  e.group.traverse((o) => {
    if (o !== e.group && (o as THREE.Mesh).isMesh && o.visible && ((o as THREE.InstancedMesh).isInstancedMesh ? (o as THREE.InstancedMesh).count > 0 : true)) n++;
  });
  return n;
};

describe('instanced flashes, orbits and beams', () => {
  it('draws every live flash of one texture in one call', () => {
    const e = new Effects(new THREE.Scene());
    for (let i = 0; i < 40; i++) e.flash({ x: i, y: 1, z: 0, color: 0xffffff, size: 1, duration: 0.5 });
    e.update(0.05, new THREE.PerspectiveCamera(), 700);
    expect(drawn(e)).toBe(1);
    const layer = [...(e as unknown as { spriteLayers: Map<string, SpriteLayer> }).spriteLayers.values()][0];
    expect(layer.mesh.count).toBe(40);
  });

  it('draws every live beam in one call and tracks both ends', () => {
    const e = new Effects(new THREE.Scene());
    for (let i = 0; i < 30; i++) e.beam({ x: 0, y: 1, z: 0 }, () => ({ x: i + 1, y: 1, z: 0 }), 0x88ffcc, 0.05, 0.4);
    e.update(0.05, new THREE.PerspectiveCamera(), 700);
    expect(drawn(e)).toBe(1);
    const layer = (e as unknown as { beamLayer: BeamLayer }).beamLayer;
    expect(layer.mesh.count).toBe(30);
    // The tube is centred between the ends and as long as the gap: a beam from x=0 to x=4 sits at 2, 4 long.
    const m = new THREE.Matrix4();
    layer.mesh.getMatrixAt(3, m);
    const p = new THREE.Vector3();
    const q = new THREE.Quaternion();
    const s = new THREE.Vector3();
    m.decompose(p, q, s);
    expect(p.x).toBeCloseTo(2);
    expect(s.z).toBeCloseTo(4);
    // +Z of the tube points along the beam (toward +x).
    const dir = new THREE.Vector3(0, 0, 1).applyQuaternion(q);
    expect(dir.x).toBeCloseTo(1);
  });

  it('orients a beam exactly like Object3D.lookAt did', () => {
    const e = new Effects(new THREE.Scene());
    const from = { x: 1, y: 0.3, z: -2 };
    const to = { x: 4, y: 1.7, z: 3 };
    e.beam(from, () => to, 0xffffff, 0.1, 1);
    e.update(0.01, new THREE.PerspectiveCamera(), 700);
    const layer = (e as unknown as { beamLayer: BeamLayer }).beamLayer;
    const ref = new THREE.Object3D();
    ref.position.set((from.x + to.x) / 2, (from.y + to.y) / 2, (from.z + to.z) / 2);
    ref.lookAt(to.x, to.y, to.z);
    const m = new THREE.Matrix4();
    layer.mesh.getMatrixAt(0, m);
    const q = new THREE.Quaternion().setFromRotationMatrix(m.clone().scale(new THREE.Vector3(1, 1, 1)));
    const p = new THREE.Vector3();
    const q2 = new THREE.Quaternion();
    m.decompose(p, q2, new THREE.Vector3());
    expect(Math.abs(q2.dot(ref.quaternion))).toBeCloseTo(1, 4);
    expect(q).toBeTruthy();
  });

  it('frees an instance when its effect ends, frees an idle one-off texture layer, and keeps the glow and beam layers', () => {
    const e = new Effects(new THREE.Scene());
    const cam = new THREE.PerspectiveCamera();
    const odd = new THREE.Texture();
    e.flash({ x: 0, y: 1, z: 0, color: 0xffffff, size: 1, duration: 0.2, tex: odd });
    e.update(0.1, cam, 700);
    const layers = (e as unknown as { spriteLayers: Map<string, SpriteLayer> }).spriteLayers;
    const layer = layers.get(odd.uuid)!;
    expect(layer.items.length).toBe(1);
    e.update(0.2, cam, 700);
    expect(layer.items.length).toBe(0);
    expect(e.transientLoad).toBe(0);
    for (let i = 0; i < 70; i++) e.update(0.1, cam, 700);
    expect(layers.has(odd.uuid)).toBe(false);
    // The glow sprites and the beams are in nearly every fight: their layers (and so their shader programs) stay.
    expect(layers.size).toBe(1);
    expect((e as unknown as { beamLayer: BeamLayer | null }).beamLayer).not.toBeNull();
  });

  it('grows a layer past its first capacity without losing instances', () => {
    const group = new THREE.Group();
    const layer = new SpriteLayer(group, new THREE.Texture(), 4);
    const items = Array.from({ length: 11 }, (_, i) => ({ x: i, y: 0, z: 0, size: 1, rot: 0, color: new THREE.Color(0xffffff), opacity: 1 }));
    for (const it of items) layer.add(it);
    layer.flush();
    expect(layer.mesh.count).toBe(11);
    expect(group.children.length).toBe(1);
    const m = new THREE.Matrix4();
    layer.mesh.getMatrixAt(10, m);
    expect(new THREE.Vector3().setFromMatrixPosition(m).x).toBe(10);
  });

  it('skips fully faded instances', () => {
    const group = new THREE.Group();
    const layer = new SpriteLayer(group, new THREE.Texture());
    layer.add({ x: 0, y: 0, z: 0, size: 1, rot: 0, color: new THREE.Color(), opacity: 0 });
    layer.add({ x: 1, y: 0, z: 0, size: 1, rot: 0, color: new THREE.Color(), opacity: 0.5 });
    layer.flush();
    expect(layer.mesh.count).toBe(1);
  });
});

describe('particle ring', () => {
  it('leaves nothing for the GPU once every particle has died (no stale sizes or alphas)', () => {
    const e = new Effects(new THREE.Scene());
    const cam = new THREE.PerspectiveCamera();
    e.emit({ x: 0, y: 1, z: 0, count: 200, color: 0xffffff, size: 0.6, life: 0.3 });
    e.emitSmoke({ x: 0, y: 1, z: 0, count: 50, color: 0x555555, size: 1.4, life: 0.3 });
    for (let i = 0; i < 40; i++) e.update(0.05, cam, 700);
    for (const key of ['additive', 'smoke'] as const) {
      const ps = (e as unknown as Record<string, { points: THREE.Points }>)[key];
      const g = ps.points.geometry;
      expect(Math.max(...(g.attributes.aAlpha.array as Float32Array))).toBe(0);
      expect(Math.max(...(g.attributes.aSize.array as Float32Array))).toBe(0);
      expect(ps.points.visible).toBe(false);
    }
  });
});

describe('radial footprint meshes', () => {
  /** Triangle list of a flat (xz) footprint as 2-D points: x and z. */
  const tris = (g: THREE.BufferGeometry) => {
    const p = g.attributes.position;
    const ix = g.index!;
    const out: number[][][] = [];
    for (let i = 0; i < ix.count; i += 3) out.push([0, 1, 2].map((k) => [p.getX(ix.getX(i + k)), p.getZ(ix.getX(i + k))]));
    return out;
  };
  const inside = (t: number[][], x: number, y: number) => {
    const s = (a: number[], b: number[]) => (x - b[0]) * (a[1] - b[1]) - (a[0] - b[0]) * (y - b[1]);
    const d1 = s(t[0], t[1]);
    const d2 = s(t[1], t[2]);
    const d3 = s(t[2], t[0]);
    return !((d1 < 0 || d2 < 0 || d3 < 0) && (d1 > 0 || d2 > 0 || d3 > 0));
  };
  const area = (g: THREE.BufferGeometry) => tris(g).reduce((a, t) => a + Math.abs((t[1][0] - t[0][0]) * (t[2][1] - t[0][1]) - (t[2][0] - t[0][0]) * (t[1][1] - t[0][1])) / 2, 0);

  it('covers every lit texel of a disc (the radius-0.5 circle) with about a fifth less area than the square', () => {
    const g = footprintGeometry('disc', 'xz');
    const t = tris(g);
    for (let i = 0; i < 4000; i++) {
      const a = Math.random() * Math.PI * 2;
      const r = Math.sqrt(Math.random()) * 0.5;
      const x = Math.cos(a) * r;
      const y = Math.sin(a) * r;
      expect(t.some((tr) => inside(tr, x, y))).toBe(true);
    }
    expect(area(g)).toBeLessThan(0.82);
    expect(area(g)).toBeGreaterThan(0.78);
  });

  it('covers the whole ring band (0.36 to 0.5) and leaves its hole undrawn', () => {
    const g = footprintGeometry('ring', 'xz');
    const t = tris(g);
    for (let i = 0; i < 4000; i++) {
      const a = Math.random() * Math.PI * 2;
      const r = 0.36 + Math.random() * 0.14;
      expect(t.some((tr) => inside(tr, Math.cos(a) * r, Math.sin(a) * r))).toBe(true);
    }
    expect(t.some((tr) => inside(tr, 0, 0))).toBe(false);
    expect(area(g)).toBeLessThan(0.45);
  });

  it('maps UVs like the plane it replaces (flat decals: z up the texture reversed)', () => {
    const plane = new THREE.PlaneGeometry(1, 1).rotateX(-Math.PI / 2);
    const g = footprintGeometry('disc', 'xz');
    const uvOf = (geo: THREE.BufferGeometry, x: number, z: number) => {
      // Barycentric interpolation of the triangle containing (x, z).
      const p = geo.attributes.position;
      const uv = geo.attributes.uv;
      const ix = geo.index!;
      for (let i = 0; i < ix.count; i += 3) {
        const v = [0, 1, 2].map((k) => ix.getX(i + k));
        const [a, b, c] = v.map((j) => [p.getX(j), p.getZ(j), uv.getX(j), uv.getY(j)]);
        const det = (b[1] - c[1]) * (a[0] - c[0]) + (c[0] - b[0]) * (a[1] - c[1]);
        const l1 = ((b[1] - c[1]) * (x - c[0]) + (c[0] - b[0]) * (z - c[1])) / det;
        const l2 = ((c[1] - a[1]) * (x - c[0]) + (a[0] - c[0]) * (z - c[1])) / det;
        const l3 = 1 - l1 - l2;
        if (l1 >= -1e-9 && l2 >= -1e-9 && l3 >= -1e-9) return [l1 * a[2] + l2 * b[2] + l3 * c[2], l1 * a[3] + l2 * b[3] + l3 * c[3]];
      }
      return null;
    };
    for (const [x, z] of [[0.2, 0.1], [-0.3, 0.25], [0.1, -0.4]]) {
      const a = uvOf(plane, x, z)!;
      const b = uvOf(g, x, z)!;
      expect(b[0]).toBeCloseTo(a[0], 5);
      expect(b[1]).toBeCloseTo(a[1], 5);
    }
  });
});

describe('particle budget', () => {
  it('thins bursts by the partner scale and never to zero', () => {
    settings.quality = 'high';
    const e = new Effects(new THREE.Scene());
    e.emit({ x: 0, y: 0, z: 0, count: 100, color: 0xffffff });
    expect(e.emitted).toBe(100);
    e.particleScale = 0.5;
    e.emit({ x: 0, y: 0, z: 0, count: 100, color: 0xffffff });
    e.emitSmoke({ x: 0, y: 0, z: 0, count: 1, color: 0xffffff });
    expect(e.emitted).toBe(100 + 50 + 1);
    e.emit({ x: 0, y: 0, z: 0, count: 0, color: 0xffffff });
    expect(e.emitted).toBe(151);
  });

  it('keeps three quarters of every burst on Graphics: Low, and stacks with the partner scale', () => {
    settings.quality = 'low';
    const e = new Effects(new THREE.Scene());
    e.emit({ x: 0, y: 0, z: 0, count: 100, color: 0xffffff });
    expect(e.emitted).toBe(75);
    e.particleScale = 0.5;
    e.emit({ x: 0, y: 0, z: 0, count: 100, color: 0xffffff });
    expect(e.emitted).toBe(75 + 38);
    settings.quality = 'high';
  });
});
