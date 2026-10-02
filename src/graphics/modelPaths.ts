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
  // Release 0.3 class heroes.
  hero_hollow_knight: m('hero_hollow_knight', 1.9),
  hero_grave_warden: m('hero_grave_warden', 1.9),
  hero_bell_monk: m('hero_bell_monk', 1.87),
  hero_carrion_witch: m('hero_carrion_witch', 1.85),
  hero_veilwalker: m('hero_veilwalker', 1.85),
  skeleton_thrall: m('skeleton_thrall', 1.75),
  grave_robber: m('grave_robber', 1.7),
  bone_hound: m('bone_hound', 1.05),
  penitent: m('penitent', 1.85),
  deacon: m('deacon', 2.1),
  carrion_sac: m('carrion_sac', 1.75),
  prelate: m('prelate', 4.6),
  // Area bosses (roadmap batch art; wired 2026-09-28).
  boss_gravedigger_king: m('boss_gravedigger_king', 3.4),
  boss_bone_abbess: m('boss_bone_abbess', 3.2),
  boss_drowned_congregation: m('boss_drowned_congregation', 3.6),
  // Enemy variety pack (art-manifest/tripo-specs/*.json). The wraith hovers, so it is a
  // static mesh built as a prop and bobbed in code.
  censer_bearer: m('censer_bearer', 1.95),
  choir_wraith: { url: 'models/props/choir_wraith.glb', height: 2.1 },
  // Discipline legions (2026-09-30): each necromancer raises its own kind of dead.
  thrall_sentinel: m('thrall_sentinel', 1.85),
  thrall_legionnaire: m('thrall_legionnaire', 1.75),
  thrall_plague: m('thrall_plague', 1.8),
  wraith_thrall: { url: 'models/props/wraith_thrall.glb', height: 1.95 },
  skull_rat: m('skull_rat', 0.5),
  bone_golem: m('bone_golem', 3.1),
  // Bone Colossus rune thrall (2026-10-02): the player's own giant. Jade-lit bone and violet Covenant cloth, so it never reads as the enemy Bone Golem.
  bone_colossus: m('bone_colossus', 3.2),
  // Flying pack (2026-09-28). Gargoyle and seraph are rigged (biped); moth and bat are static
  // meshes. All four flap their wings in the vertex shader (graphics/wingFlap.ts).
  belfry_gargoyle: m('belfry_gargoyle', 2.0),
  weeping_seraph: m('weeping_seraph', 2.3),
  shroud_moth: { url: 'models/props/shroud_moth.glb', height: 1.3 },
  tithe_bat: { url: 'models/props/tithe_bat.glb', height: 0.75 },
  // Backlog mobs (roadmap batch art, wired 2026-09-28).
  barrow_ghoul: m('barrow_ghoul', 1.9),
  lich_acolyte: m('lich_acolyte', 1.95),
  bell_templar: m('bell_templar', 2.1),
  // The Bone Abbess's niches are static props drawn as enemies while she is awake.
  skull_niche: { url: 'models/props/skull_niche.glb', height: 3.4 },
  // The Plague Cloister (2026-09-29).
  plague_doctor: m('plague_doctor', 2.0),
  flagellant: m('flagellant', 1.85),
  boss_plague_saint: m('boss_plague_saint', 4.0),
  // The Cinder Pyre (2026-09-30).
  cinder_husk: m('cinder_husk', 1.9),
  pyre_priest: m('pyre_priest', 2.0),
  cinderhound: m('cinderhound', 1.0),
  slag_brute: m('slag_brute', 2.9),
  boss_cinder_regent: m('boss_cinder_regent', 4.3),
  // The Mourning Fen (2026-09-30). Leech and wisp are static meshes (built as props): the leech slithers and the wisp bobs in code.
  bog_hag: m('bog_hag', 2.0),
  drowned_sexton: m('drowned_sexton', 2.6),
  mire_leech: { url: 'models/props/mire_leech.glb', height: 0.6 },
  fen_wisp: { url: 'models/props/fen_wisp.glb', height: 1.15 },
  boss_mire_mother: m('boss_mire_mother', 4.4),
  // Guide NPCs (2026-10-02, docs/ALCHEMIST-WING-ART.md). Clips: idle, walk, talk (+ talk2 on the Prior).
  npc_prior: m('npc_prior', 1.8),
  npc_sexton: m('npc_sexton', 1.8),
  npc_apothecary: m('npc_apothecary', 1.75),
} satisfies Record<string, CreatureModelDef>;

export type CreatureSlug = keyof typeof CREATURE_MODELS;

/** Static environment props (tools/build-characters.mjs → models/props/<id>.glb). */
export const PROP_URL = (id: string) => `models/props/${id}.glb`;
