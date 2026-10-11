#!/usr/bin/env node
// Runner-only (never in the agent's allowed tools): generate ONE validated sound request with ElevenLabs, from the job's worktree.
// Env (set by the runner for this one child only): ELEVENLABS_API_KEY, DM_SOUND_SPEC (the canonical spec from runner/lib/sound.cjs).
// Writes audio-src/eleven/<id>/v<n>.mp3 (git-ignored raw takes) and prints, per take, `COST: <credits>` (ElevenLabs' character-cost header)
// and `FILE: <path>`, then `RESULT: ok|failed <why>`. A take that already exists is kept and not paid for again.
import { mkdir, writeFile, lstat } from 'node:fs/promises';
import { join } from 'node:path';

const key = process.env.ELEVENLABS_API_KEY || '';
const API = process.env.DM_ELEVEN_BASE || 'https://api.elevenlabs.io';   // tests point this at a local fake
let spec;
try { spec = JSON.parse(process.env.DM_SOUND_SPEC || ''); } catch { console.log('RESULT: failed no-spec'); process.exit(2); }
if (!key.startsWith('sk_')) { console.log('RESULT: failed no-key'); process.exit(2); }
if (!/^[a-z0-9_]{3,40}$/.test(spec.id || '') || !['sfx', 'music'].includes(spec.kind)) { console.log('RESULT: failed bad-spec'); process.exit(2); }

const noLink = async (p) => { try { if ((await lstat(p)).isSymbolicLink()) throw new Error(`${p} is a symlink`); } catch (e) { if (e.code !== 'ENOENT') throw e; } };
const dir = join('audio-src', 'eleven', spec.id);
for (const p of ['audio-src', 'audio-src/eleven', dir]) await noLink(p);
await mkdir(dir, { recursive: true });

const request = spec.kind === 'music'
  ? { url: `${API}/v1/music?output_format=mp3_44100_128`, body: { prompt: spec.prompt, music_length_ms: Math.round(spec.duration_seconds * 1000), model_id: 'music_v2_5', force_instrumental: true }, timeout: 360000 }
  : { url: `${API}/v1/sound-generation?output_format=mp3_44100_128`, body: { text: spec.prompt, duration_seconds: spec.duration_seconds, loop: !!spec.loop, prompt_influence: spec.prompt_influence, model_id: 'eleven_text_to_sound_v2' }, timeout: 180000 };

let failed = '';
for (let n = 1; n <= spec.variants; n++) {
  const rel = join(dir, `v${n}.mp3`);
  await noLink(rel);
  try { await lstat(rel); console.log(`FILE: ${rel}`); continue; } catch { /* not made yet */ }
  try {
    const res = await fetch(request.url, { method: 'POST', headers: { 'Content-Type': 'application/json', 'xi-api-key': key }, body: JSON.stringify(request.body), signal: AbortSignal.timeout(request.timeout) });
    const cost = res.headers.get('character-cost');
    if (cost && /^\d+(\.\d+)?$/.test(cost)) console.log(`COST: ${cost}`);
    if (!res.ok) { failed = `http-${res.status} ${(await res.text()).replace(/\s+/g, ' ').slice(0, 300)}`; break; }
    const audio = Buffer.from(await res.arrayBuffer());
    if (audio.length < 1024) { failed = 'tiny-response'; break; }
    await writeFile(rel, audio, { flag: 'wx' });
    console.log(`FILE: ${rel}`);
  } catch (e) { failed = `error ${String(e.message).slice(0, 200)}`; break; }
}
console.log(failed ? `RESULT: failed ${failed}` : 'RESULT: ok');
process.exit(failed ? 1 : 0);
