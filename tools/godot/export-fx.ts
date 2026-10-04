/**
 * Exports the web game's effect tables to godot/assets/fx/fx_data.json so the Godot port (godot/fx/) reads the same numbers:
 * SPELL_FX (spell colours carry meaning), the Binbun presets (colours/scale/y/alpha per effect id), the catalog lists, per-effect
 * defaults from public/fx/binbun/index.json and the caps/budget constants of Effects.ts / BinbunFX.ts / necroFx.ts.
 * Run: npx vite-node tools/godot/export-fx.ts
 */
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { SPELL_FX } from '../../src/content/abilities';
import { FX_PRESETS } from '../../src/graphics/binbun/presets';
import { BINBUN_EFFECTS, BINBUN_IMPACTS, BINBUN_LOOPERS, BINBUN_ONESHOTS, BINBUN_WORLD_KITS } from '../../src/graphics/binbun/catalog';
import { NECRO_MATTER } from '../../src/graphics/necroFx';

const read = (p: string) => readFileSync(p, 'utf8');
const grab = (src: string, re: RegExp, what: string): number => {
  const m = re.exec(src);
  if (!m) throw new Error(`export-fx: cannot find ${what}`);
  return Number(m[1]);
};

const effects = read('src/graphics/Effects.ts');
const binbun = read('src/graphics/binbun/BinbunFX.ts');
const necro = read('src/graphics/necroFx.ts');

const index = JSON.parse(read('public/fx/binbun/index.json')) as { effects: { id: string; file: string; animation: string; duration: number; particles: number; meshes: number; decals: number; lights: number; unsupported: string[] }[] };
const perEffect: Record<string, unknown> = {};
for (const e of index.effects) {
  const f = JSON.parse(read(`public/fx/binbun/${e.file}`)) as { defaultColors?: number[][]; note?: string; animation: string; duration: number };
  perEffect[e.id] = { animation: f.animation, duration: f.duration, defaultColors: f.defaultColors ?? [], note: f.note ?? '', particles: e.particles, meshes: e.meshes, decals: e.decals, lights: e.lights, unsupported: e.unsupported };
}

const data = {
  spell_fx: SPELL_FX,
  necro_matter: NECRO_MATTER,
  presets: FX_PRESETS,
  catalog: { effects: BINBUN_EFFECTS, impacts: BINBUN_IMPACTS, loopers: BINBUN_LOOPERS, oneshots: BINBUN_ONESHOTS, world_kits: BINBUN_WORLD_KITS },
  effects: perEffect,
  caps: {
    max_oneshots: grab(binbun, /const MAX_ONESHOTS = (\d+)/, 'MAX_ONESHOTS'),
    max_loopers: grab(binbun, /const MAX_LOOPERS = (\d+)/, 'MAX_LOOPERS'),
    cull_distance: grab(binbun, /const CULL_DISTANCE = (\d+)/, 'CULL_DISTANCE'),
    fade_out: grab(binbun, /const FADE_OUT = ([\d.]+)/, 'FADE_OUT'),
    combat_transients: grab(effects, /this\.combatTransients >= (\d+)/, 'combat transient cap'),
    low_particle_scale: grab(effects, /const LOW_PARTICLE_SCALE = ([\d.]+)/, 'LOW_PARTICLE_SCALE'),
    flash_lights: grab(effects, /const FLASH_LIGHTS = (\d+)/, 'FLASH_LIGHTS'),
    additive_particles: grab(effects, /new ParticleSystem\((\d+), fx\.glow\(\)/, 'additive ring'),
    smoke_particles: grab(effects, /new ParticleSystem\((\d+), fx\.smoke\(\)/, 'smoke ring'),
    other_decal_alpha: grab(effects, /OTHER_DECAL_ALPHA = ([\d.]+)/, 'OTHER_DECAL_ALPHA'),
    other_binbun_alpha: grab(effects, /OTHER_BINBUN_ALPHA = ([\d.]+)/, 'OTHER_BINBUN_ALPHA'),
    other_binbun_scale: grab(effects, /OTHER_BINBUN_SCALE = ([\d.]+)/, 'OTHER_BINBUN_SCALE'),
    outline_after_s: grab(effects, /OUTLINE_AFTER_S = ([\d.]+)/, 'OUTLINE_AFTER_S'),
    outline_fade_s: grab(effects, /OUTLINE_FADE_S = ([\d.]+)/, 'OUTLINE_FADE_S'),
    long_decal_s: grab(effects, /LONG_DECAL_S = ([\d.]+)/, 'LONG_DECAL_S'),
    ring_for_disc: grab(effects, /RING_FOR_DISC = ([\d.]+)/, 'RING_FOR_DISC'),
    bone_shard_cap: grab(effects, /BONE_SHARD_CAP = (\d+)/, 'BONE_SHARD_CAP'),
    grave_hand_cap: grab(effects, /GRAVE_HAND_CAP = (\d+)/, 'GRAVE_HAND_CAP'),
    motif_particle_burst: grab(necro, /PARTICLE_BURST = (\d+)/, 'PARTICLE_BURST'),
    motif_particle_per_s: grab(necro, /PARTICLE_PER_S = (\d+)/, 'PARTICLE_PER_S'),
    motif_sprite_burst: grab(necro, /SPRITE_BURST = (\d+)/, 'SPRITE_BURST'),
    motif_sprite_per_s: grab(necro, /SPRITE_PER_S = (\d+)/, 'SPRITE_PER_S'),
    motif_transient_ceiling: grab(necro, /TRANSIENT_CEILING = (\d+)/, 'TRANSIENT_CEILING'),
    motif_thrall_scale: grab(necro, /THRALL_SCALE = ([\d.]+)/, 'THRALL_SCALE'),
    motif_reduced_scale: grab(necro, /REDUCED_SCALE = ([\d.]+)/, 'REDUCED_SCALE'),
  },
  /** Decal render order (Effects.ts DECAL_ORDER): friendly ground effects, hero marker, danger telegraphs. */
  decal_order: { friendly: 2, hero: 3, danger: 4 },
};
mkdirSync('godot/assets/fx', { recursive: true });
writeFileSync('godot/assets/fx/fx_data.json', JSON.stringify(data, null, 1) + '\n');
console.log(`export-fx: ${Object.keys(perEffect).length} effects, ${Object.keys(FX_PRESETS).length} presets, ${Object.keys(SPELL_FX).length} spell groups`);
