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
    // Quadruped rigs with a Blender recipe: the recipe names the paws, so those are the feet (the generic guess picks leaf
    // bones that are not feet on the Tripo quadrupeds). Mesh-contact numbers for the same legs are reported by measure-clips --stride.
    const recipeFile = path.join(here, 'blender', 'recipes', `${slug}.json`);
    const recipe = fs.existsSync(recipeFile) ? JSON.parse(fs.readFileSync(recipeFile, 'utf8')) : null;
    const feet = recipe && Object.keys(recipe.legs).length ? Object.values(recipe.legs).map((l) => l.paw) : null;
    for (const clip of ['walk', 'run']) {
      // A rig with no legs to measure (a flier's flap loop) states its pace in the recipe: body heights per second.
      if (recipe?.stride?.[clip]) { row[clip] = recipe.stride[clip]; continue; }
      const s = await strideOfClip(file, clip, { feet });
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
// In-engine measurements win over the clip-derived numbers (see tools/stride-overrides.json).
const overridesFile = path.join(here, 'stride-overrides.json');
if (fs.existsSync(overridesFile)) {
  for (const [slug, row] of Object.entries(JSON.parse(fs.readFileSync(overridesFile, 'utf8')))) {
    if (slug.startsWith('_') || !out[slug]) continue;
    log.push(`${slug.padEnd(28)} override ${JSON.stringify(row)} (was ${JSON.stringify(out[slug])})`);
    out[slug] = { ...out[slug], ...row };
  }
}
const dest = path.join(root, 'src/content/strideSpeeds.json');
fs.writeFileSync(dest, `{\n${Object.entries(out).map(([k, v]) => ` ${JSON.stringify(k)}: ${JSON.stringify(v)}`).join(',\n')}\n}\n`);
console.log(log.join('\n'));
console.log(`stride speeds: ${Object.keys(out).length} models -> ${path.relative(root, dest)}`);
