#!/usr/bin/env node
// The part of build-sound.sh that runs inside its sandbox: turns a raw ElevenLabs take into the game's file at the game's loudness and writes
// its row in docs/AUDIO-SOURCES.md, the licence record.   node sound-build.mjs <id> <take> <sfx|music>   (from the worktree root)
//   sfx    client/assets/audio/eleven/<id>.wav   mono 16-bit 44.1 kHz (one-shots start for free as QOA, like esm/; see client/audio/README.md)
//   music  client/assets/audio/eleven/<id>.mp3   stereo MP3 (Godot imports MP3); a take already at the target is copied as it is
// Loudness (EBU R128, measured with ffmpeg's loudnorm): every sound at -20 LUFS (the score's tracks measure -18.4 to -20.5, the pack's effects
// -16 to -24), true peak at most -1.5 dBTP. A plain gain, never compression: a take whose peak would pass -1.5 dBTP stops at that peak and
// stays quieter (the output says so); a take too quiet to measure is kept as generated. The game sets each sound's mix level (audioMap.json).
import { execFileSync, spawnSync } from 'node:child_process';
import { copyFileSync, existsSync, lstatSync, mkdtempSync, mkdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';

export const TARGET_LUFS = -20;
export const PEAK_DBTP = -1.5;
export const DOC = 'docs/AUDIO-SOURCES.md';
export const SECTION = '## Discord agent sounds';

// The gain that brings a take to the target, held back where its true peak would pass the ceiling; null when it cannot be measured.
export function gainFor(m, target = TARGET_LUFS, peak = PEAK_DBTP) {
  if (!m || !Number.isFinite(m.i) || m.i < -70 || !Number.isFinite(m.tp)) return null;
  const want = target - m.i;
  const gain = Math.min(want, peak - m.tp);
  return { gain, limited: gain < want - 0.05, i: m.i + gain, tp: m.tp + gain };
}

// loudnorm's measurement: the JSON block it prints at the end of the run.
export function parseLoudnorm(stderr) {
  const at = stderr.lastIndexOf('{');
  if (at < 0) return null;
  try {
    const j = JSON.parse(stderr.slice(at, stderr.indexOf('}', at) + 1));
    return { i: Number(j.input_i), tp: Number(j.input_tp) };
  } catch { return null; }
}

// Puts the sound's row into the doc's agent table, in place of its earlier row (a rebuild from another take) or after the table's last row.
export function recordRow(doc, file, row) {
  const lines = doc.split('\n');
  const own = lines.findIndex((l) => l.startsWith(`| \`${file}\` |`));
  if (own >= 0) { lines[own] = row; return lines.join('\n'); }
  const head = lines.findIndex((l) => l.startsWith(SECTION));
  if (head < 0) throw new Error(`${DOC} has no "${SECTION}" section`);
  let last = -1;
  for (let i = head + 1; i < lines.length && !lines[i].startsWith('## '); i++) if (lines[i].startsWith('|')) last = i;
  if (last < 0) throw new Error(`the "${SECTION}" section of ${DOC} has no table`);
  lines.splice(last + 1, 0, row);
  return lines.join('\n');
}

// ffmpeg prints its measurement and its errors on stderr
function ffmpeg(args) {
  const r = spawnSync('ffmpeg', ['-nostdin', '-hide_banner', ...args], { encoding: 'utf8', maxBuffer: 16 << 20 });
  if (r.status !== 0) throw new Error(`ffmpeg failed: ${String(r.stderr || (r.error && r.error.message) || '').trim().split('\n').slice(-3).join(' / ')}`);
  return r.stderr || '';
}

const measure = (file) => parseLoudnorm(ffmpeg(['-i', file, '-af', `loudnorm=I=${TARGET_LUFS}:TP=${PEAK_DBTP}:print_format=json`, '-f', 'null', '-']));

function main() {
  const [id, take, kind] = process.argv.slice(2);
  if (!/^[a-z0-9_]{3,40}$/.test(id || '') || !/^[1-4]$/.test(take || '') || !['sfx', 'music'].includes(kind)) {
    console.error('usage: sound-build.mjs <id> <take 1-4> <sfx|music>'); process.exit(2);
  }
  const src = `audio-src/eleven/${id}/v${take}.mp3`;
  const dst = `client/assets/audio/eleven/${id}.${kind === 'music' ? 'mp3' : 'wav'}`;
  if (!existsSync(DOC) || lstatSync(DOC).isSymbolicLink()) throw new Error(`${DOC} is missing or a symlink`);
  mkdirSync(path.dirname(dst), { recursive: true });
  const tmp = mkdtempSync(path.join(os.tmpdir(), 'dmsound-'));
  let level;
  try {
    // effects are measured as the mono file the game plays; music as it is
    const work = kind === 'music' ? src : path.join(tmp, 'mono.wav');
    if (kind !== 'music') ffmpeg(['-y', '-i', src, '-ac', '1', '-ar', '44100', '-c:a', 'pcm_f32le', work]);
    level = gainFor(measure(work));
    const gain = level ? level.gain : 0;
    if (kind === 'music' && Math.abs(gain) < 0.5) copyFileSync(src, dst);
    else if (kind === 'music') ffmpeg(['-y', '-i', src, '-af', `volume=${gain.toFixed(2)}dB`, '-c:a', 'libmp3lame', '-q:a', '2', dst]);
    else ffmpeg(['-y', '-i', work, '-af', `volume=${gain.toFixed(2)}dB`, '-c:a', 'pcm_s16le', dst]);
  } finally { rmSync(tmp, { recursive: true, force: true }); }
  const made = statSync(src).mtime.toISOString().slice(0, 10);
  const source = kind === 'music' ? 'ElevenLabs Music' : 'ElevenLabs Sound Effects';
  const row = `| \`${dst}\` | ${source}, take ${take}, ${made} | [${id}.json](../audio-manifest/eleven/${id}.json) |`;
  writeFileSync(DOC, recordRow(readFileSync(DOC, 'utf8'), dst, row));
  const seconds = execFileSync('ffprobe', ['-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', dst], { encoding: 'utf8' }).trim();
  const how = !level ? 'too quiet to measure, kept as generated'
    : `${level.i.toFixed(1)} LUFS, peak ${level.tp.toFixed(1)} dBTP${level.limited ? `: held at the peak ceiling, ${(TARGET_LUFS - level.i).toFixed(1)} dB under the target` : ''}`;
  console.log(`${dst} ${seconds} s, ${how}`);
  console.log(`RECORDED: ${DOC} (commit it with the sound)`);
  console.log(`BUILT: ${dst}`);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  try { main(); } catch (e) { console.error(`build-sound: ${e.message}`); process.exit(1); }
}
