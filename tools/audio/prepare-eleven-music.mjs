#!/usr/bin/env node
// Turn a private Eleven Music draft into a compact, softly crossfaded game loop.
import { readdir, readFile, mkdir } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { homedir } from 'node:os';
import { join } from 'node:path';

const cue = process.argv[2];
const allowed = new Set(['chapterhouse', 'graves', 'ossuary', 'pyre', 'boss']);
if (!allowed.has(cue) || process.argv.length !== 3) {
  console.error(`Usage: node tools/audio/prepare-eleven-music.mjs <${[...allowed].join('|')}>`);
  process.exit(1);
}
const draftDir = join(homedir(), 'death-muffin/private/music-drafts');
const files = (await readdir(draftDir)).filter((name) => name.startsWith(`${cue}-`) && name.endsWith('.mp3')).sort();
const source = join(draftDir, files.at(-1) || '');
if (!files.length) throw new Error(`No private ${cue} draft found in ${draftDir}`);
const metadata = JSON.parse(await readFile(source.replace(/\.mp3$/, '.json'), 'utf8'));
if (metadata.cueId !== cue || metadata.status !== 'private-audition-only' || !metadata.songId) {
  throw new Error(`Draft metadata is incomplete: ${source}`);
}
const probe = spawnSync('ffprobe', ['-v', 'error', '-show_entries', 'format=duration', '-of', 'default=noprint_wrappers=1:nokey=1', source], { encoding: 'utf8' });
if (probe.status !== 0) throw new Error(probe.stderr || 'ffprobe failed');
const duration = Number(probe.stdout.trim());
const overlap = 5;
if (!Number.isFinite(duration) || duration < overlap * 3) throw new Error(`Draft too short: ${duration}s`);
const analysis = spawnSync('ffmpeg', ['-hide_banner', '-nostats', '-i', source, '-af', 'loudnorm=I=-20:TP=-2:LRA=11:print_format=json', '-f', 'null', '-'], { encoding: 'utf8' });
if (analysis.status !== 0) throw new Error(analysis.stderr || 'loudness analysis failed');
const inputI = Number(/"input_i"\s*:\s*"([^\"]+)"/.exec(analysis.stderr)?.[1]);
const inputTp = Number(/"input_tp"\s*:\s*"([^\"]+)"/.exec(analysis.stderr)?.[1]);
if (!Number.isFinite(inputI) || !Number.isFinite(inputTp)) throw new Error('Could not measure source loudness');
const targetI = cue === 'boss' ? -18 : -20;
const gainDb = Math.min(targetI - inputI, -2.5 - inputTp);
const tail = (duration - overlap).toFixed(3);
const filter = [
  `[0:a]atrim=start=${tail}:end=${duration.toFixed(3)},asetpts=PTS-STARTPTS[tail]`,
  `[0:a]atrim=start=0:end=${overlap},asetpts=PTS-STARTPTS[head]`,
  `[tail][head]acrossfade=d=${overlap}:c1=tri:c2=tri[seam]`,
  `[0:a]atrim=start=${overlap}:end=${tail},asetpts=PTS-STARTPTS[middle]`,
  `[seam][middle]concat=n=2:v=0:a=1,aresample=48000,volume=${gainDb.toFixed(2)}dB[out]`,
].join(';');
const outDir = join(process.cwd(), 'public/audio/music');
await mkdir(outDir, { recursive: true });
const output = join(outDir, `${cue}.mp3`);
const encode = spawnSync('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', '-i', source, '-filter_complex', filter, '-map', '[out]', '-c:a', 'libmp3lame', '-b:a', '160k', '-ar', '48000', output], { encoding: 'utf8' });
if (encode.status !== 0) throw new Error(encode.stderr || 'ffmpeg failed');
console.log(JSON.stringify({ cue, source, songId: metadata.songId, duration, loopSeconds: duration - overlap, inputI, inputTp, gainDb, output }));
