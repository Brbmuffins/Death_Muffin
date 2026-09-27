import type * as THREE from 'three';
import { SPELL_FX } from '../../content/abilities';
import type { BinbunFX, BinbunHandle, BinbunSpawn } from './BinbunFX';
import { isBinbunImpact, type BinbunId } from './catalog';

/**
 * How each Binbun effect is played in the game: its colours (from SPELL_FX, so spell colour keeps its meaning),
 * base scale, height and opacity. Tune here, not at the call sites. Calibrated against the bloom in the DEV
 * gallery (`__cwDebug.vfxGallery()`, `__cwDebug.vfx(id)`); the global gain lives in `shaders.ts` (BINBUN_GAIN).
 */
export interface FxPreset {
  colors?: readonly THREE.ColorRepresentation[];
  scale?: number;
  y?: number;
  alpha?: number;
}

const N = SPELL_FX.needle;
const S = SPELL_FX.spear;
const X = SPELL_FX.exhume;
const M = SPELL_FX.miasma;
const L = SPELL_FX.litany;
const D = SPELL_FX.detonate;
const FR = SPELL_FX.frost;
const DI = SPELL_FX.dirge;
const BL = SPELL_FX.bloom;
const SO = SPELL_FX.souls;
const SK = SPELL_FX.skull;
const ST = SPELL_FX.step;
const W = SPELL_FX.wall;
const R = SPELL_FX.rend;
const E = SPELL_FX.enemy;

export const FX_PRESETS: Partial<Record<BinbunId, FxPreset>> = {
  // --- Rites ---
  needle_hit: { colors: [N.impact, N.trail, N.dust], scale: 0.4, y: 1 },
  crit_hit: { colors: [N.impact, N.trail, N.dust], scale: 0.6, y: 1 },
  bone_fan_hit: { colors: [N.impact, N.trail, N.dust], scale: 0.35, y: 1 },
  ivory_cleave_hit: { colors: [S.bone, S.crack, S.marrow], scale: 0.45, y: 0.9 },
  rot_lance_projectile: { colors: [0xc7e04a, 0x6f8f22, 0x2b3317], scale: 0.55 },
  toxic_stink: { colors: [M.rot, M.deep, M.spore], scale: 0.45, alpha: 0.8 },
  miasma_cloud: { colors: [M.rot, M.deep, M.spore], scale: 1, alpha: 0.85 },
  plague_bloom_area: { colors: [BL.petal, BL.rot, BL.spore], scale: 0.9, alpha: 0.85 },
  corpse_explosion: { colors: [D.ember, D.hot, D.crimson], scale: 0.8 },
  grave_frost_mist: { colors: [FR.pale, FR.frost, FR.deep], scale: 0.9, alpha: 0.8 },
  frost_shard_hit: { colors: [FR.pale, FR.frost, FR.deep], scale: 0.45, y: 0.6 },
  dirge_area: { colors: [DI.frost, DI.deep, DI.pale], scale: 0.85, alpha: 0.55 },
  litany_pulse: { colors: [L.core, L.hot, L.void], scale: 1, alpha: 0.9 },
  soul_harvest_pillar: { colors: [SO.jade, SO.deep, SO.pale], scale: 0.6, alpha: 0.8 },
  exhume_lift: { colors: [X.spirit, X.deep, X.beam], scale: 0.5, alpha: 0.75 },
  thrall_rise: { colors: [X.spirit, X.deep, X.beam], scale: 0.45, alpha: 0.7 },
  grave_step_smoke: { colors: [ST.mist, ST.crimson, ST.blood], scale: 0.7 },
  wailing_skull_projectile: { colors: [SK.jade, SK.pale, SK.deep], scale: 0.45 },
  grave_offering_orb: { colors: [X.spirit, X.beam, X.deep], scale: 0.45, y: 1.2 },
  grave_offering_ripple: { colors: [X.spirit, X.deep, X.beam], scale: 0.55, alpha: 0.85 },
  rally_area: { colors: [R.jade, R.pale, R.bone], scale: 0.7, alpha: 0.8 },
  rally_thrall_rim: { colors: [R.jade, R.pale, R.bone], scale: 0.35, alpha: 0.7 },
  carrion_seed_armed: { colors: [BL.petal, BL.rot, BL.spore], scale: 0.35 },
  carrion_seed_burst: { colors: [BL.petal, BL.rot, BL.spore], scale: 0.9 },
  toxic_puddle: { colors: [M.rot, M.deep, M.spore], scale: 0.7, alpha: 0.7 },
  veil_step_trail: { colors: [0xdde8ff, 0x6fe3c8, 0x1f8f86], scale: 0.5, y: 0.6, alpha: 0.8 },
  wall_raise: { colors: [W.bone, W.amber, W.dust], scale: 0.7 },
  rend_impact: { colors: [R.jade, R.pale, R.bone], scale: 0.5 },
  levelup_pillar: { colors: [0xe9c98f, 0xd9a441, 0xf3e8d2], scale: 0.6, alpha: 0.8 },
  soul_orb: { colors: [SO.jade, SO.pale, SO.deep], scale: 0.35, y: 0.6 },
  // --- Enemies and bosses (enemy language only: bronze, rot, curse, choir blue) ---
  censer_incense: { colors: [E.toll, 0x6a6258, 0x2a2622], scale: 0.55, alpha: 0.6 },
  vengeful_burst: { colors: [SPELL_FX.affix.vengeful, 0xffb07a, 0x3a1a10], scale: 0.7 },
  surge_eruption: { colors: [SPELL_FX.surge.glow, SPELL_FX.surge.crack, 0x2a1a10], scale: 0.9 },
  crypt_mist: { colors: [0x6a6070, 0x3a3440, 0x1a161e], scale: 0.8, alpha: 0.5 },
  bell_toll_ring: { colors: [E.toll, 0xf2d58a, 0x3a2a10], scale: 0.8, alpha: 0.85 },
  choir_scream: { colors: [0xb9c8ff, 0x7f8fd0, 0x2a3050], scale: 0.6, alpha: 0.85 },
  boss_rain_orb: { colors: [SPELL_FX.boss.spirit, SPELL_FX.boss.bronze, 0x1a1a2a], scale: 0.5 },
  prelate_impact: { colors: [SPELL_FX.boss.bronze, SPELL_FX.boss.shard, 0x2a1a10], scale: 0.9 },
  enemy_breach_rim: { colors: [0x9b5cff, 0x7c3aed, 0x160a24], scale: 0.6, alpha: 0.7 },
  archer_flash: { colors: [N.impact, N.trail, N.dust], scale: 0.3, y: 1.2 },
  // --- World and interactables ---
  interact_rim: { scale: 0.45, alpha: 0.55 },
  altar_beacon: { colors: [0xd9a441, 0xf2d58a, 0x3a2a10], scale: 0.55, alpha: 0.6 },
  waystone_portal: { colors: [0x6fe3c8, 0x1f8f86, 0x0a2a26], scale: 0.4, y: 1.2, alpha: 0.7 },
  brazier_fire: { colors: [0xffa040, 0xff5a1a, 0x401008], scale: 0.4, y: 1.05, alpha: 0.9 },
  chapterhouse_candle: { scale: 0.35, y: 0.95, alpha: 0.9 },
  bonfire: { colors: [0xffa040, 0xff5a1a, 0x401008], scale: 0.5, alpha: 0.9 },
  kiln_fire: { colors: [0xffa040, 0xff5a1a, 0x401008], scale: 0.4, y: 0.4, alpha: 0.9 },
  nave_fog: { colors: [0x6a7a74, 0x3a4a46, 0x1a2220], scale: 1.2, alpha: 0.45 },
  area_gate: { colors: [0x9b5cff, 0x5b3fae, 0x160a24], scale: 0.5, alpha: 0.5 },
};

/** Spawn an effect through its preset. `scale`/`alpha` multiply the preset; everything else overrides it. */
export function playFx(fx: BinbunFX, id: BinbunId, o: Omit<BinbunSpawn, 'x' | 'z'> & { x: number; z: number }): BinbunHandle {
  const p = FX_PRESETS[id] ?? {};
  return fx.spawn(id, {
    y: p.y,
    colors: p.colors,
    once: isBinbunImpact(id),
    ...o,
    scale: (p.scale ?? 1) * (o.scale ?? 1),
    alpha: (p.alpha ?? 1) * (o.alpha ?? 1),
  });
}
