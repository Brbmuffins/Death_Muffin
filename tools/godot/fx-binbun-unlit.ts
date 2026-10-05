// Applies unlitHook (fx-binbun-hooks.ts) to the committed Binbun shaders in place: npx vite-node tools/godot/fx-binbun-unlit.ts
// (fx-binbun-rebuild.ts applies it on every rebuild; this is for the shaders already in godot/assets/fx/binbun/shaders).
import { readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { unlitHook } from './fx-binbun-hooks';

const DIR = 'godot/assets/fx/binbun/shaders';
let changed = 0;
for (const f of readdirSync(DIR)) {
  if (!f.endsWith('.gdshader')) continue;
  const src = readFileSync(`${DIR}/${f}`, 'utf8');
  const out = unlitHook(src);
  if (out !== src) {
    writeFileSync(`${DIR}/${f}`, out);
    changed++;
  }
}
console.log(`unlitHook: ${changed} shaders rewritten`);
