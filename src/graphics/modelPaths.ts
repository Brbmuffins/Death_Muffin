/**
 * Model registry. v3 characters are built by `node tools/build-characters.mjs`
 * from Tripo outputs in art-src/tripo/<slug>/ (gitignored) into one GLB per
 * character with named clips: idle, walk, run, cast, attack, hurt, dig, death
 * (whichever were generated). Heights are world units (the player is ~1.85).
 */
export interface CreatureModelDef {
  url: string;
  height: number;
}

const m = (slug: string, height: number): CreatureModelDef => ({ url: `models/${slug}/character.glb`, height });

export const CREATURE_MODELS = {
  necromancer: m('necromancer', 1.85),
  hero_ossuary: m('hero_ossuary', 1.88),
  hero_gravecaller: m('hero_gravecaller', 1.88),
  hero_mourner: m('hero_mourner', 1.85),
  hero_rotweaver: m('hero_rotweaver', 1.85),
  skeleton_thrall: m('skeleton_thrall', 1.75),
  grave_robber: m('grave_robber', 1.7),
  bone_hound: m('bone_hound', 1.05),
  penitent: m('penitent', 1.85),
  deacon: m('deacon', 2.1),
  carrion_sac: m('carrion_sac', 1.75),
  prelate: m('prelate', 4.6),
  // Enemy variety pack (art-manifest/tripo-specs/*.json). The wraith hovers, so it is a
  // static mesh built as a prop and bobbed in code.
  censer_bearer: m('censer_bearer', 1.95),
  choir_wraith: { url: 'models/props/choir_wraith.glb', height: 2.1 },
  skull_rat: m('skull_rat', 0.5),
  bone_golem: m('bone_golem', 3.1),
} satisfies Record<string, CreatureModelDef>;

export type CreatureSlug = keyof typeof CREATURE_MODELS;

/** Static environment props (tools/build-characters.mjs → models/props/<id>.glb). */
export const PROP_URL = (id: string) => `models/props/${id}.glb`;
