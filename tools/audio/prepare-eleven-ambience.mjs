#!/usr/bin/env node
// Encode short ElevenLabs environmental loops for the existing zone-bed mixer.
import { readdir, readFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { homedir } from 'node:os';
import { join } from 'node:path';

const cue = process.argv[2];
const recipes = {
  rain: { output: 'bed_rain.ogg', filter: 'volume=8dB,aformat=channel_layouts=mono,aresample=24000,alimiter=limit=0.6:attack=5:release=40:level=0' },
  fire: { output: 'bed_flame.ogg', filter: 'volume=4dB,aformat=channel_layouts=mono,aresample=24000,alimiter=limit=0.5:attack=5:release=40:level=0' },
};
if (!(cue in recipes) || process.argv.length !== 3) {
  console.error('Usage: node tools/audio/prepare-eleven-ambience.mjs <rain|fire>');
  process.exit(1);
}
const dir = join(homedir(), 'death-muffin/private/ambience-drafts');
const files = (await readdir(dir)).filter((name) => name.startsWith(`${cue}-`) && name.endsWith('.mp3')).sort();
if (!files.length) throw new Error(`No private ${cue} draft found`);
const source = join(dir, files.at(-1));
const metadata = JSON.parse(await readFile(source.replace(/\.mp3$/, '.json'), 'utf8'));
if (metadata.cue !== cue || metadata.request?.loop !== true) throw new Error(`Draft is not marked as a loop: ${source}`);
const output = join(process.cwd(), 'public/audio/ambience', recipes[cue].output);
const encode = spawnSync('ffmpeg', [
  '-hide_banner', '-loglevel', 'error', '-y', '-i', source,
  '-af', recipes[cue].filter, '-ac', '1', '-ar', '24000', '-c:a', 'libvorbis', '-q:a', '3', output,
], { encoding: 'utf8' });
if (encode.status !== 0) throw new Error(encode.stderr || 'ffmpeg failed');
console.log(JSON.stringify({ cue, source, output }));
