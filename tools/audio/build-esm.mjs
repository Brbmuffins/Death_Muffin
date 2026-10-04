#!/usr/bin/env node
/**
 * Builds public/audio/esm/<folder>__<clip>.opus from the owner-licensed Epic Stock Media "Fantasy Game" library
 * (docs/AUDIO-SOURCES.md). The source WAVs are NOT in the repository and never leave the owner's machine: only the
 * trimmed, encoded clips the game plays are committed.
 *
 *   nice -n 19 node tools/audio/build-esm.mjs [--src <dir>] [--check]
 *
 * <dir> defaults to $ESM_SRC or /home/ubuntu/death-muffin/audio-src/fantasy-game and holds the pack's Actions/,
 * Attacks_and_Creatures/, Crafting/, Elemental_Magic/, Footsteps/, Items/ and UI/ folders.
 *
 * What is built is read from src/content/audioMap.ts (every clip named by a SoundDef, layers included) and the pack
 * rules in src/audio/packs.ts, so the map and the shipped files cannot drift. Per clip:
 *   mono, 48 kHz; leading silence trimmed (-48 dB); cut to the longest length any sound using it needs (SoundDef.trim.maxMs,
 *   else a per-kind cap: decoded audio costs memory); cast and hit clips start at their impact (<= 0.16 s after the start) so the
 *   sound lands with the VFX release, build-ups (boss tells, Litany, deaths, stations, ambience) keep their start; 2 ms fade-in,
 *   tail fade; RMS-normalised to the class target (sfx -19, ui -21, foot -25, amb -26 dBFS, active samples only) with a peak
 *   ceiling; Ogg Opus, 48 kbps VBR. Deterministic for a given ffmpeg (fixed Ogg serial, bitexact flags).
 * Writes public/audio/esm/manifest.json (sizes, lengths, skip, loudness) and docs/audio/esm-sanity-report.txt: an objective
 * pass over every pick (length, loudness, true peak, leading silence, clipping, impact time) that flags outliers, because the
 * map was made from names, not by ear. Needs ffmpeg with libopus. --check only verifies that every name resolves.
 */
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdirSync, readdirSync, readFileSync, writeFileSync, rmSync, statSync } from 'node:fs';
import { join, resolve, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { buildSync } from 'esbuild';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const args = process.argv.slice(2);
const opt = (name) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : undefined; };
const SRC = resolve(opt('--src') ?? process.env.ESM_SRC ?? '/home/ubuntu/death-muffin/audio-src/fantasy-game');
const CHECK = args.includes('--check');
const OUT = join(ROOT, 'public/audio/esm');
const RATE = 48000;
const TARGET_RMS = { sfx: -19, ui: -21, foot: -25, amb: -26 };
const PEAK_CEIL_DB = -2;
const PEAK_OVER_DB = 4; // the limiter takes the last few dB of a spiky transient
const MAX_BOOST_DB = 20;
const BITRATE = '48k';
const PK = 0.16;
const SILENCE = 0.004; // -48 dB

// Load the map and the pack rules (TypeScript) by bundling them to a temp module.
const bundle = join(tmpdir(), `esm-map-${process.pid}.mjs`);
const entry = join(tmpdir(), `esm-entry-${process.pid}.ts`);
writeFileSync(entry, `export { AUDIO_MAP } from ${JSON.stringify(join(ROOT, 'src/content/audioMap.ts'))};\nexport { packOf, keepsStart, capSeconds } from ${JSON.stringify(join(ROOT, 'src/audio/packs.ts'))};\n`);
buildSync({ entryPoints: [entry], bundle: true, format: 'esm', platform: 'node', outfile: bundle, logLevel: 'error' });
const { AUDIO_MAP, packOf, keepsStart, capSeconds } = await import(pathToFileURL(bundle).href);
rmSync(bundle, { force: true });
rmSync(entry, { force: true });

// Index the source library: "<folder>/<stem without ESM_Fantasy_Game_>" -> absolute path.
const index = new Map();
for (const folder of readdirSync(SRC, { withFileTypes: true })) {
  if (!folder.isDirectory()) continue; // the pack's images, rtf and demo track stay out
  for (const f of readdirSync(join(SRC, folder.name))) {
    if (f.endsWith('.wav')) index.set(`${folder.name}/${f.slice(0, -4).replace(/^ESM_Fantasy_Game_/, '')}`, join(SRC, folder.name, f));
  }
}
const fileOf = (name) => `${name.replace(/\//g, '__')}.opus`;

// Every clip and the sounds that use it.
const clips = new Map();
for (const [id, def] of Object.entries(AUDIO_MAP)) {
  const add = (name, layer) => {
    if (!clips.has(name)) clips.set(name, []);
    clips.get(name).push({ id, def, layer });
  };
  def.files.forEach((n) => add(n, false));
  def.layer?.files.forEach((n) => add(n, true));
}
const missing = [...clips.keys()].filter((n) => !index.has(n));
if (missing.length) { console.error(`missing source clips:\n  ${missing.join('\n  ')}`); process.exit(1); }
if (CHECK) { console.log(`ok: ${clips.size} clips resolve (${Object.keys(AUDIO_MAP).length} sounds)`); process.exit(0); }

const capOf = (u) => capSeconds(u.id, u.layer);

const ffmpeg = (a) => execFileSync('ffmpeg', ['-y', '-v', 'error', '-nostdin', ...a], { stdio: ['ignore', 'ignore', 'inherit'] });
function readWav(file) {
  const b = readFileSync(file);
  let p = 12;
  while (p < b.length - 8) {
    const id = b.toString('ascii', p, p + 4);
    const size = b.readUInt32LE(p + 4);
    if (id === 'data') {
      p += 8;
      const end = size === 0xffffffff || p + size > b.length ? b.length : p + size;
      return new Float32Array(b.buffer.slice(b.byteOffset + p, b.byteOffset + end - ((end - p) % 4)));
    }
    p += 8 + size + (size & 1);
  }
  throw new Error('no data chunk');
}
function writeWav(file, s) {
  const data = Buffer.from(s.buffer, s.byteOffset, s.byteLength);
  const h = Buffer.alloc(44);
  h.write('RIFF', 0); h.writeUInt32LE(36 + data.length, 4); h.write('WAVEfmt ', 8); h.writeUInt32LE(16, 16);
  h.writeUInt16LE(3, 20); h.writeUInt16LE(1, 22); h.writeUInt32LE(RATE, 24); h.writeUInt32LE(RATE * 4, 28); h.writeUInt16LE(4, 32); h.writeUInt16LE(32, 34);
  h.write('data', 36); h.writeUInt32LE(data.length, 40);
  writeFileSync(file, Buffer.concat([h, data]));
}
const db = (x) => 20 * Math.log10(Math.max(x, 1e-9));
function peakOf(s) { let m = 0; for (let i = 0; i < s.length; i++) { const v = Math.abs(s[i]); if (v > m) m = v; } return m; }
/** RMS over the samples within 40 dB of the peak (so a long quiet tail does not pull the level up). */
function activeRms(s) {
  const floor = peakOf(s) * 0.01;
  let q = 0, n = 0;
  for (let i = 0; i < s.length; i++) if (Math.abs(s[i]) >= floor) { q += s[i] * s[i]; n++; }
  return n ? Math.sqrt(q / n) : 0;
}
/** First 10 ms frame within 6 dB of the loudest frame in [from, from+win): the clip's impact time. */
function onsetOf(s, from, win) {
  const f = Math.round(RATE * 0.01);
  const a = Math.round(from * RATE);
  const b = Math.min(s.length, a + Math.round(win * RATE));
  const env = [];
  for (let i = a; i + f <= b; i += f) { let q = 0; for (let j = i; j < i + f; j++) q += s[j] * s[j]; env.push(Math.sqrt(q / f)); }
  const m = Math.max(0, ...env);
  const k = env.findIndex((v) => v >= m * 0.5);
  return k < 0 ? 0 : (k * f) / RATE;
}
function clippedRun(s) { let run = 0, worst = 0; for (let i = 0; i < s.length; i++) { if (Math.abs(s[i]) >= 0.999) { run++; worst = Math.max(worst, run); } else run = 0; } return worst; }

mkdirSync(OUT, { recursive: true });
const tmp = join(tmpdir(), `esm-build-${process.pid}`);
mkdirSync(tmp, { recursive: true });
const rows = [];
let n = 0;
for (const [name, users] of [...clips.entries()].sort(([a], [b]) => (a < b ? -1 : 1))) {
  const raw = join(tmp, 'raw.wav');
  ffmpeg(['-i', index.get(name), '-af', `aformat=channel_layouts=mono,aresample=${RATE}`, '-c:a', 'pcm_f32le', raw]);
  const src = readWav(raw);
  const srcPeak = peakOf(src);
  const lead = (() => { for (let i = 0; i < src.length; i++) if (Math.abs(src[i]) >= SILENCE) return i / RATE; return src.length / RATE; })();
  const start0 = Math.max(0, lead - 0.004);
  const userStart = Math.min(...users.map((u) => (u.def.trim?.startMs ?? 0) / 1000));
  const cap = Math.max(...users.map(capOf));
  const align = users.every((u) => !keepsStart(u.id) && !(u.def.trim?.startMs)) && !users.some((u) => u.layer);
  const base = start0 + userStart;
  const impact = onsetOf(src, base, cap);
  const skip = align ? Math.max(0, impact - PK) : 0;
  const from = Math.round((base + skip) * RATE);
  const len = Math.min(src.length - from, Math.round(cap * RATE));
  const cut = Float32Array.from(src.subarray(from, from + Math.max(len, 0)));
  const dur = cut.length / RATE;
  const fi = Math.round(RATE * (skip > 0 ? 0.006 : 0.002));
  const fo = Math.round(RATE * Math.min(0.3, Math.max(0.04, dur * 0.25)));
  for (let i = 0; i < Math.min(fi, cut.length); i++) cut[i] *= i / fi;
  for (let i = 0; i < Math.min(fo, cut.length); i++) cut[cut.length - 1 - i] *= i / fo;
  const cls = users.some((u) => u.id.startsWith('step')) ? 'foot' : users.every((u) => u.def.bus === 'ambience') ? 'amb' : users.every((u) => u.def.bus === 'ui') ? 'ui' : 'sfx';
  const rms = activeRms(cut);
  const peak = peakOf(cut);
  let gain = Math.min(TARGET_RMS[cls] - db(rms), MAX_BOOST_DB, PEAK_CEIL_DB + PEAK_OVER_DB - db(peak));
  if (!Number.isFinite(gain)) gain = 0;
  const g = Math.pow(10, gain / 20);
  for (let i = 0; i < cut.length; i++) cut[i] *= g;
  const wav = join(tmp, 'cut.wav');
  writeWav(wav, cut);
  const outFile = join(OUT, fileOf(name));
  ffmpeg(['-i', wav, '-af', `alimiter=limit=${Math.pow(10, PEAK_CEIL_DB / 20).toFixed(3)}:attack=1:release=20:level=disabled`, '-ac', '1', '-ar', String(RATE),
    '-c:a', 'libopus', '-b:a', BITRATE, '-vbr', 'on', '-application', 'audio', '-frame_duration', '20',
    '-fflags', '+bitexact', '-flags:a', '+bitexact', '-serial_offset', '1', outFile]);
  // Loudness of what ships (EBU R128 integrated reads -70 for clips under 0.4 s: the gated measure needs a long clip).
  const ebu = spawnSync('ffmpeg', ['-hide_banner', '-nostdin', '-i', outFile, '-af', 'ebur128=peak=true', '-f', 'null', '-'], { encoding: 'utf8' }).stderr;
  const sum = ebu.slice(ebu.lastIndexOf('Summary'));
  const lufs = Number(/I:\s+(-?[\d.]+) LUFS/.exec(sum)?.[1]);
  const tp = Number(/Peak:\s+(-?[\d.]+) dBFS/.exec(sum)?.[1]);
  rows.push({
    clip: name, file: fileOf(name), pack: [...new Set(users.map((u) => packOf(u.id)))].join('+'), users: users.map((u) => u.id),
    bytes: statSync(outFile).size, dur: +dur.toFixed(3), srcDur: +(src.length / RATE).toFixed(2), skip: +skip.toFixed(3), cls,
    srcPeakDb: +db(srcPeak).toFixed(1), srcLead: +lead.toFixed(3), clipRun: clippedRun(src), gainDb: +gain.toFixed(1),
    impact: +onsetOf(cut, 0, dur).toFixed(3), lufs: Number.isFinite(lufs) ? lufs : null, tpDb: Number.isFinite(tp) ? tp : null,
  });
  if (++n % 50 === 0) console.log(`  ${n}/${clips.size}`);
}
rmSync(tmp, { recursive: true, force: true });

// ---- the objective sanity pass: flag picks that look wrong so they can be swapped before shipping ----
const flags = [];
const minCooldown = (r) => Math.min(...r.users.map((id) => AUDIO_MAP[id].cooldownMs));
for (const r of rows) {
  const f = [];
  if (r.srcPeakDb < -30) f.push(`near-silent source (peak ${r.srcPeakDb} dBFS)`);
  if (r.gainDb > 14) f.push(`needed +${r.gainDb} dB to reach the class level (quiet source)`);
  if (r.gainDb < -14) f.push(`${r.gainDb} dB cut (very loud source)`);
  if (r.clipRun >= 3) f.push(`source clips (${r.clipRun} samples at full scale in a row)`);
  if (r.srcPeakDb > -0.1) f.push('source peaks at 0 dBFS');
  if (r.srcLead > 0.15) f.push(`long leading silence (${r.srcLead}s, trimmed)`);
  if (r.dur < 0.08) f.push(`very short (${r.dur}s)`);
  if (r.dur > 2.0 && minCooldown(r) <= 150 && !r.users.some((id) => AUDIO_MAP[id].loopMs)) f.push(`${r.dur}s clip on a fast-repeat id (cooldown ${minCooldown(r)} ms)`);
  if (r.impact > 0.5 && r.cls === 'sfx' && !r.users.every((id) => keepsStart(id))) f.push(`impact ${r.impact}s after the start (reads late)`);
  if (r.lufs !== null && r.dur >= 0.45 && r.lufs > -9) f.push(`hot (${r.lufs} LUFS)`);
  if (r.tpDb !== null && r.tpDb > -0.5) f.push(`true peak ${r.tpDb} dBFS`);
  if (r.srcDur > 8 && r.dur >= 2.9) f.push(`only the first ${r.dur}s of a ${r.srcDur}s source is used`);
  if (f.length) flags.push({ clip: r.clip, users: r.users.join(','), f });
}
const lines = [
  '# Generated by tools/audio/build-esm.mjs: objective checks on every clip the map names (the picks were made by name, not by ear).',
  `# ${rows.length} clips, ${flags.length} flagged. "users" = the sound ids that play the clip.`, '',
  ...flags.map((x) => `${x.clip}\n    users: ${x.users}\n${x.f.map((t) => `    - ${t}`).join('\n')}`),
];
mkdirSync(join(ROOT, 'docs/audio'), { recursive: true });
writeFileSync(join(ROOT, 'docs/audio/esm-sanity-report.txt'), lines.join('\n') + '\n');

const packs = {};
for (const r of rows) for (const p of r.pack.split('+')) { packs[p] ??= { clips: 0, bytes: 0 }; packs[p].clips++; packs[p].bytes += r.bytes / r.pack.split('+').length; }
const total = rows.reduce((s, r) => s + r.bytes, 0);
const decoded = rows.reduce((s, r) => s + r.dur, 0);
writeFileSync(join(OUT, 'manifest.json'), JSON.stringify({ format: 'ogg-opus', rate: RATE, bitrate: BITRATE, totalBytes: total, decodedSeconds: +decoded.toFixed(1), packs, clips: rows }, null, 1) + '\n');
console.log(`built ${rows.length} clips; ${(total / 1048576).toFixed(2)} MB on disk, ${decoded.toFixed(0)} s decoded (~${((decoded * RATE * 4) / 1048576).toFixed(0)} MB if every pack were loaded)`);
for (const [p, v] of Object.entries(packs).sort()) console.log(`  ${p.padEnd(14)} ${String(v.clips).padStart(3)} clips ${(v.bytes / 1024).toFixed(0).padStart(5)} KB`);
console.log(`${flags.length} clips flagged: docs/audio/esm-sanity-report.txt`);
