/**
 * Death Muffin -> Godot: the model table the entity/avatar/boss views need (every CREATURE_MODELS slug: url, height, yaw, clips,
 * measured clip timings, stride speeds). godot/data/slice/enemies.json only carries the enemy/boss models; thralls, legions, the
 * Bone Colossus and every hero need rows too. Output: godot/game/view_models.json. Run: npx vite-node tools/godot/export-view-models.ts
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { CREATURE_MODELS } from '../../src/graphics/modelPaths';
import { STRIDES } from '../../src/graphics/locomotion';
import CLIP_TIMINGS from '../../src/content/clipTimings.json';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const glbJson = (url: string) => {
  const d = readFileSync(resolve(ROOT, 'public', url));
  const len = d.readUInt32LE(12);
  return JSON.parse(d.subarray(20, 20 + len).toString('utf8'));
};
/** Same rule as Creature.ts / export-slice.ts: heroes -90deg; a biped (has a Hip bone) -90deg; named overrides; else 0. */
const RIG_YAW: Record<string, number> = { bone_hound: Math.PI, cinderhound: Math.PI };
const out: Record<string, unknown> = {};
for (const [slug, m] of Object.entries(CREATURE_MODELS)) {
  const rigged = m.url.endsWith('/character.glb');
  const j = glbJson(m.url);
  const hero = slug === 'necromancer' || slug.startsWith('hero_');
  const yaw = !rigged ? 0 : hero ? -Math.PI / 2 : RIG_YAW[slug] ?? ((j.nodes ?? []).some((n: { name?: string }) => n.name === 'Hip') ? -Math.PI / 2 : 0);
  out[slug] = {
    slug, url: m.url, height: m.height, rigged, yaw,
    clips: (j.animations ?? []).map((a: { name: string }) => a.name),
    timings: (CLIP_TIMINGS as Record<string, unknown>)[slug] ?? {},
    stride: (STRIDES as Record<string, unknown>)[slug] ?? null,
  };
}
writeFileSync(resolve(ROOT, 'godot/game/view_models.json'), JSON.stringify(out) + '\n');
console.log(`wrote ${Object.keys(out).length} model rows -> godot/game/view_models.json`);
