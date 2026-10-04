#!/usr/bin/env node
/**
 * NOTE (2026-10): the pack clips replaced most of these outputs (see docs/AUDIO-SOURCES.md). Only boss_toll_*, amb_bell_*, amb_gust_*,
 * amb_ember_*, amb_moan_* and amb_crow_* are still shipped; do not re-run this over public/audio/.
 *
 * Builds the second audio pass (see docs/AUDIO-SOURCES.md):
 *   public/audio/world/*.ogg     gathering, processing, rites, interface and ambient one-shots
 *   public/audio/ambience/*.ogg  seamless zone-bed loops (generated noise, no source recording)
 *
 *   node tools/audio/build-world-samples.mjs <packs-dir>
 *
 * <packs-dir> holds the unzipped Kenney CC0 packs as impact-sounds/, rpg-audio/ and
 * sci-fi-sounds/ (each with an Audio/ folder), same as build-combat-samples.mjs.
 * One-shots are mono 32 kHz Ogg Vorbis, trimmed, peak-normalised to -2 dBFS. Beds are
 * mono 24 kHz, peak -6 dBFS. Needs ffmpeg with libvorbis.
 */
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdirSync, existsSync, rmSync } from 'node:fs';
import { join, resolve } from 'node:path';

const packs = resolve(process.argv[2] ?? '');
if (!process.argv[2]) throw new Error('usage: build-world-samples.mjs <packs-dir>');
const WORLD = resolve('public/audio/world');
const BEDS = resolve('public/audio/ambience');
mkdirSync(WORLD, { recursive: true });
mkdirSync(BEDS, { recursive: true });
const PACK_DIR = { impact: 'impact-sounds/Audio', rpg: 'rpg-audio/Audio', scifi: 'sci-fi-sounds/Audio' };
const file = (ref) => {
  const [pack, name] = ref.split('/');
  const p = join(packs, PACK_DIR[pack], `${name}.ogg`);
  if (!existsSync(p)) throw new Error(`missing ${p}`);
  return p;
};
const N = (n) => `noise:${n}`;
const wood = [0, 1, 2, 3, 4].map((i) => `impact/impactWood_light_00${i}`);

function layer(i, o = {}) {
  const f = ['aformat=channel_layouts=mono', 'aresample=44100'];
  if (o.trim) f.push(`atrim=0:${o.trim}`, 'asetpts=PTS-STARTPTS');
  if (o.rev) f.push('areverse');
  if (o.pitch && o.pitch !== 1) f.push(`asetrate=${Math.round(44100 * o.pitch)}`, 'aresample=44100');
  if (o.hp) f.push(`highpass=f=${o.hp}`);
  if (o.lp) f.push(`lowpass=f=${o.lp}`);
  if (o.bp) f.push(`bandpass=f=${o.bp}:width_type=h:w=${o.bw ?? o.bp * 0.7}`);
  if (o.echo) f.push(`aecho=0.7:0.6:${o.echo}:${String(o.echo).split('|').map(() => '0.35').join('|')}`);
  if (o.fadeIn) f.push(`afade=t=in:d=${o.fadeIn}`);
  if (o.fadeOut) f.push(`afade=t=out:st=${Math.max(0, (o.trim ?? 1) / (o.pitch ?? 1) - o.fadeOut)}:d=${o.fadeOut}`);
  f.push(`volume=${o.vol ?? 1}`);
  if (o.delay) f.push(`adelay=${Math.round(o.delay * 1000)}`);
  return `[${i}:a]${f.join(',')}[l${i}]`;
}

function peakNormalise(tmp, db) {
  const log = spawnSync('ffmpeg', ['-hide_banner', '-i', tmp, '-af', 'volumedetect', '-f', 'null', '-'], { encoding: 'utf8' }).stderr;
  const m = /max_volume: (-?[\d.]+) dB/.exec(log);
  return m ? db - Number(m[1]) : 0;
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
  const tmp = join(WORLD, `.tmp-${out}.wav`);
  execFileSync('ffmpeg', [...args, '-filter_complex', graph.join(';'), '-map', '[m]', '-ac', '1', tmp]);
  const gain = peakNormalise(tmp, -2);
  execFileSync('ffmpeg', ['-y', '-v', 'error', '-i', tmp, '-af', `volume=${gain.toFixed(2)}dB,alimiter=limit=0.8`, '-ac', '1', '-ar', '32000', '-c:a', 'libvorbis', '-q:a', '2', join(WORLD, `${out}.ogg`)]);
  rmSync(tmp, { force: true });
  console.log('built', out);
}

/** A seamless 12 s bed: filtered noise, equal-power crossfaded tail-to-head, then a periodic swell. */
function bed(out, src, filter, swell) {
  const tmp = join(BEDS, `.tmp-${out}.wav`);
  const graph = [
    `${src},${filter},asplit=3[a][b][c]`,
    '[a]atrim=0:2,asetpts=PTS-STARTPTS,afade=t=in:d=2:curve=qsin[h]',
    '[b]atrim=12:14,asetpts=PTS-STARTPTS,afade=t=out:d=2:curve=qsin[t]',
    '[h][t]amix=inputs=2:normalize=0:duration=longest[over]',
    '[c]atrim=2:12,asetpts=PTS-STARTPTS[mid]',
    `[over][mid]concat=n=2:v=0:a=1,${swell}[m]`,
  ].join(';');
  execFileSync('ffmpeg', ['-y', '-v', 'error', '-filter_complex', graph, '-map', '[m]', '-ac', '1', '-ar', '24000', tmp]);
  const gain = peakNormalise(tmp, -6);
  execFileSync('ffmpeg', ['-y', '-v', 'error', '-i', tmp, '-af', `volume=${gain.toFixed(2)}dB`, '-ac', '1', '-ar', '24000', '-c:a', 'libvorbis', '-q:a', '1', join(BEDS, `${out}.ogg`)]);
  rmSync(tmp, { force: true });
  console.log('built bed', out);
}

// ===================== beds (generated; periodic swells repeat every 12 s) =====================
const noise = (color, seed) => `anoisesrc=d=14:c=${color}:r=24000:s=${seed}:a=0.9`;
const swell = (k, depth) => `volume='${1 - depth}+${depth}*(0.5+0.5*sin(2*PI*${k}*t/12))':eval=frame`;
bed('bed_wind', noise('brown', 11), 'highpass=f=60,lowpass=f=1400,bandpass=f=420:width_type=h:w=900', `${swell(1, 0.55)},${swell(3, 0.15)}`);
bed('bed_hollow', noise('brown', 12), 'lowpass=f=300,highpass=f=35,equalizer=f=95:width_type=h:w=40:g=9,equalizer=f=150:width_type=h:w=50:g=6', swell(2, 0.35));
bed('bed_water', noise('pink', 13), 'highpass=f=500,lowpass=f=3800,equalizer=f=1500:width_type=h:w=800:g=4', `${swell(4, 0.4)},${swell(7, 0.2)}`);
bed('bed_fire', 'aevalsrc=exprs=\'(random(0)*2-1)*0.35+if(lt(random(1),0.0009),(random(2)*2-1)*1.8,0)\':d=14:s=24000', 'lowpass=f=2600,highpass=f=70', swell(2, 0.3));
bed('bed_murmur', noise('pink', 14), 'bandpass=f=600:width_type=h:w=500,equalizer=f=1500:width_type=h:w=700:g=5,lowpass=f=2400', `${swell(5, 0.45)},${swell(2, 0.2)}`);

// ===================== gathering and processing =====================
[0, 1, 2].forEach((i) =>
  build(`gather_chop_${i + 1}`, [
    ['rpg/chop', { pitch: 0.75 + i * 0.06, lp: 3500, trim: 0.45, fadeOut: 0.1 }],
    [`impact/impactWood_heavy_00${i}`, { pitch: 0.8, lp: 1800, vol: 0.9, trim: 0.4, fadeOut: 0.15, delay: 0.01 }],
  ]));
[0, 1, 2].forEach((i) =>
  build(`gather_mine_${i + 1}`, [
    [`impact/impactMining_00${i}`, { pitch: 0.95 - i * 0.05, trim: 0.5, fadeOut: 0.12 }],
    [`impact/impactMetal_light_00${i}`, { pitch: 1.4, hp: 1500, vol: 0.28, trim: 0.4, fadeOut: 0.25, delay: 0.005 }],
  ]));
[0, 1].forEach((i) =>
  build(`gather_dig_${i + 1}`, [
    [`impact/footstep_snow_00${i + 1}`, { pitch: 0.7, lp: 3000, trim: 0.45, fadeOut: 0.15 }],
    [`impact/footstep_grass_00${i}`, { pitch: 0.65, lp: 2500, delay: 0.12, vol: 0.8, trim: 0.4, fadeOut: 0.15 }],
    [`impact/impactSoft_heavy_00${i}`, { pitch: 0.6, lp: 500, delay: 0.2, vol: 0.9, trim: 0.4, fadeOut: 0.15 }],
  ]));
[0, 1].forEach((i) =>
  build(`gather_splash_${i + 1}`, [
    [`scifi/slime_00${i}`, { pitch: 1.2 + i * 0.15, hp: 500, lp: 5000, trim: 0.5, fadeOut: 0.15 }],
    [N(`anoisesrc=d=0.5:c=pink:r=44100:s=${20 + i}`), { bp: 1400, bw: 1800, trim: 0.5, fadeIn: 0.02, fadeOut: 0.35, vol: 0.5 }],
    [`impact/impactSoft_medium_00${i}`, { pitch: 1.1, lp: 1200, vol: 0.5, trim: 0.3, fadeOut: 0.15 }],
  ]));
build('gather_reel_1', [
  ...[0, 1, 2, 3, 4, 5].map((k) => ['rpg/metalClick', { pitch: 1.6 - k * 0.03, hp: 900, lp: 5000, vol: 0.9, trim: 0.1, fadeOut: 0.02, delay: k * 0.075 }]),
  ['scifi/slime_001', { pitch: 1.3, hp: 500, lp: 5000, trim: 0.5, fadeOut: 0.15, delay: 0.5, vol: 0.7 }],
  [N('anoisesrc=d=0.5:c=pink:r=44100:s=23'), { bp: 1400, bw: 1800, trim: 0.5, fadeOut: 0.35, vol: 0.4, delay: 0.5 }],
]);
[0, 1].forEach((i) =>
  build(`gather_saw_${i + 1}`, [
    [`rpg/drawKnife${i + 1}`, { pitch: 0.62, lp: 3500, hp: 150, trim: 0.55, fadeIn: 0.05, fadeOut: 0.1 }],
    [`rpg/drawKnife${i + 2}`, { pitch: 0.58, lp: 3500, hp: 150, trim: 0.55, delay: 0.5, fadeIn: 0.05, fadeOut: 0.1, vol: 0.9 }],
    [N(`anoisesrc=d=1.1:c=white:r=44100:s=${30 + i}`), { bp: 2200, bw: 1500, trim: 1.05, vol: 0.14, fadeIn: 0.1, fadeOut: 0.4 }],
    [wood[i + 1], { pitch: 0.85, vol: 0.5, delay: 1.05, trim: 0.25, fadeOut: 0.1 }],
  ]));
[0, 1].forEach((i) =>
  build(`gather_kiln_${i + 1}`, [
    [`scifi/thrusterFire_00${i}`, { pitch: 0.6, lp: 1000, trim: 1.1, fadeIn: 0.15, fadeOut: 0.5, vol: 0.9 }],
    [wood[i], { pitch: 0.9, vol: 0.5, delay: 0.1, trim: 0.25, fadeOut: 0.1 }],
    [wood[i + 2], { pitch: 0.8, vol: 0.4, delay: 0.19, trim: 0.25, fadeOut: 0.1 }],
    [N(`aevalsrc=exprs='if(lt(random(1)\\,0.0012)\\,(random(2)*2-1)*1.5\\,0)':d=1.2:s=44100`), { hp: 1800, lp: 6000, vol: 0.6, trim: 1.2, fadeOut: 0.5 }],
  ]));
[0, 1].forEach((i) =>
  build(`gather_cook_${i + 1}`, [
    [N(`aevalsrc=exprs='(random(0)*2-1)*0.3+if(lt(random(1)\\,0.004)\\,(random(2)*2-1)*1.5\\,0)':d=1.2:s=44100`), { hp: 2500, lp: 9000, trim: 1.2, fadeIn: 0.05, fadeOut: 0.7, vol: 0.55 }],
    [`rpg/metalPot${i + 1}`, { pitch: 0.95, lp: 5000, vol: 0.7, trim: 0.5, fadeOut: 0.2 }],
  ]));
[0, 1].forEach((i) =>
  build(`gather_grind_${i + 1}`, [
    [`scifi/spaceEngineSmall_00${i}`, { pitch: 0.8, lp: 1100, hp: 90, trim: 1.1, fadeIn: 0.08, fadeOut: 0.35, vol: 0.8 }],
    ...[0, 1, 2, 3].map((k) => [wood[(k + i) % 5], { pitch: 0.7 + k * 0.03, lp: 2500, vol: 0.6, delay: 0.12 + k * 0.2, trim: 0.2, fadeOut: 0.08 }]),
    [`impact/footstep_concrete_00${i}`, { pitch: 0.6, lp: 1800, vol: 0.8, delay: 0.05, trim: 0.5, fadeOut: 0.2 }],
    ['rpg/metalLatch', { pitch: 0.8, vol: 0.5, delay: 1.0, trim: 0.3, fadeOut: 0.1 }],
  ]));
[0, 1].forEach((i) =>
  build(`gather_craft_${i + 1}`, [
    [`impact/impactMetal_light_00${i + 1}`, { pitch: 0.9, lp: 5000, trim: 0.45, fadeOut: 0.25 }],
    [`impact/impactWood_medium_00${i}`, { pitch: 0.9, vol: 0.7, delay: 0.01, lp: 2500, trim: 0.3, fadeOut: 0.1 }],
    ['rpg/metalClick', { pitch: 1.1, vol: 0.4, delay: 0.22, trim: 0.15, fadeOut: 0.05 }],
  ]));
build('gather_vault_open_1', [
  ['rpg/doorOpen_1', { pitch: 0.78, lp: 2800, trim: 0.9, fadeOut: 0.3 }],
  ['rpg/creak1', { pitch: 0.7, lp: 1800, vol: 0.6, trim: 0.8, fadeOut: 0.3 }],
  ['rpg/metalLatch', { pitch: 0.75, vol: 0.7, trim: 0.3, fadeOut: 0.1 }],
]);
build('gather_vault_close_1', [
  ['rpg/doorClose_1', { pitch: 0.75, lp: 2500, trim: 0.7, fadeOut: 0.25 }],
  ['impact/impactPlate_heavy_001', { pitch: 0.6, lp: 700, vol: 0.7, delay: 0.02, trim: 0.5, fadeOut: 0.25 }],
  ['rpg/metalLatch', { pitch: 0.7, vol: 0.6, delay: 0.1, trim: 0.3, fadeOut: 0.1 }],
]);

// ===================== necromancer rites =====================
[0, 1].forEach((i) =>
  build(`rite_frost_${i + 1}`, [
    [`impact/impactGlass_heavy_00${i}`, { rev: true, pitch: 1.2, hp: 800, trim: 0.5, vol: 0.5, fadeIn: 0.1 }],
    [`impact/impactGlass_medium_00${i + 1}`, { pitch: 1.3, hp: 1200, delay: 0.42, trim: 0.5, echo: 90, fadeOut: 0.25 }],
    [N(`anoisesrc=d=0.8:c=white:r=44100:s=${40 + i}`), { hp: 4500, lp: 9000, trim: 0.8, vol: 0.18, fadeOut: 0.5, delay: 0.3 }],
  ]));
[0, 1].forEach((i) =>
  build(`rite_siphon_${i + 1}`, [
    [`scifi/forceField_00${i + 1}`, { pitch: 0.7, lp: 2200, hp: 120, trim: 1.4, fadeIn: 0.2, fadeOut: 0.5, vol: 0.9 }],
    [`scifi/slime_00${i}`, { pitch: 0.6, lp: 900, delay: 0.1, trim: 0.5, vol: 0.7, fadeOut: 0.15 }],
  ], 'tremolo=f=7:d=0.45,'));
[0, 1].forEach((i) =>
  build(`rite_prison_${i + 1}`, [
    ...[0, 1, 2].map((k) => [`impact/impactWood_heavy_00${(k + i) % 5}`, { pitch: 0.75 + k * 0.08, lp: 2800, vol: 0.9 - k * 0.1, delay: k * 0.07, trim: 0.4, fadeOut: 0.15 }]),
    [`impact/impactPlate_heavy_00${i}`, { pitch: 0.55, lp: 700, delay: 0.16, vol: 0.9, trim: 0.6, fadeOut: 0.3 }],
  ]));
[0, 1].forEach((i) =>
  build(`rite_hands_${i + 1}`, [
    [`impact/footstep_snow_00${i + 2}`, { pitch: 0.55, lp: 2400, trim: 0.5, fadeOut: 0.2 }],
    [`scifi/slime_00${i}`, { pitch: 0.55, lp: 1000, vol: 0.8, delay: 0.1, trim: 0.5, fadeOut: 0.2 }],
    ...[0, 1, 2, 3].map((k) => [wood[(k + i) % 5], { pitch: 0.6 + k * 0.05, lp: 1800, vol: 0.5, delay: 0.2 + k * 0.09, trim: 0.2, fadeOut: 0.08 }]),
    ['rpg/cloth2', { pitch: 0.7, lp: 1800, vol: 0.5, delay: 0.15, trim: 0.5, fadeOut: 0.2 }],
  ]));
[0, 1].forEach((i) =>
  build(`rite_storm_${i + 1}`, [
    [`scifi/thrusterFire_00${i + 2}`, { pitch: 0.8, lp: 2600, hp: 200, trim: 1.4, fadeIn: 0.3, fadeOut: 0.6 }],
    ...[0, 1, 2, 3, 4, 5, 6].map((k) => [wood[(k * 2 + i) % 5], { pitch: 1.0 + (k % 3) * 0.12, hp: 400, vol: 0.45, delay: 0.1 + k * 0.15 + (k % 2) * 0.03, trim: 0.18, fadeOut: 0.07 }]),
  ], 'tremolo=f=9:d=0.35,'));
[0, 1].forEach((i) =>
  build(`rite_soul_${i + 1}`, [
    [`scifi/forceField_00${i + 3}`, { rev: true, pitch: 1.15, lp: 4000, trim: 0.7, fadeIn: 0.1, vol: 0.8 }],
    [`impact/impactBell_heavy_00${i + 2}`, { pitch: 0.85 + i * 0.15, lp: 3500, delay: 0.5, echo: 110, trim: 1.4, vol: 0.55, fadeOut: 0.6 }],
    [`scifi/lowFrequency_explosion_00${i}`, { pitch: 1.0, lp: 500, delay: 0.5, vol: 0.5, trim: 0.7, fadeOut: 0.4 }],
  ]));

// signatures
build('rite_wall_1', [['impact/impactPlate_heavy_002', { pitch: 0.55, lp: 1200, trim: 0.8, fadeOut: 0.3 }], ['impact/footstep_concrete_003', { pitch: 0.55, lp: 1500, vol: 0.8, delay: 0.1, trim: 0.5, fadeOut: 0.2 }], ['scifi/spaceEngineLow_003', { lp: 170, trim: 1.0, vol: 0.6, fadeOut: 0.5 }]]);
build('rite_rend_1', [['rpg/knifeSlice', { pitch: 0.7, lp: 4500, trim: 0.4, fadeOut: 0.1 }], ['rpg/cloth3', { pitch: 0.55, lp: 3000, vol: 0.9, delay: 0.05, trim: 0.5, fadeOut: 0.2 }], [wood[2], { pitch: 0.7, delay: 0.2, vol: 0.7, trim: 0.25, fadeOut: 0.1 }]]);
build('rite_dirge_1', [['impact/impactBell_heavy_003', { pitch: 0.45, lp: 1800, echo: 180, trim: 1.5, fadeOut: 0.7 }], ['scifi/forceField_000', { pitch: 0.65, lp: 1500, hp: 100, delay: 0.1, vol: 0.5, trim: 1.0, fadeIn: 0.2, fadeOut: 0.4 }]], 'apad=pad_dur=0.5,');
build('rite_bloom_1', [['scifi/slime_000', { pitch: 0.8, lp: 2000, trim: 0.5, fadeOut: 0.15 }], [N('anoisesrc=d=0.9:c=pink:r=44100:s=51'), { bp: 700, bw: 900, trim: 0.9, vol: 0.3, fadeIn: 0.1, fadeOut: 0.5, delay: 0.1 }], ['scifi/computerNoise_002', { lp: 700, vol: 0.3, trim: 0.8, delay: 0.1, fadeOut: 0.4 }]]);

// other classes (bonus)
[0, 1].forEach((i) =>
  build(`rite_chain_${i + 1}`, [0, 1, 2, 3].map((k) => [`impact/impactMetal_light_00${(k + i * 2) % 5}`, { pitch: 1.35 - k * 0.07, hp: 700, lp: 6000, vol: 0.8 - k * 0.1, delay: k * 0.05, trim: 0.3, fadeOut: 0.15 }])));
[0, 1].forEach((i) =>
  build(`rite_flail_${i + 1}`, [
    [`scifi/thrusterFire_00${i}`, { pitch: 1.1, hp: 500, lp: 4500, trim: 0.3, fadeIn: 0.08, fadeOut: 0.12, vol: 0.5 }],
    [`impact/impactMetal_medium_00${i}`, { pitch: 0.9, lp: 3500, delay: 0.12, trim: 0.4, vol: 0.8, fadeOut: 0.2 }],
  ]));
build('rite_palm_1', [['impact/impactPunch_heavy_001', { pitch: 0.85, lp: 1400, trim: 0.4, fadeOut: 0.15 }], ['impact/impactBell_heavy_001', { pitch: 1.5, lp: 4000, vol: 0.3, delay: 0.02, trim: 0.9, echo: 80, fadeOut: 0.5 }]]);
build('rite_pyre_1', [['scifi/thrusterFire_004', { pitch: 0.65, lp: 1600, hp: 100, trim: 0.9, fadeIn: 0.15, fadeOut: 0.4 }], ['scifi/lowFrequency_explosion_001', { pitch: 1.1, lp: 450, delay: 0.1, vol: 0.7, trim: 0.7, fadeOut: 0.3 }], [N(`aevalsrc=exprs='if(lt(random(1)\\,0.0015)\\,(random(2)*2-1)*1.5\\,0)':d=0.8:s=44100`), { hp: 2000, vol: 0.5, trim: 0.8, fadeOut: 0.4, delay: 0.2 }]]);
build('rite_ward_1', [['impact/impactPlate_light_001', { pitch: 1.0, lp: 4000, trim: 0.5, fadeOut: 0.2 }], ['scifi/forceField_002', { pitch: 0.9, lp: 3000, trim: 0.7, delay: 0.05, vol: 0.6, fadeOut: 0.3 }], ['impact/impactBell_heavy_002', { pitch: 1.0, lp: 3000, vol: 0.3, delay: 0.05, trim: 0.9, fadeOut: 0.5 }]]);
build('rite_choir_1', [0.8, 1.0, 1.2].map((p, k) => [`impact/impactBell_heavy_00${k}`, { pitch: p, lp: 3000, hp: 150, delay: k * 0.05, vol: 0.55, trim: 1.2, echo: 120, fadeOut: 0.5 }]).concat([['scifi/forceField_001', { pitch: 0.8, lp: 2200, vol: 0.4, trim: 0.9, fadeIn: 0.2, fadeOut: 0.4 }]]));
build('rite_blood_1', [['scifi/slime_001', { pitch: 0.65, lp: 1400, trim: 0.5, fadeOut: 0.15 }], ['impact/impactPunch_medium_003', { pitch: 0.75, lp: 1200, vol: 0.8, delay: 0.1, trim: 0.4, fadeOut: 0.15 }]]);
build('rite_spirit_1', [['scifi/forceField_001', { pitch: 1.15, lp: 5000, hp: 250, trim: 0.5, fadeIn: 0.03, fadeOut: 0.2 }], ['scifi/laserSmall_001', { pitch: 0.8, lp: 4000, vol: 0.25, trim: 0.3, fadeOut: 0.1 }]]);

// ===================== interface =====================
build('ui_open_1', [['rpg/bookOpen', { pitch: 1.05, lp: 4500, hp: 200, trim: 0.28, fadeIn: 0.01, fadeOut: 0.1, vol: 0.9 }]]);
build('ui_open_2', [['rpg/bookFlip1', { pitch: 0.95, lp: 4500, hp: 200, trim: 0.25, fadeOut: 0.1 }]]);
build('ui_close_1', [['rpg/bookClose', { pitch: 1.0, lp: 3800, hp: 200, trim: 0.25, fadeOut: 0.1 }]]);
build('ui_close_2', [['rpg/bookPlace1', { pitch: 1.05, lp: 3800, hp: 200, trim: 0.22, fadeOut: 0.1 }]]);
[0, 1].forEach((i) =>
  build(`ui_equip_${i + 1}`, [
    [`rpg/clothBelt${i ? '2' : ''}`, { pitch: 1.0, lp: 3500, trim: 0.3, fadeOut: 0.1, vol: 0.9 }],
    [`impact/impactPlate_light_00${i}`, { pitch: 1.1, lp: 3500, delay: 0.08, vol: 0.55, trim: 0.3, fadeOut: 0.15 }],
  ]));
build('ui_level_1', [0.9, 1.12, 1.5].map((p, k) => [`impact/impactBell_heavy_00${k}`, { pitch: p, lp: 4500, hp: 200, delay: k * 0.11, vol: 0.55, trim: 1.4, echo: 140, fadeOut: 0.8 }]).concat([['scifi/forceField_004', { pitch: 1.1, lp: 4500, trim: 1.0, vol: 0.35, fadeIn: 0.3, fadeOut: 0.5 }]]));
build('ui_loot_rare_1', [['impact/impactGlass_light_001', { pitch: 1.55, lp: 7000, echo: 160, trim: 0.7, fadeOut: 0.4 }], ['impact/impactBell_heavy_000', { pitch: 1.4, lp: 3500, vol: 0.28, delay: 0.03, trim: 0.9, fadeOut: 0.5 }]]);
build('ui_loot_epic_1', [['impact/impactBell_heavy_001', { pitch: 1.0, lp: 4000, echo: 150, trim: 1.4, fadeOut: 0.7 }], ['impact/impactGlass_light_003', { pitch: 1.5, lp: 7500, delay: 0.1, vol: 0.5, echo: 170, trim: 0.8, fadeOut: 0.5 }], ['scifi/forceField_003', { pitch: 0.9, lp: 3000, vol: 0.35, trim: 1.0, fadeIn: 0.2, fadeOut: 0.5 }]]);

// ===================== ambient one-shots =====================
[0, 1, 2].forEach((i) =>
  build(`amb_bell_${i + 1}`, [['impact/impactBell_heavy_00' + i, { pitch: 0.62 - i * 0.05, lp: 1300, hp: 80, echo: '280|520', trim: 1.5, fadeOut: 0.8 }]], 'apad=pad_dur=0.8,'));
[['impactGlass_light_000', 0.85], ['impactTin_medium_001', 1.2], ['impactGlass_light_002', 1.0], ['impactTin_medium_003', 0.9]].forEach(([src, p], i) =>
  build(`amb_drip_${i + 1}`, [[`impact/${src}`, { pitch: p, hp: 500, lp: 5000, trim: 0.22, fadeOut: 0.12, echo: '110|230' }]]));
[0, 1, 2].forEach((i) =>
  build(`amb_ember_${i + 1}`, [[N(`aevalsrc=exprs='if(lt(random(1)\\,${0.0008 + i * 0.0004})\\,(random(2)*2-1)*1.8\\,0)':d=1.4:s=44100`), { hp: 1800 + i * 600, lp: 8000, trim: 1.4, fadeIn: 0.1, fadeOut: 0.7 }]]));
[0, 1, 2].forEach((i) =>
  build(`amb_bubble_${i + 1}`, [[`scifi/slime_00${i % 2}`, { pitch: 0.5 + i * 0.1, lp: 900, hp: 90, trim: 0.4, fadeOut: 0.15, echo: 140 }]]));
[0, 1].forEach((i) =>
  build(`amb_dust_${i + 1}`, [0, 1, 2, 3, 4, 5].map((k) => [`impact/impactGeneric_light_00${(k + i) % 5}`, { pitch: 1.4 + (k % 3) * 0.2, lp: 3000, hp: 600, vol: 0.4 - k * 0.04, delay: k * 0.09 + (k % 2) * 0.04, trim: 0.12, fadeOut: 0.05 }])));
[0, 1].forEach((i) =>
  build(`amb_moan_${i + 1}`, [[N(`anoisesrc=d=3.2:c=pink:r=44100:s=${60 + i}`), { bp: 330 + i * 70, bw: 220, trim: 3.2, vol: 1, fadeIn: 1.2, fadeOut: 1.4 }]], 'vibrato=f=4.5:d=0.35,tremolo=f=0.7:d=0.5,aecho=0.6:0.5:200|400:0.35|0.2,'));
[0, 1].forEach((i) =>
  build(`amb_gust_${i + 1}`, [[N(`anoisesrc=d=3.6:c=brown:r=44100:s=${70 + i}`), { bp: 500 + i * 220, bw: 700, trim: 3.6, fadeIn: 1.5, fadeOut: 1.7 }]]));
// Crow caw: a swept, harmonic-rich buzz with a rasp, synthesised outright (no source recording).
[[0.32, 700, 380, 90], [0.26, 820, 450, 110]].forEach(([d, f0, f1, am], i) => {
  const ph = `2*PI*(${f0}*t-(${f0 - f1})*t*t/(2*${d}))`;
  const body = [1, 2, 3, 4, 5].map((h) => `${(1 / h).toFixed(3)}*sin(${h}*${ph})`).join('+');
  build(`amb_crow_${i + 1}`, [[N(`aevalsrc=exprs='(${body})*(0.55+0.45*sin(2*PI*${am}*t))*pow(sin(PI*t/${d})\\,0.6)':d=${d}:s=44100`), { bp: 1300, bw: 1800, trim: d }]]);
});
console.log('done');
