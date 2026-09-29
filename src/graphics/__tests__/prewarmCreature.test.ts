import { afterEach, describe, expect, it, vi } from 'vitest';
import * as THREE from 'three';
import type { Creature } from '../Creature';
import { prewarmCreature } from '../prewarmCreature';

afterEach(() => vi.unstubAllGlobals());

describe('boss graphics prewarm', () => {
  it('uploads model textures one idle task at a time before compiling, and cancels on teardown', async () => {
    const callbacks = new Map<number, () => void>();
    let nextId = 0;
    vi.stubGlobal('window', {
      requestIdleCallback: (callback: () => void) => {
        callbacks.set(++nextId, callback);
        return nextId;
      },
      cancelIdleCallback: (id: number) => callbacks.delete(id),
    });
    const root = new THREE.Group();
    root.visible = false;
    const texture = new THREE.Texture();
    root.add(new THREE.Mesh(new THREE.BoxGeometry(), new THREE.MeshBasicMaterial({ map: texture })));
    const creature = { root, loaded: true, ready: Promise.resolve() } as Creature;
    const renderer = {
      initTexture: vi.fn(),
      compileAsync: vi.fn().mockResolvedValue(root),
    } as unknown as THREE.WebGLRenderer;
    const camera = new THREE.PerspectiveCamera();
    const scene = new THREE.Scene();
    const cancel = prewarmCreature(creature, renderer, camera, scene);
    await creature.ready;
    await Promise.resolve();
    expect(callbacks.size).toBe(1);
    callbacks.get(1)!();
    expect(renderer.initTexture).toHaveBeenCalledWith(texture);
    expect(renderer.compileAsync).not.toHaveBeenCalled();
    callbacks.get(2)!();
    expect(renderer.compileAsync).toHaveBeenCalledWith(root, camera, scene);
    cancel();
    root.children[0].traverse((object) => {
      const mesh = object as THREE.Mesh;
      mesh.geometry?.dispose();
      (mesh.material as THREE.Material)?.dispose();
    });
    texture.dispose();
  });

  it('does no GPU work after scene teardown', async () => {
    const callbacks = new Map<number, () => void>();
    vi.stubGlobal('window', {
      requestIdleCallback: (callback: () => void) => {
        callbacks.set(1, callback);
        return 1;
      },
      cancelIdleCallback: (id: number) => callbacks.delete(id),
    });
    const root = new THREE.Group();
    const creature = { root, loaded: true, ready: Promise.resolve() } as Creature;
    const renderer = { initTexture: vi.fn(), compileAsync: vi.fn() } as unknown as THREE.WebGLRenderer;
    const cancel = prewarmCreature(creature, renderer, new THREE.PerspectiveCamera(), new THREE.Scene());
    cancel();
    await creature.ready;
    await Promise.resolve();
    expect(callbacks.size).toBe(0);
    expect(renderer.compileAsync).not.toHaveBeenCalled();
  });
});
