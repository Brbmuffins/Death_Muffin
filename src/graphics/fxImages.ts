import * as THREE from 'three';

/**
 * Generated VFX sprites (ASSET_PIPELINE.md → art-manifest/gemini-jobs/spells-v4.json).
 * Each is white with brightness as alpha, so effects tint it per spell exactly like
 * the procedural sprites in fxTextures. Loaded once and cached for the app lifetime;
 * until an image arrives the texture draws nothing (additive black), never a fallback box.
 */
export const FX_IMAGES = {
  skull: 'art/fx/skull.png',
  boneShard: 'art/fx/bone-shard.png',
  bloodSigil: 'art/fx/blood-sigil.png',
  frostFan: 'art/fx/frost-fan.png',
  rime: 'art/fx/rime.png',
  boneRing: 'art/fx/bone-ring.png',
} as const;
export type FxImage = keyof typeof FX_IMAGES;

const cache = new Map<FxImage, THREE.Texture>();
let loader: THREE.TextureLoader | null = null;

export function fxImage(name: FxImage): THREE.Texture {
  let tex = cache.get(name);
  if (tex) return tex;
  loader ??= new THREE.TextureLoader();
  tex = loader.load(FX_IMAGES[name]);
  tex.colorSpace = THREE.SRGBColorSpace;
  cache.set(name, tex);
  return tex;
}

/** Warm every sprite at scene start so the first cast doesn't wait on the network. */
export function preloadFxImages() {
  for (const name of Object.keys(FX_IMAGES) as FxImage[]) fxImage(name);
}
