import * as THREE from 'three';

/**
 * Generated VFX sprites (ASSET_PIPELINE.md → art-manifest/gemini-jobs/spells-v4.json).
 * Each is white with brightness as alpha, so effects tint it per spell exactly like
 * the procedural sprites in fxTextures. Loaded once and cached for the app lifetime;
 * until an image arrives the texture draws nothing (additive black), never a fallback box.
 */
export const FX_IMAGES = {
  skull: 'art/fx/skull.webp',
  boneShard: 'art/fx/bone-shard.webp',
  bloodSigil: 'art/fx/blood-sigil.webp',
  frostFan: 'art/fx/frost-fan.webp',
  rime: 'art/fx/rime.webp',
  boneRing: 'art/fx/bone-ring.webp',
  // Spell variety sprites (gemini-jobs/spells-v5.json).
  crescent: 'art/fx/crescent.webp',
  seedBud: 'art/fx/seed-bud.webp',
  wisp: 'art/fx/wisp.webp',
  rallySigil: 'art/fx/rally-sigil.webp',
  veilStreak: 'art/fx/veil-streak.webp',
  // Release 0.3 class sprites (art-manifest/gemini-jobs/classes-v1.json).
  graveOutline: 'art/fx/grave-outline.webp',
  crow: 'art/fx/crow.webp',
  hookChain: 'art/fx/hook-chain.webp',
  soundRing: 'art/fx/sound-ring.webp',
  lanternCone: 'art/fx/lantern-cone.webp',
  veilRift: 'art/fx/veil-rift.webp',
  // Area-boss telegraphs (gemini-jobs/bosses-v1.json).
  tideCrest: 'art/fx/tide-crest.webp',
  drownedHand: 'art/fx/drowned-hand.webp',
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
