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
  // Spell variety sprites (gemini-jobs/spells-v5.json).
  crescent: 'art/fx/crescent.png',
  seedBud: 'art/fx/seed-bud.png',
  wisp: 'art/fx/wisp.png',
  rallySigil: 'art/fx/rally-sigil.png',
  veilStreak: 'art/fx/veil-streak.png',
  // Release 0.3 class sprites (art-manifest/gemini-jobs/classes-v1.json).
  graveOutline: 'art/fx/grave-outline.png',
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
