import { perfNote } from '../net/perfBeacon';
import * as THREE from 'three';
import { GLTFLoader } from 'three/examples/jsm/loaders/GLTFLoader.js';

export interface ModelTemplate {
  scene: THREE.Group;
  clips: Map<string, THREE.AnimationClip>;
  /** Scale that brings the model to its requested height. */
  scale: number;
  /** Y offset (after scaling) that puts the lowest point on the ground. */
  groundOffset: number;
  skinned: boolean;
}

/**
 * Central GLB / texture cache (the audit found no shared cache: every scene
 * reloaded everything). Templates load once; callers clone them.
 */
class AssetCache {
  private loader = new GLTFLoader();
  private models = new Map<string, Promise<ModelTemplate | null>>();
  private textures = new Map<string, THREE.Texture>();
  private texLoader = new THREE.TextureLoader();

  model(url: string, targetHeight: number): Promise<ModelTemplate | null> {
    const key = `${url}@${targetHeight}`;
    let p = this.models.get(key);
    if (!p) {
      perfNote(`model ${url.split('/').pop()}`);
      p = this.loader
        .loadAsync(url)
        .then((gltf) => {
          const scene = gltf.scene;
          scene.updateMatrixWorld(true);
          const bounds = new THREE.Box3().setFromObject(scene);
          const height = Math.max(1e-3, bounds.max.y - bounds.min.y);
          const scale = targetHeight / height;
          let skinned = false;
          scene.traverse((o) => {
            const m = o as THREE.Mesh;
            if (m.isMesh) {
              m.castShadow = true;
              m.receiveShadow = true;
              if ((o as THREE.SkinnedMesh).isSkinnedMesh) {
                skinned = true;
                // Bind-pose bounds padded for animated limbs; clones copy the sphere,
                // so off-screen enemies and corpses are culled from colour + shadow passes.
                const sm = o as THREE.SkinnedMesh;
                sm.computeBoundingSphere();
                sm.boundingSphere!.radius *= 1.6;
              }
            }
          });
          const clips = new Map(gltf.animations.map((c) => [c.name, c]));
          return { scene, clips, scale, groundOffset: -bounds.min.y * scale, skinned };
        })
        .catch((err) => {
          console.warn('[assets] model failed', url, err);
          return null;
        });
      this.models.set(key, p);
    }
    return p;
  }

  texture(url: string, opts: { repeat?: number; srgb?: boolean } = {}): THREE.Texture {
    const key = `${url}|${opts.repeat ?? 1}|${opts.srgb ?? true}`;
    let tex = this.textures.get(key);
    if (!tex) {
      tex = this.texLoader.load(url);
      tex.colorSpace = opts.srgb === false ? THREE.NoColorSpace : THREE.SRGBColorSpace;
      if (opts.repeat) {
        tex.wrapS = tex.wrapT = THREE.RepeatWrapping;
        tex.repeat.set(opts.repeat, opts.repeat);
      }
      tex.anisotropy = 8;
      this.textures.set(key, tex);
    }
    return tex;
  }

  /** Probe whether an optional asset exists (HEAD) without logging 404s as errors. */
  async exists(url: string): Promise<boolean> {
    try {
      const res = await fetch(url, { method: 'HEAD' });
      return res.ok && !(res.headers.get('content-type') ?? '').includes('text/html');
    } catch {
      return false;
    }
  }
}

export const assets = new AssetCache();
