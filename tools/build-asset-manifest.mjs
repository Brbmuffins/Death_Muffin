// Writes <dist>/asset-manifest.json: every file the play build ships (hashed bundles + models/art/audio/fx), with sizes.
// Used only by public/precache.html (the Windows launcher's "update before play" step). Deterministic: sorted, no timestamps.
// Usage: node tools/build-asset-manifest.mjs [dist] [base]
import { readdir, stat, writeFile } from 'node:fs/promises';
import path from 'node:path';

const dir = path.resolve(process.argv[2] || 'dist');
const base = process.argv[3] || '/death-muffin/play/';
if (!base.startsWith('/') || !base.endsWith('/')) throw new Error('Base must be an absolute path ending in /');

// Entry pages and release markers change on every deploy and are not worth warming.
const SKIP = new Set(['index.html', 'precache.html', 'asset-manifest.json', 'release.txt', 'release-notes.json']);

async function walk(folder, prefix = '') {
  const out = [];
  for (const e of (await readdir(folder, { withFileTypes: true })).sort((a, b) => (a.name < b.name ? -1 : 1))) {
    const rel = prefix ? `${prefix}/${e.name}` : e.name;
    if (e.isDirectory()) out.push(...(await walk(path.join(folder, e.name), rel)));
    else if (e.isFile() && !SKIP.has(rel) && !rel.endsWith('.map')) out.push(rel);
  }
  return out;
}

const files = [];
let bytes = 0;
for (const rel of await walk(dir)) {
  const size = (await stat(path.join(dir, rel))).size;
  files.push([rel, size]);
  bytes += size;
}
await writeFile(path.join(dir, 'asset-manifest.json'), JSON.stringify({ base, count: files.length, bytes, files }));
console.log(`asset-manifest.json: ${files.length} files, ${(bytes / 1048576).toFixed(1)} MB`);
