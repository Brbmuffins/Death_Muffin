#!/usr/bin/env node
/**
 * NOTE (2026-10): the pack clips replaced most of these outputs (see docs/AUDIO-SOURCES.md). Only boss_toll_*, amb_bell_*, amb_gust_*,
 * amb_ember_*, amb_moan_* and amb_crow_* are still shipped; do not re-run this over public/audio/.
 *
 * Builds public/audio/combat/*.ogg from Kenney CC0 packs (see docs/AUDIO-SOURCES.md).
 *
 *   node tools/audio/build-combat-samples.mjs <packs-dir>
 *
 * <packs-dir> holds the unzipped Kenney packs as impact-sounds/, rpg-audio/ and
 * sci-fi-sounds/ (each with an Audio/ folder). Every output is mono 32 kHz Ogg
 * Vorbis, silence-trimmed and peak-normalised to -2 dBFS; the engine balances the
 * levels per sound. "Necro" variants are made by pitching down, low-passing,
 * reversing, layering and echo. Needs ffmpeg with libvorbis.
 */
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdirSync, copyFileSync, existsSync } from 'node:fs';
import { join, resolve } from 'node:path';

const packs = resolve(process.argv[2] ?? '');
if (!process.argv[2]) throw new Error('usage: build-combat-samples.mjs <packs-dir>');
const OUT = resolve('public/audio/combat');
mkdirSync(OUT, { recursive: true });
const PACK_DIR = { impact: 'impact-sounds/Audio', rpg: 'rpg-audio/Audio', scifi: 'sci-fi-sounds/Audio' };
const file = (ref) => {
  if (ref.startsWith('noise:')) return null;
  const [pack, name] = ref.split('/');
  const p = join(packs, PACK_DIR[pack], `${name}.ogg`);
  if (!existsSync(p)) throw new Error(`missing ${p}`);
  return p;
};

/** One layer: src ref + processing. Returns an ffmpeg filter chain for input index i. */
function layer(i, o = {}) {
  const f = ['aformat=channel_layouts=mono', 'aresample=44100'];
  if (o.trim) f.push(`atrim=0:${o.trim}`, 'asetpts=PTS-STARTPTS');
  if (o.rev) f.push('areverse');
  if (o.pitch && o.pitch !== 1) f.push(`asetrate=${Math.round(44100 * o.pitch)}`, 'aresample=44100');
  if (o.hp) f.push(`highpass=f=${o.hp}`);
  if (o.lp) f.push(`lowpass=f=${o.lp}`);
  if (o.echo) f.push(`aecho=0.7:0.6:${o.echo}:0.35`);
  if (o.fadeIn) f.push(`afade=t=in:d=${o.fadeIn}`);
  if (o.fadeOut) f.push(`afade=t=out:st=${Math.max(0, (o.trim ?? 1) / (o.pitch ?? 1) - o.fadeOut)}:d=${o.fadeOut}`);
  f.push(`volume=${o.vol ?? 1}`);
  if (o.delay) f.push(`adelay=${Math.round(o.delay * 1000)}`);
  return `[${i}:a]${f.join(',')}[l${i}]`;
}

function build(out, layers, tail = '') {
  const args = ['-y', '-v', 'error'];
  const graph = [];
  layers.forEach(([ref, o], i) => {
    if (ref.startsWith('noise:')) args.push('-f', 'lavfi', '-i', ref.slice(6));
    else args.push('-i', file(ref));
    graph.push(layer(i, o));
  });
  const ins = layers.map((_, i) => `[l${i}]`).join('');
  graph.push(`${ins}amix=inputs=${layers.length}:normalize=0:duration=longest,${tail}aresample=32000,silenceremove=start_periods=1:start_threshold=-48dB:start_silence=0.01[m]`);
  const tmp = join(OUT, `.tmp-${out}.wav`);
  execFileSync('ffmpeg', [...args, '-filter_complex', graph.join(';'), '-map', '[m]', '-ac', '1', tmp]);
  // Peak-normalise to -2 dBFS.
  const log = spawnSync('ffmpeg', ['-hide_banner', '-i', tmp, '-af', 'volumedetect', '-f', 'null', '-'], { encoding: 'utf8' }).stderr;
  const m = /max_volume: (-?[\d.]+) dB/.exec(log);
  const gain = m ? -2 - Number(m[1]) : 0;
  execFileSync('ffmpeg', ['-y', '-v', 'error', '-i', tmp, '-af', `volume=${gain.toFixed(2)}dB,alimiter=limit=0.8`, '-ac', '1', '-ar', '32000', '-c:a', 'libvorbis', '-q:a', '2', join(OUT, `${out}.ogg`)]);
  execFileSync('rm', ['-f', tmp]);
  console.log('built', out);
}

const wood = ['impact/impactWood_light_000', 'impact/impactWood_light_001', 'impact/impactWood_light_002', 'impact/impactWood_light_003', 'impact/impactWood_light_004'];

// --- needle (thin bone-splinter slice, tick on impact) ---
['rpg/knifeSlice', 'rpg/knifeSlice2', 'rpg/drawKnife1'].forEach((s, i) =>
  build(`needle_cast_${i + 1}`, [[s, { trim: 0.35, hp: 700, pitch: 1.15 + i * 0.05, vol: 0.9, fadeOut: 0.1 }], ['scifi/thrusterFire_00' + i, { trim: 0.25, hp: 2500, lp: 7000, vol: 0.25, fadeIn: 0.05, fadeOut: 0.12 }]]));
[0, 1, 2].forEach((i) =>
  build(`needle_hit_${i + 1}`, [[wood[i], { hp: 300, pitch: 1.25 - i * 0.05, trim: 0.3, fadeOut: 0.1 }], ['impact/impactGeneric_light_00' + i, { lp: 3500, pitch: 1.1, trim: 0.2, vol: 0.5, fadeOut: 0.08 }]]));

// --- bone crack / flesh thud (enemy hit) ---
[['impact/impactWood_medium_000', 'impact/impactSoft_medium_000'], ['impact/impactPlank_medium_001', 'impact/impactSoft_medium_001'], ['impact/impactWood_medium_003', 'impact/impactSoft_medium_002']].forEach(([a, b], i) =>
  build(`bone_hit_${i + 1}`, [[a, { pitch: 1.05 - i * 0.07, hp: 150, trim: 0.4, fadeOut: 0.12 }], [b, { pitch: 0.8, lp: 1500, vol: 0.8, trim: 0.35, fadeOut: 0.1 }]]));

// --- marrow spear: whoosh + heavy thud ---
[0, 1].forEach((i) =>
  build(`spear_${i + 1}`, [
    ['scifi/thrusterFire_00' + (i + 2), { trim: 0.55, hp: 250, lp: 4500, pitch: 0.9 + i * 0.1, fadeIn: 0.2, fadeOut: 0.2, vol: 0.7 }],
    ['impact/impactWood_heavy_00' + i, { delay: 0.15, pitch: 0.8, lp: 4000, trim: 0.6, fadeOut: 0.25 }],
    ['impact/impactPunch_heavy_00' + i, { delay: 0.15, pitch: 0.7, lp: 900, vol: 0.9, trim: 0.5, fadeOut: 0.2 }],
  ]));

// --- exhume: grave-dirt crunch + wet earth + sub rumble ---
[0, 1, 2].forEach((i) =>
  build(`exhume_${i + 1}`, [
    ['impact/footstep_snow_00' + (i + 1), { pitch: 0.62, lp: 3500, trim: 0.5, vol: 1, fadeOut: 0.15 }],
    ['impact/footstep_grass_00' + i, { pitch: 0.7, delay: 0.14, lp: 3000, trim: 0.5, vol: 0.9, fadeOut: 0.15 }],
    ['scifi/slime_00' + (i % 2), { pitch: 0.65, delay: 0.05, lp: 1400, vol: 0.5, trim: 0.5, fadeOut: 0.2 }],
    ['scifi/spaceEngineLow_00' + i, { trim: 1.0, lp: 220, fadeIn: 0.3, fadeOut: 0.5, vol: 0.9, delay: 0.1 }],
  ]));

// --- thrall rise: bone clatter ---
[0, 1].forEach((i) =>
  build(`thrall_rise_${i + 1}`, [
    [wood[i], { pitch: 1.1, trim: 0.25, fadeOut: 0.08 }],
    [wood[i + 2], { pitch: 0.95, delay: 0.07, trim: 0.25, vol: 0.8, fadeOut: 0.08 }],
    [wood[(i + 3) % 5], { pitch: 1.2, delay: 0.14, trim: 0.25, vol: 0.7, fadeOut: 0.08 }],
    [wood[(i + 1) % 5], { pitch: 1.0, delay: 0.23, trim: 0.25, vol: 0.6, fadeOut: 0.08 }],
    ['rpg/cloth' + (i + 2), { delay: 0.02, pitch: 0.85, lp: 2200, trim: 0.5, vol: 0.5, fadeOut: 0.2 }],
  ]));

// --- corpse explosion: wet crunch, low boom ---
[0, 1, 2].forEach((i) =>
  build(`corpse_burst_${i + 1}`, [
    ['scifi/explosionCrunch_00' + i, { pitch: 0.78 - i * 0.04, lp: 3800, trim: 0.8, fadeOut: 0.25 }],
    ['scifi/slime_00' + (i % 2), { pitch: 0.7, delay: 0.04, lp: 2200, vol: 0.9, trim: 0.5, fadeOut: 0.2 }],
    ['scifi/lowFrequency_explosion_00' + (i % 2), { pitch: 0.9, lp: 450, trim: 1.0, vol: 0.9, fadeOut: 0.5 }],
  ]));

// --- Black Litany: reversed inhale into a low boom ---
[0, 1].forEach((i) =>
  build(`litany_${i + 1}`, [
    ['scifi/forceField_00' + (i + 1), { rev: true, pitch: 0.85, lp: 3000, trim: 0.9, vol: 0.7, fadeIn: 0.1 }],
    ['scifi/lowFrequency_explosion_00' + i, { pitch: 0.75, lp: 700, delay: 0.5, vol: 1, fadeOut: 0.8, trim: 1.7 }],
    ['impact/impactBell_heavy_00' + (i + 1), { pitch: 0.5, lp: 1800, delay: 0.52, vol: 0.5, echo: 90, trim: 1.4, fadeOut: 0.6 }],
  ]));

// --- Miasma: wet bubbling gas ---
[0, 1].forEach((i) =>
  build(`miasma_${i + 1}`, [
    ['scifi/slime_00' + i, { pitch: 0.75, lp: 1500, trim: 0.5, vol: 1, fadeOut: 0.1 }],
    ['scifi/slime_00' + (1 - i), { pitch: 0.6, lp: 1200, delay: 0.3, vol: 0.8, trim: 0.5, fadeOut: 0.1 }],
    ['scifi/computerNoise_00' + i, { lp: 600, hp: 80, vol: 0.35, trim: 1.0, fadeIn: 0.2, fadeOut: 0.4 }],
  ]));

// --- deaths ---
[1, 2, 3].forEach((n, i) =>
  build(`enemy_death_${i + 1}`, [
    ['impact/impactSoft_heavy_00' + n, { pitch: 0.85, lp: 1800, trim: 0.5, fadeOut: 0.2 }],
    [wood[i], { pitch: 0.95, delay: 0.03, vol: 0.6, trim: 0.25, fadeOut: 0.08 }],
    ['rpg/dropLeather', { pitch: 0.7 + i * 0.05, delay: 0.1, vol: 0.5, lp: 1800, trim: 0.4, fadeOut: 0.15 }],
  ]));
[0, 1].forEach((i) =>
  build(`elite_death_${i + 1}`, [
    ['impact/impactPunch_heavy_00' + i, { pitch: 0.7, lp: 1500, trim: 0.6, fadeOut: 0.2 }],
    ['impact/impactBell_heavy_00' + i, { pitch: 0.55, lp: 2500, delay: 0.03, vol: 0.55, echo: 120, trim: 1.4, fadeOut: 0.6 }],
    ['scifi/lowFrequency_explosion_00' + (1 - i), { pitch: 0.9, lp: 500, vol: 0.9, trim: 1.0, fadeOut: 0.5 }],
  ]));

// --- player hurt: body blow, muffled ---
[0, 1, 2].forEach((i) =>
  build(`hurt_${i + 1}`, [
    ['impact/impactPunch_medium_00' + i, { pitch: 0.85, lp: 1800, trim: 0.4, fadeOut: 0.15 }],
    ['impact/impactSoft_heavy_00' + i, { pitch: 0.75, lp: 700, vol: 0.8, trim: 0.4, fadeOut: 0.15 }],
  ]));

// --- thralls: deliberately small and dry ---
[3, 4, 1].forEach((n, i) =>
  build(`thrall_melee_${i + 1}`, [
    [wood[n], { pitch: 0.95 + i * 0.06, lp: 3800, hp: 120, trim: 0.25, fadeOut: 0.1 }],
    ['impact/impactSoft_medium_00' + i, { pitch: 0.9, lp: 1200, vol: 0.5, trim: 0.25, fadeOut: 0.1 }],
  ]));
['rpg/drawKnife2', 'rpg/knifeSlice2'].forEach((s, i) =>
  build(`thrall_shot_${i + 1}`, [[s, { trim: 0.28, hp: 500, lp: 5000, pitch: 1.0 + i * 0.1, fadeOut: 0.1 }], [wood[i + 3], { delay: 0.12, pitch: 1.3, vol: 0.5, trim: 0.2, fadeOut: 0.08 }]]));
[1, 2].forEach((n, i) =>
  build(`thrall_magic_${i + 1}`, [['scifi/forceField_00' + n, { trim: 0.45, pitch: 0.8 + i * 0.1, lp: 2600, hp: 150, fadeIn: 0.05, fadeOut: 0.25 }]]));

// --- bosses ---
[0, 1].forEach((i) =>
  build(`boss_slam_${i + 1}`, [
    ['impact/impactMetal_heavy_00' + i, { pitch: 0.55, lp: 2500, trim: 0.6, fadeOut: 0.3 }],
    ['scifi/lowFrequency_explosion_00' + i, { pitch: 0.7, lp: 600, vol: 1, trim: 1.8, fadeOut: 0.7 }],
    ['impact/impactPunch_heavy_00' + (i + 2), { pitch: 0.55, lp: 900, vol: 0.8, trim: 0.6, fadeOut: 0.3 }],
  ]));
[0, 1].forEach((i) =>
  build(`boss_toll_${i + 1}`, [['impact/impactBell_heavy_00' + i, { pitch: 0.5 - i * 0.05, lp: 3500, echo: 140, trim: 1.4, fadeOut: 0.5 }], ['scifi/spaceEngineLow_00' + i, { lp: 160, trim: 1.5, fadeIn: 0.1, fadeOut: 0.8, vol: 0.5 }]], 'apad=pad_dur=0.6,'));
build('boss_awaken_1', [['impact/impactBell_heavy_002', { pitch: 0.4, echo: 180, trim: 1.4, lp: 3000, fadeOut: 0.5 }], ['scifi/spaceEngineLow_002', { lp: 140, trim: 4, fadeIn: 1.5, fadeOut: 1.8, vol: 0.9 }]], 'apad=pad_dur=1,');
build('player_death_1', [['impact/impactBell_heavy_004', { pitch: 0.5, echo: 160, trim: 1.4, lp: 2200, fadeOut: 0.5 }], ['impact/impactSoft_heavy_004', { pitch: 0.6, lp: 600, trim: 0.5, fadeOut: 0.2, vol: 0.9 }]], 'apad=pad_dur=0.8,');

// --- ghostly whispers (synthesised in ffmpeg: no source recording) ---
[[1500, 'pink'], [2100, 'brown'], [1150, 'pink']].forEach(([fc, color], i) =>
  build(`wail_${i + 1}`, [[`noise:anoisesrc=d=1.1:c=${color}:a=0.6:r=44100:s=${i + 7}`, { hp: 300 }]],
    `bandpass=f=${fc}:width_type=h:w=${fc * 0.7},tremolo=f=${5 + i * 1.7}:d=0.85,vibrato=f=5:d=0.4,afade=t=in:d=0.2,afade=t=out:st=0.5:d=0.6,aecho=0.6:0.5:70|130:0.4|0.25,`));

// --- Grave Step / veil: air + cloth ---
[0, 1].forEach((i) =>
  build(`grave_step_${i + 1}`, [
    ['scifi/thrusterFire_00' + (i + 1), { trim: 0.45, hp: 150, lp: 2200, fadeIn: 0.15, fadeOut: 0.2, vol: 0.8 }],
    ['rpg/clothBelt' + (i ? '2' : ''), { delay: 0.2, pitch: 0.8, lp: 2000, vol: 0.6, trim: 0.4, fadeOut: 0.15 }],
    ['impact/impactSoft_heavy_00' + i, { delay: 0.2, pitch: 0.6, lp: 500, vol: 0.8, trim: 0.4, fadeOut: 0.15 }],
  ]));
build('veil_whoosh_1', [['scifi/thrusterFire_003', { trim: 0.9, hp: 300, lp: 5000, pitch: 1.1, fadeIn: 0.35, fadeOut: 0.4 }], ['scifi/forceField_003', { trim: 0.8, rev: true, lp: 3000, vol: 0.5, fadeOut: 0.2 }]]);
console.log('done');
