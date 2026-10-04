#!/usr/bin/env node
// Generate private, seamless environmental loops with ElevenLabs Sound Effects v2.
import { readFile, mkdir, stat, writeFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';

const prompts = {
  rain: 'Steady cold rainfall in a deserted graveyard and marsh. Soft individual drops on stone, wet earth, and shallow puddles with a low broad rain wash. Natural outdoor space, no thunder, wind, music, voices, animals, or footsteps. Consistent texture for a seamless ambient loop.',
  fire: 'Large ritual pyre burning steadily outdoors. Layered low flame roar, intimate dry wood crackles, occasional small ember pops. Natural fire only, no explosions, wind, music, voices, or footsteps. Consistent texture for a seamless ambient loop.',
};
const cue = process.argv[2];
if (!(cue in prompts) || process.argv.slice(3).some((arg) => arg !== '--dry-run')) {
  console.error(`Usage: node tools/audio/generate-eleven-ambience.mjs <${Object.keys(prompts).join('|')}> [--dry-run]`);
  process.exit(1);
}
const request = { text: prompts[cue], loop: true, duration_seconds: 20, model_id: 'eleven_text_to_sound_v2', prompt_influence: 0.45 };
if (process.argv.includes('--dry-run')) {
  console.log(JSON.stringify({ cue, request }, null, 2));
  process.exit(0);
}
const keyFile = join(homedir(), 'death-muffin/private/elevenlabs-api-key');
let key = process.env.ELEVENLABS_API_KEY?.trim() || '';
if (!key) {
  const info = await stat(keyFile);
  if (info.mode & 0o077) throw new Error(`API key file must have mode 0600: ${keyFile}`);
  key = (await readFile(keyFile, 'utf8')).trim();
}
if (!key.startsWith('sk_')) throw new Error('ElevenLabs secret API key must start with sk_');

console.log(`Generating private ${cue} loop...`);
const response = await fetch('https://api.elevenlabs.io/v1/sound-generation?output_format=mp3_44100_128', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json', 'xi-api-key': key },
  body: JSON.stringify(request),
  signal: AbortSignal.timeout(180000),
});
if (!response.ok) throw new Error(`ElevenLabs HTTP ${response.status}: ${(await response.text()).slice(0, 800)}`);
const contentType = response.headers.get('content-type') || '';
if (!contentType.startsWith('audio/') && !contentType.includes('octet-stream')) throw new Error(`Unexpected content type: ${contentType}`);
const audio = Buffer.from(await response.arrayBuffer());
if (audio.length < 1024) throw new Error(`Unexpectedly small audio response: ${audio.length} bytes`);
const dir = join(homedir(), 'death-muffin/private/ambience-drafts');
await mkdir(dir, { recursive: true, mode: 0o700 });
const stamp = new Date().toISOString().replaceAll(':', '-').replaceAll('.', '-');
const base = join(dir, `${cue}-${stamp}`);
await writeFile(`${base}.mp3`, audio, { flag: 'wx', mode: 0o600 });
await writeFile(`${base}.json`, JSON.stringify({ cue, generatedAt: new Date().toISOString(), request, bytes: audio.length, contentType }, null, 2) + '\n', { flag: 'wx', mode: 0o600 });
console.log(`Saved private loop: ${base}.mp3 (${audio.length} bytes)`);
