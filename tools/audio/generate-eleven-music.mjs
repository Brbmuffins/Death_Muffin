#!/usr/bin/env node
// Generate one private audition cue at a time. Never write API output to public/.
import { readFile, mkdir, stat, writeFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';

const KEY_FILE = join(homedir(), 'death-muffin/private/elevenlabs-api-key');
const OUT_DIR = join(homedir(), 'death-muffin/private/music-drafts');
const MODEL = 'music_v2_5';

const cues = {
  chapterhouse: {
    title: 'The Chapterhouse',
    durationMs: 75000,
    prompt: 'Original instrumental dark fantasy game score for a sanctuary inside a ruined monastery. Quiet, dignified, and faintly haunted. A low bowed cello motif, soft viola harmonics, sparse felt piano notes, distant wordless choir texture made only with instruments, and restrained low strings. Slow pulse, minor mode, memorable but understated theme. Leave generous space for dialogue, footsteps, and combat effects. No percussion, no vocals, no sudden loud climax. A gentle ending that can crossfade into the beginning.',
  },
  graves: {
    title: 'The Hollow Graves',
    durationMs: 90000,
    prompt: 'Original instrumental dark fantasy game exploration score for a windswept burial field at night. Lonely bowed strings, low woodwind, sparse hammered dulcimer, and a distant church bell color. A slow three-note motif, restrained harmonic movement, old stone and cold air. Quiet enough beneath footsteps and enemy sounds, with long pauses between phrases. No vocals, no full drum beat, no heroic fanfare, no sudden peak. End softly for crossfading.',
  },
  ossuary: {
    title: 'The Ossuary',
    durationMs: 90000,
    prompt: 'Original instrumental dark fantasy game exploration score for underground ossuary halls and flooded stone crypts. Muted cello and bass viol, distant low organ, sparse glassy chimes, and a slow descending motif. Ancient, reverent, unsettling, with long quiet spaces so footsteps, drips, and enemies remain clear. Very restrained percussion, no vocals, no dramatic climax, no imitation of an existing soundtrack. End softly for crossfading.',
  },
  pyre: {
    title: 'The Cinder Pyre',
    durationMs: 90000,
    prompt: 'Original instrumental dark fantasy game exploration score for an ash-covered ritual pyre. A dark orchestra of smoldering low strings, dry bowed textures, and sparse hammered metal, joined by distant sustained electric guitar notes with warm overdrive and long reverb. Patient minor-key motif, heat and danger held at a distance rather than constant action. Subtle low pulse, long pauses for combat sounds, no vocals, no loud cymbals, no heroic fanfare, no imitation of an existing soundtrack. A soft ending suitable for crossfading.',
  },
  boss: {
    title: 'Bell-Sworn Prelate',
    durationMs: 90000,
    prompt: 'Original instrumental dark fantasy boss battle score for a fallen bell keeper in a ruined cathedral. Dark orchestra and low-tuned overdriven electric guitar together: tense low strings, solemn brass, deep cello ostinato, tolling bronze bell accents, ritual frame drums, and measured guitar power chords that answer the orchestra. Clear rhythmic drive and a distinctive recurring four-note motif. Build in controlled stages, leaving room for combat cues and warning sounds. Dark and tragic rather than triumphant. No vocals, no modern synth lead, no imitation of an existing game soundtrack. Resolve with a short tail suitable for a crossfade.',
  },
};

const [cueId, ...flags] = process.argv.slice(2);
if (!cueId || cueId === '--list') {
  console.log('Cues:', Object.keys(cues).join(', '));
  console.log('Usage: node tools/audio/generate-eleven-music.mjs <cue> [--dry-run]');
  process.exit(cueId === '--list' ? 0 : 1);
}
if (!(cueId in cues) || flags.some((flag) => flag !== '--dry-run')) {
  console.error('Unknown cue or option. Use --list to see available cues.');
  process.exit(1);
}

const cue = cues[cueId];
const request = {
  prompt: cue.prompt,
  music_length_ms: cue.durationMs,
  model_id: MODEL,
  force_instrumental: true,
};
if (flags.includes('--dry-run')) {
  console.log(JSON.stringify({ cueId, title: cue.title, request, outputDir: OUT_DIR }, null, 2));
  process.exit(0);
}

let key = process.env.ELEVENLABS_API_KEY?.trim() || '';
if (!key) {
  const keyFileStat = await stat(KEY_FILE).catch(() => null);
  if (keyFileStat && (keyFileStat.mode & 0o077)) {
    throw new Error(`API key file is readable by other users. Run: chmod 600 ${KEY_FILE}`);
  }
  key = (await readFile(KEY_FILE, 'utf8').catch(() => '')).trim();
}
if (!key) {
  console.error(`ElevenLabs key missing. Set ELEVENLABS_API_KEY or put it in ${KEY_FILE} (mode 0600).`);
  process.exit(1);
}
if (!key.startsWith('sk_')) {
  console.error('The file contains an API key ID or other value, not the ElevenLabs secret API key (which starts with sk_). Replace the file with the secret shown when you create or rotate the key.');
  process.exit(1);
}

console.log(`Generating private draft: ${cue.title} (${cue.durationMs / 1000}s)...`);
const response = await fetch('https://api.elevenlabs.io/v1/music', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json', 'xi-api-key': key },
  body: JSON.stringify(request),
  signal: AbortSignal.timeout(360000),
});
if (!response.ok) {
  const detail = (await response.text()).slice(0, 800);
  throw new Error(`ElevenLabs HTTP ${response.status}: ${detail}`);
}
const contentType = response.headers.get('content-type') || '';
if (!contentType.startsWith('audio/') && !contentType.includes('octet-stream')) {
  throw new Error(`Unexpected content type: ${contentType}`);
}
const audio = Buffer.from(await response.arrayBuffer());
if (audio.length < 1024) throw new Error(`Unexpectedly small audio response: ${audio.length} bytes`);

await mkdir(OUT_DIR, { recursive: true, mode: 0o700 });
const stamp = new Date().toISOString().replaceAll(':', '-').replaceAll('.', '-');
const base = join(OUT_DIR, `${cueId}-${stamp}`);
await writeFile(`${base}.mp3`, audio, { flag: 'wx', mode: 0o600 });
await writeFile(`${base}.json`, JSON.stringify({
  cueId,
  title: cue.title,
  generatedAt: new Date().toISOString(),
  songId: response.headers.get('song-id'),
  contentType,
  bytes: audio.length,
  request,
  status: 'private-audition-only',
}, null, 2) + '\n', { flag: 'wx', mode: 0o600 });
console.log(`Saved private draft: ${base}.mp3 (${audio.length} bytes)`);
