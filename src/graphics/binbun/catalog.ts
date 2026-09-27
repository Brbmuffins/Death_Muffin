/**
 * The converted Binbun ids (art-manifest/binbun-effects.json; a unit test keeps this in
 * sync) and how each one is played (spell-variety brief §5).
 */

/** One-off impacts whose converted animation is `main`: play with `once: true`. */
export const BINBUN_IMPACTS = [
  'needle_hit',
  'crit_hit',
  'rend_impact',
  'wall_raise',
  'vengeful_burst',
  'surge_eruption',
  'archer_flash',
  'bone_fan_hit',
  'ivory_cleave_hit',
] as const;

/** Persistent effects: give them `follow` or `duration` (they are culled when far or off-screen). */
export const BINBUN_LOOPERS = [
  'interact_rim',
  'altar_beacon',
  'waystone_portal',
  'recall_portal',
  'brazier_fire',
  'bonfire',
  'kiln_fire',
  'crypt_mist',
  'nave_fog',
  'toxic_puddle',
  'toxic_stink',
  'soul_orb',
  'censer_incense',
  'rally_thrall_rim',
  'carrion_seed_armed',
  'curse_bolt',
  'rot_lance_projectile',
  'wailing_skull_projectile',
  'sanctify_beam',
  'exhume_beam',
  'veil_step_trail',
  'chapterhouse_candle',
  'area_gate',
  'loot_common',
  'loot_uncommon',
  'loot_rare',
  'loot_epic',
  'loot_legendary',
  'loot_mythic',
  'loot_divine',
] as const;

/** Played through their `oneshot` animation. */
export const BINBUN_ONESHOTS = [
  'miasma_cloud',
  'plague_bloom_area',
  'corpse_explosion',
  'grave_frost_mist',
  'frost_shard_hit',
  'dirge_area',
  'litany_pulse',
  'soul_harvest_pillar',
  'exhume_lift',
  'thrall_rise',
  'grave_step_smoke',
  'enemy_breach_rim',
  'prelate_impact',
  'grave_offering_orb',
  'grave_offering_ripple',
  'rally_area',
  'carrion_seed_burst',
  'levelup_pillar',
  'bell_toll_ring',
  'choir_scream',
  'boss_rain_orb',
] as const;

/** Material/shader kits with no nodes (the world_* entries): ported one by one later, never spawned. */
export const BINBUN_WORLD_KITS = ['world_water_dirty', 'world_water_basic', 'world_grass', 'world_grass_ground', 'world_transition_ridge', 'world_transition_blades', 'world_sky_dark'] as const;

export type BinbunId = (typeof BINBUN_IMPACTS)[number] | (typeof BINBUN_LOOPERS)[number] | (typeof BINBUN_ONESHOTS)[number];

/** Every spawnable id, gallery order: rites and impacts, then persistent props. */
export const BINBUN_EFFECTS: readonly BinbunId[] = [...BINBUN_ONESHOTS, ...BINBUN_IMPACTS, ...BINBUN_LOOPERS];

export const isBinbunImpact = (id: string) => (BINBUN_IMPACTS as readonly string[]).includes(id);
export const isBinbunLooper = (id: string) => (BINBUN_LOOPERS as readonly string[]).includes(id);
