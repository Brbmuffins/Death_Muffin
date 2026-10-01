/**
 * build-clip-timings.mjs — measures every creature GLB once and writes src/content/clipTimings.json:
 * { <slug>: { <clip>: [durationSeconds, impactSeconds] } } for the one-shot clips whose timing matters
 * (attack*, cast, slam, sweep, flick, channel, summon). "Impact" is the peak hand-speed frame from
 * measure-clips.mjs. Creature.playStrike() uses it so a swing's impact lands when the sim's wind-up ends.
 *
 *   node tools/build-clip-timings.mjs
 *
 * Re-run after adding or regenerating a model. Rigs the measurer cannot read (quadrupeds without a Hip
 * bone) are listed and skipped; the runtime falls back to a fraction of the clip for them.
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { measureFile } from './measure-clips.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, '..');
const models = path.join(root, 'public/models');
const TIMED = /^(attack\d?|cast\d?|slam|sweep|flick|channel|summon)$/;

const out = {};
const skipped = [];
for (const slug of fs.readdirSync(models).sort()) {
  const file = path.join(models, slug, 'character.glb');
  if (!fs.existsSync(file)) continue;
  try {
    const clips = {};
    for (const c of await measureFile(file)) if (TIMED.test(c.name)) clips[c.name] = [c.dur, c.peakAt];
    if (Object.keys(clips).length) out[slug] = clips;
  } catch (err) {
    skipped.push(`${slug} (${err.message.split(': ').pop()})`);
  }
}
const dest = path.join(root, 'src/content/clipTimings.json');
fs.writeFileSync(dest, `{\n${Object.entries(out).map(([k, v]) => ` ${JSON.stringify(k)}: ${JSON.stringify(v)}`).join(',\n')}\n}\n`);
console.log(`clip timings: ${Object.keys(out).length} models -> ${path.relative(root, dest)}`);
if (skipped.length) console.log(`skipped: ${skipped.join(', ')}`);
