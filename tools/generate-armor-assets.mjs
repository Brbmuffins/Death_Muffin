/** Generate matching vector inventory icons and the additive server item migration. */
import { readFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';

const root = resolve(import.meta.dirname, '..');
// Bundle (armorSets imports legendarySets) so the data: URL import below is self-contained.
const { build } = await import('esbuild');
const js = (await build({ entryPoints: [resolve(root, 'src/content/armorSets.ts')], bundle: true, write: false, format: 'esm', platform: 'node' })).outputFiles[0].text;
const { ARMOR_PIECES } = await import(`data:text/javascript,${encodeURIComponent(js)}`);
const outDir = resolve(root, 'public/art/items');
mkdirSync(outDir, { recursive: true });

const shapes = {
  head: '<path d="M28 71V53a36 36 0 0 1 72 0v18l-12 5V57H40v19z"/><path d="M25 75h78v10H25z"/>',
  chest: '<path d="m44 23 20 9 20-9 24 15-9 21-11-6v48H40V53l-11 6-9-21z"/><path d="M64 33v67" fill="none"/>',
  hands: '<path d="m21 34 13-5 10 11 9-9 10 9-4 27-14 30-18-5-5-32z"/><path d="m72 40 10-9 9 9 10-11 13 5-1 26-5 32-18 5-14-30z"/>',
  legs: '<path d="M33 23h62l-5 35-10 45H61l-4-39-4 39H34L24 58z"/><path d="M57 36v29" fill="none"/>',
  feet: '<path d="M25 39h28v35l13 12-3 15H17V87l8-14z"/><path d="M75 39h28v34l8 14v14H65l-3-15 13-12z"/>',
};
const hex = (n) => `#${n.toString(16).padStart(6, '0')}`;
const quote = (s) => `'${String(s).replaceAll("'", "''")}'`;

for (const p of ARMOR_PIECES) {
  const dark = '#17151f';
  const legendaryFrame = p.collection === 3 ? `<rect x="5" y="5" width="118" height="118" rx="15" fill="none" stroke="#ff9a2e" stroke-width="3"/><rect x="10" y="10" width="108" height="108" rx="12" fill="none" stroke="${hex(p.accent)}" stroke-width="1.5" opacity=".8"/><path d="m64 5 9 11-9 11-9-11z" fill="#ff9a2e"/><path d="M30 113h68" stroke="#ff9a2e" stroke-width="3"/>` : '';
  const ascendedFrame = p.collection === 2 ? `<rect x="7" y="7" width="114" height="114" rx="14" fill="none" stroke="${hex(p.accent)}" stroke-width="2" opacity=".9"/><path d="m64 8 8 10-8 10-8-10z" fill="${hex(p.accent)}"/><path d="M34 112h60" stroke="${hex(p.accent)}" stroke-width="2"/>` : '';
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="128" height="128" viewBox="0 0 128 128"><defs><radialGradient id="bg"><stop stop-color="${hex(p.color)}" stop-opacity=".34"/><stop offset="1" stop-color="${dark}"/></radialGradient><linearGradient id="metal" x2="1" y2="1"><stop stop-color="${hex(p.accent)}"/><stop offset=".48" stop-color="${hex(p.color)}"/><stop offset="1" stop-color="${dark}"/></linearGradient></defs><rect width="128" height="128" rx="17" fill="url(#bg)"/><path d="M12 19h21M95 19h21M12 109h21M95 109h21" stroke="${hex(p.accent)}" stroke-width="3" opacity=".8"/>${ascendedFrame}${legendaryFrame}<g fill="url(#metal)" stroke="${hex(p.accent)}" stroke-width="3" stroke-linejoin="round">${shapes[p.part]}</g><circle cx="64" cy="58" r="7" fill="${hex(p.accent)}" stroke="${dark}" stroke-width="2"/></svg>`;
  writeFileSync(resolve(outDir, `${p.id}.svg`), `${svg}\n`);
}

for (const [collection, filename, label] of [
  [1, '011-class-armor.sql', 'Nine discipline-themed armor sets'],
  [2, '012-ascended-armor.sql', 'Nine ascended discipline armor sets'],
  [3, '025-legendary-sets.sql', 'Four legendary armor sets (20 pieces)'],
]) {
  const rows = ARMOR_PIECES.filter((p) => p.collection === collection).map((p) => `  (${[
    p.id, p.name, p.rarity, p.type, p.part, 0, JSON.stringify(p.stats), `art/items/${p.id}.svg`, p.sell, 0, 0, 1,
  ].map((v) => typeof v === 'number' ? String(v) : quote(v)).join(', ')})`);
  const note = collection === 3 ? `-- BEFORE APPLYING: run SHOW COLUMNS FROM items LIKE 'rarity'. The server already accepts 'legendary' (server.js validRarities); if the column is an\n-- ENUM without it, widen it first (ALTER TABLE items MODIFY rarity ENUM(...existing values..., 'legendary')). A VARCHAR needs nothing.\n` : '';
  const sql = `-- ${label}; additive and safe to rerun.\n${note}-- Apply to the Death Muffin database after a backup, before publishing the client.\nINSERT IGNORE INTO items\n  (id, name, rarity, item_type, equipment_slot, two_handed, stat_bonus, icon_id, sell_value, crafted, stackable, max_stack_size)\nVALUES\n${rows.join(',\n')};\n`;
  writeFileSync(resolve(root, `server/death-muffin/backend/migrations/${filename}`), sql);
}
console.log(`Generated ${ARMOR_PIECES.length} icons and three armor migrations.`);
