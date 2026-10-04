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
  /** The parsed GLB this template scales: identical for every height asked of the same url (use it as the key for per-model caches). */
  base?: object;
}

/** What one parse of a url yields, before any height is applied. */
interface ParsedModel {
  scene: THREE.Group;
  clips: Map<string, THREE.AnimationClip>;
  height: number;
  minY: number;
  skinned: boolean;
}

const nextTurn = () => new Promise<void>((r) => setTimeout(r, 0));
const SLICE_MS = 4;

/**
 * SkinnedMesh.computeBoundingBox + computeBoundingSphere in one pass over the vertices (the same points in the same order, so the
 * results are identical), yielding to the event loop every few milliseconds so a big model never holds a frame. The sphere keeps
 * the 1.6x padding the animated limbs need.
 */
export async function skinBounds(sm: THREE.SkinnedMesh) {
  const position = sm.geometry.getAttribute('position');
  const box = new THREE.Box3();
  const sphere = new THREE.Sphere();
  box.makeEmpty();
  sphere.makeEmpty();
  const v = new THREE.Vector3();
  const slice = typeof document === 'undefined' || !document.hidden;
  let t0 = performance.now();
  for (let i = 0; i < position.count; i++) {
    sm.getVertexPosition(i, v);
    box.expandByPoint(v);
    sphere.expandByPoint(v);
    // Check the clock only every 256 vertices.
    if (slice && (i & 255) === 255 && performance.now() - t0 > SLICE_MS) {
      await nextTurn();
      t0 = performance.now();
    }
  }
  sm.boundingBox = box;
  sphere.radius *= 1.6;
  sm.boundingSphere = sphere;
}

/**
 * Central GLB / texture cache (the audit found no shared cache: every scene
 * reloaded everything). Templates load once; callers clone them.
 */
class AssetCache {
  private loader = new GLTFLoader();
  /** One parse per url (the file is fetched, decoded and bounded once); heights only choose a scale. */
  private parsed = new Map<string, Promise<ParsedModel | null>>();
  /** Memoised per url + height so callers asking twice get the same template object (warm caches key on it). */
  private models = new Map<string, Promise<ModelTemplate | null>>();
  private textures = new Map<string, THREE.Texture>();
  private texLoader = new THREE.TextureLoader();

  /** Fetch and parse `url` once, whatever size is asked for later. */
  private parse(url: string): Promise<ParsedModel | null> {
    let p = this.parsed.get(url);
    if (!p) {
      perfNote(`model ${url.split('/').slice(-2).join('/')}`);
      p = this.loader
        .loadAsync(url)
        .then(async (gltf) => {
          const scene = gltf.scene;
          scene.updateMatrixWorld(true);
          let skinned = false;
          const skins: THREE.SkinnedMesh[] = [];
          scene.traverse((o) => {
            const m = o as THREE.Mesh;
            if (m.isMesh) {
              m.castShadow = true;
              m.receiveShadow = true;
              if ((o as THREE.SkinnedMesh).isSkinnedMesh) {
                skinned = true;
                skins.push(o as THREE.SkinnedMesh);
              }
            }
          });
          // Bind-pose bounds (padded for animated limbs; clones copy them, so off-screen enemies and corpses are culled from
          // colour + shadow passes). three computes these with a skinning transform per vertex, twice, in one go: ~400 ms of
          // one task for a hero-sized model on a mid PC (the Ossuary entry long task). One pass, sliced across frames.
          for (const sm of skins) await skinBounds(sm);
          const bounds = new THREE.Box3().setFromObject(scene);
          const height = Math.max(1e-3, bounds.max.y - bounds.min.y);
          const clips = new Map(gltf.animations.map((c) => [c.name, c]));
          return { scene, clips, height, minY: bounds.min.y, skinned };
        })
        .catch((err) => {
          console.warn('[assets] model failed', url, err);
          return null;
        });
      this.parsed.set(url, p);
    }
    return p;
  }

  /** Is `url` already parsed (or being parsed)? Lets idle preloading skip what a fight already pulled in. */
  hasModel(url: string): boolean {
    return this.parsed.has(url);
  }

  /** Parse `url` without caring about a size (idle preloading). Resolves true when the model is usable. */
  preload(url: string): Promise<boolean> {
    return this.parse(url).then((m) => !!m);
  }

  model(url: string, targetHeight: number): Promise<ModelTemplate | null> {
    const key = `${url}@${targetHeight}`;
    let p = this.models.get(key);
    if (!p) {
      p = this.parse(url).then((m) => {
        if (!m) return null;
        const scale = targetHeight / m.height;
        return { scene: m.scene, clips: m.clips, scale, groundOffset: -m.minY * scale, skinned: m.skinned, base: m };
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
