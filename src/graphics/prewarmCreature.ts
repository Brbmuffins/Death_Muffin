import * as THREE from 'three';
import type { Creature } from './Creature';

/** Move a boss's first shader compile and texture upload ahead of its summon. */
export function prewarmCreature(
  creature: Creature,
  renderer: THREE.WebGLRenderer,
  camera: THREE.Camera,
  scene: THREE.Scene,
): () => void {
  let cancelled = false;
  let idle = 0;
  let timer = 0;
  const schedule = (fn: () => void) => {
    if (typeof window.requestIdleCallback === 'function') {
      idle = window.requestIdleCallback(fn, { timeout: 3000 });
    } else timer = window.setTimeout(fn, 250);
  };
  void creature.ready.then(() => {
    if (cancelled || !creature.loaded || creature.root.visible) return;
    const textures = new Set<THREE.Texture>();
    creature.root.traverse((object) => {
      const material = (object as THREE.Mesh).material;
      if (!material) return;
      for (const m of Array.isArray(material) ? material : [material]) {
        for (const value of Object.values(m)) {
          if ((value as THREE.Texture)?.isTexture) textures.add(value as THREE.Texture);
        }
      }
    });
    const pending = [...textures];
    const next = () => {
      if (cancelled || creature.root.visible) return;
      const texture = pending.shift();
      if (texture) {
        try { renderer.initTexture(texture); }
        catch (error) {
          console.warn('[graphics] boss texture prewarm failed', error);
          return;
        }
        schedule(next);
      } else {
        void renderer.compileAsync(creature.root, camera, scene).catch((error: unknown) => {
          console.warn('[graphics] boss prewarm failed', error);
        });
      }
    };
    schedule(next);
  }).catch((error: unknown) => {
    console.warn('[graphics] boss model prewarm failed', error);
  });
  return () => {
    cancelled = true;
    if (idle) window.cancelIdleCallback(idle);
    if (timer) window.clearTimeout(timer);
  };
}
