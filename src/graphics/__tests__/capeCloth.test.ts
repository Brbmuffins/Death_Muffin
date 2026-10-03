import { describe, expect, it, vi } from 'vitest';
import * as THREE from 'three';
import { CREATURE_MODELS } from '../modelPaths';
import { creatureTemplate } from './propHarness';

const store = vi.hoisted(() => ({ models: new Map<string, unknown>() }));
vi.mock('../AssetCache', () => ({ assets: { model: async (url: string) => store.models.get(url) } }));
vi.mock('../fxTextures', async () => {
  const T = await import('three');
  return { fx: new Proxy({}, { get: () => () => new T.Texture() }) };
});

const { NecromancerAvatar } = await import('../Avatars');
const { CapeCloth } = await import('../capeCloth');
const { buildCape } = await import('../gearProps');

async function hero(slug: 'hero_ossuary' | 'hero_rotweaver') {
  const tpl = await creatureTemplate(slug, CREATURE_MODELS[slug].height);
  tpl.skinned = true;
  store.models.set(CREATURE_MODELS[slug].url, tpl);
  store.models.set(CREATURE_MODELS.necromancer.url, await creatureTemplate('necromancer', CREATURE_MODELS.necromancer.height));
  const avatar = new NecromancerAvatar(new THREE.Scene(), '#a26bff', false, slug);
  await vi.waitFor(() => expect(avatar.c.loaded).toBe(true));
  return avatar;
}

describe('cape cloth step', () => {
  it('stays cheap and allocates nothing per frame', async () => {
    const avatar = await hero('hero_ossuary');
    avatar.setCape('cape_apprentice');
    const cape = (avatar as unknown as { cape: { obj: THREE.Object3D } }).cape.obj;
    const cloth = CapeCloth.create(cape, avatar.c.root)!;
    expect(cloth).not.toBeNull();
    let x = 0;
    const frame = () => {
      x += 0.09;
      avatar.c.update(1 / 60);
      avatar.c.root.position.x = x;
      avatar.c.root.updateMatrixWorld(true);
      cloth.step(1 / 60, x, true);
    };
    for (let i = 0; i < 300; i++) frame(); // warm up the JIT and the clip
    const t0 = performance.now();
    const N = 2000;
    for (let i = 0; i < N; i++) { avatar.c.root.position.x += 0.09; cloth.step(1 / 60, i * 0.03, true); }
    const ms = (performance.now() - t0) / N;
    console.info(`cape step: ${(ms * 1000).toFixed(1)} us per cape`);
    // Budget on a mid CPU is 0.05 ms; this bound is loose so a loaded CI box does not flake.
    expect(ms).toBeLessThan(0.25);
    // No per-frame allocation: heap growth over many steps stays far below one object per step.
    const gc = (globalThis as { gc?: () => void }).gc;
    gc?.();
    const before = process.memoryUsage().heapUsed;
    for (let i = 0; i < 20000; i++) cloth.step(1 / 60, i * 0.03, true);
    const grew = process.memoryUsage().heapUsed - before;
    expect(grew).toBeLessThan(2_000_000);
    avatar.dispose();
  }, 60_000);

  it('keeps the rest footprint, and returns to it for the baked sway', async () => {
    const avatar = await hero('hero_rotweaver');
    avatar.setCape('cape_apprentice');
    const cape = (avatar as unknown as { cape: { obj: THREE.Object3D } }).cape.obj;
    const body = cape.userData.cloth.body as THREE.Mesh;
    const rest = Float32Array.from(body.geometry.getAttribute('position').array as Float32Array);
    const cloth = CapeCloth.create(cape, avatar.c.root)!;
    for (let i = 0; i < 120; i++) { avatar.c.update(1 / 60); avatar.c.root.updateMatrixWorld(true); cloth.step(1 / 60, 0, false); }
    const pos = body.geometry.getAttribute('position').array as Float32Array;
    // Standing still, the cloth hangs where the old rigid cape did, within a few centimetres.
    let worst = 0;
    for (let i = 0; i < rest.length; i++) worst = Math.max(worst, Math.abs(pos[i] - rest[i]));
    expect(worst).toBeLessThan(0.1);
    cloth.rest();
    expect(Array.from(pos)).toEqual(Array.from(rest));
    avatar.dispose();
  }, 60_000);

  it('buildCape names its cloth meshes', () => {
    const c = buildCape(0x884422, 0xddcc88);
    expect(c.userData.cloth.body).toBeDefined();
    expect(c.children[0].children[1]).toBe(c.userData.cloth.hem);
  });
});
