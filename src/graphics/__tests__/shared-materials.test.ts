import { describe, expect, it } from 'vitest';
import * as THREE from 'three';
import { skinBounds } from '../AssetCache';
import { applyFlash, FLASH_LEVELS, MaterialVariant, variantFor } from '../creatureMaterials';

function skinned() {
  const geo = new THREE.BoxGeometry(1, 2, 1, 3, 4, 3);
  const n = geo.getAttribute('position').count;
  const idx = new Uint16Array(n * 4);
  const wgt = new Float32Array(n * 4);
  for (let i = 0; i < n; i++) {
    idx[i * 4] = i % 2;
    wgt[i * 4] = 0.6;
    idx[i * 4 + 1] = (i + 1) % 2;
    wgt[i * 4 + 1] = 0.4;
  }
  geo.setAttribute('skinIndex', new THREE.Uint16BufferAttribute(idx, 4));
  geo.setAttribute('skinWeight', new THREE.Float32BufferAttribute(wgt, 4));
  const root = new THREE.Bone();
  const arm = new THREE.Bone();
  arm.position.set(0.5, 1, 0);
  arm.rotation.z = 0.6;
  root.add(arm);
  const mesh = new THREE.SkinnedMesh(geo, new THREE.MeshStandardMaterial());
  mesh.add(root);
  mesh.bind(new THREE.Skeleton([root, arm]));
  mesh.updateMatrixWorld(true);
  return mesh;
}

describe('skinBounds', () => {
  it('matches three computeBoundingBox / computeBoundingSphere (sphere padded 1.6x)', async () => {
    const a = skinned();
    a.computeBoundingBox();
    a.computeBoundingSphere();
    const b = skinned();
    await skinBounds(b);
    expect(b.boundingBox!.min.toArray()).toEqual(a.boundingBox!.min.toArray());
    expect(b.boundingBox!.max.toArray()).toEqual(a.boundingBox!.max.toArray());
    expect(b.boundingSphere!.center.toArray()).toEqual(a.boundingSphere!.center.toArray());
    expect(b.boundingSphere!.radius).toBeCloseTo(a.boundingSphere!.radius * 1.6, 6);
  });
});

describe('MaterialVariant', () => {
  const build = (src: THREE.Material) => (src as THREE.MeshStandardMaterial).clone();
  const src = new THREE.MeshStandardMaterial({ color: 0x884422 });
  const color = new THREE.Color(0xfff0dc);

  it('hands every body the same material for a source', () => {
    const v = new MaterialVariant(build);
    expect(v.get(src)).toBe(v.get(src));
    expect(v.get(src)).not.toBe(src);
  });

  it('flash copies are shared per level and pulse like the per-body path did', () => {
    const v = new MaterialVariant(build);
    v.get(src);
    const f = v.flash(src, 4, color);
    expect(v.flash(src, 4, color)).toBe(f);
    expect(v.flash(src, 5, color)).not.toBe(f);
    const want = new THREE.MeshStandardMaterial();
    applyFlash(want, v.emissive, v.intensity, 4 / FLASH_LEVELS, color);
    expect(f.emissive.getHex()).toBe(want.emissive.getHex());
    expect(f.emissiveIntensity).toBeCloseTo(want.emissiveIntensity, 6);
  });

  it('fade materials are pooled, not rebuilt', () => {
    const v = new MaterialVariant(build);
    const a = v.takeFade(src);
    const b = v.takeFade(src);
    expect(a).not.toBe(b);
    v.giveFade(src, a);
    expect(v.takeFade(src)).toBe(a);
  });

  it('looks are per template and key', () => {
    const t = {};
    let built = 0;
    const mk = () => variantFor(t, 'a', (s) => (built++, build(s)));
    expect(mk()).toBe(mk());
    expect(variantFor(t, 'b', build)).not.toBe(mk());
    expect(variantFor({}, 'a', build)).not.toBe(mk());
  });
});
