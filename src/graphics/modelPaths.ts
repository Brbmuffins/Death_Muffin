/**
 * Model path registry. Assets are built by `node tools/build-models.mjs`
 * from raw Tripo outputs in art-src/tripo/ (gitignored) into
 * public/models/<slug>/ with stable names: rig.glb + one GLB per clip.
 */

export interface CharacterPaths {
  rig: string;          // optimized skinned GLB
  idle?: string;        // animation-only GLBs (geometry stripped)
  walk?: string;
  run?: string;
  hurt?: string;
  attack?: string;      // slash or shoot clip
}

const charPaths = (slug: string, attack?: 'slash' | 'shoot'): CharacterPaths => ({
  rig:  `models/${slug}/rig.glb`,
  idle: `models/${slug}/idle.glb`,
  walk: `models/${slug}/walk.glb`,
  run:  `models/${slug}/run.glb`,
  hurt: `models/${slug}/hurt.glb`,
  ...(attack ? { attack: `models/${slug}/${attack}.glb` } : {}),
});

export const MODEL_PATHS: Record<string, CharacterPaths> = {
  brandolf: charPaths('brandolf'),          // attack clip pending (10-credit retarget)
  bogar:    charPaths('bogar', 'slash'),
  guardian: charPaths('guardian', 'slash'),
  arcanist: charPaths('arcanist', 'shoot'),
  slime:    { rig: 'models/slime/rig.glb' },
};

/**
 * Map server class_index to model slug. Server CLASS_NAMES: 0=Engineer,
 * 1=Guardian, 2=Shadowblade (Bo-Gar), 3=Cleric (Brandolf), 4=Arcanist.
 * Engineer (0) has no model yet — callers fall back to the class capsule.
 */
export const CLASS_TO_MODEL: Record<number, string> = {
  1: 'guardian',
  2: 'bogar',
  3: 'brandolf',
  4: 'arcanist',
};
