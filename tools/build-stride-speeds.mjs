/**
 * build-stride-speeds.mjs — measures how fast each creature's walk / run clip actually travels over the ground and
 * writes src/content/strideSpeeds.json: { <slug>: { walk: n, run: n } } where n is body-heights per second (the
 * planted feet's speed relative to the body, divided by the model's bind-pose height). The runtime multiplies by the
 * model's world height, so a scaled elite or boss strides at the right pace too (Creature.strideSpeed).
 *
 *   node tools/build-stride-speeds.mjs
 *
 * Re-run after adding or regenerating a model. Replaces the hand-guessed WALK_SPEED table in EntityViews.
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { bindHeight, strideOfClip } from './measure-clips.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, '..');
const models = path.join(root, 'public/models');

const out = {};
const log = [];
for (const slug of fs.readdirSync(models).sort()) {
  const file = path.join(models, slug, 'character.glb');
  if (!fs.existsSync(file)) continue;
  try {
    const h = await bindHeight(file);
    const row = {};
    for (const clip of ['walk', 'run']) {
      const s = await strideOfClip(file, clip);
      if (s && s.speed > 0.01) row[clip] = +(s.speed / h).toFixed(3);
    }
    if (Object.keys(row).length) {
      out[slug] = row;
      log.push(`${slug.padEnd(28)} h=${h.toFixed(2)} ${Object.entries(row).map(([k, v]) => `${k} ${v}/s`).join('  ')}`);
    }
  } catch (err) {
    log.push(`${slug}: skipped (${err.message})`);
  }
}
const dest = path.join(root, 'src/content/strideSpeeds.json');
fs.writeFileSync(dest, `{\n${Object.entries(out).map(([k, v]) => ` ${JSON.stringify(k)}: ${JSON.stringify(v)}`).join(',\n')}\n}\n`);
console.log(log.join('\n'));
console.log(`stride speeds: ${Object.keys(out).length} models -> ${path.relative(root, dest)}`);
