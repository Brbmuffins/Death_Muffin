// Writes the HUD chrome glyphs of src/ui/icons.ts as stand-alone SVGs (stroke = bone-300) under godot/ui/hud/art/icons/.
// run from the repo root:  npx vite-node godot/ui/hud/tools/gen_icons.mjs
import { ICON } from '../../../../src/ui/icons';
import { mkdirSync, writeFileSync } from 'node:fs';
const dir = 'godot/ui/hud/art/icons';
mkdirSync(dir, { recursive: true });
for (const [k, v] of Object.entries(ICON)) {
  writeFileSync(`${dir}/${k}.svg`, String(v).replace(/currentColor/g, '#d8cfbd').replace('<svg ', '<svg xmlns="http://www.w3.org/2000/svg" width="48" height="48" '));
}
console.log('icons', Object.keys(ICON).length);
