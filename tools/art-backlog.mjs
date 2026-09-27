/**
 * art-backlog.mjs — list generated art that no game code references yet (the "art ready, code
 * pending" roadmap in docs/ART-BACKLOG.md). A file counts as referenced when its public path
 * (`art/items/x.png`, `models/props/x.glb`) or, for GLBs, its model id appears as a string anywhere
 * in src/ or index.html, or when it is an item icon whose id is a known item (icons resolve by name).
 *
 *   node tools/art-backlog.mjs            print unreferenced files grouped by folder
 *   node tools/art-backlog.mjs --json     machine-readable
 */
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { dirname, join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const walk = (dir) => readdirSync(dir).flatMap((n) => {
  const p = join(dir, n);
  return statSync(p).isDirectory() ? walk(p) : [p];
});
// Only modules the game actually loads count: a data file nobody imports yet doesn't make its art "used".
const srcFiles = walk(join(ROOT, 'src')).filter((f) => /\.(ts|css)$/.test(f) && !/__tests__/.test(f));
const texts = new Map(srcFiles.map((f) => [f, readFileSync(f, 'utf8')]));
const loaded = srcFiles.filter((f) => {
  const name = f.replace(/\\/g, '/').split('/').pop().replace(/\.(ts|css)$/, '');
  if (name === 'main' || f.endsWith('.css')) return true;
  return [...texts].some(([other, t]) => other !== f && (t.includes(`/${name}'`) || t.includes(`/${name}.ts'`)));
});
const code = [...loaded.map((f) => texts.get(f)), readFileSync(join(ROOT, 'index.html'), 'utf8')].join('\n');

// Item icons also resolve by convention (InventoryPanel/LootView: `art/items/<id>.png`), so an
// icon is live as soon as its id is a known item in content/items.ts.
const itemIds = new Set([...readFileSync(join(ROOT, 'src', 'content', 'items.ts'), 'utf8').matchAll(/^ {2}([a-z0-9_]+): /gm)].map((m) => m[1]));

const assets = [...walk(join(ROOT, 'public', 'art')), ...walk(join(ROOT, 'public', 'models'))]
  .filter((f) => /\.(png|webp|jpg|glb)$/.test(f));
const pending = {};
for (const file of assets) {
  const rel = relative(join(ROOT, 'public'), file).replace(/\\/g, '/');
  // Model id: models/<slug>/character.glb → slug; models/props/<id>.glb → id.
  const id = rel.startsWith('models/props/') ? rel.slice('models/props/'.length, -4) : rel.startsWith('models/') ? rel.split('/')[1] : null;
  const item = rel.startsWith('art/items/') ? rel.slice('art/items/'.length).replace(/\.(png|webp)$/, '') : null;
  const used =
    code.includes(rel) ||
    (item !== null && itemIds.has(item)) ||
    (id !== null && (code.includes(`'${id}'`) || code.includes(`"${id}"`) || code.includes(`${id}:`)));
  if (used || rel.endsWith('clips.json')) continue;
  const group = rel.split('/').slice(0, -1).join('/');
  (pending[group] ??= []).push(rel.split('/').pop());
}
if (process.argv.includes('--json')) console.log(JSON.stringify(pending, null, 2));
else {
  let n = 0;
  for (const [group, files] of Object.entries(pending).sort()) {
    n += files.length;
    console.log(`\n${group} (${files.length})\n  ${files.sort().join('\n  ')}`);
  }
  console.log(`\n${n} files with no code reference yet.`);
}
