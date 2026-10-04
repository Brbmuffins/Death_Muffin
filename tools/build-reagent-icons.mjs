/**
 * Draws the inventory icons for the reagents, zone herbs, seeds, boss ichors and the new brews (content/reagents.ts) as small
 * SVGs in the armor-set style (128x128, radial backdrop, corner ticks) into public/art/items/<id>.svg. Hand-drawn and
 * deterministic: no generation credits. Re-run after adding a reagent: node tools/build-reagent-icons.mjs
 *   node tools/build-reagent-icons.mjs --check  (exit 1 if an icon is missing or stale)
 */
import { build } from 'esbuild';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const OUTDIR = join(root, 'public/art/items');

async function load() {
  const res = await build({ entryPoints: [join(root, 'src/content/reagents.ts')], bundle: true, platform: 'node', format: 'esm', write: false });
  return import('data:text/javascript;base64,' + Buffer.from(res.outputFiles[0].text).toString('base64'));
}

const hex = (n) => '#' + n.toString(16).padStart(6, '0');
/** Colour families: [light, mid, dark]. */
const P = {
  dust: ['#e6dcc2', '#b89a5a', '#3a3020'],
  ecto: ['#dce8ff', '#8fb4ff', '#1c2540'],
  bile: ['#d6f06a', '#7fa05a', '#1d2a14'],
  ash: ['#d8d2cc', '#8a7d76', '#2a1614'],
  ember: ['#ffc45a', '#ff7a2a', '#3a1608'],
  rot: ['#e2efa8', '#a8c23a', '#232d12'],
  earth: ['#c9a27a', '#6a4a30', '#20160e'],
  bone: ['#f1e9d6', '#cfc8b8', '#3a342a'],
  water: ['#bfe0ff', '#4f86c8', '#10203a'],
  bell: ['#f0cf86', '#d9a441', '#3a2a10'],
};

const shell = (accent, inner) =>
  `<svg xmlns="http://www.w3.org/2000/svg" width="128" height="128" viewBox="0 0 128 128"><defs><radialGradient id="bg"><stop stop-color="${accent[1]}" stop-opacity=".30"/><stop offset="1" stop-color="#17151f"/></radialGradient><linearGradient id="m" x2="1" y2="1"><stop stop-color="${accent[0]}"/><stop offset=".5" stop-color="${accent[1]}"/><stop offset="1" stop-color="${accent[2]}"/></linearGradient></defs><rect width="128" height="128" rx="17" fill="url(#bg)"/><path d="M12 19h21M95 19h21M12 109h21M95 109h21" stroke="${accent[0]}" stroke-width="3" opacity=".7"/>${inner}</svg>\n`;

const stroke = (a) => `stroke="${a[0]}" stroke-width="3" stroke-linejoin="round" stroke-linecap="round"`;

const dot = (a, x, y, r) => `<circle cx="${x}" cy="${y}" r="${r}" fill="${a[0]}" opacity=".9"/>`;

const DRAW = {
  dust: (a) => `<path d="M26 92c10-30 24-44 38-44s28 14 38 44z" fill="url(#m)" ${stroke(a)}/>${[[52, 70, 3], [70, 62, 2.5], [62, 82, 3.5], [84, 82, 2.5], [44, 86, 2.5], [74, 74, 2]].map(([x, y, r]) => dot(a, x, y, r)).join('')}<path d="M20 96h88" ${stroke(a)}/>`,
  ecto: (a) => `<path d="M64 22c22 22 30 38 22 54-6 12-14 18-22 18s-16-6-22-18c-8-16 0-32 22-54z" fill="url(#m)" ${stroke(a)} opacity=".95"/><path d="M52 62c6 6 18 6 24 0M54 76c5 4 15 4 20 0" stroke="${a[2]}" stroke-width="3" fill="none" stroke-linecap="round"/>${dot(a, 56, 50, 3)}${dot(a, 72, 44, 2)}<path d="M38 100c8 6 14-6 26 0s18-6 26 0" stroke="${a[0]}" stroke-width="3" fill="none" stroke-linecap="round" opacity=".7"/>`,
  bile: (a) => `<path d="M54 24h20v14l14 22a26 26 0 1 1-48 0l14-22z" fill="url(#m)" ${stroke(a)}/><path d="M50 72c8 6 20 6 28 0" stroke="${a[2]}" stroke-width="3" fill="none"/>${dot(a, 58, 82, 3)}${dot(a, 72, 76, 2.5)}<path d="M50 24h28" ${stroke(a)}/>`,
  ash: (a) => `<path d="M24 96l14-26 16 10 10-34 14 28 14-14 12 36z" fill="url(#m)" ${stroke(a)}/><path d="M56 88c4-12 12-12 16 0z" fill="#ff7a2a" stroke="#ffc45a" stroke-width="2"/>${dot(['#ffc45a'], 40, 60, 2)}${dot(['#ffc45a'], 88, 54, 2.5)}${dot(['#ffc45a'], 64, 44, 2)}`,
  rotcap: (a) => `<path d="M26 66c0-22 17-38 38-38s38 16 38 38z" fill="url(#m)" ${stroke(a)}/><path d="M54 66h20l-3 30H57z" fill="${a[1]}" stroke="${a[0]}" stroke-width="3" stroke-linejoin="round"/>${dot(a, 48, 50, 4)}${dot(a, 70, 44, 3)}${dot(a, 82, 56, 3.5)}<path d="M40 100h48" ${stroke(a)}/>`,
  seed_rotcap: (a) => `<path d="M40 60c0-14 10-24 24-24s24 10 24 24z" fill="url(#m)" ${stroke(a)}/><path d="M58 60h12l-2 14H60z" fill="${a[1]}" stroke="${a[0]}" stroke-width="2" stroke-linejoin="round"/>${[[36, 96], [56, 102], [78, 98], [94, 92]].map(([x, y]) => `<ellipse cx="${x}" cy="${y}" rx="7" ry="4.5" fill="${a[1]}" stroke="${a[0]}" stroke-width="2.5" transform="rotate(-20 ${x} ${y})"/>`).join('')}`,
  ashbloom: (a) => `<path d="M64 100V66" stroke="${a[0]}" stroke-width="4" stroke-linecap="round"/><path d="M64 88c-14 0-22-6-26-14 10-2 20 2 26 10zM64 82c14 0 22-6 26-14-10-2-20 2-26 10z" fill="${a[2]}" stroke="${a[0]}" stroke-width="2.5"/><g fill="url(#m)" stroke="#ffc45a" stroke-width="2.5" stroke-linejoin="round"><path d="M64 66c-8-10-8-22 0-32 8 10 8 22 0 32z"/><path d="M64 66c-12-4-20-12-22-24 12 0 22 8 22 24z"/><path d="M64 66c12-4 20-12 22-24-12 0-22 8-22 24z"/></g><circle cx="64" cy="64" r="5" fill="#ffc45a"/>`,
  seed_ashbloom: (a) => `<g fill="url(#m)" stroke="#ffc45a" stroke-width="2.5" stroke-linejoin="round"><path d="M64 60c-6-8-6-16 0-24 6 8 6 16 0 24z"/><path d="M64 60c-10-3-16-9-18-18 10 0 18 6 18 18z"/><path d="M64 60c10-3 16-9 18-18-10 0-18 6-18 18z"/></g>${[[36, 94], [56, 100], [78, 96], [94, 90]].map(([x, y]) => `<ellipse cx="${x}" cy="${y}" rx="7" ry="4.5" fill="${a[2]}" stroke="#ffc45a" stroke-width="2.5" transform="rotate(-20 ${x} ${y})"/>`).join('')}`,
  ichor: (a) => `<path d="M52 20h24v12l-4 8v10c14 6 22 18 22 32 0 16-14 26-30 26S34 98 34 82c0-14 8-26 22-32V40l-4-8z" fill="${a[2]}" stroke="${a[0]}" stroke-width="3" stroke-linejoin="round"/><path d="M40 82c0 12 10 20 24 20s24-8 24-20c0-6-2-10-6-14H46c-4 4-6 8-6 14z" fill="url(#m)"/><path d="M64 58c7 8 11 13 11 18a11 11 0 0 1-22 0c0-5 4-10 11-18z" fill="${a[0]}" opacity=".9"/><path d="M52 20h24" ${stroke(a)}/>`,
  flask: (a, tall) => tall
    ? `<path d="M56 20h16v10l-2 4v40a14 14 0 0 1-12 0V34l-2-4z" fill="${a[2]}" stroke="${a[0]}" stroke-width="3" stroke-linejoin="round"/><path d="M57 54h14v22a12 12 0 0 1-14 0z" fill="url(#m)"/><path d="M52 20h24" ${stroke(a)}/><path d="M50 104h28" ${stroke(a)}/>`
    : `<path d="M54 22h20v16l18 26c6 8 6 18 0 26-5 7-14 10-28 10s-23-3-28-10c-6-8-6-18 0-26l18-26z" transform="translate(0 0)" fill="${a[2]}" stroke="${a[0]}" stroke-width="3" stroke-linejoin="round"/><path d="M36 82c-2 8 2 14 8 18 6 4 14 4 20 4s14 0 20-4c6-4 10-10 8-18-8 4-14 2-22 2s-22 2-34-2z" fill="url(#m)"/><path d="M50 22h28" ${stroke(a)}/>`,
};

/** A small mark over a flask body, per effect family. */
const MARK = {
  flask_tonic_dust: ['dust', true, (a) => `${dot(a, 62, 62, 2)}${dot(a, 66, 68, 2)}${dot(a, 62, 72, 2)}`],
  flask_haste: ['ecto', false, (a) => `<path d="M58 60l10-8-2 10h8l-12 12 3-10z" fill="${a[0]}"/>`],
  flask_fortune: ['bell', true, (a) => `<path d="M64 58l3 6 7 1-5 5 1 7-6-3-6 3 1-7-5-5 7-1z" fill="${a[0]}" transform="scale(.6) translate(42 34)"/>`],
  flask_wisdom: ['ecto', true, (a) => `<circle cx="64" cy="66" r="4" fill="${a[0]}"/>`],
  flask_lifesteal: ['step', false, (a) => `<path d="M64 88c-14-10-18-18-14-24 4-5 10-3 14 3 4-6 10-8 14-3 4 6 0 14-14 24z" fill="${a[0]}" opacity=".85"/>`],
  flask_rotproof: ['rot', false, (a) => `<path d="M50 84c8-4 20-4 28 0M54 92c6-3 14-3 20 0" stroke="${a[0]}" stroke-width="3" fill="none" stroke-linecap="round"/>`],
  flask_cinderskin: ['ember', false, (a) => `<path d="M64 62c8 8 12 14 12 20a12 12 0 0 1-24 0c0-6 4-12 12-20z" fill="${a[0]}" opacity=".85"/>`],
  flask_ghostwalk: ['souls', true, (a) => `<path d="M58 60c4 4 8 4 12 0" stroke="${a[0]}" stroke-width="2.5" fill="none"/>`],
  flask_bloodmoon: ['step', false, (a) => `<circle cx="64" cy="82" r="11" fill="${a[0]}" opacity=".85"/><circle cx="69" cy="80" r="9" fill="${a[2]}"/>`],
  flask_hymnal: ['water', false, (a) => `<path d="M64 66v26M55 75h18" stroke="${a[0]}" stroke-width="4" stroke-linecap="round"/>`],
  flask_regent: ['bell', false, (a) => `<path d="M50 88l4-14 6 8 4-12 4 12 6-8 4 14z" fill="${a[0]}" opacity=".9"/>`],
};
P.step = ['#f2a0a8', '#c23a48', '#3a1218'];
P.souls = ['#c8fff0', '#6fe3c8', '#0f3a36'];

P.mire = ['#c8f0d8', '#4fae8a', '#0e2a24'];
// Pet charms: a cord and a gem-set pendant, one gem colour per pet (cosmetics.ts PETS).
P.charm_bat = ['#d9c4ff', '#8a5ad0', '#1e1236'];
P.charm_rat = ['#e8d6c0', '#9a7a58', '#2a1e12'];
P.charm_pup = ['#c4ecf4', '#58a8c0', '#10283a'];
P.charm_thrall = ['#f1e9d6', '#cfc8b8', '#3a342a'];
P.charm_moth = ['#e6f0c8', '#a8c46a', '#26301a'];
DRAW.charm = (a) => `<path d="M40 22c0 22 10 30 24 30s24-8 24-30" fill="none" stroke="${a[0]}" stroke-width="3" stroke-linecap="round" opacity=".8"/><path d="M64 52l22 18-8 28H50l-8-28z" fill="url(#m)" ${stroke(a)}/><path d="M64 62l10 8-4 14H58l-4-14z" fill="${a[2]}" opacity=".55"/>${dot(a, 58, 68, 2.5)}<circle cx="64" cy="44" r="4" fill="none" stroke="${a[0]}" stroke-width="3"/>`;
const EXTRA = { ichor_mire: 'ichor_mire', charm_tithe_bat: 'charm_bat', charm_grave_rat: 'charm_rat', charm_drowned_pup: 'charm_pup', charm_wee_thrall: 'charm_thrall', charm_shroud_moth: 'charm_moth' };

const ICHOR_PALETTE = { ichor_earth: 'earth', ichor_bone: 'bone', ichor_water: 'water', ichor_bell: 'bell', ichor_rot: 'rot', ichor_fire: 'ember', ichor_mire: 'mire' };

export function drawIcon(art, brewColor) {
  if (MARK[art]) {
    const [fam, tall, mark] = MARK[art];
    const a = art === 'flask_tonic_dust' ? P.dust : P[fam];
    const body = DRAW.flask(a, tall) + mark(a);
    return shell(a, tall ? `<g transform="translate(-25.6 -24.8) scale(1.4)">${body}</g>` : body);
  }
  if (art.startsWith('charm_')) return shell(P[art], DRAW.charm(P[art]));
  if (ICHOR_PALETTE[art]) return shell(P[ICHOR_PALETTE[art]], DRAW.ichor(P[ICHOR_PALETTE[art]]));
  const fam = { dust: 'dust', ecto: 'ecto', bile: 'bile', ash: 'ash', rotcap: 'rot', seed_rotcap: 'rot', ashbloom: 'ember', seed_ashbloom: 'ember' }[art];
  return shell(P[fam], DRAW[art](P[fam]));
}

const { REAGENT_ITEMS, REAGENT_BREW_ITEMS } = await load();
const all = [...Object.entries(REAGENT_ITEMS), ...Object.entries(REAGENT_BREW_ITEMS), ...Object.entries(EXTRA).map(([id, art]) => [id, { art }])];
let bad = 0;
for (const [id, it] of all) {
  const svg = drawIcon(it.art);
  const file = join(OUTDIR, `${id}.svg`);
  if (process.argv.includes('--check')) {
    if (!existsSync(file) || readFileSync(file, 'utf8') !== svg) { console.error(`stale or missing: ${file}`); bad++; }
  } else writeFileSync(file, svg);
}
if (process.argv.includes('--check')) { if (bad) process.exit(1); console.log(`${all.length} reagent icons up to date`); }
else console.log(`wrote ${all.length} icons to ${OUTDIR}`);
