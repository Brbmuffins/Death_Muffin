// Bakes the web game's procedural FX sprites (src/graphics/fxTextures.ts, canvas-drawn) to godot/assets/fx/tex/*.png so the Godot
// port uses the exact same pixels, and copies the generated sprites (public/art/fx/*.webp) to godot/assets/fx/art/.
// Run under the renderer lock:  flock -w 900 /home/ubuntu/death-muffin/qa-browser.lock node tools/godot/fx-textures.mjs
import { copyFileSync, mkdirSync, readdirSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { build } from 'esbuild';

const require = createRequire('/home/ubuntu/.npm/_npx/e41f203b7505f1fb/node_modules/');
const { chromium } = require('playwright');

const OUT = 'godot/assets/fx';
mkdirSync(`${OUT}/tex`, { recursive: true });
mkdirSync(`${OUT}/art`, { recursive: true });
for (const f of readdirSync('public/art/fx')) copyFileSync(`public/art/fx/${f}`, `${OUT}/art/${f}`);

const bundle = await build({ entryPoints: ['src/graphics/fxTextures.ts'], bundle: true, format: 'iife', globalName: 'FXT', write: false, platform: 'browser' });
const browser = await chromium.launch({ executablePath: '/home/ubuntu/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome', args: ['--use-angle=swiftshader'] });
const page = await browser.newPage();
await page.setContent('<html><body></body></html>');
await page.addScriptTag({ content: bundle.outputFiles[0].text });
const names = ['glow', 'ring', 'disc', 'sigil', 'cone', 'coneEdge', 'bar', 'smoke', 'spark', 'cracks', 'lightPool'];
for (const n of names) {
  const url = await page.evaluate((k) => FXT.fx[k]().image.toDataURL('image/png'), n);
  writeFileSync(`${OUT}/tex/${n}.png`, Buffer.from(url.split(',')[1], 'base64'));
}
await browser.close();
console.log(`fx-textures: ${names.length} procedural sprites, ${readdirSync('public/art/fx').length} generated sprites`);
